// `zigit commit -m <message>`
//
// The porcelain workflow on top of write-tree + commit-tree:
//
//   1. Resolve HEAD → branch ref name (e.g. "refs/heads/main").
//   2. Try to read that ref → previous commit oid, or null on the
//      first commit (an "unborn" branch).
//   3. Build a tree from the current index.
//   4. Build a commit object with the previous commit as the (sole)
//      parent, write it.
//   5. Atomically point the branch ref at the new commit.
//   6. Print "[branch (root-commit)? short-sha] subject".
//
// Identity resolution order, mirroring git's:
//   GIT_{AUTHOR,COMMITTER}_{NAME,EMAIL,DATE}  (env)
//   .git/config user.{name,email}             (repo config)
//   "zigit" / "zigit@local"                   (last-resort default)
//
// Refuses to commit if the index has no entries — matches real git's
// "nothing to commit" behaviour for the first commit.
//
// We always emit "+0000" tz; correct local-tz handling lands in
// Phase 5 alongside the libc detour for `strftime`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    var message: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--message")) {
            i += 1;
            if (i >= args.len) return error.MissingMessageArg;
            message = args[i];
        } else {
            return error.UnknownArgument;
        }
    }
    const msg = message orelse return error.MissingMessage;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    // 1. Which branch does HEAD point at?
    const branch_ref_name = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(branch_ref_name);

    // 2. What's currently at the tip of that branch?
    const parent_oid = try zigit.refs.tryResolve(allocator, io, repo.git_dir, branch_ref_name);
    const is_root = parent_oid == null;

    // 3. Build tree from the current index.
    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();
    if (index.entries.items.len == 0) return error.NothingToCommit;

    const tree_oid = try writeTreeFromIndex(allocator, &store, &index);

    // 4. Identity + commit object.
    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    const author_name = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_NAME", "user.name", "zigit");
    defer allocator.free(author_name);
    const author_email = try resolveString(allocator, environ, &cfg, "GIT_AUTHOR_EMAIL", "user.email", "zigit@local");
    defer allocator.free(author_email);
    const committer_name = try resolveString(allocator, environ, &cfg, "GIT_COMMITTER_NAME", "user.name", author_name);
    defer allocator.free(committer_name);
    const committer_email = try resolveString(allocator, environ, &cfg, "GIT_COMMITTER_EMAIL", "user.email", author_email);
    defer allocator.free(committer_email);

    const author_when = try resolveUnixOrNow(io, environ, "GIT_AUTHOR_DATE");
    const committer_when = try resolveUnixOrFallback(environ, "GIT_COMMITTER_DATE", author_when);

    var parents_storage: [1]zigit.Oid = undefined;
    const parents: []const zigit.Oid = if (parent_oid) |p| blk: {
        parents_storage[0] = p;
        break :blk parents_storage[0..1];
    } else &.{};

    const payload = try zigit.object.commit.serialize(allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = parents,
        .author = .{ .name = author_name, .email = author_email, .when_unix = author_when },
        .committer = .{ .name = committer_name, .email = committer_email, .when_unix = committer_when },
        .message = msg,
    });
    defer allocator.free(payload);

    const commit_oid = zigit.object.computeOid(.commit, payload);
    try store.write(allocator, .commit, payload, commit_oid);

    // 5. Move the branch.
    try zigit.refs.update(io, repo.git_dir, branch_ref_name, commit_oid);

    // 6. Summary.
    var commit_hex: [40]u8 = undefined;
    commit_oid.toHex(&commit_hex);
    const branch_short = if (std.mem.startsWith(u8, branch_ref_name, "refs/heads/"))
        branch_ref_name[11..]
    else
        branch_ref_name;

    const subject_end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
    const subject = msg[0..subject_end];

    var line_buf: [1024]u8 = undefined;
    const line = if (is_root)
        try std.fmt.bufPrint(
            &line_buf,
            "[{s} (root-commit) {s}] {s}\n",
            .{ branch_short, commit_hex[0..7], subject },
        )
    else
        try std.fmt.bufPrint(
            &line_buf,
            "[{s} {s}] {s}\n",
            .{ branch_short, commit_hex[0..7], subject },
        );
    try File.stdout().writeStreamingAll(io, line);
}

/// Same recursive bucket-by-component algorithm as `cli/write_tree.zig`,
/// scoped here to avoid the porcelain shelling out to itself.
fn writeTreeFromIndex(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    index: *zigit.Index,
) !zigit.Oid {
    var staged: std.ArrayListUnmanaged(StagedFile) = .empty;
    defer staged.deinit(allocator);
    for (index.entries.items) |e| {
        try staged.append(allocator, .{ .path = e.path, .mode = e.mode, .oid = e.oid });
    }
    return try buildTree(allocator, store, staged.items);
}

const StagedFile = struct {
    path: []const u8,
    mode: u32,
    oid: zigit.Oid,
};

fn buildTree(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    entries: []const StagedFile,
) !zigit.Oid {
    var subdirs: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(StagedFile)) = .empty;
    defer {
        var it = subdirs.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(allocator);
        subdirs.deinit(allocator);
    }

    var tree_entries: std.ArrayListUnmanaged(zigit.object.TreeEntry) = .empty;
    defer tree_entries.deinit(allocator);

    for (entries) |se| {
        if (std.mem.indexOfScalar(u8, se.path, '/')) |slash| {
            const component = se.path[0..slash];
            const remainder = se.path[slash + 1 ..];
            const gop = try subdirs.getOrPut(allocator, component);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{
                .path = remainder, .mode = se.mode, .oid = se.oid,
            });
        } else {
            try tree_entries.append(allocator, .{
                .mode = se.mode, .name = se.path, .oid = se.oid,
            });
        }
    }

    var it = subdirs.iterator();
    while (it.next()) |kv| {
        const sub_oid = try buildTree(allocator, store, kv.value_ptr.items);
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

fn resolveUnixOrFallback(environ: std.process.Environ, env_key: []const u8, fallback: i64) !i64 {
    if (environ.getPosix(env_key)) |v| return try std.fmt.parseInt(i64, v, 10);
    return fallback;
}
