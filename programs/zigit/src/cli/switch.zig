// `zigit switch [-c] NAME`
//
// Move HEAD to a different branch + update workdir + index.
//
// Args:
//   -c        Create branch NAME at HEAD before switching to it.
//   NAME      A branch name (relative to refs/heads/).
//
// Workflow:
//   1. Resolve target → branch ref name + commit oid + tree oid.
//   2. Build path → (mode, oid) maps for current HEAD's tree, the
//      target tree, and the index. Walk the workdir.
//   3. Safety check (refuses with a clear error message if any of
//      the following would silently lose user work):
//        * A path that differs between current-tree and target-tree
//          AND has staged or unstaged modifications.
//        * A path new in target-tree where the workdir has an
//          untracked file at the same location.
//   4. Apply target tree to disk: write new+changed blobs, delete
//      paths that exist in current-tree but not target-tree.
//   5. Rebuild index from the target tree (each entry's stat fields
//      populated from the freshly-written file on disk so future
//      `status`/`diff` calls don't misreport).
//   6. Update HEAD → "ref: refs/heads/NAME\n".

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const heads_dir = "refs/heads";

const PathOid = struct { mode: u32, oid: zigit.Oid };
const PathMap = std.StringHashMapUnmanaged(PathOid);

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var create = false;
    var name_opt: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--create")) {
            create = true;
        } else if (name_opt == null) {
            name_opt = a;
        } else {
            return error.TooManyArguments;
        }
    }
    const name = name_opt orelse return error.MissingBranchName;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    if (create) try createBranchAtHead(allocator, io, &repo, name);

    try doSwitch(allocator, io, &repo, name);
}

fn createBranchAtHead(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    name: []const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ heads_dir, name });

    if (repo.git_dir.access(io, ref_path, .{})) {
        return error.BranchAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const head_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse
        return error.NoCommitsToBranchFrom;
    try zigit.refs.update(io, repo.git_dir, ref_path, head_oid);
}

fn doSwitch(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    name: []const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const target_ref = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ heads_dir, name });

    const target_commit_opt = try zigit.refs.tryResolve(allocator, io, repo.git_dir, target_ref);
    const target_commit = target_commit_opt orelse return error.BranchNotFound;

    const new_head = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{target_ref});
    defer allocator.free(new_head);

    try applyCommit(allocator, io, repo, target_commit, new_head);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Switched to branch '{s}'\n", .{name});
    try File.stdout().writeStreamingAll(io, msg);
}

/// Public so `checkout` can drive the same workflow with a different
/// HEAD payload (raw oid for detached checkout, "ref: ..." for
/// branch checkout).
pub fn applyCommit(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    target_commit: zigit.Oid,
    new_head_payload: []const u8,
) !void {

    var store = repo.looseStore();

    // Resolve current and target trees.
    var current_map = try buildHeadTreeMap(allocator, io, repo.git_dir, &store);
    defer freePathMap(allocator, &current_map);

    var target_map = try buildTreeMap(allocator, &store, try resolveCommitTree(allocator, &store, target_commit));
    defer freePathMap(allocator, &target_map);

    // Load the index for the staged-conflict check.
    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();
    var index_map: PathMap = .empty;
    defer index_map.deinit(allocator);
    for (index.entries.items) |e| try index_map.put(allocator, e.path, .{ .mode = e.mode, .oid = e.oid });

    // Workdir snapshot.
    var work_root = try openWorkRoot(io, repo);
    defer work_root.close(io);
    const listing = try zigit.workdir.walk(allocator, io, work_root);
    defer zigit.workdir.freeEntries(allocator, listing);

    // Safety check.
    if (try findConflict(allocator, io, work_root, current_map, target_map, index_map, listing)) |conflict| {
        defer allocator.free(conflict.path);
        var msg_buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "error: would overwrite {s} for '{s}'\n", .{ conflict.reason, conflict.path });
        try File.stderr().writeStreamingAll(io, msg);
        return error.WouldLoseChanges;
    }

    // Apply target tree: write/overwrite blobs that target says we need.
    try zigit.worktree.applyTree(allocator, io, work_root, &store, try resolveCommitTree(allocator, &store, target_commit));

    // Remove paths that current had but target doesn't.
    var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_remove.deinit(allocator);
    var c_iter = current_map.iterator();
    while (c_iter.next()) |kv| {
        if (!target_map.contains(kv.key_ptr.*)) try to_remove.append(allocator, kv.key_ptr.*);
    }
    try zigit.worktree.removePaths(io, work_root, to_remove.items);

    // Rebuild index from the target tree, stating each freshly-written file.
    try rebuildIndexFromTarget(allocator, io, work_root, repo.git_dir, target_map);

    // Move HEAD atomically.
    try repo.git_dir.writeFile(io, .{ .sub_path = "HEAD.tmp", .data = new_head_payload });
    try repo.git_dir.rename("HEAD.tmp", repo.git_dir, "HEAD", io);
}

fn resolveCommitTree(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    commit_oid: zigit.Oid,
) !zigit.Oid {
    var commit_obj = try store.read(allocator, commit_oid);
    defer commit_obj.deinit(allocator);
    if (commit_obj.kind != .commit) return error.NotACommit;
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);
    return parsed.tree_oid;
}

