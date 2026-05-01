// `zigit clone URL [PATH]`
//
// Read-only clone over smart-HTTP v2.
//
// Steps:
//   1. Derive a target dir name from URL if PATH wasn't given.
//   2. mkdir + zigit-init the target.
//   3. discoverV2 — sanity-check the server speaks v2.
//   4. ls-refs — get HEAD + every refs/heads/*, refs/tags/*.
//   5. Find HEAD's commit oid (and its symref-target so we can point
//      .git/HEAD at the right branch).
//   6. fetch want=<HEAD-oid> done — receive the pack.
//   7. index-pack the received bytes → .idx.
//   8. Write pack-<sha>.{pack,idx} to .git/objects/pack/.
//   9. Write packed-refs from the ls-refs output.
//   10. Write .git/HEAD pointing at the right branch (symbolic).
//   11. Resolve HEAD → tree → materialise the work tree, rebuild
//       the index from that tree (same path switch/checkout uses).
//
// Errors abort cleanly with a friendly message; the partial .git
// directory is left in place so the user can inspect / retry.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");
const init_cmd = @import("init.zig");

pub fn run(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, args: []const []const u8) !void {
    _ = environ;
    if (args.len < 1 or args.len > 2) return error.UsageCloneUrlOptionalPath;

    // Phase 15: only HTTP(S) is implemented end-to-end. Detect ssh
    // forms early and emit a clear hint instead of trying to parse
    // them as URLs and failing inside std.http.Client with a cryptic
    // error.
    switch (zigit.net.url.classify(args[0])) {
        .ssh, .scp_like => return error.SshTransportNotYetImplemented,
        .git => return error.GitTransportNotYetImplemented,
        .https, .http, .unknown => {},
    }

    const url = std.mem.trimEnd(u8, args[0], "/");
    const target_path = if (args.len == 2) args[1] else try defaultPathFromUrl(allocator, url);
    defer if (args.len == 1) allocator.free(target_path);

    // 2. Init the target.
    try init_cmd.run(allocator, io, &.{target_path});

    // chdir so Repository.discover finds the new repo.
    var prev_buf: [Dir.max_path_bytes]u8 = undefined;
    const prev_len = try std.process.currentPath(io, &prev_buf);
    defer std.process.setCurrentPath(io, prev_buf[0..prev_len]) catch {};
    try std.process.setCurrentPath(io, target_path);

    // 3. Capability check.
    try zigit.net.smart_http.discoverV2(allocator, io, url);

    // 4. ls-refs.
    const refs = try zigit.net.smart_http.lsRefs(allocator, io, url);
    defer zigit.net.smart_http.freeRefs(allocator, refs);
    if (refs.len == 0) return error.RemoteHasNoRefs;

    // 5. Find HEAD.
    var head_oid_hex: ?[40]u8 = null;
    var head_branch: ?[]const u8 = null;
    for (refs) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) {
            head_oid_hex = r.oid_hex;
            if (r.symref_target.len > 0) head_branch = r.symref_target;
            break;
        }
    }
    if (head_oid_hex == null) return error.RemoteMissingHead;

    var msg_buf: [256]u8 = undefined;
    const start_msg = try std.fmt.bufPrint(&msg_buf, "Cloning into '{s}'...\n", .{target_path});
    try File.stdout().writeStreamingAll(io, start_msg);

    // 6. fetch every advertised branch + tag (deduped) so the resulting
    //    pack covers the full repo; matches what `git clone` does by
    //    default. HEAD is implicit (covered by its target branch).
    var wants_seen: std.AutoHashMapUnmanaged([40]u8, void) = .empty;
    defer wants_seen.deinit(allocator);
    var wants_list: std.ArrayListUnmanaged([40]u8) = .empty;
    defer wants_list.deinit(allocator);
    for (refs) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        if ((try wants_seen.getOrPut(allocator, r.oid_hex)).found_existing) continue;
        try wants_list.append(allocator, r.oid_hex);
    }
    if (wants_list.items.len == 0) {
        // Nothing branch-shaped advertised — fall back to HEAD oid.
        try wants_list.append(allocator, head_oid_hex.?);
    }
    const pack_bytes = try zigit.net.smart_http.fetch(allocator, io, url, wants_list.items);
    defer allocator.free(pack_bytes);

    // 7. index-pack.
    const idx_result = try zigit.pack.index_pack.build(allocator, pack_bytes);
    defer allocator.free(idx_result.idx_bytes);

    // 8. Write pack files into .git/objects/pack/.
    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    try repo.objects_dir.createDirPath(io, "pack");
    var pack_dir = try repo.objects_dir.openDir(io, "pack", .{});
    defer pack_dir.close(io);

    var pack_oid_hex: [40]u8 = undefined;
    idx_result.pack_oid.toHex(&pack_oid_hex);

    var name_buf: [64]u8 = undefined;
    const pack_name = try std.fmt.bufPrint(&name_buf, "pack-{s}.pack", .{pack_oid_hex[0..40]});
    try pack_dir.writeFile(io, .{ .sub_path = pack_name, .data = pack_bytes });

    var name_buf2: [64]u8 = undefined;
    const idx_name = try std.fmt.bufPrint(&name_buf2, "pack-{s}.idx", .{pack_oid_hex[0..40]});
    try pack_dir.writeFile(io, .{ .sub_path = idx_name, .data = idx_result.idx_bytes });

    // 9. Write packed-refs. Match real `git clone`'s convention:
    //    the active branch (HEAD's symref-target) goes to
    //    refs/heads/<branch>; every other advertised branch becomes
    //    refs/remotes/origin/<branch>. Tags stay under refs/tags/.
    const head_branch_short: []const u8 = blk: {
        const head_target = head_branch orelse break :blk "main";
        if (std.mem.startsWith(u8, head_target, "refs/heads/")) break :blk head_target[11..];
        break :blk head_target;
    };
    try writePackedRefs(allocator, io, repo.git_dir, refs, head_branch_short);

    // 9b. Auto-add `[remote "origin"]` so `zigit fetch / push` (and
    //     anyone reading .git/config) can find the source URL.
    {
        var cfg = try zigit.config.load(allocator, io, repo.git_dir);
        defer cfg.deinit();
        try cfg.set("remote", "origin", "url", url);
        const fetch_spec = "+refs/heads/*:refs/remotes/origin/*";
        try cfg.set("remote", "origin", "fetch", fetch_spec);
        // Also record the upstream for the active branch — that's what
        // `git clone` does and it's what `push` will look at.
        try cfg.set("branch", head_branch_short, "remote", "origin");
        const merge_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{head_branch_short});
        defer allocator.free(merge_ref);
        try cfg.set("branch", head_branch_short, "merge", merge_ref);
        try cfg.save(allocator, io, repo.git_dir);
    }

    // 10. Set HEAD to the symbolic ref the remote suggested (or
    //     fall back to refs/heads/main if HEAD wasn't symbolic).
    const head_target = head_branch orelse "refs/heads/main";
    const head_payload = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{head_target});
    defer allocator.free(head_payload);
    try repo.git_dir.writeFile(io, .{ .sub_path = "HEAD.tmp", .data = head_payload });
    try repo.git_dir.rename("HEAD.tmp", repo.git_dir, "HEAD", io);

    // 11. Materialise the work tree by checking out HEAD's tree.
    //     Re-discover so the new pack is loaded into PackStore.
    repo.deinit();
    repo = try zigit.Repository.discover(allocator, io);

    var store = repo.looseStore();
    var commit_obj = try store.read(allocator, .{ .bytes = hexToBytes(head_oid_hex.?) });
    defer commit_obj.deinit(allocator);
    var parsed = try zigit.object.commit.parse(allocator, commit_obj.payload);
    defer parsed.deinit(allocator);

    // Open work-tree root (parent of .git).
    const work_root_path = std.fs.path.dirname(repo.git_dir_path) orelse return error.NoWorkTree;
    var work_root = try Dir.openDirAbsolute(io, work_root_path, .{});
    defer work_root.close(io);
    try zigit.worktree.applyTree(allocator, io, work_root, &store, parsed.tree_oid);

    // Rebuild index from tree (statting freshly-written files).
    try rebuildIndexFromTree(allocator, io, work_root, repo.git_dir, &store, parsed.tree_oid);

    const done_msg = try std.fmt.bufPrint(
        &msg_buf,
        "Cloned {d} objects (HEAD: {s})\n",
        .{ idx_result.object_count, pack_oid_hex[0..7] },
    );
    try File.stdout().writeStreamingAll(io, done_msg);
}

