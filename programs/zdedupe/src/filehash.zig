//! BLAKE3 digests of many whole files at once, on every core.
//!
//! Every file is cut into ranges of `range_size`, each a whole BLAKE3 subtree
//! (blake3_tree.zig) that any worker hashes; a file's digest is finished from
//! its ranges' values when the last of them is done. So one huge file keeps
//! every core busy, and so do many small ones. The digest is the plain BLAKE3
//! of the file (holes read as zeros, see `hasher.feedRange`).
//!
//! A permanent delete verifies its files with this (session.zig): the digest
//! must still be the scan's. Each file's size is checked when every range is
//! opened, and its mtime is recorded, so the caller can tell whether the file
//! changed between being read and being deleted.

const std = @import("std");
const types = @import("types.zig");
const hasher = @import("hasher.zig");
const blake3_tree = @import("blake3_tree.zig");
const pstat = @import("pstat.zig");
const libc = @import("sys.zig").c;

/// Bytes of one file a worker hashes before it takes more work: 2^16 chunks.
pub const range_size: u64 = 64 * 1024 * 1024;

comptime {
    std.debug.assert(range_size % blake3_tree.chunk_len == 0 and std.math.isPowerOfTwo(range_size / blake3_tree.chunk_len));
}

pub const Item = struct {
    path: []const u8,
    /// The size the file must have: any other, and it gets no digest.
    size: u64,
    /// Set when every byte was read and the file kept `size` throughout.
    digest: ?hasher.Hash = null,
    /// The file's mtime (seconds) when it was read.
    mtime: i64 = 0,
};

/// Fill in `digest` and `mtime` for each of `items`. A file that cannot be
/// opened or read, is not a regular file, or is not `size` bytes, gets no
/// digest. `cancel`, when set, stops the work; the items not finished by then
/// get no digest.
pub fn hashAll(
    allocator: std.mem.Allocator,
    items: []Item,
    thread_count: u32,
    cancel: ?*const std.atomic.Value(bool),
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const states = try arena.alloc(State, items.len);
    var unit_count: usize = 0;
    for (items, states) |*item, *state| {
        item.digest = null;
        const ranges: u32 = @intCast(@max(1, std.math.divCeil(u64, item.size, range_size) catch unreachable));
        state.* = .{ .cvs = try arena.alloc(blake3_tree.Cv, ranges - 1), .ranges = ranges, .units_left = .init(ranges) };
        unit_count += ranges;
    }
    // File by file, each in order: files finish one after another.
    const units = try arena.alloc(Unit, unit_count);
    var u: usize = 0;
    for (states, 0..) |state, i| {
        for (0..state.ranges) |r| {
            units[u] = .{ .item = @intCast(i), .range = @intCast(r) };
            u += 1;
        }
    }

    var shared: Shared = .{ .items = items, .states = states, .units = units, .cancel = cancel };
    const workers: usize = @max(1, @min(thread_count, unit_count));
    if (workers == 1) {
        shared.work();
        return;
    }
    const threads = try arena.alloc(std.Thread, workers);
    var started: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch break;
        started += 1;
    }
    if (started == 0) shared.work();
    for (threads[0..started]) |t| t.join();
}

const State = struct {
    /// Chaining values of every range but the last.
    cvs: []blake3_tree.Cv,
    tail: blake3_tree.Hasher = undefined,
    ranges: u32,
    failed: std.atomic.Value(bool) = .init(false),
    mtime: std.atomic.Value(i64) = .init(0),
    units_left: std.atomic.Value(u32),
};

const Unit = struct { item: u32, range: u32 };

const Shared = struct {
    items: []Item,
    states: []State,
    units: []const Unit,
    cancel: ?*const std.atomic.Value(bool),
    next: std.atomic.Value(usize) = .init(0),

    fn work(self: *Shared) void {
        while (true) {
            if (self.cancel) |c| if (c.load(.acquire)) return;
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.units.len) return;
            const unit = self.units[i];
            const item = &self.items[unit.item];
            const state = &self.states[unit.item];
            if (!state.failed.load(.acquire)) {
                if (!hashRange(item, state, unit.range)) state.failed.store(true, .release);
            }
            if (state.units_left.fetchSub(1, .acq_rel) == 1 and !state.failed.load(.acquire)) {
                item.mtime = state.mtime.load(.acquire);
                item.digest = state.tail.final(state.cvs);
            }
        }
    }

};

/// Hash one range of `item` into its state. False if the file cannot be
/// read, is not the expected size, or ends early.
fn hashRange(item: *const Item, state: *State, r: u32) bool {
    const fd = hasher.openRegularFile(item.path) catch return false;
    defer _ = libc.close(fd);
    const st = pstat.fstat(fd) catch return false;
    if (st.size != item.size) return false;
    if (r == 0) state.mtime.store(st.mtime_sec, .release);

    const start = @as(u64, r) * range_size;
    const end = @min(item.size, start + range_size);
    var h = blake3_tree.Hasher.init(start / blake3_tree.chunk_len);
    var read: hasher.Budget = .{ .monitor = null, .left = std.math.maxInt(u64) };
    const whole = hasher.feedRange(blake3_tree.Hasher, &h, fd, start, end, null, &read) catch return false;
    if (!whole) return false;
    if (r + 1 == state.ranges) state.tail = h else state.cvs[r] = h.subtreeCv();
    return true;
}

const Scratch = @import("testing_scratch.zig").Scratch;

test "whole-file digests match a plain BLAKE3, for files of one range, several, and none" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "filehash");
    defer scratch.deinit();

    const big: u64 = 2 * range_size + 12345;
    const mark: [4096]u8 = @splat('m');
    try scratch.writeSparse("big", big, &.{ .{ .offset = range_size + 7, .data = &mark }, .{ .offset = big - 1, .data = "z" } });
    try scratch.writeFile("small", "a few bytes");
    try scratch.writeFile("empty", "");
    try scratch.writeFile("short", "shorter than it was");

    var items = [_]Item{
        .{ .path = try scratch.join("big"), .size = big },
        .{ .path = try scratch.join("small"), .size = 11 },
        .{ .path = try scratch.join("empty"), .size = 0 },
        // Not the size the caller expects: no digest.
        .{ .path = try scratch.join("short"), .size = 999 },
        .{ .path = try scratch.join("missing"), .size = 5 },
    };
    defer for (items) |item| allocator.free(item.path);
    try hashAll(allocator, &items, 4, null);

    const content = try allocator.alloc(u8, big);
    defer allocator.free(content);
    @memset(content, 0);
    @memcpy(content[range_size + 7 ..][0..mark.len], &mark);
    content[big - 1] = 'z';
    try std.testing.expectEqual(hasher.hashBytesBlake3(content), items[0].digest.?);
    try std.testing.expectEqual(hasher.hashBytesBlake3("a few bytes"), items[1].digest.?);
    try std.testing.expectEqual(hasher.hashBytesBlake3(""), items[2].digest.?);
    try std.testing.expect(items[3].digest == null and items[4].digest == null);
    try std.testing.expect(items[0].mtime > 0);
}

test "a cancelled run leaves what it did not finish without a digest" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "filehash-cancel");
    defer scratch.deinit();
    try scratch.writeFile("f", "data");
    var items = [_]Item{.{ .path = try scratch.join("f"), .size = 4 }};
    defer allocator.free(items[0].path);
    var cancel: std.atomic.Value(bool) = .init(true);
    try hashAll(allocator, &items, 4, &cancel);
    try std.testing.expect(items[0].digest == null);
}
