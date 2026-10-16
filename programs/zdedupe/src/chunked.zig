//! Early-exit comparison of large same-size candidates
//!
//! A full hash reads every byte of every candidate before anything is known.
//! For a set of big files whose probes agree (same size, same prefix, same
//! samples) that can be hundreds of gigabytes, and most such sets still turn
//! out to differ: two disk images of one size, two builds of one archive.
//!
//! Here the members of one set are read side by side, a chunk at a time.
//! After each chunk the digest of everything read so far is compared across
//! the members; a member whose prefix matches no other's cannot be a
//! duplicate of anything in the set, so it is dropped and never read again.
//! A set that splits into two agreeing halves carries on as two. Members that
//! reach the end together get the digest of their whole content - the same
//! plain BLAKE3 / SHA-256 a full hash gives (holes fed as zeros, see
//! `hasher.feedRange`) - so grouping, reports and verification are unchanged.
//!
//! With BLAKE3 (`compareSetsByRanges`) every range of `chunk_size` is a whole
//! BLAKE3 subtree (blake3_tree.zig): a worker hashes one range of one member,
//! any worker takes any range, and the ranges' values combine into the plain
//! digest at the end. So a set of two huge files is read by every core, and
//! many sets share them. Ranges are taken in file order across all sets, so
//! the early ones are compared first; once every member still in a set has
//! hashed range r, a member whose value for r matches no other's is dropped.
//!
//! SHA-256 has no tree (`compareSetsInRounds`): one worker per set reads its
//! members a chunk at a time and compares the digest of everything read so
//! far, taken by finalizing a copy of each running hasher, so each byte is
//! hashed once.

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const blake3_tree = @import("blake3_tree.zig");
const fast_walker = @import("fast_walker.zig");
const libc = @import("sys.zig").c;

/// Files at least this big are compared chunk by chunk rather than hashed
/// independently.
pub const min_size: u64 = hasher.probe_sample_min;

/// Bytes read from each member before members are compared again.
pub const chunk_size: u64 = 64 * 1024 * 1024;

pub const Stats = struct {
    /// Members dropped before their end because no other member matched.
    dropped_early: u64 = 0,
};

/// Compare each set in `sets` (indices into `files`, every set of one size)
/// and give the members that turn out identical their full digest in
/// `FileEntry.hash`; the others are left without one. The work is spread over
/// `thread_count` workers.
pub fn compareSets(
    allocator: std.mem.Allocator,
    files: []types.FileEntry,
    sets: []const []const usize,
    algorithm: types.Config.HashAlgorithm,
    thread_count: u32,
    monitor: ?*types.Monitor,
) !Stats {
    return switch (algorithm) {
        .blake3 => compareSetsByRanges(allocator, files, sets, thread_count, monitor),
        .sha256 => compareSetsInRounds(allocator, files, sets, algorithm, thread_count, monitor),
    };
}

// --- BLAKE3: ranges on any worker -------------------------------------------

comptime {
    // A range must be a whole BLAKE3 subtree: a power of two of 1 KiB chunks.
    std.debug.assert(chunk_size % blake3_tree.chunk_len == 0 and std.math.isPowerOfTwo(chunk_size / blake3_tree.chunk_len));
}

