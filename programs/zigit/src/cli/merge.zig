// `zigit merge BRANCH`
//
// Merge BRANCH (anywhere under refs/heads/) into the current branch.
//
// Three cases, in order of precedence:
//
//   1. merge_base(HEAD, BRANCH) == BRANCH
//      → Already up-to-date. No-op.
//   2. merge_base(HEAD, BRANCH) == HEAD
//      → Fast-forward. Move HEAD's branch ref to BRANCH's tip,
//        update workdir + index. No new commit.
//   3. Otherwise
//      → True three-way. Build merged tree from base/ours/theirs at
//        file granularity. On any conflict, abort with a clear list
//        of paths and exit non-zero. On clean, write the merged tree,
//        create a merge commit with two parents (HEAD, BRANCH),
//        advance HEAD's branch, materialise.
//
// Author identity for the merge commit follows the same env →
// .git/config → "zigit" fallback ladder as `commit`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const heads_dir = "refs/heads";

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    if (args.len != 1) return error.UsageMergeOneBranch;
    const branch = args[0];

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    // Resolve current branch + its tip.
    const current_full = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(current_full);
    if (!std.mem.startsWith(u8, current_full, "refs/heads/")) return error.HeadIsDetached;

    const ours = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, current_full)) orelse return error.UnbornBranch;

    // Resolve target.
    var ref_buf: [Dir.max_path_bytes]u8 = undefined;
    const theirs_ref = try std.fmt.bufPrint(&ref_buf, "{s}/{s}", .{ heads_dir, branch });
    const theirs = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, theirs_ref)) orelse return error.BranchNotFound;

    if (ours.eql(theirs)) {
        try File.stdout().writeStreamingAll(io, "Already up to date.\n");
        return;
    }

    const base_oid = (try zigit.merge.base.find(allocator, &store, ours, theirs)) orelse
        return error.NoCommonAncestor;

    if (base_oid.eql(theirs)) {
        try File.stdout().writeStreamingAll(io, "Already up to date.\n");
        return;
    }

    if (base_oid.eql(ours)) {
        try fastForward(allocator, io, &repo, &store, current_full, theirs);
        return;
    }

    try threeWay(allocator, io, environ, &repo, &store, current_full, base_oid, ours, theirs);
}

fn fastForward(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    current_ref: []const u8,
    new_tip: zigit.Oid,
) !void {
    // Move the ref + materialise — same path switch uses, but we
    // already know there's nothing to refuse.
    const target_tree = try treeOfCommit(allocator, store, new_tip);
    var work_root = try openWorkRoot(io, repo);
    defer work_root.close(io);
    try zigit.worktree.applyTree(allocator, io, work_root, store, target_tree);

    try zigit.refs.update(io, repo.git_dir, current_ref, new_tip);

    var hex: [40]u8 = undefined;
    new_tip.toHex(&hex);
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Fast-forward to {s}\n", .{hex[0..7]});
    try File.stdout().writeStreamingAll(io, msg);
}

fn threeWay(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    current_ref: []const u8,
    base_oid: zigit.Oid,
    ours: zigit.Oid,
    theirs: zigit.Oid,
) !void {
    const base_tree = try treeOfCommit(allocator, store, base_oid);
    const ours_tree = try treeOfCommit(allocator, store, ours);
    const theirs_tree = try treeOfCommit(allocator, store, theirs);

    var base_map = try buildMap(allocator, store, base_tree);
    defer freeMap(allocator, &base_map);
    var ours_map = try buildMap(allocator, store, ours_tree);
    defer freeMap(allocator, &ours_map);
    var theirs_map = try buildMap(allocator, store, theirs_tree);
    defer freeMap(allocator, &theirs_map);

    // Convert to merge.three_way.Map (stripping the path-allocator
    // trick — three_way takes the same StringHashMapUnmanaged shape).
    var result = try zigit.merge.three_way.merge(allocator, base_map, ours_map, theirs_map);
    defer result.deinit(allocator);

    if (result.conflicts.len > 0) {
        var buf: [4096]u8 = undefined;
        try File.stderr().writeStreamingAll(io, "merge: conflicts in:\n");
        for (result.conflicts) |c| {
            const reason = switch (c.reason) {
                .modify_modify => "modify/modify",
                .add_add => "add/add",
                .modify_delete => "modify/delete",
                .delete_modify => "delete/modify",
            };
            const line = try std.fmt.bufPrint(&buf, "  {s}  ({s})\n", .{ c.path, reason });
            try File.stderr().writeStreamingAll(io, line);
        }
        try File.stderr().writeStreamingAll(io, "merge: aborting (no auto-resolution yet)\n");
        return error.MergeConflict;
    }

    // Build the merged tree.
    const merged_tree_oid = try buildTreeFromResolved(allocator, store, result.merged);

    // Materialise + remove paths that are gone.
    var work_root = try openWorkRoot(io, repo);
    defer work_root.close(io);
    try zigit.worktree.applyTree(allocator, io, work_root, store, merged_tree_oid);
    try removeStalePaths(allocator, io, work_root, ours_map, result.merged);

    // Build the merge commit.
    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();
    const author_name = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_NAME", "user.name", "zigit");
    defer allocator.free(author_name);
    const author_email = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_EMAIL", "user.email", "zigit@local");
    defer allocator.free(author_email);
    const author_when = try resolveUnixOrNow(io, environ, "GIT_AUTHOR_DATE");

    const branch_short = if (std.mem.startsWith(u8, current_ref, "refs/heads/")) current_ref[11..] else current_ref;
    const message = try std.fmt.allocPrint(
        allocator,
        "Merge branch '{s}'\n",
        .{
            // Best effort — we don't carry the source branch name through;
            // use the target ref's short name as a placeholder. Phase 11
            // can plumb the actual source.
            branch_short,
        },
    );
    defer allocator.free(message);

    const parents = [_]zigit.Oid{ ours, theirs };
    const payload = try zigit.object.commit.serialize(allocator, .{
        .tree_oid = merged_tree_oid,
        .parent_oids = &parents,
        .author = .{ .name = author_name, .email = author_email, .when_unix = author_when },
        .committer = .{ .name = author_name, .email = author_email, .when_unix = author_when },
        .message = message,
    });
    defer allocator.free(payload);

    const commit_oid = zigit.object.computeOid(.commit, payload);
    try store.write(allocator, .commit, payload, commit_oid);
    try zigit.refs.update(io, repo.git_dir, current_ref, commit_oid);

    var hex: [40]u8 = undefined;
    commit_oid.toHex(&hex);
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Merge made {s} ({d} files)\n", .{ hex[0..7], result.merged.len });
    try File.stdout().writeStreamingAll(io, msg);
}

