// Materialise / unmaterialise a tree against the work tree.
//
// `applyTree` walks a tree object recursively and writes every blob
// to disk under `work_root`, creating any missing directories.
// `removePaths` deletes a list of paths from disk, tolerant of
// already-missing entries.
//
// Neither function touches the index — that's the caller's job
// (switch/checkout rebuild the index from the new tree once the
// disk write succeeds).
//
// Symlink discipline (v1.1, see docs/V1_1_SPEC.md Part 2):
//   * Mode `120000` blobs are materialised via `Dir.symLink` — the
//     blob payload is the link TARGET STRING (e.g. `../foo`), not
//     the contents of any file. We do NOT stat or open the target
//     before creating the link; dangling symlinks are legal git
//     state and the discipline is "lstat semantics, never stat".
//   * Before writing any entry (file or symlink), we lstat the
//     existing path and unlink it if it's a symlink. Without this,
//     `writeFile` on a path that's currently a symlink would
//     follow the link and overwrite the TARGET's contents — which
//     could be outside the work tree.
//   * On Windows, `symLink` requires `SeCreateSymbolicLinkPrivilege`
//     (developer mode). On the AccessDenied case we fall back to
//     writing the target string as a regular file plus a stderr
//     warning. v1.1 doesn't test Windows in CI; the fallback is
//     correctness insurance.
//
// What we don't do here:
//   * Empty-directory pruning — when removePaths leaves a directory
//     empty, we don't remove it. Real git does, and shipping it is
//     trivial (try deleteDir, swallow ENOTEMPTY); deferred to keep
//     the diff small.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Oid = @import("object/oid.zig").Oid;
const tree_mod = @import("object/tree.zig");
const LooseStore = @import("object/loose_store.zig").LooseStore;
const Kind = @import("object/kind.zig").Kind;

pub const ApplyError = error{ NotABlob } || Io.UnexpectedError;

/// Walk `tree_oid` recursively and write every blob to `work_root`.
/// Existing entries are removed-and-replaced. Mode bits are honoured
/// to the extent the platform allows: 100755 → executable bit set on
/// POSIX, 100644 → non-executable, 120000 → real OS symlink.
pub fn applyTree(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    store: *LooseStore,
    tree_oid: Oid,
) !void {
    const Reader = struct {
        s: *LooseStore,
        a: std.mem.Allocator,
        fn read(self: @This(), oid: Oid) ![]const u8 {
            const loaded = try self.s.read(self.a, oid);
            return loaded.payload;
        }
    };
    const leaves = try tree_mod.walkRecursive(allocator, tree_oid, Reader{ .s = store, .a = allocator }, Reader.read);
    defer tree_mod.freeLeaves(allocator, leaves);

    for (leaves) |leaf| {
        try writeBlob(allocator, io, work_root, store, leaf.path, leaf.mode, leaf.oid);
    }
}

