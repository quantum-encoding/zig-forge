// Three-way merge over flat (path → mode+oid) maps.
//
// We don't do line-level merging yet — every "both modified the
// same file with different content" case is a conflict, even when
// the changes are line-disjoint. This keeps the resolver tiny and
// predictable; line-aware diff3 can land on top later (the bones
// are already there in src/diff/myers.zig).
//
// Resolution table (X, Y, Z all distinct content):
//
//   base | ours | theirs | result
//   -----+------+--------+----------------------------------
//     X  |  X   |   X    | unchanged → X
//     X  |  X   |   Y    | take theirs (we didn't touch it)
//     X  |  Y   |   X    | take ours (they didn't touch it)
//     X  |  Y   |   Y    | both made the same change → Y
//     X  |  Y   |   Z    | CONFLICT (modify/modify)
//     -  |  X   |   -    | added in ours → take ours
//     -  |  -   |   X    | added in theirs → take theirs
//     -  |  X   |   X    | added in both, same → X
//     -  |  X   |   Y    | CONFLICT (add/add)
//     X  |  -   |   X    | deleted in ours, untouched in theirs → delete
//     X  |  X   |   -    | deleted in theirs, untouched in ours → delete
//     X  |  Y   |   -    | CONFLICT (modify/delete)
//     X  |  -   |   Y    | CONFLICT (delete/modify)
//     X  |  -   |   -    | deleted in both → delete
//
// We treat mode-only changes as content changes (mode is part of the
// (mode, oid) tuple).

const std = @import("std");
const Oid = @import("../object/oid.zig").Oid;

pub const Slot = struct {
    mode: u32,
    oid: Oid,
};

pub const Map = std.StringHashMapUnmanaged(Slot);

pub const Resolved = struct {
    /// Owned by the supplied allocator.
    path: []u8,
    mode: u32,
    oid: Oid,
};

pub const Conflict = struct {
    /// Owned by the supplied allocator.
    path: []u8,
    reason: Reason,

    pub const Reason = enum {
        modify_modify,
        add_add,
        modify_delete,
        delete_modify,
    };
};

pub const Result = struct {
    /// Sorted by path. Owned slice + each entry's path is owned.
    merged: []Resolved,
    /// Sorted by path. Owned slice + each entry's path is owned.
    conflicts: []Conflict,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.merged) |m| allocator.free(m.path);
        allocator.free(self.merged);
        for (self.conflicts) |c| allocator.free(c.path);
        allocator.free(self.conflicts);
        self.* = undefined;
    }
};

