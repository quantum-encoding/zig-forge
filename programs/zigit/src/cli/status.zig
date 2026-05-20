// `zigit status [-s|--porcelain]`
//
// Three-way comparison between three flat path → (mode, oid) sets:
//
//   HEAD tree    — what the last commit points at  (or empty if unborn)
//   Index        — what's currently staged
//   Working tree — what's on disk now
//
// We compute two diffs:
//
//   * staged   = Index vs HEAD     → "new file" / "modified" / "deleted"
//   * unstaged = Workdir vs Index  → "modified" / "deleted"
//
// Plus one set:
//
//   * untracked = Workdir paths not in Index
//
// Output formats:
//
//   default       Long human-readable (matches `git status` reasonably
//                 closely — tip lines, indented file lists by category).
//   -s/--porcelain
//                 Two-column "XY path" lines. X = staged status vs
//                 HEAD, Y = workdir status vs index. Space = unmodified.
//                 ?? = untracked.
//
// Limitations (all land in Phase 5):
//   * No .gitignore — every untracked file shows up.
//   * Symlinks are recorded as untracked rather than hashed-as-targets.
//   * No stat-cache fast path; we re-hash every workdir file on every
//     `status` invocation. Correct, slow on big trees.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const Status = enum { unmodified, modified, added, deleted };

const PathState = struct {
    staged: Status = .unmodified,
    unstaged: Status = .unmodified,
};

/// Where the current branch sits relative to its configured upstream.
/// Computed locally from .git/refs/remotes/<remote>/<branch> — no
/// network. The user must `zigit fetch` to refresh the remote ref.
const Tracking = struct {
    /// e.g. "origin/main" — formatted for inclusion in human messages.
    upstream_label: []const u8,
    state: union(enum) {
        up_to_date,
        ahead: u32,
        behind: u32,
        diverged: struct { ahead: u32, behind: u32 },
        /// Remote ref is present but we can't walk one of the graphs
        /// (missing objects locally — typical when fetch only updated
        /// refs but not the pack). Print git's no-count form.
        unresolvable,
    },
};

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var porcelain = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--porcelain")) {
            porcelain = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    // Branch name (drop "refs/heads/" if present).
    const branch_ref = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(branch_ref);
    const branch_short = if (std.mem.startsWith(u8, branch_ref, "refs/heads/"))
        branch_ref[11..]
    else
        branch_ref;

    // ── Build the three path → (mode, oid) maps ────────────────────────
    const head_map = try buildHeadMap(allocator, io, repo.git_dir, &store);
    defer {
        var hm = head_map;
        freePathOidMap(allocator, &hm);
    }

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();
    var index_map: std.StringHashMapUnmanaged(PathOid) = .empty;
    defer index_map.deinit(allocator);
    for (index.entries.items) |e| try index_map.put(allocator, e.path, .{ .mode = e.mode, .oid = e.oid });

    // Open the work tree as a Dir handle so we can stat / read files
    // by path relative to it. The repo holds .git/, but its parent on
    // disk is the work tree root.
    var work_root = try openWorkRoot(allocator, io, &repo);
    defer work_root.close(io);

    // Subtle .gitmodules notice — submodules aren't supported in v1.
    // We skip the warning under -s/--porcelain so machine-parseable
    // output stays clean.
    if (!porcelain) try maybeWarnGitmodules(io, work_root);

    const listing = try zigit.workdir.walk(allocator, io, work_root);
    defer zigit.workdir.freeEntries(allocator, listing);

    // ── Compute per-path state ─────────────────────────────────────────
    var state_by_path: std.StringHashMapUnmanaged(PathState) = .empty;
    defer state_by_path.deinit(allocator);

    // For every (path, source) combination we touch, we need a stable
    // backing string the StringHashMap can key on without lifetime
    // headaches. Drop everything into an arena.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var untracked: std.ArrayListUnmanaged([]const u8) = .empty;
    defer untracked.deinit(allocator);

    // Pass 1: staged comparison (Index vs HEAD).
    var idx_iter = index_map.iterator();
    while (idx_iter.next()) |kv| {
        const path = kv.key_ptr.*;
        const idx_entry = kv.value_ptr.*;
        if (head_map.get(path)) |head_entry| {
            if (!head_entry.oid.eql(idx_entry.oid) or head_entry.mode != idx_entry.mode) {
                try setStaged(allocator, &state_by_path, a, path, .modified);
            }
        } else {
            try setStaged(allocator, &state_by_path, a, path, .added);
        }
    }
    var head_iter = head_map.iterator();
    while (head_iter.next()) |kv| {
        if (!index_map.contains(kv.key_ptr.*)) {
            try setStaged(allocator, &state_by_path, a, kv.key_ptr.*, .deleted);
        }
    }

    // Pass 2: unstaged comparison (Workdir vs Index).
    var workdir_set: std.StringHashMapUnmanaged(void) = .empty;
    defer workdir_set.deinit(allocator);
    for (listing) |w_entry| {
        try workdir_set.put(allocator, w_entry.path, {});

        if (index_map.get(w_entry.path)) |idx_entry| {
            // Hash the workdir file as a blob and compare. Slow path
            // until we wire the stat cache in Phase 5.
            const content = work_root.readFileAlloc(io, w_entry.path, allocator, .unlimited) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.IsDir => continue,
                else => return err,
            };
            defer allocator.free(content);
            const wd_oid = zigit.object.computeOid(.blob, content);
            if (!wd_oid.eql(idx_entry.oid)) {
                try setUnstaged(allocator, &state_by_path, a, w_entry.path, .modified);
            }
        } else {
            try untracked.append(allocator, try a.dupe(u8, w_entry.path));
        }
    }
    // Indexed paths missing from workdir → unstaged delete.
    var idx_iter2 = index_map.iterator();
    while (idx_iter2.next()) |kv| {
        if (!workdir_set.contains(kv.key_ptr.*)) {
            try setUnstaged(allocator, &state_by_path, a, kv.key_ptr.*, .deleted);
        }
    }

    // ── Render ────────────────────────────────────────────────────────
    if (porcelain) {
        try renderPorcelain(allocator, io, &state_by_path, untracked.items);
    } else {
        const head_oid = try zigit.refs.tryResolve(allocator, io, repo.git_dir, branch_ref);

        // Ahead/behind: meaningful only in the long format. We read the
        // upstream tip from .git/refs/remotes/<remote>/<branch> — no
        // network. The user must run `zigit fetch` to refresh it.
        var cfg = try zigit.config.load(allocator, io, repo.git_dir);
        defer cfg.deinit();
        var tracking_opt: ?Tracking = null;
        if (head_oid) |hoid| {
            tracking_opt = try resolveTracking(allocator, io, &repo, &store, &cfg, branch_short, hoid);
        }
        defer if (tracking_opt) |t| allocator.free(@constCast(t.upstream_label));

        try renderLong(allocator, io, branch_short, head_oid != null, tracking_opt, &state_by_path, untracked.items);
    }
}

