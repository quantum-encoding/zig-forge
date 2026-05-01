// `zigit stash <push|list|pop|drop> [args]`
//
// Save the current work-tree state to a stack so you can come back
// to it after switching branches or experimenting with `reset`.
//
// Storage shape:
//   * Each stash is a commit object:
//       tree      = snapshot of the work tree (every indexed path's
//                   current on-disk content)
//       parent    = HEAD when stashed (so `pop` knows the base for
//                   the three-way merge that re-applies the stash)
//       message   = "stash on <branch>: <user-msg-or-head-subject>"
//   * The stack lives in .git/zigit-stash-list, one oid per line,
//     newest first. (Real git uses the reflog of refs/stash for this;
//     we'll switch when the reflog ships in Phase 17.)
//
// Subcommands:
//   push [-m MSG]   Capture work-tree, push to stack, reset workdir
//                   + index to HEAD. Refuses if HEAD is unborn or
//                   there are no local changes.
//   list            Print one line per stash: `stash@{N}: <subject>`
//   pop             Apply the top stash via three-way merge against
//                   HEAD, then drop it. Aborts with conflicts left in
//                   the work tree if the merge isn't clean (drop
//                   doesn't happen so the user can retry after
//                   resolving).
//   drop            Just remove the top stash without applying.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const stash_list_file = "zigit-stash-list";

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        // `zigit stash` with no args = `zigit stash push`.
        return try cmdPush(allocator, io, environ, &.{});
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "push")) return try cmdPush(allocator, io, environ, rest);
    if (std.mem.eql(u8, sub, "list")) return try cmdList(allocator, io);
    if (std.mem.eql(u8, sub, "pop")) return try cmdPop(allocator, io);
    if (std.mem.eql(u8, sub, "drop")) return try cmdDrop(allocator, io);
    return error.UnknownStashSubcommand;
}

// ── push ──────────────────────────────────────────────────────────────────────

fn cmdPush(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    var msg_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") or std.mem.eql(u8, args[i], "--message")) {
            i += 1;
            if (i >= args.len) return error.MissingMessageArg;
            msg_arg = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const head_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse
        return error.UnbornBranch;
    const head_tree = try treeOfCommit(allocator, &store, head_oid);

    var work_root = try openWorkRoot(io, &repo);
    defer work_root.close(io);

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();

    // Build a tree from the workdir's current content, walking every
    // indexed path. (Untracked files are NOT stashed — that's the
    // `--include-untracked` flag we don't support yet.)
    const workdir_tree = try snapshotWorkdirTree(allocator, io, work_root, &store, &index);

    if (workdir_tree.eql(head_tree)) {
        try File.stdout().writeStreamingAll(io, "No local changes to save\n");
        return;
    }

    // Author + commit.
    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();
    const author_name = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_NAME", "user.name", "zigit");
    defer allocator.free(author_name);
    const author_email = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_EMAIL", "user.email", "zigit@local");
    defer allocator.free(author_email);
    const when_unix = try resolveUnixOrNow(io, environ, "GIT_AUTHOR_DATE");

    const branch_short = try shortBranchName(allocator, io, repo.git_dir);
    defer allocator.free(branch_short);

    var head_obj = try store.read(allocator, head_oid);
    defer head_obj.deinit(allocator);
    var head_parsed = try zigit.object.commit.parse(allocator, head_obj.payload);
    defer head_parsed.deinit(allocator);
    const head_subject_end = std.mem.indexOfScalar(u8, head_parsed.message, '\n') orelse head_parsed.message.len;
    const head_subject = head_parsed.message[0..head_subject_end];

    const message: []const u8 = if (msg_arg) |m|
        try std.fmt.allocPrint(allocator, "stash on {s}: {s}\n", .{ branch_short, m })
    else
        try std.fmt.allocPrint(allocator, "stash on {s}: {s}\n", .{ branch_short, head_subject });
    defer allocator.free(message);

    const parents = [_]zigit.Oid{head_oid};
    const payload = try zigit.object.commit.serialize(allocator, .{
        .tree_oid = workdir_tree,
        .parent_oids = &parents,
        .author = .{ .name = author_name, .email = author_email, .when_unix = when_unix },
        .committer = .{ .name = author_name, .email = author_email, .when_unix = when_unix },
        .message = message,
    });
    defer allocator.free(payload);

    const stash_oid = zigit.object.computeOid(.commit, payload);
    try store.write(allocator, .commit, payload, stash_oid);

    // Push onto the stack.
    try pushStashOnto(allocator, io, repo.git_dir, stash_oid);

    // Reset workdir + index to HEAD.
    try zigit.worktree.applyTree(allocator, io, work_root, &store, head_tree);
    try rebuildIndexFromTree(allocator, io, &repo, &store, head_tree);

    var hex: [40]u8 = undefined;
    stash_oid.toHex(&hex);
    var buf: [256]u8 = undefined;
    const out_msg = try std.fmt.bufPrint(&buf, "Saved working directory and index state at {s}\n", .{hex[0..7]});
    try File.stdout().writeStreamingAll(io, out_msg);
}

