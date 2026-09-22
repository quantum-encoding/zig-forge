//! Narrowing a list of findings, over raw path bytes.
//!
//! A whole-disk scan produces more findings than anyone reads top to bottom, so
//! every list the results session serves can be narrowed by a size floor, a
//! substring, and three facets — where a member is, what it is called, and what
//! type it is. The facets describe ONE member: "a folder called `src` under
//! `~/work`", never "something under `~/work` and, elsewhere, something called
//! `src`".
//!
//! Matching works on the byte slices the store hands out: nothing here copies a
//! path, and `Matcher.init` is the only allocating call (two small lower-cased
//! copies of the query itself).

const std = @import("std");

/// What a caller asks a list of findings to be narrowed by. All fields
/// optional; this whole value is the cache key for a computed row order, so
/// `eql` must compare every field.
pub const Filters = struct {
    /// ASCII-case-insensitive substring of any member's path; non-ASCII bytes
    /// must match exactly.
    text: []const u8 = "",
    /// Smallest finding to show. What "size" means is per kind: a file's size,
    /// a folder set's size per copy, an overlap's shared size.
    min_bytes: u64 = 0,
    /// Overlaps only: hide pairs where each side still has something unique.
    redundant_only: bool = false,
    /// Location facet: a member lies at or below this directory.
    under: ?[]const u8 = null,
    /// Name facet: that member is called exactly this.
    name: ?[]const u8 = null,
    /// Type facet: that member has this extension, lower-case with the dot
    /// (".png"); the empty string means "no extension".
    ext: ?[]const u8 = null,

    pub fn eql(a: Filters, b: Filters) bool {
        return std.mem.eql(u8, a.text, b.text) and
            a.min_bytes == b.min_bytes and
            a.redundant_only == b.redundant_only and
            optEql(a.under, b.under) and
            optEql(a.name, b.name) and
            optEql(a.ext, b.ext);
    }

    /// A copy owning its own strings, for holding past the arena that parsed it.
    pub fn clone(self: Filters, gpa: std.mem.Allocator) !Filters {
        var out: Filters = .{ .min_bytes = self.min_bytes, .redundant_only = self.redundant_only };
        errdefer out.deinit(gpa);
        out.text = try gpa.dupe(u8, self.text);
        if (self.under) |s| out.under = try gpa.dupe(u8, s);
        if (self.name) |s| out.name = try gpa.dupe(u8, s);
        if (self.ext) |s| out.ext = try gpa.dupe(u8, s);
        return out;
    }

    pub fn deinit(self: Filters, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.under) |s| gpa.free(s);
        if (self.name) |s| gpa.free(s);
        if (self.ext) |s| gpa.free(s);
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return std.mem.eql(u8, a.?, b.?);
}

/// The part of `path` after its last slash.
pub fn baseName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// Extension including the dot, or empty. A leading dot is a hidden file, not
/// an extension: `.gitignore` has none, `a.tar.gz` has `.gz`. The case is the
/// path's own; compare with `std.ascii.eqlIgnoreCase`.
pub fn extension(path: []const u8) []const u8 {
    const name = baseName(path);
    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (i == 0 or i + 1 >= name.len) return "";
    return name[i..];
}

/// True if `path` is `base` itself or lies below it, by whole path components:
/// `/a/proj-backup` is not below `/a/proj`.
pub fn isAtOrUnder(path: []const u8, base_in: []const u8) bool {
    const base = if (base_in.len > 1 and base_in[base_in.len - 1] == '/')
        base_in[0 .. base_in.len - 1]
    else
        base_in;
    if (std.mem.eql(u8, base, "/")) return path.len > 0 and path[0] == '/';
    return std.mem.startsWith(u8, path, base) and
        (path.len == base.len or path[base.len] == '/');
}

