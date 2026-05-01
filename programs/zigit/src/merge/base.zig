// Find the merge base of two commits — the youngest commit
// reachable from both. Used by `merge` (to choose strategy +
// three-way base) and `rebase` (to know how far back to peel).
//
// Algorithm: BFS from both starting points in lockstep, marking
// visited oids. The first commit visited from one side that's
// already marked from the other side is a common ancestor.
//
// We pick the first one we see from a BFS that visits parents in
// reverse-chronological order. In a fully linear or simple branchy
// history this is the right answer; pathological merge-of-merges
// graphs can have multiple "best" bases that warrant the recursive
// strategy real git uses, but that's a Phase 11 nicety.

const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;
const commit_mod = @import("../object/commit.zig");
const LooseStore = @import("../object/loose_store.zig").LooseStore;

/// Walk from both `a` and `b` toward the root, returning the first
/// oid visited from one side that's already been seen from the other.
/// Returns null when they share no history (different root commits).
pub fn find(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    a: Oid,
    b: Oid,
) !?Oid {
    if (a.eql(b)) return a;

    var seen_a: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer seen_a.deinit(allocator);
    var seen_b: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer seen_b.deinit(allocator);

    var queue_a: std.ArrayListUnmanaged(Oid) = .empty;
    defer queue_a.deinit(allocator);
    var queue_b: std.ArrayListUnmanaged(Oid) = .empty;
    defer queue_b.deinit(allocator);
    try queue_a.append(allocator, a);
    try queue_b.append(allocator, b);

    while (queue_a.items.len > 0 or queue_b.items.len > 0) {
        if (queue_a.items.len > 0) {
            const x = queue_a.orderedRemove(0);
            if (seen_b.contains(x.bytes)) return x;
            if (!(try seen_a.getOrPut(allocator, x.bytes)).found_existing) {
                try enqueueParents(allocator, store, x, &queue_a);
            }
        }
        if (queue_b.items.len > 0) {
            const y = queue_b.orderedRemove(0);
            if (seen_a.contains(y.bytes)) return y;
            if (!(try seen_b.getOrPut(allocator, y.bytes)).found_existing) {
                try enqueueParents(allocator, store, y, &queue_b);
            }
        }
    }
    return null;
}

fn enqueueParents(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    oid: Oid,
    queue: *std.ArrayListUnmanaged(Oid),
) !void {
    var obj = try store.read(allocator, oid);
    defer obj.deinit(allocator);
    if (obj.kind != .commit) return error.NotACommit;

    var parsed = try commit_mod.parse(allocator, obj.payload);
    defer parsed.deinit(allocator);

    for (parsed.parent_oids) |p| try queue.append(allocator, p);
}