// ── list ──────────────────────────────────────────────────────────────────────

fn cmdList(allocator: std.mem.Allocator, io: Io) !void {
    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const oids = try readStashList(allocator, io, repo.git_dir);
    defer allocator.free(oids);

    const out = File.stdout();
    var buf: [512]u8 = undefined;
    for (oids, 0..) |oid, i| {
        var commit_obj = try store.read(allocator, oid);
        defer commit_obj.deinit(allocator);
        var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
        defer parsed.deinit(allocator);

        const subject_end = std.mem.indexOfScalar(u8, parsed.message, '\n') orelse parsed.message.len;
        const subject = parsed.message[0..subject_end];
        const line = try std.fmt.bufPrint(&buf, "stash@{{{d}}}: {s}\n", .{ i, subject });
        try out.writeStreamingAll(io, line);
    }
}

// ── pop ───────────────────────────────────────────────────────────────────────

fn cmdPop(allocator: std.mem.Allocator, io: Io) !void {
    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    const oids = try readStashList(allocator, io, repo.git_dir);
    defer allocator.free(oids);
    if (oids.len == 0) return error.StashIsEmpty;

    const top = oids[0];

    // Decode the stash.
    var stash_obj = try store.read(allocator, top);
    defer stash_obj.deinit(allocator);
    var stash_parsed = try zigit.object.commit.parse(allocator, stash_obj.payload);
    defer stash_parsed.deinit(allocator);
    if (stash_parsed.parent_oids.len == 0) return error.MalformedStash;
    const base_oid = stash_parsed.parent_oids[0];

    const head_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse
        return error.UnbornBranch;

    const stash_tree = stash_parsed.tree_oid;
    const head_tree = try treeOfCommit(allocator, &store, head_oid);
    const base_tree = try treeOfCommit(allocator, &store, base_oid);

    var base_map = try buildMap(allocator, &store, base_tree);
    defer freeMap(allocator, &base_map);
    var ours_map = try buildMap(allocator, &store, head_tree);
    defer freeMap(allocator, &ours_map);
    var theirs_map = try buildMap(allocator, &store, stash_tree);
    defer freeMap(allocator, &theirs_map);

    var result = try zigit.merge.three_way.merge(allocator, base_map, ours_map, theirs_map);
    defer result.deinit(allocator);

    if (result.conflicts.len > 0) {
        var buf: [4096]u8 = undefined;
        try File.stderr().writeStreamingAll(io, "stash pop: conflicts in:\n");
        for (result.conflicts) |c| {
            const line = try std.fmt.bufPrint(&buf, "  {s}\n", .{c.path});
            try File.stderr().writeStreamingAll(io, line);
        }
        try File.stderr().writeStreamingAll(io, "stash pop: stash kept (resolve + drop manually)\n");
        return error.StashConflict;
    }

    // Apply.
    var work_root = try openWorkRoot(io, &repo);
    defer work_root.close(io);
    const merged_tree = try buildTreeFromResolved(allocator, &store, result.merged);
    try zigit.worktree.applyTree(allocator, io, work_root, &store, merged_tree);
    try removeStalePaths(allocator, io, work_root, ours_map, result.merged);
    try rebuildIndexFromTree(allocator, io, &repo, &store, merged_tree);

    // Drop the top.
    try writeStashList(allocator, io, repo.git_dir, oids[1..]);

    var hex: [40]u8 = undefined;
    top.toHex(&hex);
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Dropped stash@{{0}} ({s})\n", .{hex[0..7]});
    try File.stdout().writeStreamingAll(io, msg);
}

// ── drop ──────────────────────────────────────────────────────────────────────