// ── Helpers ──────────────────────────────────────────────────────────

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, root, .{});
}

fn treeOfCommit(allocator: std.mem.Allocator, store: *zigit.LooseStore, commit_oid: zigit.Oid) !zigit.Oid {
    var commit_obj = try store.read(allocator, commit_oid);
    defer commit_obj.deinit(allocator);
    if (commit_obj.kind != .commit) return error.NotACommit;
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);
    return parsed.tree_oid;
}

fn buildMap(allocator: std.mem.Allocator, store: *zigit.LooseStore, tree_oid: zigit.Oid) !zigit.merge.three_way.Map {
    var map: zigit.merge.three_way.Map = .empty;
    errdefer freeMap(allocator, &map);

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

fn freeMap(allocator: std.mem.Allocator, map: *zigit.merge.three_way.Map) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit(allocator);
}

/// Build a nested tree from a flat list of (path, mode, oid). Same
/// bucket-by-component algorithm `commit` and `write-tree` use.
fn buildTreeFromResolved(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    resolved: []const zigit.merge.three_way.Resolved,
) !zigit.Oid {
    return try buildTreeRec(allocator, store, resolved, "");
}

fn buildTreeRec(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    entries: []const zigit.merge.three_way.Resolved,
    prefix: []const u8,
) !zigit.Oid {
    var subdirs: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(zigit.merge.three_way.Resolved)) = .empty;
    defer {
        var it = subdirs.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(allocator);
        subdirs.deinit(allocator);
    }

    var tree_entries: std.ArrayListUnmanaged(zigit.object.TreeEntry) = .empty;
    defer tree_entries.deinit(allocator);

    for (entries) |e| {
        // Trim our prefix off the front (so we work with paths
        // relative to this subtree).
        if (!std.mem.startsWith(u8, e.path, prefix)) continue;
        const rel = e.path[prefix.len..];
        if (rel.len == 0) continue;

        if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
            const component = rel[0..slash];
            const gop = try subdirs.getOrPut(allocator, component);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, e);
        } else {
            try tree_entries.append(allocator, .{
                .mode = e.mode,
                .name = rel,
                .oid = e.oid,
            });
        }
    }

    var sit = subdirs.iterator();
    while (sit.next()) |kv| {
        const sub_prefix = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, kv.key_ptr.* });
        defer allocator.free(sub_prefix);
        const sub_oid = try buildTreeRec(allocator, store, kv.value_ptr.items, sub_prefix);
        try tree_entries.append(allocator, .{
            .mode = zigit.object.tree.tree_mode_octal,
            .name = kv.key_ptr.*,
            .oid = sub_oid,
        });
    }

    std.mem.sort(zigit.object.TreeEntry, tree_entries.items, {}, zigit.object.tree.lessThanForTree);

    const payload = try zigit.object.tree.serialize(allocator, tree_entries.items);
    defer allocator.free(payload);
    const oid = zigit.object.computeOid(.tree, payload);
    try store.write(allocator, .tree, payload, oid);
    return oid;
}

fn removeStalePaths(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    old_map: zigit.merge.three_way.Map,
    new_entries: []const zigit.merge.three_way.Resolved,
) !void {
    // Build a set of the new paths.
    var new_set: std.StringHashMapUnmanaged(void) = .empty;
    defer new_set.deinit(allocator);
    for (new_entries) |e| try new_set.put(allocator, e.path, {});

    var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_remove.deinit(allocator);
    var it = old_map.keyIterator();
    while (it.next()) |k| {
        if (!new_set.contains(k.*)) try to_remove.append(allocator, k.*);
    }
    try zigit.worktree.removePaths(io, work_root, to_remove.items);
}

fn resolveString(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    cfg: *const zigit.config.Config,
    env_key: []const u8,
    config_key: []const u8,
    fallback: []const u8,
) ![]u8 {
    if (environ.getPosix(env_key)) |v| return try allocator.dupe(u8, v);
    if (cfg.get(config_key)) |v| return try allocator.dupe(u8, v);
    return try allocator.dupe(u8, fallback);
}

fn resolveUnixOrNow(io: Io, environ: std.process.Environ, env_key: []const u8) !i64 {
    if (environ.getPosix(env_key)) |v| return try std.fmt.parseInt(i64, v, 10);
    const now: std.Io.Timestamp = .now(io, .real);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
}