/// One member of one set, as the range workers see it.
const Member = struct {
    file: usize,
    alive: std.atomic.Value(bool) = .init(true),
    /// Per range: the subtree's chaining value, or for the last range a
    /// digest of that range alone. Comparable between members of one set.
    values: []blake3_tree.Cv,
    /// Per range: hashed. Guarded by the set's lock.
    done: []bool,
    /// The last range's hasher, which the whole digest is finished from.
    tail: blake3_tree.Hasher = undefined,
    /// What is left of this member's share of the phase's bytes.
    budget_left: std.atomic.Value(u64),

    /// Count `n` bytes read toward the monitor, up to this member's share.
    fn credit(self: *Member, monitor: ?*types.Monitor, n: u64) void {
        var left = self.budget_left.load(.monotonic);
        while (true) {
            const take = @min(n, left);
            if (take == 0) return;
            left = self.budget_left.cmpxchgWeak(left, left - take, .monotonic, .monotonic) orelse {
                if (monitor) |m| m.addBytes(take);
                return;
            };
        }
    }

    /// Account for the rest of this member's share, however it ended.
    fn finishBudget(self: *Member, monitor: ?*types.Monitor) void {
        const rest = self.budget_left.swap(0, .monotonic);
        if (monitor) |m| if (rest > 0) m.addBytes(rest);
    }
};

const SetState = struct {
    members: []Member,
    /// Each member's whole digest, filled in when the set finishes.
    digests: [][blake3_tree.digest_length]u8,
    ranges: u32,
    lock: SpinLock = .{},
    /// Units of this set not yet finished; the worker finishing the last
    /// one finishes the set.
    units_left: std.atomic.Value(usize),
};

/// Held for a few comparisons at a time.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const Unit = struct { set: u32, member: u32, range: u32 };

const RangeShared = struct {
    files: []types.FileEntry,
    sets: []SetState,
    units: []const Unit,
    monitor: ?*types.Monitor,
    next: std.atomic.Value(usize) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),

    fn workerThread(self: *RangeShared, index: usize) void {
        // A file evicted to the cloud after the walk fails to read rather
        // than being downloaded (macOS; see fast_walker).
        _ = fast_walker.noMaterializeThisThread();
        self.work(index);
    }

    /// `index` names this worker's Monitor slot.
    fn work(self: *RangeShared, index: usize) void {
        while (true) {
            if (self.monitor) |m| if (m.cancelled()) return;
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.units.len) return;
            self.runUnit(self.units[i], index) catch return; // error.Cancelled
        }
    }

    fn runUnit(self: *RangeShared, unit: Unit, worker: usize) error{Cancelled}!void {
        const set = &self.sets[unit.set];
        defer self.unitDone(set);
        const member = &set.members[unit.member];
        if (!member.alive.load(.acquire)) return;
        const entry = &self.files[member.file];
        const start = @as(u64, unit.range) * chunk_size;
        const end = @min(entry.size, start + chunk_size);

        if (self.monitor) |m| m.begin(worker, entry.path);
        defer if (self.monitor) |m| m.end(worker);
        var h = blake3_tree.Hasher.init(start / blake3_tree.chunk_len);
        var read: hasher.Budget = .{ .monitor = null, .left = std.math.maxInt(u64) };
        const whole = readRange(&h, entry, start, end, self.monitor, &read) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            else => false, // unreadable now: no hash, as for a failed full hash
        };
        member.credit(self.monitor, std.math.maxInt(u64) - read.left);
        if (!whole) {
            member.alive.store(false, .release);
            member.finishBudget(self.monitor);
            return;
        }
        const last = unit.range + 1 == set.ranges;
        const value: blake3_tree.Cv = if (last) blk: {
            member.tail = h;
            break :blk std.mem.bytesToValue(blake3_tree.Cv, &h.final(&.{}));
        } else h.subtreeCv();

        set.lock.lock();
        defer set.lock.unlock();
        member.values[unit.range] = value;
        member.done[unit.range] = true;
        self.decide(set, unit.range);
    }

    /// Once every member still in `set` has hashed range `r`, drop those whose
    /// value for it matches no other's: they cannot be a copy of anything here.
    /// Called with the set's lock held.
    fn decide(self: *RangeShared, set: *SetState, r: u32) void {
        for (set.members) |*m| if (m.alive.load(.acquire) and !m.done[r]) return;
        for (set.members, 0..) |*m, i| {
            if (!m.alive.load(.acquire)) continue;
            const matched = for (set.members, 0..) |*o, j| {
                if (j != i and o.alive.load(.acquire) and std.mem.eql(u32, &o.values[r], &m.values[r])) break true;
            } else false;
            if (!matched) {
                m.alive.store(false, .release);
                m.finishBudget(self.monitor);
                if (r + 1 < set.ranges) _ = self.dropped.fetchAdd(1, .monotonic);
            }
        }
    }

    fn unitDone(self: *RangeShared, set: *SetState) void {
        if (set.units_left.fetchSub(1, .acq_rel) != 1) return;
        // Every unit of the set is finished: the members still in it get the
        // whole digest, if another member has the same one.
        for (set.members, set.digests) |*m, *d| {
            if (m.alive.load(.acquire)) d.* = m.tail.final(m.values[0 .. set.ranges - 1]);
        }
        for (set.members, set.digests, 0..) |*m, *d, i| {
            if (!m.alive.load(.acquire)) continue;
            const shared_digest = for (set.members, set.digests, 0..) |*o, *od, j| {
                if (j != i and o.alive.load(.acquire) and std.mem.eql(u8, d, od)) break true;
            } else false;
            if (shared_digest) self.files[m.file].hash = d.*;
        }
        for (set.members) |*m| m.finishBudget(self.monitor);
        if (self.monitor) |mon| _ = mon.done.fetchAdd(set.members.len, .release);
    }
};