fn cmdDrop(allocator: std.mem.Allocator, io: Io) !void {
    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    const oids = try readStashList(allocator, io, repo.git_dir);
    defer allocator.free(oids);
    if (oids.len == 0) return error.StashIsEmpty;

    try writeStashList(allocator, io, repo.git_dir, oids[1..]);

    var hex: [40]u8 = undefined;
    oids[0].toHex(&hex);
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Dropped stash@{{0}} ({s})\n", .{hex[0..7]});
    try File.stdout().writeStreamingAll(io, msg);
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn pushStashOnto(allocator: std.mem.Allocator, io: Io, git_dir: Dir, new_oid: zigit.Oid) !void {
    const existing = try readStashList(allocator, io, git_dir);
    defer allocator.free(existing);
    var combined: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    defer combined.deinit(allocator);
    try combined.append(allocator, new_oid);
    try combined.appendSlice(allocator, existing);
    try writeStashList(allocator, io, git_dir, combined.items);
}

fn readStashList(allocator: std.mem.Allocator, io: Io, git_dir: Dir) ![]zigit.Oid {
    const bytes = git_dir.readFileAlloc(io, stash_list_file, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(zigit.Oid, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var oids: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    errdefer oids.deinit(allocator);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len != 40) continue;
        try oids.append(allocator, try zigit.Oid.fromHex(line));
    }
    return try oids.toOwnedSlice(allocator);
}

fn writeStashList(allocator: std.mem.Allocator, io: Io, git_dir: Dir, oids: []const zigit.Oid) !void {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, oids.len * 41);
    defer allocating.deinit();
    var hex: [40]u8 = undefined;
    for (oids) |o| {
        o.toHex(&hex);
        try allocating.writer.writeAll(&hex);
        try allocating.writer.writeAll("\n");
    }
    if (oids.len == 0) {
        // Empty file is fine — keeps the slot for next push.
        try git_dir.writeFile(io, .{ .sub_path = stash_list_file, .data = "" });
    } else {
        try git_dir.writeFile(io, .{ .sub_path = stash_list_file, .data = allocating.written() });
    }
}

fn snapshotWorkdirTree(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    store: *zigit.LooseStore,
    index: *zigit.Index,
) !zigit.Oid {
    var entries: std.ArrayListUnmanaged(zigit.merge.three_way.Resolved) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }

    for (index.entries.items) |e| {
        // Read the current on-disk content for each indexed path; if
        // the file was deleted, drop it from the snapshot tree.
        const bytes = work_root.readFileAlloc(io, e.path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        const oid = zigit.object.computeOid(.blob, bytes);
        try store.write(allocator, .blob, bytes, oid);
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, e.path),
            .mode = e.mode,
            .oid = oid,
        });
    }

    return try buildTreeFromResolved(allocator, store, entries.items);
}

fn shortBranchName(allocator: std.mem.Allocator, io: Io, git_dir: Dir) ![]u8 {
    const full = try zigit.refs.resolveSymbolic(allocator, io, git_dir, zigit.refs.head_path);
    defer allocator.free(full);
    const short = if (std.mem.startsWith(u8, full, "refs/heads/")) full[11..] else full;
    return try allocator.dupe(u8, short);
}

// (Same helpers as merge / rebase — duplicated here to keep the
// patch surface small. A shared module is the right Phase 17+ move.)

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, root, .{});
}

fn treeOfCommit(allocator: std.mem.Allocator, store: *zigit.LooseStore, commit_oid: zigit.Oid) !zigit.Oid {
    var commit_obj = try store.read(allocator, commit_oid);
    defer commit_obj.deinit(allocator);
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

fn removeStalePaths(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    old_map: zigit.merge.three_way.Map,
    new_entries: []const zigit.merge.three_way.Resolved,
) !void {
    var new_set: std.StringHashMapUnmanaged(void) = .empty;
    defer new_set.deinit(allocator);
    for (new_entries) |e| try new_set.put(allocator, e.path, {});
    var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_remove.deinit(allocator);
    var it = old_map.keyIterator();
    while (it.next()) |k| if (!new_set.contains(k.*)) try to_remove.append(allocator, k.*);
    try zigit.worktree.removePaths(io, work_root, to_remove.items);
}

fn rebuildIndexFromTree(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    tree_oid: zigit.Oid,
) !void {
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
    var index: zigit.Index = .empty(allocator);
    defer index.deinit();
    for (leaves) |l| {
        const flags_path_len: u16 = if (l.path.len > 0xFFF) 0xFFF else @intCast(l.path.len);
        try index.upsert(.{
            .ctime_s = 0, .ctime_ns = 0, .mtime_s = 0, .mtime_ns = 0,
            .dev = 0, .ino = 0,
            .mode = l.mode, .uid = 0, .gid = 0, .file_size = 0,
            .oid = l.oid,
            .flags = flags_path_len,
            .path = l.path,
        });
    }
    try index.save(io, repo.git_dir);
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
