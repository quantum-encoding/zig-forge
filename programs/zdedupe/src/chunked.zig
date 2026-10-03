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
//! The prefix digest comes from finalizing a copy of the running hasher, so
//! each byte is hashed once.

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
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
/// `FileEntry.hash`; the others are left without one. Sets are spread over
/// `thread_count` workers; each set is read by one.
pub fn compareSets(
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "chunked");
    defer scratch.deinit();

    const size: u64 = 2 * chunk_size + 5 * 1024 * 1024;
    const head = [_]u8{'h'} ** 4096;
    const x = [_]u8{'x'} ** 4096;
    const y = [_]u8{'y'} ** 4096;
    const zeros = [_]u8{0} ** (1024 * 1024);
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
    const stats = try compareSets(allocator, &files, &.{&[_]usize{ 0, 1, 2, 3 }}, .blake3, 4, &monitor);

    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    @memset(content, 0);
    @memcpy(content[0..head.len], &head);
    @memcpy(content[mid..][0..x.len], &x);
    content[size - 1] = 't';
    const want = hasher.hashBytesBlake3(content);

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