/// Hash bytes [start, end) of `entry` into `h`. False if the file is no longer
/// the size the walk saw, or ended early.
fn readRange(h: *blake3_tree.Hasher, entry: *const types.FileEntry, start: u64, end: u64, monitor: ?*types.Monitor, read: *hasher.Budget) !bool {
    const fd = try hasher.openRegularFile(entry.path);
    defer _ = libc.close(fd);
    const st = @import("pstat.zig").fstat(fd) catch return false;
    if (st.size != entry.size) return false;
    return hasher.feedRange(blake3_tree.Hasher, h, fd, start, end, monitor, read);
}

fn compareSetsByRanges(
    allocator: std.mem.Allocator,
    files: []types.FileEntry,
    sets: []const []const usize,
    thread_count: u32,
    monitor: ?*types.Monitor,
) !Stats {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const states = try arena.alloc(SetState, sets.len);
    var unit_count: usize = 0;
    var max_ranges: u32 = 0;
    for (sets, states) |set, *state| {
        const size = files[set[0]].size;
        const ranges: u32 = @intCast(@max(1, std.math.divCeil(u64, size, chunk_size) catch unreachable));
        const members = try arena.alloc(Member, set.len);
        for (set, members) |idx, *m| {
            m.* = .{
                .file = idx,
                .values = try arena.alloc(blake3_tree.Cv, ranges),
                .done = try arena.alloc(bool, ranges),
                .budget_left = .init(files[idx].readBytes()),
            };
            @memset(m.done, false);
        }
        state.* = .{
            .members = members,
            .digests = try arena.alloc([blake3_tree.digest_length]u8, set.len),
            .ranges = ranges,
            .units_left = .init(set.len * ranges),
        };
        unit_count += set.len * ranges;
        max_ranges = @max(max_ranges, ranges);
    }
    // Range by range across every set: the first ranges, where most
    // differences show, are all hashed before any set's later ones.
    const units = try arena.alloc(Unit, unit_count);
    var u: usize = 0;
    for (0..max_ranges) |r| {
        for (states, 0..) |state, s| {
            if (r >= state.ranges) continue;
            for (0..state.members.len) |m| {
                units[u] = .{ .set = @intCast(s), .member = @intCast(m), .range = @intCast(r) };
                u += 1;
            }
        }
    }

    var shared: RangeShared = .{ .files = files, .sets = states, .units = units, .monitor = monitor };
    const workers: usize = @max(1, @min(thread_count, unit_count, types.Monitor.slot_count));
    const threads = try arena.alloc(std.Thread, workers);
    var started: usize = 0;
    for (threads, 0..) |*t, index| {
        t.* = std.Thread.spawn(.{}, RangeShared.workerThread, .{ &shared, index }) catch break;
        started += 1;
    }
    if (started == 0) {
        const previous = fast_walker.noMaterializeThisThread();
        defer fast_walker.restoreMaterialize(previous);
        shared.work(0);
    }
    for (threads[0..started]) |t| t.join();
    return .{ .dropped_early = shared.dropped.load(.acquire) };
}

