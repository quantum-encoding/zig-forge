// `zigit rebase ONTO`
//
// Replay every commit on the current branch since merge_base(HEAD,
// ONTO) on top of ONTO. Each replay is a cherry-pick: a three-way
// merge whose base is the commit's *original* parent.
//
// Workflow:
//
//   1. Resolve current branch + tip + ONTO oid.
//   2. base ← merge_base(tip, ONTO)
//   3. If base == tip → "Already on top of ONTO."
//   4. If base == ONTO → "Up to date" (already includes ONTO).
//   5. Walk first-parent from tip back to base, collecting commits
//      in chronological (oldest-first) order.
//   6. new_tip ← ONTO
//      for commit in to_replay:
//        cherry-pick commit onto new_tip:
//          base   = commit's original parent's tree
//          ours   = new_tip's tree
//          theirs = commit's tree
//          three_way.merge(...)
//          if conflicts → abort cleanly
//        build merged tree, create new commit with new_tip as parent
//        new_tip ← new commit oid
//   7. Move HEAD's branch ref → new_tip; materialise.
//
// We don't yet support interactive rebase, --autostash, or
// fixup/squash. Conflicts abort the whole rebase (no half-finished
// state on disk because we only update HEAD at the very end).

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
    if (args.len != 1) return error.UsageRebaseOneOnto;
    const onto_branch = args[0];

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const current_full = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(current_full);
    if (!std.mem.startsWith(u8, current_full, "refs/heads/")) return error.HeadIsDetached;
    const tip = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, current_full)) orelse return error.UnbornBranch;

    var ref_buf: [Dir.max_path_bytes]u8 = undefined;
    const onto_ref = try std.fmt.bufPrint(&ref_buf, "{s}/{s}", .{ heads_dir, onto_branch });
    const onto = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, onto_ref)) orelse return error.OntoNotFound;

    if (tip.eql(onto)) {
        try File.stdout().writeStreamingAll(io, "Current branch already at onto.\n");
        return;
    }

    const base_oid = (try zigit.merge.base.find(allocator, &store, tip, onto)) orelse return error.NoCommonAncestor;

    if (base_oid.eql(tip)) {
        try File.stdout().writeStreamingAll(io, "Current branch is already an ancestor of onto — fast-forwarding.\n");
        try checkoutAndMove(allocator, io, &repo, &store, current_full, onto);
        try logRebase(allocator, io, environ, &repo, current_full, tip, onto, onto_branch);
        return;
    }
    if (base_oid.eql(onto)) {
        try File.stdout().writeStreamingAll(io, "Onto is an ancestor of current branch — nothing to rebase.\n");
        return;
    }

    // Collect commits to replay (tip → base, exclusive), reverse to oldest-first.
    var to_replay: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    defer to_replay.deinit(allocator);
    var current = tip;
    while (!current.eql(base_oid)) {
        try to_replay.append(allocator, current);
        current = try firstParent(allocator, &store, current) orelse return error.WalkedPastBase;
    }
    std.mem.reverse(zigit.Oid, to_replay.items);

    var msg_buf: [256]u8 = undefined;
    const start = try std.fmt.bufPrint(
        &msg_buf,
        "Rebasing {d} commits onto {s}\n",
        .{ to_replay.items.len, onto_branch },
    );
    try File.stdout().writeStreamingAll(io, start);

    // Replay one by one.
    var new_tip = onto;
    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    const author_name = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_NAME", "user.name", "zigit");
    defer allocator.free(author_name);
    const author_email = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_EMAIL", "user.email", "zigit@local");
    defer allocator.free(author_email);

    for (to_replay.items, 0..) |commit_oid, i| {
        const replayed = cherryPick(allocator, io, environ, &store, new_tip, commit_oid, author_name, author_email) catch |err| switch (err) {
            error.MergeConflict => {
                var buf: [256]u8 = undefined;
                const oops = try std.fmt.bufPrint(
                    &buf,
                    "rebase: conflict at commit {d}/{d} — aborting (working tree unchanged).\n",
                    .{ i + 1, to_replay.items.len },
                );
                try File.stderr().writeStreamingAll(io, oops);
                return error.MergeConflict;
            },
            else => return err,
        };
        new_tip = replayed;
    }

    // Now atomically move the branch + materialise the new tip.
    try checkoutAndMove(allocator, io, &repo, &store, current_full, new_tip);
    try logRebase(allocator, io, environ, &repo, current_full, tip, new_tip, onto_branch);

    var hex: [40]u8 = undefined;
    new_tip.toHex(&hex);
    const done = try std.fmt.bufPrint(&msg_buf, "Rebased to {s}\n", .{hex[0..7]});
    try File.stdout().writeStreamingAll(io, done);
}

