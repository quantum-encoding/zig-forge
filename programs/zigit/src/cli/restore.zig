// `zigit restore [--staged] PATH...`
//
// Two modes, mirroring real git:
//
//   No flags:            Restore PATH(s) in the work tree from the
//                        index. Throws away unstaged edits.
//   --staged:            Restore PATH(s) in the index from HEAD's
//                        tree. Effectively unstages without touching
//                        the work tree.
//
// We don't yet support `--source=COMMIT` (restore a specific path
// from an arbitrary commit) — workdir-from-index and index-from-HEAD
// are the two cases that cover ~99% of day-to-day use.
//
// Pathspec is exact-match only — no globbing. Pass paths verbatim.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var staged = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--staged") or std.mem.eql(u8, a, "-S")) {
            staged = true;
        } else {
            try paths.append(allocator, a);
        }
    }
    if (paths.items.len == 0) return error.MissingPath;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    if (staged) {
        try restoreStaged(allocator, io, &repo, &store, paths.items);
    } else {
        try restoreWorkdir(allocator, io, &repo, &store, paths.items);
    }
}

fn restoreWorkdir(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    paths: []const []const u8,
) !void {
    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    var work_root = try openWorkRoot(io, repo);
    defer work_root.close(io);

    for (paths) |path| {
        var found = false;
        for (index.entries.items) |e| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            found = true;
            var loaded = try store.read(allocator, e.oid);
            defer loaded.deinit(allocator);
            if (loaded.kind != .blob) return error.NotABlob;

            if (std.fs.path.dirname(path)) |parent| {
                try work_root.createDirPath(io, parent);
            }
            try work_root.writeFile(io, .{ .sub_path = path, .data = loaded.payload });
            break;
        }
        if (!found) {
            // Restore-from-index of an unindexed file: just delete it.
            // (Matches real git's behaviour of refusing to restore
            // untracked paths — but for the simpler case where the
            // user explicitly named the path, we treat "not in index"
            // as an error to avoid surprises.)
            var msg_buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "error: pathspec '{s}' did not match any file known to zigit\n", .{path});
            try File.stderr().writeStreamingAll(io, msg);
            return error.PathspecNotFound;
        }
    }
}

fn restoreStaged(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    paths: []const []const u8,
) !void {
    // Build HEAD tree's path → (mode, oid) map.
    var head_map = try buildHeadTreeMap(allocator, io, repo.git_dir, store);
    defer freeMap(allocator, &head_map);

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    for (paths) |path| {
        if (head_map.get(path)) |slot| {
            // Find the existing index entry to overwrite, or insert anew.
            const existing_idx_opt = blk: {
                for (index.entries.items, 0..) |e, i| {
                    if (std.mem.eql(u8, e.path, path)) break :blk i;
                }
                break :blk null;
            };
            if (existing_idx_opt) |i| {
                var entry = index.entries.items[i];
                entry.mode = slot.mode;
                entry.oid = slot.oid;
                index.entries.items[i] = entry;
            } else {
                // Add to index from HEAD-only state (path was deleted from index).
                try index.upsert(.{
                    .ctime_s = 0, .ctime_ns = 0, .mtime_s = 0, .mtime_ns = 0,
                    .dev = 0, .ino = 0,
                    .mode = slot.mode, .uid = 0, .gid = 0, .file_size = 0,
                    .oid = slot.oid,
                    .flags = if (path.len > 0xFFF) 0xFFF else @intCast(path.len),
                    .path = path,
                });
            }
        } else {
            // Path not in HEAD → drop from index (mirrors `git reset HEAD <path>`).
            var i: usize = 0;
            while (i < index.entries.items.len) {
                if (std.mem.eql(u8, index.entries.items[i].path, path)) {
                    _ = index.entries.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    try index.save(io, repo.git_dir);
}

const PathOid = struct { mode: u32, oid: zigit.Oid };
const PathMap = std.StringHashMapUnmanaged(PathOid);

fn buildHeadTreeMap(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    store: *zigit.LooseStore,
) !PathMap {
    var map: PathMap = .empty;
    errdefer freeMap(allocator, &map);

    const head_commit = (try zigit.refs.tryResolve(allocator, io, git_dir, zigit.refs.head_path)) orelse return map;

    var commit_obj = try store.read(allocator, head_commit);
    defer commit_obj.deinit(allocator);
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);

    const Reader = struct {
        s: *zigit.LooseStore,
        a: std.mem.Allocator,
        fn read(self: @This(), oid: zigit.Oid) ![]const u8 {
            const loaded = try self.s.read(self.a, oid);
            return loaded.payload;
        }
    };
    const leaves = try zigit.object.tree.walkRecursive(allocator, parsed.tree_oid, Reader{ .s = store, .a = allocator }, Reader.read);
    defer zigit.object.tree.freeLeaves(allocator, leaves);

    for (leaves) |l| {
        const owned = try allocator.dupe(u8, l.path);
        try map.put(allocator, owned, .{ .mode = l.mode, .oid = l.oid });
    }
    return map;
}

fn freeMap(allocator: std.mem.Allocator, map: *PathMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit(allocator);
}

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, root, .{});
}
