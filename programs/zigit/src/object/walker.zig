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

    // Enqueue-time dedup: in a deep monorepo every commit's root tree
    // references many of the same blobs/subtrees as its neighbours.
    // Pushing them all and deduping on pop blew the queue up O(N×M)
    // for N commits × M tree entries. Filter at enqueue so the queue
    // size stays bounded by `unique reachable objects`.
    const enqueue = struct {
        fn call(
            a: std.mem.Allocator,
            q: *std.ArrayListUnmanaged(Oid),
            s: *std.AutoHashMapUnmanaged([20]u8, void),
            h: *const std.AutoHashMapUnmanaged([20]u8, void),
            oid: Oid,
        ) !void {
            if (h.contains(oid.bytes)) return;
            const gop = try s.getOrPut(a, oid.bytes);
            if (gop.found_existing) return;
            try q.append(a, oid);
        }
    }.call;

    try enqueue(allocator, &queue, &seen, &haves, start);

    while (queue.items.len > 0) {
        const current = queue.pop().?;

        var obj = try store.read(allocator, current);
        defer obj.deinit(allocator);

        switch (obj.kind) {
            .commit => {
                var parsed = try commit_mod.parse(allocator, obj.payload);
                defer parsed.deinit(allocator);
                try enqueue(allocator, &queue, &seen, &haves, parsed.tree_oid);
                for (parsed.parent_oids) |p| try enqueue(allocator, &queue, &seen, &haves, p);
            },
            .tree => {
                var it: tree_mod.Iterator = .{ .bytes = obj.payload };
                while (try it.next()) |entry| try enqueue(allocator, &queue, &seen, &haves, entry.oid);
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
