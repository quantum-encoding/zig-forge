// `zigit prune [--dry-run]`
//
// Walk every ref (HEAD + everything under refs/{heads,tags}/ +
// packed-refs entries + every reflog entry's new oid) to build a
// reachable set, then delete any loose object that isn't in it.
//
// What we deliberately don't do:
//   * Honour `--expire <when>` / `gc.pruneExpire`. Real git defaults
//     to two weeks of grace; we just delete everything unreachable.
//     (Future: read mtime from the loose-object file and skip recent
//     ones unless the user passes `--expire=now`.)
//   * Touch packed objects. Pack-level pruning happens by re-packing
//     only reachable objects + dropping the old packs — that's gc's
//     job, not prune's.
//
// Output is a compact summary: how many loose objects were scanned,
// how many were unreachable, and the byte total reclaimed.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var dry_run = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            dry_run = true;
        } else {
            return error.UnknownFlag;
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var store = repo.looseStore();

    // 1. Build the reachable set across every ref.
    var reachable: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer reachable.deinit(allocator);
    try collectReachable(allocator, io, &repo, &store, &reachable);

    // 2. Walk every loose object and decide whether to keep it.
    var scanned: usize = 0;
    var unreferenced: usize = 0;
    var bytes_reclaimed: u64 = 0;

    var objects_root = repo.objects_dir.openDir(io, ".", .{ .iterate = true }) catch
        return error.NoObjectsDir;
    defer objects_root.close(io);

    var top_iter = objects_root.iterate();
    while (try top_iter.next(io)) |top| {
        if (top.kind != .directory) continue;
        if (top.name.len != 2) continue; // skip pack/, info/
        if (!isHexByte(top.name)) continue;

        var bucket = try objects_root.openDir(io, top.name, .{ .iterate = true });
        defer bucket.close(io);

        var inner = bucket.iterate();
        while (try inner.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len != 38) continue;
            scanned += 1;

            var hex_buf: [40]u8 = undefined;
            @memcpy(hex_buf[0..2], top.name);
            @memcpy(hex_buf[2..40], entry.name);
            const oid = zigit.Oid.fromHex(&hex_buf) catch continue;
            if (reachable.contains(oid.bytes)) continue;

            // Unreferenced. Stat for the byte-tally, then unlink.
            unreferenced += 1;
            const file = try bucket.openFile(io, entry.name, .{ .mode = .read_only });
            const len = try file.length(io);
            file.close(io);
            bytes_reclaimed += len;

            if (!dry_run) try bucket.deleteFile(io, entry.name);
        }
    }

    var line_buf: [256]u8 = undefined;
    const verb = if (dry_run) "would prune" else "pruned";
    const line = try std.fmt.bufPrint(
        &line_buf,
        "Scanned {d} loose objects; {s} {d} ({d} bytes reclaimed)\n",
        .{ scanned, verb, unreferenced, bytes_reclaimed },
    );
    try File.stdout().writeStreamingAll(io, line);
}

fn isHexByte(name: []const u8) bool {
    if (name.len != 2) return false;
    return std.ascii.isHex(name[0]) and std.ascii.isHex(name[1]);
}

/// Walk every ref tip + reflog entry's new-oid + reflog old-oid, then
/// expand each into its commit's reachable closure and accumulate the
/// oids in `reachable`.
fn collectReachable(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    store: *zigit.LooseStore,
    reachable: *std.AutoHashMapUnmanaged([20]u8, void),
) !void {
    // Tips: HEAD + every loose ref + every packed-refs entry.
    var tips: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    defer tips.deinit(allocator);

    if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) |o| {
        try tips.append(allocator, o);
    }
    try collectLooseRefs(allocator, io, repo.git_dir, "refs/heads", &tips);
    try collectLooseRefs(allocator, io, repo.git_dir, "refs/tags", &tips);
    try collectLooseRefs(allocator, io, repo.git_dir, "refs/remotes", &tips);
    try collectPackedRefs(allocator, io, repo.git_dir, &tips);

    // Reflog: every old/new oid is considered reachable, matching
    // real git's behaviour during prune (it keeps reflog'd commits
    // for the grace period). We don't model the grace period — these
    // oids count as reachable forever.
    try collectReflogOids(allocator, io, repo.git_dir, &tips);

    const empty: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    for (tips.items) |tip| {
        // The walker treats blob/tag oids as no-op walks; commits
        // expand to their tree + recursively to entries. If the
        // ref directly points at a blob (rare for a real repo, but
        // possible), the walker still records that single oid.
        const r = zigit.object.walker.walk(allocator, store, tip, empty) catch |err| switch (err) {
            // Tip's commit may have been pruned in a prior aborted
            // gc cycle; skip silently.
            error.ObjectNotFound => continue,
            else => return err,
        };
        defer zigit.object.walker.freeReachable(allocator, r);
        for (r.oids) |o| try reachable.put(allocator, o.bytes, {});
    }
}