/// The child of `base` that `path` lives in: `/a/b/c/d` under `/a` is `/a/b`.
/// `path == base` yields `base` itself. Null if `path` is not under `base`.
pub fn areaUnder(path: []const u8, base_in: []const u8) ?[]const u8 {
    if (!isAtOrUnder(path, base_in)) return null;
    const base = if (base_in.len > 1 and base_in[base_in.len - 1] == '/')
        base_in[0 .. base_in.len - 1]
    else
        base_in;
    // First byte of the component below `base`.
    const start: usize = if (std.mem.eql(u8, base, "/")) 1 else base.len + 1;
    if (path.len <= start) return path; // `path` is `base` itself
    const rest = path[start..];
    const next = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return path[0 .. start + next];
}

/// ASCII-case-insensitive substring test. `needle` must already be lower-cased.
/// Non-ASCII bytes compare exactly.
pub fn containsIgnoreAsciiCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != needle[i]) break;
        } else return true;
    }
    return false;
}

/// The path of a member, whatever shape the caller's list holds: a bare path
/// slice, or any record with a `path` field (an alive file, a set directory).
inline fn pathOf(member: anytype) []const u8 {
    const T = @TypeOf(member);
    if (T == []const u8 or T == []u8) return member;
    return member.path;
}

/// `Filters` prepared for matching many paths.
pub const Matcher = struct {
    /// Trimmed and lower-cased; empty means "no text filter".
    text: []const u8,
    under: ?[]const u8,
    name: ?[]const u8,
    ext: ?[]const u8,
    min_bytes: u64,
    redundant_only: bool,

    /// `text` and `ext` are lower-cased into `arena`; the rest is borrowed from
    /// `filters`, which must outlive the matcher.
    pub fn init(arena: std.mem.Allocator, filters: Filters) !Matcher {
        const trimmed = std.mem.trim(u8, filters.text, " \t\r\n");
        const text = try arena.alloc(u8, trimmed.len);
        for (trimmed, text) |c, *out| out.* = std.ascii.toLower(c);
        return .{
            .text = text,
            .under = filters.under,
            .name = filters.name,
            // Compared with `std.ascii.eqlIgnoreCase`, so it is kept as given.
            .ext = filters.ext,
            .min_bytes = filters.min_bytes,
            .redundant_only = filters.redundant_only,
        };
    }

    /// Location, name and type all hold for this one member.
    pub fn memberSelected(self: *const Matcher, path: []const u8) bool {
        if (self.under) |base| {
            if (!isAtOrUnder(path, base)) return false;
        }
        if (self.name) |want| {
            if (!std.mem.eql(u8, baseName(path), want)) return false;
        }
        if (self.ext) |want| {
            if (!std.ascii.eqlIgnoreCase(extension(path), want)) return false;
        }
        return true;
    }

    pub fn hasMemberFacets(self: *const Matcher) bool {
        return self.under != null or self.name != null or self.ext != null;
    }

    /// Does a finding of `bytes` with these members pass? `members` is a slice
    /// of path slices, or of records carrying a `path` field.
    pub fn matches(self: *const Matcher, bytes: u64, members: anytype) bool {
        if (bytes < self.min_bytes) return false;
        if (self.hasMemberFacets()) {
            const any = for (members) |m| {
                if (self.memberSelected(pathOf(m))) break true;
            } else false;
            if (!any) return false;
        }
        if (self.text.len == 0) return true;
        return for (members) |m| {
            if (containsIgnoreAsciiCase(pathOf(m), self.text)) break true;
        } else false;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn matcher(arena: std.mem.Allocator, filters: Filters) !Matcher {
    return Matcher.init(arena, filters);
}

test "names and extensions" {
    try testing.expectEqualStrings("c.txt", baseName("/a/b/c.txt"));
    try testing.expectEqualStrings("plain", baseName("plain"));
    try testing.expectEqualStrings(".PNG", extension("/a/Photo.PNG"));
    try testing.expectEqualStrings(".gz", extension("/a/archive.tar.gz"));
    try testing.expectEqualStrings("", extension("/a/.gitignore"));
    try testing.expectEqualStrings("", extension("/a/Makefile"));
    try testing.expectEqualStrings("", extension("/a/trailing."));
    // The dot must be in the file name, not in a directory above it.
    try testing.expectEqualStrings("", extension("/a/v1.2/binary"));
}

test "under means a whole path component" {
    try testing.expect(isAtOrUnder("/a/proj", "/a/proj"));
    try testing.expect(isAtOrUnder("/a/proj/src/x", "/a/proj"));
    try testing.expect(isAtOrUnder("/a/proj/src", "/a/proj/"));
    try testing.expect(!isAtOrUnder("/a/proj-backup/src", "/a/proj"));
    try testing.expect(!isAtOrUnder("/a", "/a/proj"));
    try testing.expect(isAtOrUnder("/anything", "/"));
}

test "areas are the next level down" {
    try testing.expectEqualStrings("/home/u/work", areaUnder("/home/u/work/app/src", "/home/u").?);
    try testing.expectEqualStrings("/home/u/work", areaUnder("/home/u/work", "/home/u").?);
    try testing.expectEqualStrings("/home/u", areaUnder("/home/u", "/home/u").?);
    try testing.expectEqualStrings("/home/u/file.txt", areaUnder("/home/u/file.txt", "/home/u/").?);
    try testing.expectEqualStrings("/usr", areaUnder("/usr/lib/x", "/").?);
    try testing.expect(areaUnder("/home/user2/x", "/home/u") == null);
}

test "size, text and facets combine" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const members = [_][]const u8{ "/home/u/work/App/src", "/mnt/backup/app/src" };

    try testing.expect((try matcher(a, .{})).matches(10, &members));
    try testing.expect(!(try matcher(a, .{ .min_bytes = 11 })).matches(10, &members));
    try testing.expect((try matcher(a, .{ .text = "  BACKUP " })).matches(10, &members));
    try testing.expect(!(try matcher(a, .{ .text = "nowhere" })).matches(10, &members));
    try testing.expect((try matcher(a, .{ .under = "/mnt" })).matches(10, &members));
    try testing.expect(!(try matcher(a, .{ .under = "/srv" })).matches(10, &members));
    try testing.expect((try matcher(a, .{ .name = "src" })).matches(10, &members));
    try testing.expect((try matcher(a, .{ .ext = ".SRC" })).matches(10, &[_][]const u8{"/a/x.src"}));
}

test "location and name must hold for the same member" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Something is under /mnt, and something is called "lib" — but not the same
    // member, so "a folder called lib under /home" is false.
    const members = [_][]const u8{ "/home/u/work/src", "/mnt/backup/lib" };
    try testing.expect(!(try matcher(a, .{ .under = "/home", .name = "lib" })).matches(10, &members));
    try testing.expect((try matcher(a, .{ .under = "/mnt", .name = "lib" })).matches(10, &members));
}

test "matches accepts records carrying a path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Row = struct { path: []const u8, mtime: i64 };
    const rows = [_]Row{.{ .path = "/a/b/Photo.PNG", .mtime = 0 }};
    try testing.expect((try matcher(arena.allocator(), .{ .ext = ".png" })).matches(1, &rows));
}

test "filters compare by value, including the optional facets" {
    const base: Filters = .{ .text = "x", .min_bytes = 5 };
    try testing.expect(base.eql(.{ .text = "x", .min_bytes = 5 }));
    try testing.expect(!base.eql(.{ .text = "x", .min_bytes = 6 }));
    try testing.expect(!base.eql(.{ .text = "x", .min_bytes = 5, .under = "/a" }));
    try testing.expect((Filters{ .under = "/a" }).eql(.{ .under = "/a" }));
    try testing.expect(!(Filters{ .under = "/a" }).eql(.{ .under = "/b" }));

    var owned = try (Filters{ .text = "t", .ext = ".png" }).clone(testing.allocator);
    defer owned.deinit(testing.allocator);
    try testing.expect(owned.eql(.{ .text = "t", .ext = ".png" }));
}