fn writeBlob(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    store: *LooseStore,
    rel_path: []const u8,
    mode: u32,
    oid: Oid,
) !void {
    // Refuse to write through a symlinked parent. `createDirPath` follows an
    // existing symlink component, so a mode-120000 blob materialised earlier
    // in this same `applyTree` pass as a real OS symlink (e.g. `d` → /tmp/x)
    // would let a later leaf `d/f` escape the work root — the classic checkout
    // "plant a symlink, then write through it" attack. Tree-entry name
    // validation (object/tree.isValidEntryName) already blocks `..`/`/`/`.git`
    // inside a single component; this closes the cross-entry ordering gap.
    try assertParentsNotSymlinked(io, work_root, rel_path);

    if (std.fs.path.dirname(rel_path)) |parent| {
        try work_root.createDirPath(io, parent);
    }

    var loaded = try store.read(allocator, oid);
    defer loaded.deinit(allocator);
    if (loaded.kind != .blob) return error.NotABlob;

    // Unlink any existing entry that's a symlink BEFORE writing, so
    // `writeFile` doesn't follow the link and clobber the target's
    // contents. This also handles the symlink→file transition. lstat
    // semantics via `follow_symlinks = false` are load-bearing here.
    if (work_root.statFile(io, rel_path, .{ .follow_symlinks = false })) |existing| {
        if (existing.kind == .sym_link) {
            work_root.deleteFile(io, rel_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (mode == tree_mod.blob_mode_symlink) {
        // Mode 120000: the blob payload IS the link target string.
        // Create the symlink WITHOUT checking whether the target
        // exists — dangling symlinks are legal git state and the
        // checkout must materialise them anyway.
        //
        // `symLink` returns PathAlreadyExists if `rel_path` is a
        // regular file or directory; in that case we unlink and
        // retry once. (We already unlinked existing symlinks above.)
        const target = loaded.payload;
        work_root.symLink(io, target, rel_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                work_root.deleteFile(io, rel_path) catch |e2| switch (e2) {
                    error.FileNotFound, error.IsDir => {},
                    else => return e2,
                };
                try work_root.symLink(io, target, rel_path, .{});
            },
            error.AccessDenied, error.PermissionDenied => {
                // Windows fallback. Write the target string as a
                // regular file so the checkout doesn't fail outright.
                try work_root.writeFile(io, .{ .sub_path = rel_path, .data = target });
                var buf: [Dir.max_path_bytes + 96]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "warning: wrote symlink '{s}' as a regular file (symlink permission denied)\n",
                    .{rel_path},
                ) catch return;
                File.stderr().writeStreamingAll(io, msg) catch {};
            },
            else => return err,
        };
        return; // symlinks have no executable bit
    }

    // Regular file (mode 100644 / 100755).
    try work_root.writeFile(io, .{ .sub_path = rel_path, .data = loaded.payload });

    if (mode == tree_mod.blob_mode_executable) {
        if (work_root.openFile(io, rel_path, .{})) |f| {
            defer f.close(io);
            f.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }
}

/// lstat every parent component of `rel_path` (a '/'-joined relative path)
/// and refuse if any existing component is a symlink. Each prefix is checked
/// with `follow_symlinks = false`, so the prefix's own final component is
/// evaluated without dereference; we return on the first symlink, before path
/// resolution would traverse it, so a symlinked component is never followed.
fn assertParentsNotSymlinked(io: Io, work_root: Dir, rel_path: []const u8) !void {
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rel_path, end, '/')) |slash| {
        const prefix = rel_path[0..slash];
        if (prefix.len > 0) {
            if (work_root.statFile(io, prefix, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) return error.UnsafeSymlinkInPath;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        end = slash + 1;
    }
}

/// Best-effort delete of every path in `paths` (in order). FileNotFound
/// is silently swallowed so callers can pass paths that may or may not
/// exist (e.g. files removed by an earlier checkout step).
pub fn removePaths(io: Io, work_root: Dir, paths: []const []const u8) !void {
    for (paths) |p| {
        work_root.deleteFile(io, p) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => {},
            else => return err,
        };
    }
}

const testing = std.testing;

test "assertParentsNotSymlinked refuses a symlinked parent component" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A plain nested path with no symlink parents is allowed (nothing exists
    // yet — FileNotFound on the parents is fine).
    try assertParentsNotSymlinked(io, tmp.dir, "a/b/c.txt");

    // Real directories as parents are allowed.
    try tmp.dir.createDirPath(io, "real/sub");
    try assertParentsNotSymlinked(io, tmp.dir, "real/sub/c.txt");

    // Plant a symlink `d` (the attack: a mode-120000 blob checked out first),
    // then a later leaf `d/f` must be refused rather than written through it.
    try tmp.dir.symLink(io, "/tmp", "d", .{});
    try testing.expectError(
        error.UnsafeSymlinkInPath,
        assertParentsNotSymlinked(io, tmp.dir, "d/f"),
    );
    // Deeper below the symlink is refused too.
    try testing.expectError(
        error.UnsafeSymlinkInPath,
        assertParentsNotSymlinked(io, tmp.dir, "d/e/f"),
    );
}