fn collectLooseRefs(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    sub: []const u8,
    out: *std.ArrayListUnmanaged(zigit.Oid),
) !void {
    var dir = git_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stack.items) |s| allocator.free(s);
        stack.deinit(allocator);
    }
    try stack.append(allocator, try allocator.dupe(u8, ""));

    while (stack.pop()) |sub_path| {
        defer allocator.free(sub_path);

        var here = if (sub_path.len == 0)
            try dir.openDir(io, ".", .{ .iterate = true })
        else
            try dir.openDir(io, sub_path, .{ .iterate = true });
        defer here.close(io);

        var it = here.iterate();
        while (try it.next(io)) |entry| {
            const next_path = if (sub_path.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, entry.name });
            errdefer allocator.free(next_path);

            switch (entry.kind) {
                .directory => try stack.append(allocator, next_path),
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".lock")) {
                        allocator.free(next_path);
                        continue;
                    }
                    defer allocator.free(next_path);
                    var ref_buf: [Dir.max_path_bytes]u8 = undefined;
                    const ref_name = try std.fmt.bufPrint(&ref_buf, "{s}/{s}", .{ sub, next_path });
                    if (try zigit.refs.tryResolve(allocator, io, git_dir, ref_name)) |o| {
                        try out.append(allocator, o);
                    }
                },
                else => allocator.free(next_path),
            }
        }
    }
}

fn collectPackedRefs(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    out: *std.ArrayListUnmanaged(zigit.Oid),
) !void {
    const bytes = git_dir.readFileAlloc(io, "packed-refs", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '^') {
            // Peeled tag — also reachable.
            const peeled = std.mem.trim(u8, line[1..], " \t\r");
            if (peeled.len < 40) continue;
            const oid = zigit.Oid.fromHex(peeled[0..40]) catch continue;
            try out.append(allocator, oid);
            continue;
        }
        if (line.len < 41) continue;
        const oid = zigit.Oid.fromHex(line[0..40]) catch continue;
        try out.append(allocator, oid);
    }
}

fn collectReflogOids(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    out: *std.ArrayListUnmanaged(zigit.Oid),
) !void {
    var logs_root = git_dir.openDir(io, "logs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer logs_root.close(io);
    try recurseReflogDir(allocator, io, logs_root, "logs", git_dir, out);
}

fn recurseReflogDir(
    allocator: std.mem.Allocator,
    io: Io,
    here: Dir,
    here_path: []const u8,
    git_dir: Dir,
    out: *std.ArrayListUnmanaged(zigit.Oid),
) !void {
    var it = here.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub_path_buf: [Dir.max_path_bytes]u8 = undefined;
                const sub_path = try std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ here_path, entry.name });
                var sub_dir = try here.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                try recurseReflogDir(allocator, io, sub_dir, sub_path, git_dir, out);
            },
            .file => {
                var sub_path_buf: [Dir.max_path_bytes]u8 = undefined;
                const sub_path = try std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ here_path, entry.name });
                const bytes = try git_dir.readFileAlloc(io, sub_path, allocator, .unlimited);
                defer allocator.free(bytes);

                var rit = zigit.reflog.iterate(bytes);
                while (rit.next()) |re| {
                    if (zigit.Oid.fromHex(&re.old_hex)) |o| try out.append(allocator, o) else |_| {}
                    if (zigit.Oid.fromHex(&re.new_hex)) |o| try out.append(allocator, o) else |_| {}
                }
            },
            else => {},
        }
    }
}