// --- SHA-256: one worker per set, in rounds ----------------------------------

fn compareSetsInRounds(
    allocator: std.mem.Allocator,
    files: []types.FileEntry,
    sets: []const []const usize,
    algorithm: types.Config.HashAlgorithm,
    thread_count: u32,
    monitor: ?*types.Monitor,
) !Stats {
    var shared: Shared = .{ .files = files, .sets = sets, .algorithm = algorithm, .monitor = monitor, .allocator = allocator };
    const workers = @max(1, @min(thread_count, @as(u32, @intCast(sets.len))));
    if (workers == 1) {
        const previous = fast_walker.noMaterializeThisThread();
        defer fast_walker.restoreMaterialize(previous);
        shared.work(0);
    } else {
        const threads = try allocator.alloc(std.Thread, workers);
        defer allocator.free(threads);
        var started: usize = 0;
        for (threads, 0..) |*t, index| {
            t.* = std.Thread.spawn(.{}, Shared.workerThread, .{ &shared, index }) catch break;
            started += 1;
        }
        if (started == 0) {
            const previous = fast_walker.noMaterializeThisThread();
            defer fast_walker.restoreMaterialize(previous);
            shared.work(0);
        }
        for (threads[0..started]) |t| t.join();
    }
    if (shared.failure) |err| return err;
    return .{ .dropped_early = shared.dropped.load(.acquire) };
}

const Shared = struct {
    files: []types.FileEntry,
    sets: []const []const usize,
    algorithm: types.Config.HashAlgorithm,
    monitor: ?*types.Monitor,
    allocator: std.mem.Allocator,
    next: std.atomic.Value(usize) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    /// First allocation failure, written once by whoever sets `failed`; the
    /// other workers stop taking sets.
    failure: ?anyerror = null,
    failed: std.atomic.Value(bool) = .init(false),

    fn workerThread(self: *Shared, index: usize) void {
        // A file evicted to the cloud after the walk fails to read rather
        // than being downloaded (macOS; see fast_walker).
        _ = fast_walker.noMaterializeThisThread();
        self.work(index);
    }

    /// `index` names this worker's Monitor slot.
    fn work(self: *Shared, index: usize) void {
        while (true) {
            if (self.failed.load(.acquire)) return;
            if (self.monitor) |m| if (m.cancelled()) return;
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.sets.len) return;
            const result = switch (self.algorithm) {
                .blake3 => compareSet(std.crypto.hash.Blake3, self, self.sets[i], index),
                .sha256 => compareSet(std.crypto.hash.sha2.Sha256, self, self.sets[i], index),
            };
            result catch |err| {
                if (err == error.Cancelled) return;
                if (self.failed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) self.failure = err;
                return;
            };
        }
    }
};