fn buildHeadTreeMap(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    store: *zigit.LooseStore,
) !PathMap {
    var map: PathMap = .empty;
    errdefer freePathMap(allocator, &map);

    const head_commit = (try zigit.refs.tryResolve(allocator, io, git_dir, zigit.refs.head_path)) orelse return map;

    var commit_obj = try store.read(allocator, head_commit);
    defer commit_obj.deinit(allocator);
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);

    return try buildTreeMap(allocator, store, parsed.tree_oid);
}

fn buildTreeMap(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    tree_oid: zigit.Oid,
) !PathMap {
    var map: PathMap = .empty;
    errdefer freePathMap(allocator, &map);

    const Reader = struct {
        s: *zigit.LooseStore,
        a: std.mem.Allocator,
        fn read(self: @This(), oid: zigit.Oid) ![]const u8 {
            const loaded = try self.s.read(self.a, oid);
            return loaded.payload;
        }
    };
    const leaves = try zigit.object.tree.walkRecursive(allocator, tree_oid, Reader{ .s = store, .a = allocator }, Reader.read);
    defer zigit.object.tree.freeLeaves(allocator, leaves);

    for (leaves) |l| {
        const owned = try allocator.dupe(u8, l.path);
        try map.put(allocator, owned, .{ .mode = l.mode, .oid = l.oid });
    }
    return map;
}

fn freePathMap(allocator: std.mem.Allocator, map: *PathMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit(allocator);
}

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const work_root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, work_root, .{});
}

const Conflict = struct {
    /// Owned by caller; allocated with the same allocator passed in.
    reason: []const u8,
    path: []u8,
};

fn findConflict(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    current_map: PathMap,
    target_map: PathMap,
    index_map: PathMap,
    listing: []const zigit.workdir.Entry,
) !?Conflict {
    var workdir_set: std.StringHashMapUnmanaged(void) = .empty;
    defer workdir_set.deinit(allocator);
    for (listing) |w| try workdir_set.put(allocator, w.path, {});

    // Check #1: paths that change between current and target must be
    // "clean" in both index and workdir.
    var ci = current_map.iterator();
    while (ci.next()) |kv| {
        const path = kv.key_ptr.*;
        const cur = kv.value_ptr.*;
        if (target_map.get(path)) |tgt| {
            if (cur.oid.eql(tgt.oid) and cur.mode == tgt.mode) continue; // unchanged → safe
        }

        if (index_map.get(path)) |idx| {
            if (!idx.oid.eql(cur.oid)) return .{ .reason = "staged change", .path = try allocator.dupe(u8, path) };
        } else {
            return .{ .reason = "staged delete", .path = try allocator.dupe(u8, path) };
        }

        if (workdir_set.contains(path)) {
            const bytes = work_root.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.IsDir => continue,
                else => return err,
            };
            defer allocator.free(bytes);
            const wd_oid = zigit.object.computeOid(.blob, bytes);
            if (!wd_oid.eql(cur.oid)) return .{ .reason = "local change", .path = try allocator.dupe(u8, path) };
        }
    }

    // Check #2: target-only paths must not collide with untracked workdir entries.
    var ti = target_map.iterator();
    while (ti.next()) |kv| {
        const path = kv.key_ptr.*;
        if (current_map.contains(path)) continue;
        if (!workdir_set.contains(path)) continue;
        if (!index_map.contains(path)) return .{ .reason = "untracked file would be overwritten", .path = try allocator.dupe(u8, path) };
    }

    return null;
}

fn rebuildIndexFromTarget(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    git_dir: Dir,
    target_map: PathMap,
) !void {
    var index: zigit.Index = .empty(allocator);
    defer index.deinit();

    var it = target_map.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        const info = kv.value_ptr.*;

        // Stat the freshly-written file so the index entry's mtime
        // matches what's on disk. (We just wrote it via applyTree.)
        var f = try work_root.openFile(io, path, .{});
        defer f.close(io);
        const st = try f.stat(io);

        const mtime_s: u32 = clampSec(st.mtime.nanoseconds);
        const mtime_ns: u32 = clampNs(st.mtime.nanoseconds);
        const ctime_s: u32 = clampSec(st.ctime.nanoseconds);
        const ctime_ns: u32 = clampNs(st.ctime.nanoseconds);

        const flags_path_len: u16 = if (path.len > 0xFFF) 0xFFF else @intCast(path.len);

        try index.upsert(.{
            .ctime_s = ctime_s,
            .ctime_ns = ctime_ns,
            .mtime_s = mtime_s,
            .mtime_ns = mtime_ns,
            .dev = 0,
            .ino = @truncate(@as(u128, @bitCast(@as(i128, st.inode)))),
            .mode = info.mode,
            .uid = 0,
            .gid = 0,
            .file_size = std.math.cast(u32, st.size) orelse std.math.maxInt(u32),
            .oid = info.oid,
            .flags = flags_path_len,
            .path = path,
        });
    }

    try index.save(io, git_dir);
}

fn clampSec(ns: i96) u32 {
    const seconds = @divFloor(ns, std.time.ns_per_s);
    if (seconds < 0) return 0;
    if (seconds > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(seconds);
}

fn clampNs(ns: i96) u32 {
    return @intCast(@mod(ns, std.time.ns_per_s));
}
