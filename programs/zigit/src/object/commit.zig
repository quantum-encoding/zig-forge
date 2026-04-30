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

/// Parsed view of a commit object's payload. All slices borrow from
/// the input bytes — copy if you need to outlive them.
pub const Parsed = struct {
    tree_oid: Oid,
    /// Owned by caller (we use the supplied allocator for the slice).
    parent_oids: []Oid,
    author_line: []const u8,
    committer_line: []const u8,
    message: []const u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.parent_oids);
        self.* = undefined;
    }
};

/// Parse a commit object payload (i.e. the bytes returned by
/// LooseStore.read for a commit). Lenient about trailing newlines on
/// the message but strict on the header lines — every header before
/// the blank separator must be one of the expected kinds.
pub fn parse(allocator: std.mem.Allocator, payload: []const u8) !Parsed {
    // Find the empty line that separates headers from message.
    const sep_idx = std.mem.indexOf(u8, payload, "\n\n") orelse return error.MalformedCommit;
    const headers = payload[0..sep_idx];
    const message = payload[sep_idx + 2 ..];

    var tree_oid: ?Oid = null;
    var author_line: ?[]const u8 = null;
    var committer_line: ?[]const u8 = null;

    var parents: std.ArrayListUnmanaged(Oid) = .empty;
    errdefer parents.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, headers, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "tree ")) {
            const hex = line[5..];
            if (hex.len != 40) return error.MalformedCommit;
            tree_oid = try Oid.fromHex(hex);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const hex = line[7..];
            if (hex.len != 40) return error.MalformedCommit;
            try parents.append(allocator, try Oid.fromHex(hex));
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_line = line[7..];
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_line = line[10..];
        } else {
            // Future header (gpgsig, mergetag, encoding…) — ignored.
        }
    }

    return .{
        .tree_oid = tree_oid orelse return error.CommitMissingTree,
        .parent_oids = try parents.toOwnedSlice(allocator),
        .author_line = author_line orelse return error.CommitMissingAuthor,
        .committer_line = committer_line orelse return error.CommitMissingCommitter,
        .message = message,
    };
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

test "parse round-trips serialize" {
    var tree_oid: Oid = undefined;
    @memset(&tree_oid.bytes, 0xCD);
    var p1: Oid = undefined;
    @memset(&p1.bytes, 0xEE);
    var p2: Oid = undefined;
    @memset(&p2.bytes, 0xFF);

    const author: Author = .{ .name = "Author", .email = "a@x", .when_unix = 42 };
    const committer: Author = .{ .name = "Committer", .email = "c@x", .when_unix = 43 };

    const parents = [_]Oid{ p1, p2 };
    const bytes = try serialize(testing.allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = &parents,
        .author = author,
        .committer = committer,
        .message = "subject\n\nbody body body\n",
    });
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit(testing.allocator);

    try testing.expect(parsed.tree_oid.eql(tree_oid));
    try testing.expectEqual(@as(usize, 2), parsed.parent_oids.len);
    try testing.expect(parsed.parent_oids[0].eql(p1));
    try testing.expect(parsed.parent_oids[1].eql(p2));
    try testing.expectEqualStrings("Author <a@x> 42 +0000", parsed.author_line);
    try testing.expectEqualStrings("Committer <c@x> 43 +0000", parsed.committer_line);
    try testing.expectEqualStrings("subject\n\nbody body body\n", parsed.message);
}
