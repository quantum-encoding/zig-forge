// Events log — thin wrapper over the WAL primitive for the SSE
// handler's durable-replay path.
//
// The SSE durable-replay canary (CONFORMANCE Layer C) requires that
// `Last-Event-ID: N` reconnects deliver every event with seq > N,
// from the durable events table. NOT from any in-memory live-stream
// buffer. This module exposes exactly that:
//
//   replayFrom(store, since_seq, cb)
//     → walks the WAL from the start, filters to event_insert ops,
//       calls cb for each event with seq > since_seq.
//
// The store's in-memory events_recent ring is an OPTIMIZATION for
// the GET /api/notifications/recent path (small N, hot, no replay
// gap). The SSE canary explicitly forces a 50-event gap to ensure
// reconnects hit the durable path, not the ring. So this module
// reads only from the WAL — the ring is irrelevant to replay-truth.

const std = @import("std");
const Io = std.Io;
const types = @import("store/types.zig");
const store_mod = @import("store/store.zig");

/// Callback invoked once per event in replay order (seq-ascending).
pub const ReplayCallback = *const fn (ctx: ?*anyopaque, event: types.EventRow) void;

/// Replay events with seq > `since_seq` to the callback. Returns the
/// number of events emitted. Reads from the WAL directly so the
/// durable-replay contract (CONFORMANCE §6.1 canary) is satisfied
/// structurally — replay truth is the on-disk WAL, not a buffer.
pub fn replayFrom(
    store: *store_mod.Store,
    io: Io,
    since_seq: u64,
    ctx: ?*anyopaque,
    cb: ReplayCallback,
) !u64 {
    const Ctx = struct {
        outer_ctx: ?*anyopaque,
        outer_cb: ReplayCallback,
        since: u64,
        emitted: u64,
    };
    var inner_ctx = Ctx{
        .outer_ctx = ctx,
        .outer_cb = cb,
        .since = since_seq,
        .emitted = 0,
    };

    // Hold the store mutex for the duration of the replay so no new
    // event_insert can race past the cursor we're reading. This is a
    // long-held lock, but SSE replay only fires on reconnect (rare
    // path) and the alternative (snapshot copy + release) costs
    // proportional to WAL size. For v1 the simple lock is fine.
    store.mutex.lockUncancelable(store.io);
    defer store.mutex.unlock(store.io);

    _ = try store.wal.replay(io, &inner_ctx, replayAdapter);
    return inner_ctx.emitted;
}

fn replayAdapter(raw_ctx: ?*anyopaque, seq: u64, op: types.WalOp, payload: []const u8) void {
    const Ctx = struct {
        outer_ctx: ?*anyopaque,
        outer_cb: ReplayCallback,
        since: u64,
        emitted: u64,
    };
    const ctx: *Ctx = @alignCast(@ptrCast(raw_ctx orelse return));

    // Skip non-event WAL entries. They're part of the durable history
    // but not part of the events table the SSE handler tails.
    if (op != .event_insert) return;
    if (seq <= ctx.since) return;

    // Decode via the store's versioned field-wise reader (same path the
    // recover() replay uses). Previously this @memcpy'd the raw struct
    // and gated on `payload.len == @sizeOf(EventRow)` — a layout/arch
    // change would have silently skipped every event on reconnect.
    var event = store_mod.deserializeEvent(payload) orelse return;
    event.seq = seq; // seq is set at WAL-write time, not in payload

    ctx.outer_cb(ctx.outer_ctx, event);
    ctx.emitted += 1;
}

// ── Tests ──

const testing = std.testing;

const Collected = struct {
    list: *std.ArrayListUnmanaged(types.EventRow),
};

fn collectAll(ctx: ?*anyopaque, event: types.EventRow) void {
    const c: *Collected = @alignCast(@ptrCast(ctx orelse return));
    c.list.append(testing.allocator, event) catch {};
}

test "replayFrom delivers events with seq > since, in seq order" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-events-order";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try store_mod.Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    const seq1 = try store.insertEvent(io, .commit_pushed, "jak/a", "first", "{}", 1);
    const seq2 = try store.insertEvent(io, .commit_pushed, "jak/b", "second", "{}", 2);
    const seq3 = try store.insertEvent(io, .commit_pushed, "jak/c", "third", "{}", 3);

    var list: std.ArrayListUnmanaged(types.EventRow) = .empty;
    defer list.deinit(testing.allocator);
    var c = Collected{ .list = &list };

    // Replay from BEFORE the first event — should deliver all three.
    const emitted = try replayFrom(&store, io, 0, &c, collectAll);
    try testing.expectEqual(@as(u64, 3), emitted);
    try testing.expectEqual(seq1, list.items[0].seq);
    try testing.expectEqual(seq2, list.items[1].seq);
    try testing.expectEqual(seq3, list.items[2].seq);
    try testing.expectEqualStrings("first", list.items[0].title.slice());
    try testing.expectEqualStrings("second", list.items[1].title.slice());
    try testing.expectEqualStrings("third", list.items[2].title.slice());
}

test "replayFrom skips events with seq <= since (the canary path)" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-events-canary";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try store_mod.Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    const e1 = try store.insertEvent(io, .commit_pushed, "a", "E1", "{}", 1);
    _ = try store.insertEvent(io, .commit_pushed, "b", "E2", "{}", 2);
    _ = try store.insertEvent(io, .commit_pushed, "c", "E3", "{}", 3);

    var list: std.ArrayListUnmanaged(types.EventRow) = .empty;
    defer list.deinit(testing.allocator);
    var c = Collected{ .list = &list };

    // Reconnect with Last-Event-ID: e1. Should deliver E2, E3 only.
    // This is the durable-replay canary's wire shape in microcosm.
    const emitted = try replayFrom(&store, io, e1, &c, collectAll);
    try testing.expectEqual(@as(u64, 2), emitted);
    try testing.expectEqualStrings("E2", list.items[0].title.slice());
    try testing.expectEqualStrings("E3", list.items[1].title.slice());
}

test "replayFrom returns 0 when since is at-or-past the tip" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-events-tip";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try store_mod.Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    _ = try store.insertEvent(io, .commit_pushed, "a", "only", "{}", 1);

    var list: std.ArrayListUnmanaged(types.EventRow) = .empty;
    defer list.deinit(testing.allocator);
    var c = Collected{ .list = &list };

    const emitted = try replayFrom(&store, io, 999, &c, collectAll);
    try testing.expectEqual(@as(u64, 0), emitted);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}