fn logRebase(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    repo: *zigit.Repository,
    current_ref: []const u8,
    old_tip: zigit.Oid,
    new_tip: zigit.Oid,
    onto_branch: []const u8,
) !void {
    const id = try zigit.reflog.identityFromEnviron(allocator, io, environ, repo.git_dir);
    defer zigit.reflog.deinitIdentity(allocator, id);
    const ts = try zigit.reflog.timestampFromEnviron(io, environ);
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "rebase finished: returning to {s}", .{onto_branch});
    try zigit.reflog.logUpdate(allocator, io, repo.git_dir, current_ref, old_tip, new_tip, id, ts, msg);
}

/// Cherry-pick `commit_oid` (whose original parent's tree is the
/// merge base) on top of `onto_tip`. Returns the new commit oid.
fn cherryPick(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    store: *zigit.LooseStore,
    onto_tip: zigit.Oid,
    commit_oid: zigit.Oid,
    author_name: []const u8,
    author_email: []const u8,
) !zigit.Oid {
    var commit_obj = try store.read(allocator, commit_oid);
    defer commit_obj.deinit(allocator);
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);

    if (parsed.parent_oids.len == 0) return error.RootCommitInRebase;
    const original_parent = parsed.parent_oids[0];

    const base_tree = try treeOfCommit(allocator, store, original_parent);
    const ours_tree = try treeOfCommit(allocator, store, onto_tip);
    const theirs_tree = parsed.tree_oid;

    var base_map = try buildMap(allocator, store, base_tree);
    defer freeMap(allocator, &base_map);
    var ours_map = try buildMap(allocator, store, ours_tree);
    defer freeMap(allocator, &ours_map);
    var theirs_map = try buildMap(allocator, store, theirs_tree);
    defer freeMap(allocator, &theirs_map);

    var result = try zigit.merge.three_way.merge(allocator, base_map, ours_map, theirs_map);
    defer result.deinit(allocator);

    if (result.conflicts.len > 0) return error.MergeConflict;

    const merged_tree = try buildTreeFromResolved(allocator, store, result.merged);

    const when_unix = try resolveUnixOrNow(io, environ, "GIT_AUTHOR_DATE");
    const parents = [_]zigit.Oid{onto_tip};
    const payload = try zigit.object.commit.serialize(allocator, .{
        .tree_oid = merged_tree,
        .parent_oids = &parents,
        .author = .{ .name = author_name, .email = author_email, .when_unix = when_unix },
        .committer = .{ .name = author_name, .email = author_email, .when_unix = when_unix },
        .message = parsed.message,
    });
    defer allocator.free(payload);

    const new_oid = zigit.object.computeOid(.commit, payload);
    try store.write(allocator, .commit, payload, new_oid);
    return new_oid;
}

fn checkoutAndMove(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    current_ref: []const u8,
    new_tip: zigit.Oid,
) !void {
    const tree = try treeOfCommit(allocator, store, new_tip);
    var work_root = try openWorkRoot(io, repo);
    defer work_root.close(io);
    try zigit.worktree.applyTree(allocator, io, work_root, store, tree);
    try zigit.refs.update(io, repo.git_dir, current_ref, new_tip);
}

// ── Helpers (mirror cli/merge.zig — small enough to duplicate; a
// shared cherry-pick module is fair game in Phase 11) ────────────────

fn firstParent(allocator: std.mem.Allocator, store: *zigit.LooseStore, oid: zigit.Oid) !?zigit.Oid {
    var obj = try store.read(allocator, oid);
    defer obj.deinit(allocator);
    var parsed = try zigit.object.commit.parse(allocator, obj.payload);
    defer parsed.deinit(allocator);
    if (parsed.parent_oids.len == 0) return null;
    return parsed.parent_oids[0];
}

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
        if (!std.mem.startsWith(u8, e.path, prefix)) continue;
        const rel = e.path[prefix.len..];
        if (rel.len == 0) continue;
        if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
            const component = rel[0..slash];
            const gop = try subdirs.getOrPut(allocator, component);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, e);
        } else {
            try tree_entries.append(allocator, .{ .mode = e.mode, .name = rel, .oid = e.oid });
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
