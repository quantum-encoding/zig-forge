// Walk the work tree and produce a flat list of every file.
//
// Skips:
//   - `.git/`               — hardcoded; git's own metadata. Never
//                             driven by `.gitignore` (which doesn't
//                             list it).
//   - `.git/index.tmp`      — rename target should never be visible
//                             here, but we'd ignore it on principle.
//   - Symlinked directories — symlinks (regardless of target) are
//                             emitted as leaves, never descended.
//                             Iterator's lstat semantics give us
//                             `entry.kind == .sym_link` even when
//                             the target is a directory.
//
// Optional ruleset filtering: when a `*const Ruleset` is supplied,
// the walker honours its prune contract — directories matching
// `ruleset.isIgnoredDir(rel_path)` are NOT descended (correctness
// boundary, not just perf), and files/symlinks matching
// `ruleset.isIgnored(rel_path, false)` are not emitted. Pass `null`
// to walk every untracked path (the legacy behaviour).

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Ruleset = @import("ignore/ruleset.zig").Ruleset;

pub const Mode = enum { regular, executable, symlink };

pub const Entry = struct {
    /// Slash-separated path relative to the work-tree root. Owned.
    path: []u8,
    mode: Mode,
};

/// Owned slice of Entry. Free with `freeEntries`.
pub const Listing = []Entry;

pub fn freeEntries(allocator: std.mem.Allocator, listing: Listing) void {
    for (listing) |e| allocator.free(e.path);
    allocator.free(listing);
}

pub fn walk(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    ruleset: ?*const Ruleset,
) !Listing {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }

    // We need an iterable handle on the same directory, so reopen
    // with .iterate=true. The original handle stays untouched.
    var iter_root = try work_root.openDir(io, ".", .{ .iterate = true });
    defer iter_root.close(io);

    var walker = try iter_root.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |w_entry| {
        // Normalise to forward-slashes so paths match index storage
        // even on Windows. The walker uses path.sep which is '\\' on
        // win32 — easy fix when we get there.
        switch (w_entry.kind) {
            .directory => {
                if (std.mem.eql(u8, w_entry.basename, ".git")) continue;
                // PRUNE: an excluded directory must not be entered.
                // This is the correctness boundary, not just a perf
                // hint — see docs/V1_1_SPEC.md and ruleset.zig's
                // file header. Skipping the `enter` is identical to
                // git not descending into excluded subtrees.
                if (ruleset) |rs| {
                    if (rs.isIgnoredDir(w_entry.path)) continue;
                }
                try walker.enter(io, w_entry);
            },
            .file => {
                if (ruleset) |rs| {
                    if (rs.isIgnored(w_entry.path, false)) continue;
                }
                try entries.append(allocator, .{
                    .path = try allocator.dupe(u8, w_entry.path),
                    .mode = .regular, // permissions check happens at stat-time
                });
            },
            .sym_link => {
                // Symlinks (to files OR directories) are emitted as
                // leaves and not followed. The `entry.kind` is the
                // lstat result, not stat — so a symlink-to-dir
                // never reaches the .directory branch above.
                if (ruleset) |rs| {
                    if (rs.isIgnored(w_entry.path, false)) continue;
                }
                try entries.append(allocator, .{
                    .path = try allocator.dupe(u8, w_entry.path),
                    .mode = .symlink,
                });
            },
            else => {},
        }
    }

    // Stable order for downstream comparisons.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    return try entries.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const ruleset_mod = @import("ignore/ruleset.zig");

fn pathsOf(listing: Listing) ![]const []const u8 {
    const paths = try testing.allocator.alloc([]const u8, listing.len);
    for (listing, 0..) |e, i| paths[i] = e.path;
    return paths;
}

test "walk: no ruleset emits every file under work tree, skips .git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.log", .data = "x" });
    try tmp.dir.createDirPath(testing.io, ".git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/HEAD", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/nested.txt", .data = "x" });

    const listing = try walk(testing.allocator, testing.io, tmp.dir, null);
    defer freeEntries(testing.allocator, listing);

    try testing.expectEqual(@as(usize, 3), listing.len);
    // Sorted alphabetically. `.git` entries are NOT present.
    try testing.expectEqualStrings("a.txt", listing[0].path);
    try testing.expectEqualStrings("b.log", listing[1].path);
    try testing.expectEqualStrings("sub/nested.txt", listing[2].path);
}

