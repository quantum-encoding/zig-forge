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
// What we don't do here:
//   * Symlink writes — Phase 5 cuts: blobs at mode 120000 are
//     written as plain files. Real link semantics land alongside the
//     symlink-aware index work.
//   * Empty-directory pruning — when removePaths leaves a directory
//     empty, we don't remove it. Real git does, and shipping it is
//     trivial (try deleteDir, swallow ENOTEMPTY); deferred to keep
//     the diff small.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Oid = @import("object/oid.zig").Oid;
const tree_mod = @import("object/tree.zig");
const LooseStore = @import("object/loose_store.zig").LooseStore;
const Kind = @import("object/kind.zig").Kind;

pub const ApplyError = error{ NotABlob } || Io.UnexpectedError;

/// Walk `tree_oid` recursively and write every blob to `work_root`.
/// Existing files are overwritten. Mode bits are honoured to the
/// extent the platform allows: 100755 → executable bit set on POSIX,
/// 100644 → non-executable, 120000 → currently same as 100644 (TODO).
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
    if (std.fs.path.dirname(rel_path)) |parent| {
        try work_root.createDirPath(io, parent);
    }

    var loaded = try store.read(allocator, oid);
    defer loaded.deinit(allocator);
    if (loaded.kind != .blob) return error.NotABlob;

    try work_root.writeFile(io, .{ .sub_path = rel_path, .data = loaded.payload });

    // POSIX executable bit. Permissions API is fairly chunky; the
    // current handle-based approach is to set permissions on the file
    // we just wrote.
    if (mode == 0o100755) {
        if (work_root.openFile(io, rel_path, .{})) |f| {
            defer f.close(io);
            f.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
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
