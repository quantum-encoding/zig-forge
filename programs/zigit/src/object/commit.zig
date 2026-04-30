// Commit object — points at a tree, plus zero-or-more parents,
// authorship, and a message.
//
// Wire format (no leading whitespace per line, lines terminated by \n):
//
//   tree     <40-char hex>
//   parent   <40-char hex>           (zero or more, in argv order)
//   author   <name> <<email>> <unix-ts> <tz-offset>
//   committer <name> <<email>> <unix-ts> <tz-offset>
//   <blank line>
//   <message>
//
// The blank line between the headers and the message is mandatory,
// and the message must end with a single newline.
//
// `tz-offset` is the local-to-UTC offset as +HHMM or -HHMM. We
// always emit "+0000" for now — switching to the real tz takes a
// detour through libc tm, which we don't link.

const std = @import("std");
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;

pub const Author = struct {
    name: []const u8,
    email: []const u8,
    /// Seconds since 1970-01-01 UTC.
    when_unix: i64,
    /// "+HHMM" / "-HHMM".
    timezone: []const u8 = "+0000",
};

pub const Spec = struct {
    tree_oid: Oid,
    parent_oids: []const Oid,
    author: Author,
    committer: Author,
    /// The message; we add the trailing newline for you.
    message: []const u8,
};

pub fn serialize(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer allocating.deinit();
    const w = &allocating.writer;

    var hex: [40]u8 = undefined;
    spec.tree_oid.toHex(&hex);
    try w.print("tree {s}\n", .{hex[0..40]});

    for (spec.parent_oids) |p| {
        p.toHex(&hex);
        try w.print("parent {s}\n", .{hex[0..40]});
    }

    try writeIdent(w, "author", spec.author);
    try writeIdent(w, "committer", spec.committer);

    try w.writeAll("\n");
    try w.writeAll(spec.message);
    if (spec.message.len == 0 or spec.message[spec.message.len - 1] != '\n') {
        try w.writeAll("\n");
    }

    return try allocating.toOwnedSlice();
}

fn writeIdent(w: *std.Io.Writer, label: []const u8, ident: Author) !void {
    try w.print(
        "{s} {s} <{s}> {d} {s}\n",
        .{ label, ident.name, ident.email, ident.when_unix, ident.timezone },
    );
}

const testing = std.testing;

test "serialize a one-parent commit" {
    var tree_oid: Oid = undefined;
    @memset(&tree_oid.bytes, 0xAA);
    var parent_oid: Oid = undefined;
    @memset(&parent_oid.bytes, 0xBB);

    const author: Author = .{
        .name = "Test",
        .email = "t@example.com",
        .when_unix = 1700000000,
    };

    const parents = [_]Oid{parent_oid};
    const bytes = try serialize(testing.allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = &parents,
        .author = author,
        .committer = author,
        .message = "subject\n",
    });
    defer testing.allocator.free(bytes);

    const expected =
        "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "parent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "author Test <t@example.com> 1700000000 +0000\n" ++
        "committer Test <t@example.com> 1700000000 +0000\n" ++
        "\nsubject\n";
    try testing.expectEqualStrings(expected, bytes);
}
