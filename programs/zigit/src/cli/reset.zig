// `zigit reset [--soft|--mixed|--hard] [TARGET]`
//
// TARGET defaults to HEAD's current commit (so a bare `zigit reset`
// re-syncs the index with HEAD without touching the work tree —
// the canonical "unstage everything" command).
//
// Three modes:
//
//   --soft    Move HEAD's branch ref to TARGET. Index + workdir
//             unchanged. Useful for amending commit boundaries:
//             `reset --soft HEAD~3` collapses the last 3 commits
//             back into staged changes you can re-commit.
//
//   --mixed   (default) Move HEAD's branch ref to TARGET AND
//             rewrite the index from TARGET's tree. Workdir
//             unchanged — your in-progress edits stay. Result:
//             paths that were staged but not in TARGET become
//             unstaged.
//
//   --hard    Move HEAD AND rewrite the index AND overwrite the
//             work tree from TARGET's tree. DESTRUCTIVE — any
//             unstaged or staged changes that differ from TARGET
//             are lost.
//
// We don't yet support pathspec-targeted reset (`reset HEAD <path>`
// → unstage only that path); that's already covered by
// `restore --staged <path>`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const Mode = enum { soft, mixed, hard };

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var mode: Mode = .mixed;
    var target_arg: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--soft")) {
            mode = .soft;
        } else if (std.mem.eql(u8, a, "--mixed")) {
            mode = .mixed;
        } else if (std.mem.eql(u8, a, "--hard")) {
            mode = .hard;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (target_arg == null) {
            target_arg = a;
        } else {
            return error.TooManyArguments;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    // Resolve target.
    const target_oid: zigit.Oid = if (target_arg) |t|
        try resolveCommitish(allocator, io, &repo, &store, t)
    else
        (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse return error.UnbornHead;

    // Find the branch ref HEAD points at — that's what we move.
    const branch_ref = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(branch_ref);
    if (!std.mem.startsWith(u8, branch_ref, "refs/heads/")) return error.HeadIsDetached;

    // 1. Always: move the branch ref.
    try zigit.refs.update(io, repo.git_dir, branch_ref, target_oid);

    if (mode == .soft) {
        try printSummary(io, target_oid, "soft");
        return;
    }

    // 2. --mixed and --hard: rewrite index from target's tree.
    const tree_oid = try treeOfCommit(allocator, &store, target_oid);
    try rebuildIndexFromTree(allocator, io, &repo, &store, tree_oid);

    if (mode == .mixed) {
        try printSummary(io, target_oid, "mixed");
        return;
    }

    // 3. --hard: also rewrite the work tree.
    var work_root = try openWorkRoot(io, &repo);
    defer work_root.close(io);
    try zigit.worktree.applyTree(allocator, io, work_root, &store, tree_oid);

    try printSummary(io, target_oid, "hard");
}

fn resolveCommitish(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    target: []const u8,
) !zigit.Oid {
    // Try as a branch ref.
    var ref_buf: [Dir.max_path_bytes]u8 = undefined;
    const branch_ref = try std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{target});
    if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, branch_ref)) |oid| return oid;

    // Try as HEAD or any plain ref.
    if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, target)) |oid| return oid;

    // Try as oid prefix (must be ≥ 4 chars; resolvePrefix enforces it).
    return store.resolvePrefix(target);
}

fn printSummary(io: Io, target: zigit.Oid, mode_name: []const u8) !void {
    var hex: [40]u8 = undefined;
    target.toHex(&hex);
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "HEAD is now at {s} ({s})\n", .{ hex[0..7], mode_name });
    try File.stdout().writeStreamingAll(io, msg);
}

fn treeOfCommit(allocator: std.mem.Allocator, store: *zigit.LooseStore, commit_oid: zigit.Oid) !zigit.Oid {
    var commit_obj = try store.read(allocator, commit_oid);
    defer commit_obj.deinit(allocator);
    if (commit_obj.kind != .commit) return error.NotACommit;
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);
    return parsed.tree_oid;
}

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, root, .{});
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