fn compareSet(comptime Hasher: type, shared: *Shared, set: []const usize, worker: usize) !void {
    const allocator = shared.allocator;
    const n = set.len;
    const states = try allocator.alloc(Hasher, n);
    defer allocator.free(states);
    const budgets = try allocator.alloc(hasher.Budget, n);
    defer allocator.free(budgets);
    const alive = try allocator.alloc(bool, n);
    defer allocator.free(alive);
    const prefix = try allocator.alloc(hasher.Hash, n);
    defer allocator.free(prefix);

    for (set, states, budgets, alive) |idx, *state, *budget, *live| {
        state.* = Hasher.init(.{});
        budget.* = .{ .monitor = shared.monitor, .left = shared.files[idx].readBytes() };
        live.* = true;
    }
    // Every member's share of the phase's bytes is accounted for however it
    // leaves: dropped, unreadable, cancelled or finished.
    defer for (budgets) |*b| b.finish();

    const size = shared.files[set[0]].size;
    var start: u64 = 0;
    while (start < size) : (start += chunk_size) {
        const end = @min(size, start + chunk_size);
        for (set, states, budgets, alive, prefix) |idx, *state, *budget, *live, *digest| {
            if (!live.*) continue;
            const path = shared.files[idx].path;
            if (shared.monitor) |m| m.begin(worker, path);
            defer if (shared.monitor) |m| m.end(worker);
            const whole = readChunk(Hasher, state, path, start, end, shared.monitor, budget) catch |err| switch (err) {
                error.Cancelled => return error.Cancelled,
                else => false, // unreadable now: no hash, as for a failed full hash
            };
            if (!whole) {
                live.* = false;
                continue;
            }
            var copy = state.*;
            copy.final(digest);
        }
        // A member whose prefix matches no other live member's is unique.
        var remaining: usize = 0;
        for (alive, prefix, 0..) |*live, *digest, i| {
            if (!live.*) continue;
            const matched = for (alive, prefix, 0..) |other_live, *other, j| {
                if (j != i and other_live and std.mem.eql(u8, digest, other)) break true;
            } else false;
            if (!matched) {
                live.* = false;
                budgets[i].finish();
                if (end < size) _ = shared.dropped.fetchAdd(1, .monotonic);
            } else remaining += 1;
        }
        if (remaining == 0) break;
    }

    for (set, states, alive) |idx, *state, live| {
        if (!live) continue;
        var digest: hasher.Hash = undefined;
        state.final(&digest);
        shared.files[idx].hash = digest;
    }
    if (shared.monitor) |m| _ = m.done.fetchAdd(n, .release);
}

/// Feed [start, end) of `path` to `state`. False if the file is now shorter.
fn readChunk(comptime Hasher: type, state: *Hasher, path: []const u8, start: u64, end: u64, monitor: ?*types.Monitor, budget: *hasher.Budget) !bool {
    const fd = try hasher.openRegularFile(path);
    defer _ = libc.close(fd);
    return hasher.feedRange(Hasher, state, fd, start, end, monitor, budget);
}

test "chunked compare: matching members get their content digest, a late difference is dropped early" {
    try expectChunkedCompare(.blake3);
}

test "chunked compare by SHA-256, in rounds: the same answers" {
    try expectChunkedCompare(.sha256);
}

