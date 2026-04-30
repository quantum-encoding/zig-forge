// `zigit diff [--cached|--staged] [pathspec...]`
//
// Default mode:           workdir vs index   (what `add` would stage)
// --cached / --staged:    index vs HEAD tree (what `commit` would record)
//
// We iterate every path that appears on at least one side, run Myers
// over the line slices, and emit a unified diff per file using the
// renderer in `diff/unified.zig`.
//
// Pathspec filtering is exact-match only for now — a path argument
// must equal an entry's path in the index/tree. Globs and prefix
// match land in Phase 5.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var cached = false;
    var pathspecs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pathspecs.deinit(allocator);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--cached") or std.mem.eql(u8, a, "--staged")) {
            cached = true;
        } else {
            try pathspecs.append(allocator, a);
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    var head_map = try buildHeadMap(allocator, io, repo.git_dir, &store);
    defer freePathOidMap(allocator, &head_map);

    var index = try zigit.Index.load(allocator, io, repo.git_dir);
    defer index.deinit();
    var index_map: std.StringHashMapUnmanaged(PathOid) = .empty;
    defer index_map.deinit(allocator);
    for (index.entries.items) |e| try index_map.put(allocator, e.path, .{ .mode = e.mode, .oid = e.oid });

    if (cached) {
        // before = HEAD tree, after = index
        try renderDiffs(allocator, io, &store, head_map, index_map, null, pathspecs.items);
    } else {
        // before = index, after = workdir (read from disk)
        var work_root = try openWorkRoot(io, &repo);
        defer work_root.close(io);
        var empty_after: std.StringHashMapUnmanaged(PathOid) = .empty;
        defer empty_after.deinit(allocator);
        try renderDiffs(allocator, io, &store, index_map, empty_after, work_root, pathspecs.items);
    }
}

const PathOid = struct { mode: u32, oid: zigit.Oid };

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

fn openWorkRoot(io: Io, repo: *zigit.Repository) !Dir {
    const work_root = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    return try Dir.openDirAbsolute(io, work_root, .{});
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn renderDiffs(
    allocator: std.mem.Allocator,
    io: Io,
    store: *zigit.LooseStore,
    before: std.StringHashMapUnmanaged(PathOid),
    after_map: std.StringHashMapUnmanaged(PathOid),
    workdir_opt: ?Dir,
    pathspecs: []const []const u8,
) !void {
    // Build the union of paths to consider.
    var paths_set: std.StringHashMapUnmanaged(void) = .empty;
    defer paths_set.deinit(allocator);

    var b_iter = before.iterator();
    while (b_iter.next()) |kv| try paths_set.put(allocator, kv.key_ptr.*, {});
    var a_iter = after_map.iterator();
    while (a_iter.next()) |kv| try paths_set.put(allocator, kv.key_ptr.*, {});

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);
    var ps_iter = paths_set.iterator();
    while (ps_iter.next()) |kv| try paths.append(allocator, kv.key_ptr.*);

    if (pathspecs.len > 0) {
        var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
        defer filtered.deinit(allocator);
        for (paths.items) |p| {
            for (pathspecs) |ps| if (std.mem.eql(u8, p, ps)) {
                try filtered.append(allocator, p);
                break;
            };
        }
        paths.deinit(allocator);
        paths = filtered;
    }

    std.mem.sort([]const u8, paths.items, {}, lessStr);

    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer allocating.deinit();
    const out = File.stdout();

    for (paths.items) |path| {
        allocating.clearRetainingCapacity();
        try renderOnePath(
            allocator,
            io,
            &allocating.writer,
            store,
            before.get(path),
            after_map.get(path),
            workdir_opt,
            path,
        );
        if (allocating.written().len > 0) {
            try out.writeStreamingAll(io, allocating.written());
        }
    }
}

fn renderOnePath(
    allocator: std.mem.Allocator,
    io: Io,
    out: *std.Io.Writer,
    store: *zigit.LooseStore,
    before_opt: ?PathOid,
    after_map_opt: ?PathOid,
    workdir_opt: ?Dir,
    path: []const u8,
) !void {
    const before_bytes: ?[]u8 = if (before_opt) |bp| try loadBlobBytes(allocator, store, bp.oid) else null;
    defer if (before_bytes) |b| allocator.free(b);

    var after_bytes: ?[]u8 = null;
    var after_oid_opt: ?zigit.Oid = null;
    var after_mode: u32 = 0o100644;

    if (after_map_opt) |ap| {
        after_bytes = try loadBlobBytes(allocator, store, ap.oid);
        after_oid_opt = ap.oid;
        after_mode = ap.mode;
    } else if (workdir_opt) |wd| {
        const bytes = wd.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |b| {
            after_bytes = b;
            after_oid_opt = zigit.object.computeOid(.blob, b);
        }
    }
    defer if (after_bytes) |b| allocator.free(b);

    // Identical → no diff.
    if (before_opt) |bp| {
        if (after_oid_opt) |a_oid| {
            if (bp.oid.eql(a_oid)) return;
        }
    }
    // Both sides absent shouldn't happen (we wouldn't have queued the
    // path), but bail safely.
    if (before_opt == null and after_oid_opt == null) return;

    var before_hex: [40]u8 = undefined;
    var after_hex: [40]u8 = undefined;
    if (before_opt) |bp| bp.oid.toHex(&before_hex) else @memset(&before_hex, '0');
    if (after_oid_opt) |ao| ao.toHex(&after_hex) else @memset(&after_hex, '0');

    var mode_buf: [8]u8 = undefined;
    const mode_value: u32 = if (before_opt) |bp| bp.mode else after_mode;
    const mode_str = try std.fmt.bufPrint(&mode_buf, "{o}", .{mode_value});

    const a_lines = try zigit.diff.unified.splitLinesKeepingNewline(allocator, if (before_bytes) |b| b else "");
    defer allocator.free(a_lines);
    const b_lines = try zigit.diff.unified.splitLinesKeepingNewline(allocator, if (after_bytes) |b| b else "");
    defer allocator.free(b_lines);

    const edits = try zigit.diff.myers.diff(allocator, a_lines, b_lines);
    defer allocator.free(edits);

    try zigit.diff.unified.renderFile(
        allocator,
        out,
        .{
            .path = path,
            .old_oid_hex = &before_hex,
            .new_oid_hex = &after_hex,
            .mode = mode_str,
        },
        a_lines,
        b_lines,
        edits,
        zigit.diff.unified.default_context,
    );
}

fn loadBlobBytes(
    allocator: std.mem.Allocator,
    store: *zigit.LooseStore,
    oid: zigit.Oid,
) ![]u8 {
    const loaded = try store.read(allocator, oid);
    if (loaded.kind != .blob) {
        allocator.free(loaded.payload);
        return error.NotABlob;
    }
    return loaded.payload;
}
