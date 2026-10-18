//! Real paths for the folders a scan starts from, and the folders a host names.
//!
//! Protection, excludes, keep rules and every comparison of paths in the core
//! match bytes as spelled. The walker follows a root that is a link, so a root
//! spelled through one would be walked under a spelling no rule recognises:
//! macOS `/tmp` and `/var` (only `/private/...` is listed), or a user's
//! `~/sys` pointing at `/System`, whose contents would be walked as
//! `~/sys/...` with nothing in them protected. So every root is resolved to
//! its real path before a walk, and results and stores carry real paths.
//!
//! The platform's own call: `realpath` on POSIX, the final path by handle on
//! Windows (sys_windows.zig), in the core's form (forward slashes, an
//! upper-case drive letter). A path that does not resolve is kept as given:
//! the walk then fails on it as it always has.

const std = @import("std");
const sys = @import("sys.zig");
const filters = @import("filters.zig");

const Allocator = std.mem.Allocator;

/// The real path of `path`, owned, or null when it cannot be resolved
/// (missing, unreadable).
pub fn of(gpa: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (path.len == 0) return null;
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const resolved = sys.c.realpath(z.ptr, &buf) orelse return null;
    return try gpa.dupe(u8, filters.trimSep(std.mem.span(resolved)));
}

/// The real path of `path` when it resolves, else `path` itself; owned.
pub fn orGiven(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return (try of(gpa, path)) orelse try gpa.dupe(u8, path);
}

/// `orGiven` for each of `paths`; free with `freeAll`.
pub fn allOrGiven(gpa: Allocator, paths: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, paths.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |p| gpa.free(p);
        gpa.free(out);
    }
    for (paths, out) |p, *slot| {
        slot.* = try orGiven(gpa, p);
        filled += 1;
    }
    return out;
}

pub fn freeAll(gpa: Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

// ---------------------------------------------------------------------------
// Delete targets: acted on as given, never through a link
// ---------------------------------------------------------------------------
//
// Resolving is for scanning and matching. Whatever is deleted, trashed or
// trusted as the copy that survives must be named by its own real path, so
// the entry acted on is the one the request names and every rule matched
// against that path (protection above all) saw where it really is. These are
// asked immediately before each action, never remembered.

/// Every folder above `path` is a real folder reached through no link (and
/// exists). Its last component is the caller's to check (`lstat`), which
/// tells a link there apart from a missing entry.
pub fn parentIsReal(path: []const u8) bool {
    const parent = filters.parentDir(path) orelse return true;
    return isReal(parent);
}

/// `path` exists and is its own real path: no link anywhere in it.
pub fn isReal(path: []const u8) bool {
    var in_buf: [sys.c.PATH_MAX]u8 = undefined;
    if (path.len >= in_buf.len) return false;
    @memcpy(in_buf[0..path.len], path);
    in_buf[path.len] = 0;
    var out_buf: [sys.c.PATH_MAX]u8 = undefined;
    const resolved = sys.c.realpath(@ptrCast(&in_buf), &out_buf) orelse return false;
    return std.mem.eql(u8, filters.trimSep(std.mem.span(resolved)), filters.trimSep(path));
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

test "a link resolves to what it names; a missing path is kept as given" {
    var s = try Scratch.init(testing.allocator, "realpath");
    defer s.deinit();
    try s.makeDir("real");
    try s.makeDir("real/inner");
    try s.symLink("real", "link");
    const link = try s.join("link/inner");
    defer testing.allocator.free(link);
    const want = try s.join("real/inner");
    defer testing.allocator.free(want);
    const got = (try of(testing.allocator, link)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);

    try testing.expect(try of(testing.allocator, "/nonexistent/zdedupe/x") == null);
    const kept = try orGiven(testing.allocator, "/nonexistent/zdedupe/x");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("/nonexistent/zdedupe/x", kept);
}

test "a path through a link is not its own real path" {
    var s = try Scratch.init(testing.allocator, "realpath-exact");
    defer s.deinit();
    try s.makeDir("real");
    try s.writeFile("real/f", "x");
    try s.symLink("real", "link");
    const real_f = try s.join("real/f");
    defer testing.allocator.free(real_f);
    const via = try s.join("link/f");
    defer testing.allocator.free(via);
    const link = try s.join("link");
    defer testing.allocator.free(link);
    try testing.expect(isReal(real_f) and parentIsReal(real_f));
    try testing.expect(!isReal(via) and !parentIsReal(via));
    // The link itself: its parent is real, it is not.
    try testing.expect(parentIsReal(link) and !isReal(link));
    try testing.expect(!isReal("/nonexistent/zdedupe/x"));
    try testing.expect(parentIsReal("/"));
}
