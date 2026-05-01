// Reachability walker — given a starting commit oid, enumerate
// every object the receiver needs to fully reconstruct that commit.
//
// Algorithm:
//
//   queue ← [start_commit]
//   while queue:
//     pop oid
//     if oid in haves:        skip   (receiver already has it + transitively
//                                     everything reachable from it)
//     if oid in seen:         skip
//     seen.add(oid)
//     load object → kind, payload
//     case commit:
//       collect parents into queue
//       collect tree into queue
//     case tree:
//       collect every entry's oid into queue
//     case blob, tag:
//       no further recursion
//
// We DON'T trim sub-objects of trees we've already fully traversed
// (just deduping by oid is enough for correctness; perf can come
// later via packfile-style "have ancestors" pruning if it ever
// matters).
//
// `haves` is the receiver's "I already have this" set (their current
// branch tip, after fully expanding its reachable set). For a first
// push to an empty branch, pass an empty haves set; for an update,
// pass a closure walked from the previous remote oid.

const std = @import("std");
const Oid = @import("oid.zig").Oid;
const tree_mod = @import("tree.zig");
const commit_mod = @import("commit.zig");
const LooseStore = @import("loose_store.zig").LooseStore;

pub const Reachable = struct {
    /// Owned. Sorted by oid ascending — handy for the pack writer
    /// which wants a stable order anyway.
    oids: []Oid,
};

pub fn freeReachable(allocator: std.mem.Allocator, r: Reachable) void {
    allocator.free(r.oids);
}

pub fn walk(
    allocator: std.mem.Allocator,
    store: *LooseStore,
    start: Oid,
    haves: std.AutoHashMapUnmanaged([20]u8, void),
) !Reachable {
    var seen: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer seen.deinit(allocator);

    var queue: std.ArrayListUnmanaged(Oid) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, start);

    while (queue.items.len > 0) {
        const current = queue.pop().?;
        if (haves.contains(current.bytes)) continue;
        if ((try seen.getOrPut(allocator, current.bytes)).found_existing) continue;

        var obj = try store.read(allocator, current);
        defer obj.deinit(allocator);

        switch (obj.kind) {
            .commit => {
                var parsed = try commit_mod.parse(allocator, obj.payload);
                defer parsed.deinit(allocator);
                try queue.append(allocator, parsed.tree_oid);
                for (parsed.parent_oids) |p| try queue.append(allocator, p);
            },
            .tree => {
                var it: tree_mod.Iterator = .{ .bytes = obj.payload };
                while (try it.next()) |entry| try queue.append(allocator, entry.oid);
            },
            .blob, .tag => {},
        }
    }

    var oids: std.ArrayListUnmanaged(Oid) = .empty;
    errdefer oids.deinit(allocator);
    try oids.ensureTotalCapacityPrecise(allocator, seen.count());
    var it = seen.keyIterator();
    while (it.next()) |k| oids.appendAssumeCapacity(.{ .bytes = k.* });

    std.mem.sort(Oid, oids.items, {}, struct {
        fn lt(_: void, a: Oid, b: Oid) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.lt);

    return .{ .oids = try oids.toOwnedSlice(allocator) };
}