const PathOid = struct {
    mode: u32,
    oid: zigit.Oid,
};

fn buildHeadMap(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    store: *zigit.LooseStore,
) !std.StringHashMapUnmanaged(PathOid) {
    var map: std.StringHashMapUnmanaged(PathOid) = .empty;
    errdefer freePathOidMap(allocator, &map);

    const head_oid = (try zigit.refs.tryResolve(allocator, io, git_dir, zigit.refs.head_path)) orelse return map;

    var commit_obj = try store.read(allocator, head_oid);
    defer commit_obj.deinit(allocator);
    if (commit_obj.kind != .commit) return error.HeadNotACommit;

    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);

    const Reader = struct {
        s: *zigit.LooseStore,
        a: std.mem.Allocator,
        fn read(self: @This(), oid: zigit.Oid) ![]const u8 {
            const loaded = try self.s.read(self.a, oid);
            // Caller owns `payload`; LoadedObject's deinit would also
            // free it, but we transfer ownership instead so the caller
            // can free with the same allocator.
            return loaded.payload;
        }
    };

    const leaves = try zigit.object.tree.walkRecursive(
        allocator,
        parsed.tree_oid,
        Reader{ .s = store, .a = allocator },
        Reader.read,
    );
    defer zigit.object.tree.freeLeaves(allocator, leaves);

    for (leaves) |l| {
        const owned_path = try allocator.dupe(u8, l.path);
        try map.put(allocator, owned_path, .{ .mode = l.mode, .oid = l.oid });
    }

    return map;
}

fn freePathOidMap(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(PathOid)) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit(allocator);
}