test "walk: ruleset filters files at the leaf level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "keep.txt", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "drop.log", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/also.log", .data = "x" });

    var rs = try ruleset_mod.load(testing.allocator, testing.io, tmp.dir, .{});
    defer rs.deinit();

    const listing = try walk(testing.allocator, testing.io, tmp.dir, &rs);
    defer freeEntries(testing.allocator, listing);

    // .gitignore itself is tracked by convention; the walker still
    // emits it (the index/already-tracked check at the caller level
    // handles tracked-but-ignored). Keep.txt is emitted. Both
    // .log files are filtered out (the deep one via basename match).
    try testing.expectEqual(@as(usize, 2), listing.len);
    try testing.expectEqualStrings(".gitignore", listing[0].path);
    try testing.expectEqualStrings("keep.txt", listing[1].path);
}

test "walk: ruleset prunes excluded directories (no descent at all)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "node_modules/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src.zig", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "node_modules/pkg");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "node_modules/lib.js", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "node_modules/pkg/index.js", .data = "x" });

    var rs = try ruleset_mod.load(testing.allocator, testing.io, tmp.dir, .{});
    defer rs.deinit();

    const listing = try walk(testing.allocator, testing.io, tmp.dir, &rs);
    defer freeEntries(testing.allocator, listing);

    // Only the root-level files. Nothing under node_modules/ was
    // even iterated — the prune fired at the descent decision.
    try testing.expectEqual(@as(usize, 2), listing.len);
    try testing.expectEqualStrings(".gitignore", listing[0].path);
    try testing.expectEqualStrings("src.zig", listing[1].path);
}

test "walk: prune-boundary — !-rule inside excluded dir does NOT resurrect files" {
    // The headline correctness test, end-to-end through the walker.
    // Root `.gitignore` excludes `bar/`. `bar/.gitignore` has
    // `!keep.txt`. The negation can't reach because the walker
    // never descends into `bar/`. Files inside stay invisible.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "bar/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "visible.txt", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "bar");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bar/.gitignore", .data = "!keep.txt\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bar/keep.txt", .data = "x" });

    var rs = try ruleset_mod.load(testing.allocator, testing.io, tmp.dir, .{});
    defer rs.deinit();

    const listing = try walk(testing.allocator, testing.io, tmp.dir, &rs);
    defer freeEntries(testing.allocator, listing);

    // .gitignore + visible.txt only. Crucially, `bar/keep.txt` is
    // NOT in the listing — even though, viewed in isolation, the
    // ruleset wouldn't actively flag `bar/keep.txt` as ignored
    // (the dir_only `bar/` pattern doesn't match a file path).
    // The correctness comes from never visiting it.
    try testing.expectEqual(@as(usize, 2), listing.len);
    try testing.expectEqualStrings(".gitignore", listing[0].path);
    try testing.expectEqualStrings("visible.txt", listing[1].path);
}

test "walk: symlink (to file) is emitted as a leaf, not followed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.txt", .data = "x" });
    tmp.dir.symLink(testing.io, "target.txt", "alias", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const listing = try walk(testing.allocator, testing.io, tmp.dir, null);
    defer freeEntries(testing.allocator, listing);

    try testing.expectEqual(@as(usize, 2), listing.len);
    try testing.expectEqualStrings("alias", listing[0].path);
    try testing.expectEqual(Mode.symlink, listing[0].mode);
    try testing.expectEqualStrings("target.txt", listing[1].path);
    try testing.expectEqual(Mode.regular, listing[1].mode);
}

test "walk: symlink-to-directory is treated as a leaf, NEVER descended" {
    // Critical guard against the infinite-loop / out-of-repo
    // cases. A symlink whose target is a directory shows up with
    // kind = .sym_link (lstat), so the walker emits it without
    // calling enter().
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "real_dir");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real_dir/inside.txt", .data = "x" });
    tmp.dir.symLink(testing.io, "real_dir", "link_dir", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const listing = try walk(testing.allocator, testing.io, tmp.dir, null);
    defer freeEntries(testing.allocator, listing);

    // We expect:
    //   link_dir            (the symlink itself, as a leaf)
    //   real_dir/inside.txt (the real file, reached via real_dir)
    // What we MUST NOT see is `link_dir/inside.txt` — that would
    // mean the walker followed the symlink.
    try testing.expectEqual(@as(usize, 2), listing.len);
    try testing.expectEqualStrings("link_dir", listing[0].path);
    try testing.expectEqual(Mode.symlink, listing[0].mode);
    try testing.expectEqualStrings("real_dir/inside.txt", listing[1].path);
}