fn defaultPathFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Take the last path segment, strip a trailing ".git" if present.
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return error.CannotInferTargetPath;
    const last = url[slash + 1 ..];
    const trimmed = if (std.mem.endsWith(u8, last, ".git")) last[0 .. last.len - 4] else last;
    if (trimmed.len == 0) return error.CannotInferTargetPath;
    return try allocator.dupe(u8, trimmed);
}

fn hexToBytes(hex: [40]u8) [20]u8 {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &hex) catch unreachable;
    return out;
}

fn writePackedRefs(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    refs: []const zigit.net.smart_http.Ref,
    head_branch_short: []const u8,
) !void {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer allocating.deinit();
    try allocating.writer.writeAll("# pack-refs with: peeled fully-peeled sorted \n");

    // Build the rewritten ref list:
    //   * the HEAD branch  → refs/heads/<head_branch_short>
    //   * other branches   → refs/remotes/origin/<short-name>
    //   * tags             → unchanged
    var rewritten: std.ArrayListUnmanaged(struct { name: []u8, oid_hex: [40]u8 }) = .empty;
    defer {
        for (rewritten.items) |r| allocator.free(r.name);
        rewritten.deinit(allocator);
    }

    for (refs) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        if (std.mem.startsWith(u8, r.name, "refs/heads/")) {
            const short = r.name[11..];
            if (std.mem.eql(u8, short, head_branch_short)) {
                try rewritten.append(allocator, .{
                    .name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{short}),
                    .oid_hex = r.oid_hex,
                });
            } else {
                try rewritten.append(allocator, .{
                    .name = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{short}),
                    .oid_hex = r.oid_hex,
                });
            }
        } else if (std.mem.startsWith(u8, r.name, "refs/tags/")) {
            try rewritten.append(allocator, .{
                .name = try allocator.dupe(u8, r.name),
                .oid_hex = r.oid_hex,
            });
        }
    }

    std.mem.sort(@TypeOf(rewritten.items[0]), rewritten.items, {}, struct {
        fn lt(_: void, a: @TypeOf(rewritten.items[0]), b: @TypeOf(rewritten.items[0])) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    for (rewritten.items) |r| {
        try allocating.writer.print("{s} {s}\n", .{ r.oid_hex, r.name });
    }

    try git_dir.writeFile(io, .{ .sub_path = "packed-refs.tmp", .data = allocating.written() });
    try git_dir.rename("packed-refs.tmp", git_dir, "packed-refs", io);
}

fn rebuildIndexFromTree(
    allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    git_dir: Dir,
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
        var f = try work_root.openFile(io, l.path, .{});
        defer f.close(io);
        const st = try f.stat(io);

        const flags_path_len: u16 = if (l.path.len > 0xFFF) 0xFFF else @intCast(l.path.len);

        try index.upsert(.{
            .ctime_s = clampSec(st.ctime.nanoseconds),
            .ctime_ns = clampNs(st.ctime.nanoseconds),
            .mtime_s = clampSec(st.mtime.nanoseconds),
            .mtime_ns = clampNs(st.mtime.nanoseconds),
            .dev = 0,
            .ino = @truncate(@as(u128, @bitCast(@as(i128, st.inode)))),
            .mode = l.mode,
            .uid = 0,
            .gid = 0,
            .file_size = std.math.cast(u32, st.size) orelse std.math.maxInt(u32),
            .oid = l.oid,
            .flags = flags_path_len,
            .path = l.path,
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