fn expectChunkedCompare(algorithm: types.Config.HashAlgorithm) !void {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "chunked");
    defer scratch.deinit();

    const size: u64 = 2 * chunk_size + 5 * 1024 * 1024;
    const head: [4096]u8 = @splat('h');
    const x: [4096]u8 = @splat('x');
    const y: [4096]u8 = @splat('y');
    const zeros: [1024 * 1024]u8 = @splat(0);
    const tail_a = [_]u8{'t'};
    const tail_d = [_]u8{'u'};
    const mid = chunk_size + 1024 * 1024;
    const extents = struct {
        fn of(second: []const u8, last: []const u8) [3]Scratch.Extent {
            return .{ .{ .offset = 0, .data = &head }, .{ .offset = mid, .data = second }, .{ .offset = size - 1, .data = last } };
        }
    };
    try scratch.writeSparse("a", size, &extents.of(&x, &tail_a));
    // b holds the same content as a, part of it as written zeros rather than a hole.
    try scratch.writeSparse("b", size, &(extents.of(&x, &tail_a) ++ [_]Scratch.Extent{.{ .offset = 10 * 1024 * 1024, .data = &zeros }}));
    try scratch.writeSparse("c", size, &extents.of(&y, &tail_a)); // differs in the second chunk
    try scratch.writeSparse("d", size, &extents.of(&x, &tail_d)); // differs in the last byte

    var files: [4]types.FileEntry = undefined;
    for (&files, [_][]const u8{ "a", "b", "c", "d" }) |*f, name| {
        f.* = .{ .path = try scratch.join(name), .size = size, .inode = 0, .dev = 0, .mtime = 0, .hash = null, .quick_hash = null };
    }
    defer for (files) |f| allocator.free(f.path);

    var monitor: types.Monitor = .{};
    const stats = try compareSets(allocator, &files, &.{&[_]usize{ 0, 1, 2, 3 }}, algorithm, 4, &monitor);

    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    @memset(content, 0);
    @memcpy(content[0..head.len], &head);
    @memcpy(content[mid..][0..x.len], &x);
    content[size - 1] = 't';
    const want = switch (algorithm) {
        .blake3 => hasher.hashBytesBlake3(content),
        .sha256 => hasher.hashBytesSha256(content),
    };

    try std.testing.expectEqual(want, files[0].hash.?);
    try std.testing.expectEqual(want, files[1].hash.?);
    try std.testing.expect(files[2].hash == null);
    try std.testing.expect(files[3].hash == null);
    // c went after the second chunk; d only at the end, which is not early.
    try std.testing.expectEqual(@as(u64, 1), stats.dropped_early);
    // Every member's share was accounted for.
    var total: u64 = 0;
    for (files) |f| total += f.readBytes();
    try std.testing.expectEqual(total, monitor.bytes_done.load(.acquire));
}

test "chunked compare: sets share the workers, and each gets its own answer" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "chunked-sets");
    defer scratch.deinit();

    // Two sizes, so two sets: p and q identical over five ranges; r and s of
    // another size, differing in their first range.
    const size_pq: u64 = 4 * chunk_size + 777;
    const size_rs: u64 = 2 * chunk_size + 3;
    const mark: [4096]u8 = @splat('m');
    const other: [4096]u8 = @splat('o');
    try scratch.writeSparse("p", size_pq, &.{ .{ .offset = 3 * chunk_size + 5, .data = &mark }, .{ .offset = size_pq - 1, .data = "z" } });
    try scratch.writeSparse("q", size_pq, &.{ .{ .offset = 3 * chunk_size + 5, .data = &mark }, .{ .offset = size_pq - 1, .data = "z" } });
    try scratch.writeSparse("r", size_rs, &.{.{ .offset = 100, .data = &mark }});
    try scratch.writeSparse("s", size_rs, &.{.{ .offset = 100, .data = &other }});

    var files: [4]types.FileEntry = undefined;
    for (&files, [_][]const u8{ "p", "q", "r", "s" }, [_]u64{ size_pq, size_pq, size_rs, size_rs }) |*f, name, size| {
        f.* = .{ .path = try scratch.join(name), .size = size, .inode = 0, .dev = 0, .mtime = 0, .hash = null, .quick_hash = null };
    }
    defer for (files) |f| allocator.free(f.path);

    const stats = try compareSets(allocator, &files, &.{ &[_]usize{ 0, 1 }, &[_]usize{ 2, 3 } }, .blake3, 8, null);

    const content = try allocator.alloc(u8, size_pq);
    defer allocator.free(content);
    @memset(content, 0);
    @memcpy(content[3 * chunk_size + 5 ..][0..mark.len], &mark);
    content[size_pq - 1] = 'z';
    try std.testing.expectEqual(hasher.hashBytesBlake3(content), files[0].hash.?);
    try std.testing.expectEqual(files[0].hash.?, files[1].hash.?);
    try std.testing.expect(files[2].hash == null and files[3].hash == null);
    // r and s part in their first range of two: both dropped early.
    try std.testing.expectEqual(@as(u64, 2), stats.dropped_early);
}