pub fn merge(
    allocator: std.mem.Allocator,
    base: Map,
    ours: Map,
    theirs: Map,
) !Result {
    var merged: std.ArrayListUnmanaged(Resolved) = .empty;
    errdefer {
        for (merged.items) |m| allocator.free(m.path);
        merged.deinit(allocator);
    }
    var conflicts: std.ArrayListUnmanaged(Conflict) = .empty;
    errdefer {
        for (conflicts.items) |c| allocator.free(c.path);
        conflicts.deinit(allocator);
    }

    // Union of all three sets of paths, deduped.
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    defer paths.deinit(allocator);
    var bi = base.iterator();
    while (bi.next()) |kv| try paths.put(allocator, kv.key_ptr.*, {});
    var oi = ours.iterator();
    while (oi.next()) |kv| try paths.put(allocator, kv.key_ptr.*, {});
    var ti = theirs.iterator();
    while (ti.next()) |kv| try paths.put(allocator, kv.key_ptr.*, {});

    var pi = paths.keyIterator();
    while (pi.next()) |path| {
        const b_opt = base.get(path.*);
        const o_opt = ours.get(path.*);
        const t_opt = theirs.get(path.*);

        if (try resolveOne(b_opt, o_opt, t_opt)) |outcome| {
            switch (outcome) {
                .keep => |s| try merged.append(allocator, .{
                    .path = try allocator.dupe(u8, path.*),
                    .mode = s.mode,
                    .oid = s.oid,
                }),
                .delete => {},
                .conflict => |reason| try conflicts.append(allocator, .{
                    .path = try allocator.dupe(u8, path.*),
                    .reason = reason,
                }),
            }
        }
    }

    std.mem.sort(Resolved, merged.items, {}, struct {
        fn lt(_: void, a: Resolved, b: Resolved) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    std.mem.sort(Conflict, conflicts.items, {}, struct {
        fn lt(_: void, a: Conflict, b: Conflict) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    return .{
        .merged = try merged.toOwnedSlice(allocator),
        .conflicts = try conflicts.toOwnedSlice(allocator),
    };
}

const Outcome = union(enum) {
    keep: Slot,
    delete,
    conflict: Conflict.Reason,
};

fn slotEql(a: Slot, b: Slot) bool {
    return a.mode == b.mode and a.oid.eql(b.oid);
}

fn resolveOne(b: ?Slot, o: ?Slot, t: ?Slot) !?Outcome {
    if (b == null and o == null and t == null) return null;

    if (b == null) {
        // Add cases.
        if (o != null and t == null) return Outcome{ .keep = o.? };
        if (o == null and t != null) return Outcome{ .keep = t.? };
        if (slotEql(o.?, t.?)) return Outcome{ .keep = o.? };
        return Outcome{ .conflict = .add_add };
    }

    // Base exists.
    if (o == null and t == null) return Outcome.delete; // both deleted
    if (o == null) {
        // Deleted in ours.
        if (slotEql(t.?, b.?)) return Outcome.delete; // unchanged in theirs → delete
        return Outcome{ .conflict = .delete_modify };
    }
    if (t == null) {
        // Deleted in theirs.
        if (slotEql(o.?, b.?)) return Outcome.delete;
        return Outcome{ .conflict = .modify_delete };
    }

    // All three exist.
    if (slotEql(o.?, t.?)) return Outcome{ .keep = o.? }; // unchanged or same change
    if (slotEql(o.?, b.?)) return Outcome{ .keep = t.? }; // theirs only modified
    if (slotEql(t.?, b.?)) return Outcome{ .keep = o.? }; // ours only modified
    return Outcome{ .conflict = .modify_modify };
}

const testing = std.testing;

fn newOid(byte: u8) Oid {
    var o: Oid = undefined;
    @memset(&o.bytes, byte);
    return o;
}

test "all three identical: clean keep" {
    const allocator = testing.allocator;
    const sl: Slot = .{ .mode = 0o100644, .oid = newOid(0xAA) };

    var base: Map = .empty; defer base.deinit(allocator);
    try base.put(allocator, "a.txt", sl);
    var ours: Map = .empty; defer ours.deinit(allocator);
    try ours.put(allocator, "a.txt", sl);
    var theirs: Map = .empty; defer theirs.deinit(allocator);
    try theirs.put(allocator, "a.txt", sl);

    var r = try merge(allocator, base, ours, theirs);
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), r.merged.len);
    try testing.expectEqual(@as(usize, 0), r.conflicts.len);
}

test "ours unchanged, theirs modified: take theirs" {
    const allocator = testing.allocator;
    const original: Slot = .{ .mode = 0o100644, .oid = newOid(0xAA) };
    const modified: Slot = .{ .mode = 0o100644, .oid = newOid(0xBB) };

    var base: Map = .empty; defer base.deinit(allocator);
    try base.put(allocator, "a.txt", original);
    var ours: Map = .empty; defer ours.deinit(allocator);
    try ours.put(allocator, "a.txt", original);
    var theirs: Map = .empty; defer theirs.deinit(allocator);
    try theirs.put(allocator, "a.txt", modified);

    var r = try merge(allocator, base, ours, theirs);
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), r.merged.len);
    try testing.expect(r.merged[0].oid.eql(modified.oid));
}

test "both modified differently: conflict" {
    const allocator = testing.allocator;
    const a: Slot = .{ .mode = 0o100644, .oid = newOid(0xAA) };
    const b: Slot = .{ .mode = 0o100644, .oid = newOid(0xBB) };
    const c: Slot = .{ .mode = 0o100644, .oid = newOid(0xCC) };

    var base: Map = .empty; defer base.deinit(allocator);
    try base.put(allocator, "f", a);
    var ours: Map = .empty; defer ours.deinit(allocator);
    try ours.put(allocator, "f", b);
    var theirs: Map = .empty; defer theirs.deinit(allocator);
    try theirs.put(allocator, "f", c);

    var r = try merge(allocator, base, ours, theirs);
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), r.merged.len);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqual(Conflict.Reason.modify_modify, r.conflicts[0].reason);
}

test "added in both with same content: clean" {
    const allocator = testing.allocator;
    const sl: Slot = .{ .mode = 0o100644, .oid = newOid(0xAA) };

    var base: Map = .empty; defer base.deinit(allocator);
    var ours: Map = .empty; defer ours.deinit(allocator);
    try ours.put(allocator, "new", sl);
    var theirs: Map = .empty; defer theirs.deinit(allocator);
    try theirs.put(allocator, "new", sl);

    var r = try merge(allocator, base, ours, theirs);
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), r.merged.len);
}

test "modify/delete: conflict" {
    const allocator = testing.allocator;
    const a: Slot = .{ .mode = 0o100644, .oid = newOid(0xAA) };
    const b: Slot = .{ .mode = 0o100644, .oid = newOid(0xBB) };

    var base: Map = .empty; defer base.deinit(allocator);
    try base.put(allocator, "f", a);
    var ours: Map = .empty; defer ours.deinit(allocator);
    try ours.put(allocator, "f", b); // modified
    var theirs: Map = .empty; defer theirs.deinit(allocator);
    // theirs deleted f

    var r = try merge(allocator, base, ours, theirs);
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqual(Conflict.Reason.modify_delete, r.conflicts[0].reason);
}
