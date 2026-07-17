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

/// One leaf produced by `walkRecursive`. `path` is the full
/// slash-joined path from the root tree (e.g. "sub/deep/d.txt").
/// Owned by the returned ArrayList.
pub const Leaf = struct {
    path: []u8,
    mode: u32,
    oid: Oid,
};

/// Recursively flatten a tree into its blob leaves. Caller owns the
/// returned slice and each `path` inside it (free both with the
/// supplied allocator).
///
/// `read_object` is a callback rather than a direct LooseStore
/// reference so callers using a different store (e.g. an in-memory
/// snapshot in tests) can plug in. The bytes returned by the
/// callback are borrowed for the duration of the call only — we
/// re-iterate as we recurse, so the callback must own them long
/// enough for the iteration to finish (LooseStore.read does this).
pub fn walkRecursive(
    allocator: std.mem.Allocator,
    root_oid: Oid,
    context: anytype,
    /// Signature: fn(@TypeOf(context), Oid) ![]const u8
    /// Returns the raw tree-object payload bytes for `oid`.
    /// Caller owns the returned slice — walkRecursive frees it.
    comptime read_tree: anytype,
) ![]Leaf {
    var leaves: std.ArrayListUnmanaged(Leaf) = .empty;
    errdefer {
        for (leaves.items) |l| allocator.free(l.path);
        leaves.deinit(allocator);
    }

    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix_buf.deinit(allocator);

    try walkInto(allocator, &leaves, &prefix_buf, root_oid, context, read_tree);
    return try leaves.toOwnedSlice(allocator);
}

fn walkInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Leaf),
    prefix: *std.ArrayListUnmanaged(u8),
    tree_oid: Oid,
    context: anytype,
    comptime read_tree: anytype,
) !void {
    const payload = try read_tree(context, tree_oid);
    defer allocator.free(payload);

    var it: Iterator = .{ .bytes = payload };
    while (try it.next()) |entry| {
        const saved_len = prefix.items.len;
        defer prefix.shrinkRetainingCapacity(saved_len);

        if (saved_len > 0) try prefix.append(allocator, '/');
        try prefix.appendSlice(allocator, entry.name);

        if (entry.isTree()) {
            try walkInto(allocator, out, prefix, entry.oid, context, read_tree);
        } else {
            const path_copy = try allocator.dupe(u8, prefix.items);
            try out.append(allocator, .{
                .path = path_copy,
                .mode = entry.mode,
                .oid = entry.oid,
            });
        }
    }
}

pub fn freeLeaves(allocator: std.mem.Allocator, leaves: []Leaf) void {
    for (leaves) |l| allocator.free(l.path);
    allocator.free(leaves);
}

/// True when `name` is a safe single tree-entry component. Rejects the
/// path-traversal / repo-corruption class git guards against in fsck and
/// checkout:
///   * empty
///   * "." and ".."
///   * any '/' (an entry name is a single path component, never nested)
///   * any embedded NUL (defensive — the wire format terminates the name
///     at the first NUL, but a caller could hand us a pre-sliced name)
///   * ".git" in any case-folded or NTFS/HFS-folded spelling
pub fn isValidEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c == '/' or c == 0) return false;
    }
    if (isDotGit(name)) return false;
    return true;
}

/// Match ".git" the way git's `is_ntfs_dotgit` / `is_hfs_dotgit` do —
/// case-insensitively, and defeating the filesystem-folding evasions that
/// let a crafted name resolve to `.git` on a checkout:
///   * trailing dots / spaces (NTFS strips them: ".git.", ".git ")
///   * the 8.3 short name "git~1" (NTFS)
///   * HFS+ ignorable code points interspersed (e.g. U+200C) — we strip the
///     well-known ignorables before comparing.
fn isDotGit(name: []const u8) bool {
    // NTFS: strip trailing '.' and ' ' before comparing.
    var end = name.len;
    while (end > 0 and (name[end - 1] == '.' or name[end - 1] == ' ')) end -= 1;
    const trimmed = name[0..end];

    if (eqlIgnoreAsciiCase(trimmed, ".git")) return true;
    // NTFS 8.3 short name for ".git" is "git~1".
    if (eqlIgnoreAsciiCase(trimmed, "git~1")) return true;

    // HFS+ folds away a set of "ignorable" code points. Strip them and
    // re-compare against ".git" (case-insensitive). If none are present
    // this is a cheap no-op that returns the same answer as above.
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c < 0x80) {
            if (n >= buf.len) return false;
            buf[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        // Decode one UTF-8 code point; on any malformed sequence, bail
        // (it can't equal an ASCII ".git" spelling).
        const len = std.unicode.utf8ByteSequenceLength(c) catch return false;
        if (i + len > name.len) return false;
        const cp = std.unicode.utf8Decode(name[i .. i + len]) catch return false;
        i += len;
        if (isHfsIgnorable(cp)) continue; // dropped, like HFS+ does
        return false; // a non-ignorable non-ASCII code point → not ".git"
    }
    return eqlIgnoreAsciiCase(buf[0..n], ".git");
}

fn eqlIgnoreAsciiCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// The code points HFS+ treats as ignorable in filename comparison — the
/// same list git's `is_hfs_dotgit` folds away.
fn isHfsIgnorable(cp: u21) bool {
    return switch (cp) {
        0x200C, // ZERO WIDTH NON-JOINER
        0x200D, // ZERO WIDTH JOINER
        0x200E, // LEFT-TO-RIGHT MARK
        0x200F, // RIGHT-TO-LEFT MARK
        0x202A, // LEFT-TO-RIGHT EMBEDDING
        0x202B, // RIGHT-TO-LEFT EMBEDDING
        0x202C, // POP DIRECTIONAL FORMATTING
        0x202D, // LEFT-TO-RIGHT OVERRIDE
        0x202E, // RIGHT-TO-LEFT OVERRIDE
        0x206A, // INHIBIT SYMMETRIC SWAPPING
        0x206B, // ACTIVATE SYMMETRIC SWAPPING
        0x206C, // INHIBIT ARABIC FORM SHAPING
        0x206D, // ACTIVATE ARABIC FORM SHAPING
        0x206E, // NATIONAL DIGIT SHAPES
        0x206F, // NOMINAL DIGIT SHAPES
        0xFEFF, // ZERO WIDTH NO-BREAK SPACE (BOM)
        => true,
        else => false,
    };
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

        // Reject dangerous entry names at parse time. A tree object is
        // network-reachable (clone/fetch/pull pull packs from arbitrary
        // servers) and the checkout path (worktree.applyTree/writeBlob)
        // writes leaf paths straight to disk. A name containing `/`, `..`,
        // a NUL, or `.git` (in any case- or NTFS/HFS-folded spelling) is a
        // path-traversal / repo-corruption primitive. Real git rejects the
        // same class in fsck/checkout. Refuse the whole object.
        if (!isValidEntryName(name)) return error.InvalidTreeEntryName;

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

test "isValidEntryName accepts ordinary names, rejects the traversal class" {
    // Ordinary names pass.
    try testing.expect(isValidEntryName("a.txt"));
    try testing.expect(isValidEntryName("sub"));
    try testing.expect(isValidEntryName(".gitignore")); // NOT ".git"
    try testing.expect(isValidEntryName(".gitattributes"));
    try testing.expect(isValidEntryName("git")); // bare "git" is fine
    try testing.expect(isValidEntryName("..foo"));
    try testing.expect(isValidEntryName("a..b"));

    // The dangerous class is rejected.
    try testing.expect(!isValidEntryName(""));
    try testing.expect(!isValidEntryName("."));
    try testing.expect(!isValidEntryName(".."));
    try testing.expect(!isValidEntryName("a/b"));
    try testing.expect(!isValidEntryName("/"));
    try testing.expect(!isValidEntryName("../evil"));
    try testing.expect(!isValidEntryName("a\x00b"));

    // .git in every folded spelling.
    try testing.expect(!isValidEntryName(".git"));
    try testing.expect(!isValidEntryName(".GIT"));
    try testing.expect(!isValidEntryName(".Git"));
    try testing.expect(!isValidEntryName(".git.")); // NTFS trailing dot
    try testing.expect(!isValidEntryName(".git ")); // NTFS trailing space
    try testing.expect(!isValidEntryName(".git..  ")); // mixed trailing
    try testing.expect(!isValidEntryName("git~1")); // NTFS 8.3 short name
    try testing.expect(!isValidEntryName("GIT~1"));
    try testing.expect(!isValidEntryName(".g\u{200c}it")); // HFS ignorable ZWNJ
    try testing.expect(!isValidEntryName(".gi\u{200d}t")); // HFS ignorable ZWJ
}

test "Iterator.next rejects a tree entry named .. " {
    // Build a payload with a single subtree entry named "..".
    var oid: Oid = undefined;
    @memset(&oid.bytes, 0x11);
    const bad: Entry = .{ .mode = tree_mode_octal, .name = "..", .oid = oid };
    // serialize() doesn't validate (it trusts locally-built entries), so we
    // can use it to forge a hostile payload and confirm the PARSER refuses.
    const bytes = try serialize(testing.allocator, &.{bad});
    defer testing.allocator.free(bytes);

    var it: Iterator = .{ .bytes = bytes };
    try testing.expectError(error.InvalidTreeEntryName, it.next());
}

test "Iterator.next rejects a tree entry named .git" {
    var oid: Oid = undefined;
    @memset(&oid.bytes, 0x22);
    const bad: Entry = .{ .mode = tree_mode_octal, .name = ".git", .oid = oid };
    const bytes = try serialize(testing.allocator, &.{bad});
    defer testing.allocator.free(bytes);

    var it: Iterator = .{ .bytes = bytes };
    try testing.expectError(error.InvalidTreeEntryName, it.next());
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
