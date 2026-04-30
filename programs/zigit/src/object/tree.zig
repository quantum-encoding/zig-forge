// Tree object — git's directory snapshot.
//
// Wire format: a packed sequence of entries. Per entry:
//
//   <octal mode (no leading zero)> SP <name> NUL <20-byte oid>
//
// Modes git accepts:
//   100644  regular file
//   100755  executable file
//   120000  symlink
//   160000  gitlink (submodule head)
//    40000  subtree
//
// Entries must be sorted by name with the comparison done as if
// directory names had a trailing '/' appended — i.e. "foo" sorts
// before "foo.txt" but "foo/" (a tree) sorts after "foo.txt". We
// model this by sorting on a key that appends '/' to subtree names.

const std = @import("std");
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;

pub const tree_mode_octal: u32 = 0o40000;
pub const blob_mode_regular: u32 = 0o100644;
pub const blob_mode_executable: u32 = 0o100755;
pub const blob_mode_symlink: u32 = 0o120000;

pub const Entry = struct {
    mode: u32,
    name: []const u8,
    oid: Oid,

    pub fn isTree(self: Entry) bool {
        return self.mode == tree_mode_octal;
    }
};

/// Serialize a sorted slice of Entries into the canonical tree
/// payload. Caller owns the returned slice. Asserts the input is
/// already sorted via `lessThanForTree`.
pub fn serialize(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, entries.len * 32);
    defer allocating.deinit();
    const w = &allocating.writer;

    for (entries) |e| {
        // Mode is octal with no leading zero. "100644", "40000", etc.
        try w.print("{o} {s}\x00", .{ e.mode, e.name });
        try w.writeAll(&e.oid.bytes);
    }

    return try allocating.toOwnedSlice();
}

/// Order two tree entries the way git does: byte-compare names with
/// a virtual '/' appended to subtree names. Stable for the canonical
/// tree format.
pub fn lessThanForTree(_: void, a: Entry, b: Entry) bool {
    return compareForTree(a, b) < 0;
}

fn compareForTree(a: Entry, b: Entry) i32 {
    var i: usize = 0;
    while (i < a.name.len and i < b.name.len) : (i += 1) {
        const av = a.name[i];
        const bv = b.name[i];
        if (av != bv) return @as(i32, av) - @as(i32, bv);
    }

    // One is a strict prefix of the other (or they're equal). The
    // virtual trailing slash for trees decides the tie.
    const a_tail: u8 = if (i < a.name.len)
        a.name[i]
    else if (a.isTree())
        '/'
    else
        0;
    const b_tail: u8 = if (i < b.name.len)
        b.name[i]
    else if (b.isTree())
        '/'
    else
        0;
    return @as(i32, a_tail) - @as(i32, b_tail);
}

/// Iterator over a tree object's payload bytes — borrows the slice,
/// doesn't allocate.
pub const Iterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Iterator) !?Entry {
        if (self.cursor >= self.bytes.len) return null;

        const space = std.mem.indexOfScalarPos(u8, self.bytes, self.cursor, ' ') orelse
            return error.MalformedTreeEntry;
        const mode_str = self.bytes[self.cursor..space];
        const mode = try std.fmt.parseInt(u32, mode_str, 8);

        const name_start = space + 1;
        const nul = std.mem.indexOfScalarPos(u8, self.bytes, name_start, 0) orelse
            return error.MalformedTreeEntry;
        const name = self.bytes[name_start..nul];

        const oid_start = nul + 1;
        if (self.bytes.len < oid_start + 20) return error.MalformedTreeEntry;
        var oid: Oid = undefined;
        @memcpy(&oid.bytes, self.bytes[oid_start..][0..20]);

        self.cursor = oid_start + 20;
        return .{ .mode = mode, .name = name, .oid = oid };
    }
};

const testing = std.testing;

test "lessThanForTree treats subtrees as if they had a trailing slash" {
    var oid_zero: Oid = undefined;
    @memset(&oid_zero.bytes, 0);

    const blob: Entry = .{ .mode = blob_mode_regular, .name = "foo.txt", .oid = oid_zero };
    const tree: Entry = .{ .mode = tree_mode_octal, .name = "foo", .oid = oid_zero };

    // "foo" + virtual '/' (47) > "foo.txt"[3] = '.' (46)
    // → tree sorts AFTER blob.
    try testing.expect(lessThanForTree({}, blob, tree));
    try testing.expect(!lessThanForTree({}, tree, blob));
}

test "serialize then iterate round-trips" {
    var oid_a: Oid = undefined; @memset(&oid_a.bytes, 0xAA);
    var oid_b: Oid = undefined; @memset(&oid_b.bytes, 0xBB);

    var entries = [_]Entry{
        .{ .mode = blob_mode_regular, .name = "a.txt", .oid = oid_a },
        .{ .mode = tree_mode_octal,   .name = "sub",   .oid = oid_b },
    };
    std.mem.sort(Entry, &entries, {}, lessThanForTree);

    const bytes = try serialize(testing.allocator, &entries);
    defer testing.allocator.free(bytes);

    var it: Iterator = .{ .bytes = bytes };
    const first = (try it.next()).?;
    try testing.expectEqualStrings("a.txt", first.name);
    try testing.expectEqual(@as(u32, blob_mode_regular), first.mode);
    try testing.expect(std.mem.eql(u8, &oid_a.bytes, &first.oid.bytes));
    const second = (try it.next()).?;
    try testing.expectEqualStrings("sub", second.name);
    try testing.expectEqual(@as(u32, tree_mode_octal), second.mode);
    try testing.expect((try it.next()) == null);
}