fn openWorkRoot(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
) !Dir {
    // Repository.git_dir_path is absolute; the work tree is its parent.
    const work_root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    _ = allocator;
    return try Dir.openDirAbsolute(io, work_root, .{});
}

fn getOrPutState(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(PathState),
    arena: std.mem.Allocator,
    path: []const u8,
) !*PathState {
    const gop = try map.getOrPut(allocator, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = try arena.dupe(u8, path);
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

fn setStaged(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(PathState),
    arena: std.mem.Allocator,
    path: []const u8,
    s: Status,
) !void {
    const ptr = try getOrPutState(allocator, map, arena, path);
    ptr.staged = s;
}

fn setUnstaged(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(PathState),
    arena: std.mem.Allocator,
    path: []const u8,
    s: Status,
) !void {
    const ptr = try getOrPutState(allocator, map, arena, path);
    ptr.unstaged = s;
}

fn statusChar(s: Status) u8 {
    return switch (s) {
        .unmodified => ' ',
        .modified => 'M',
        .added => 'A',
        .deleted => 'D',
    };
}

const PorcelainRow = struct { path: []const u8, st: PathState };
const LongRow = struct { label: []const u8, path: []const u8 };

fn lessByPath(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn renderPorcelain(
    allocator: std.mem.Allocator,
    io: Io,
    state_by_path: *const std.StringHashMapUnmanaged(PathState),
    untracked: []const []const u8,
) !void {
    // Collect + sort all reported paths so output is deterministic.
    var rows: std.ArrayListUnmanaged(PorcelainRow) = .empty;
    defer rows.deinit(allocator);
    var it = state_by_path.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.staged == .unmodified and kv.value_ptr.unstaged == .unmodified) continue;
        try rows.append(allocator, .{ .path = kv.key_ptr.*, .st = kv.value_ptr.* });
    }
    std.mem.sort(PorcelainRow, rows.items, {}, lessByPath(PorcelainRow));

    const out = File.stdout();
    var line_buf: [4096]u8 = undefined;
    for (rows.items) |row| {
        const line = try std.fmt.bufPrint(&line_buf, "{c}{c} {s}\n", .{
            statusChar(row.st.staged),
            statusChar(row.st.unstaged),
            row.path,
        });
        try out.writeStreamingAll(io, line);
    }

    const u_sorted = try allocator.dupe([]const u8, untracked);
    defer allocator.free(u_sorted);
    std.mem.sort([]const u8, u_sorted, {}, lessStr);
    for (u_sorted) |p| {
        const line = try std.fmt.bufPrint(&line_buf, "?? {s}\n", .{p});
        try out.writeStreamingAll(io, line);
    }
}

fn renderLong(
    allocator: std.mem.Allocator,
    io: Io,
    branch_short: []const u8,
    has_commits: bool,
    tracking: ?Tracking,
    state_by_path: *const std.StringHashMapUnmanaged(PathState),
    untracked: []const []const u8,
) !void {
    const out = File.stdout();
    var buf: [4096]u8 = undefined;

    try out.writeStreamingAll(io, try std.fmt.bufPrint(&buf, "On branch {s}\n", .{branch_short}));
    if (!has_commits) try out.writeStreamingAll(io, "\nNo commits yet\n");
    if (tracking) |t| try writeTrackingLines(io, &buf, t);

    var staged_rows: std.ArrayListUnmanaged(LongRow) = .empty;
    defer staged_rows.deinit(allocator);
    var unstaged_rows: std.ArrayListUnmanaged(LongRow) = .empty;
    defer unstaged_rows.deinit(allocator);

    var it = state_by_path.iterator();
    while (it.next()) |kv| {
        const st = kv.value_ptr.*;
        const path = kv.key_ptr.*;
        switch (st.staged) {
            .added => try staged_rows.append(allocator, .{ .label = "new file", .path = path }),
            .modified => try staged_rows.append(allocator, .{ .label = "modified", .path = path }),
            .deleted => try staged_rows.append(allocator, .{ .label = "deleted ", .path = path }),
            .unmodified => {},
        }
        switch (st.unstaged) {
            .modified => try unstaged_rows.append(allocator, .{ .label = "modified", .path = path }),
            .deleted => try unstaged_rows.append(allocator, .{ .label = "deleted ", .path = path }),
            .added, .unmodified => {},
        }
    }
    std.mem.sort(LongRow, staged_rows.items, {}, lessByPath(LongRow));
    std.mem.sort(LongRow, unstaged_rows.items, {}, lessByPath(LongRow));

    if (staged_rows.items.len > 0) {
        try out.writeStreamingAll(io, "\nChanges to be committed:\n");
        for (staged_rows.items) |r| {
            const line = try std.fmt.bufPrint(&buf, "\t{s}:   {s}\n", .{ r.label, r.path });
            try out.writeStreamingAll(io, line);
        }
    }
    if (unstaged_rows.items.len > 0) {
        try out.writeStreamingAll(io, "\nChanges not staged for commit:\n");
        for (unstaged_rows.items) |r| {
            const line = try std.fmt.bufPrint(&buf, "\t{s}:   {s}\n", .{ r.label, r.path });
            try out.writeStreamingAll(io, line);
        }
    }

    if (untracked.len > 0) {
        const u_sorted = try allocator.dupe([]const u8, untracked);
        defer allocator.free(u_sorted);
        std.mem.sort([]const u8, u_sorted, {}, lessStr);
        try out.writeStreamingAll(io, "\nUntracked files:\n");
        for (u_sorted) |p| {
            const line = try std.fmt.bufPrint(&buf, "\t{s}\n", .{p});
            try out.writeStreamingAll(io, line);
        }
    }

    if (staged_rows.items.len == 0 and unstaged_rows.items.len == 0 and untracked.len == 0) {
        if (has_commits) {
            try out.writeStreamingAll(io, "\nnothing to commit, working tree clean\n");
        } else {
            try out.writeStreamingAll(io, "\nnothing to commit (create/copy files and use \"zigit add\" to track)\n");
        }
    }
}

/// Look up the configured upstream for `branch_short` and produce a
/// commit-only ahead/behind summary. Returns null when there's no
/// upstream configured or the remote-tracking ref doesn't exist
/// locally — matches git's behaviour of silently omitting the line.
fn resolveTracking(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    cfg: *const zigit.config.Config,
    branch_short: []const u8,
    local_oid: zigit.Oid,
) !?Tracking {
    // branch.<name>.remote → "origin"
    // branch.<name>.merge  → "refs/heads/main"
    const remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch_short});
    defer allocator.free(remote_key);
    const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{branch_short});
    defer allocator.free(merge_key);

    const remote_name = cfg.get(remote_key) orelse return null;
    const merge_ref = cfg.get(merge_key) orelse return null;
    if (!std.mem.startsWith(u8, merge_ref, "refs/heads/")) return null;
    const upstream_branch = merge_ref["refs/heads/".len..];

    // Build the remote-tracking ref path: refs/remotes/<remote>/<branch>.
    const tracking_ref = try std.fmt.allocPrint(
        allocator,
        "refs/remotes/{s}/{s}",
        .{ remote_name, upstream_branch },
    );
    defer allocator.free(tracking_ref);

    const upstream_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, tracking_ref)) orelse return null;

    const upstream_label = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ remote_name, upstream_branch },
    );
    errdefer allocator.free(upstream_label);

    if (upstream_oid.eql(local_oid)) {
        return .{ .upstream_label = upstream_label, .state = .up_to_date };
    }

    // Two graph walks: commit-only reachable sets from each side. If
    // either walk fails (missing objects locally — typical after a
    // ref-only fetch), degrade to .unresolvable.
    var maybe_remote_set = try commitsReachable(allocator, store, upstream_oid);
    defer if (maybe_remote_set) |*s| s.deinit(allocator);
    var maybe_local_set = try commitsReachable(allocator, store, local_oid);
    defer if (maybe_local_set) |*s| s.deinit(allocator);

    if (maybe_remote_set == null or maybe_local_set == null) {
        return .{ .upstream_label = upstream_label, .state = .unresolvable };
    }
    const remote_set = maybe_remote_set.?;
    const local_set = maybe_local_set.?;

    var ahead: u32 = 0;
    var local_it = local_set.keyIterator();
    while (local_it.next()) |k| {
        if (!remote_set.contains(k.*)) ahead += 1;
    }
    var behind: u32 = 0;
    var remote_it = remote_set.keyIterator();
    while (remote_it.next()) |k| {
        if (!local_set.contains(k.*)) behind += 1;
    }

    const state: @TypeOf(@as(Tracking, undefined).state) = if (ahead == 0 and behind == 0)
        .up_to_date
    else if (ahead > 0 and behind == 0)
        .{ .ahead = ahead }
    else if (ahead == 0 and behind > 0)
        .{ .behind = behind }
    else
        .{ .diverged = .{ .ahead = ahead, .behind = behind } };

    return .{ .upstream_label = upstream_label, .state = state };
}

/// Commit-only BFS. Returns the set of OIDs reachable from `start`
/// or null if we hit a missing object / malformed commit. Treats a
/// non-commit start oid as malformed.
fn commitsReachable(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    start: zigit.Oid,
) !?std.AutoHashMapUnmanaged([20]u8, void) {
    var visited: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    errdefer visited.deinit(allocator);

    var queue: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    defer queue.deinit(allocator);

    try queue.append(allocator, start);
    try visited.put(allocator, start.bytes, {});

    while (queue.pop()) |current| {
        var loaded = store.read(allocator, current) catch |e| switch (e) {
            error.ObjectNotFound => {
                visited.deinit(allocator);
                return null;
            },
            else => return e,
        };
        defer loaded.deinit(allocator);
        if (loaded.kind != .commit) {
            visited.deinit(allocator);
            return null;
        }

        var parsed = zigit.object.commit.parse(allocator, loaded.payload) catch {
            visited.deinit(allocator);
            return null;
        };
        defer parsed.deinit(allocator);

        for (parsed.parent_oids) |p| {
            const gop = try visited.getOrPut(allocator, p.bytes);
            if (!gop.found_existing) try queue.append(allocator, p);
        }
    }

    return visited;
}

fn writeTrackingLines(io: Io, buf: []u8, t: Tracking) !void {
    const out = File.stdout();
    switch (t.state) {
        .up_to_date => {
            const line = try std.fmt.bufPrint(buf, "Your branch is up to date with '{s}'.\n", .{t.upstream_label});
            try out.writeStreamingAll(io, line);
        },
        .ahead => |n| {
            const noun = pluralize(n);
            const line = try std.fmt.bufPrint(
                buf,
                "Your branch is ahead of '{s}' by {d} {s}.\n  (use \"git push\" to publish your local commits)\n",
                .{ t.upstream_label, n, noun },
            );
            try out.writeStreamingAll(io, line);
        },
        .behind => |n| {
            const noun = pluralize(n);
            const line = try std.fmt.bufPrint(
                buf,
                "Your branch is behind '{s}' by {d} {s}, and can be fast-forwarded.\n  (use \"git pull\" to update your local branch)\n",
                .{ t.upstream_label, n, noun },
            );
            try out.writeStreamingAll(io, line);
        },
        .diverged => |d| {
            const noun = pluralize(@max(d.ahead, d.behind));
            const line = try std.fmt.bufPrint(
                buf,
                "Your branch and '{s}' have diverged,\nand have {d} and {d} different {s} each, respectively.\n  (use \"git pull\" if you want to integrate the remote branch with yours)\n",
                .{ t.upstream_label, d.ahead, d.behind, noun },
            );
            try out.writeStreamingAll(io, line);
        },
        .unresolvable => {
            // Remote ref present but we can't count — likely the user
            // ran `zigit fetch` against a server without grabbing the
            // pack. Match git's degraded form ("your branch and X have
            // diverged" without numbers).
            const line = try std.fmt.bufPrint(
                buf,
                "Your branch and '{s}' refer to different commits, but the divergence is unknown.\n  (run \"zigit fetch\" to update local objects)\n",
                .{t.upstream_label},
            );
            try out.writeStreamingAll(io, line);
        },
    }
}

fn pluralize(n: u32) []const u8 {
    return if (n == 1) "commit" else "commits";
}

/// If the work tree carries a .gitmodules file, surface a single-line
/// notice on stderr. Submodule resolution isn't wired up in v1, so we
/// flag the discrepancy rather than silently ignore it. Same warning
/// is emitted by `zigit diff`.
fn maybeWarnGitmodules(io: Io, work_root: Dir) !void {
    if (work_root.access(io, ".gitmodules", .{})) {
        try File.stderr().writeStreamingAll(
            io,
            "warning: this repository contains submodules, which zigit currently ignores\n",
        );
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

