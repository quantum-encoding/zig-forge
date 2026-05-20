// `zigit fetch [REMOTE]`
//
// Incremental fetch over smart-HTTP v2. Default remote is "origin".
//
// Steps:
//   1. Resolve remote.<name>.url from .git/config.
//   2. discoverV2 — sanity-check the server speaks v2.
//   3. lsRefs — get the remote's current ref → oid mapping.
//   4. For each advertised refs/heads/<branch>, decide whether to
//      pull: filter out oids we already have locally.
//   5. If anything to fetch: smart_http.fetch(wants) → pack bytes,
//      index_pack → .idx, write the pair into .git/objects/pack/.
//   6. Update .git/refs/remotes/<name>/<branch> for every advertised
//      branch.
//
// We don't currently implement have/want negotiation — the server
// sends a fat pack reachable from `wants`. That's wasteful on
// large repos but always correct, and matches the user-chosen
// scope. Tags and HEAD-as-symref are deferred; only refs/heads/* is
// tracked into refs/remotes/<name>/.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len > 1) return error.UsageFetchOptionalRemote;
    const remote_name: []const u8 = if (args.len == 1) args[0] else "origin";

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote_name});
    defer allocator.free(url_key);
    const url = cfg.get(url_key) orelse return error.RemoteNotFound;

    // 1. Capability check + ls-refs.
    try zigit.net.smart_http.discoverV2(allocator, io, url);
    const refs = try zigit.net.smart_http.lsRefs(allocator, io, url);
    defer zigit.net.smart_http.freeRefs(allocator, refs);

    // 2. Filter to refs/heads/* (we ignore HEAD and refs/tags/* for now).
    var heads: std.ArrayListUnmanaged(zigit.net.smart_http.Ref) = .empty;
    defer heads.deinit(allocator);
    for (refs) |r| {
        if (std.mem.startsWith(u8, r.name, "refs/heads/")) try heads.append(allocator, r);
    }

    if (heads.items.len == 0) {
        try File.stdout().writeStreamingAll(io, "fetch: remote advertised no branches\n");
        return;
    }

    // 3. Decide which oids we still need to download. Read each
    //    advertised oid via the local store; if read succeeds the
    //    object's already on disk.
    var store = repo.looseStore();
    var wants_seen: std.AutoHashMapUnmanaged([40]u8, void) = .empty;
    defer wants_seen.deinit(allocator);
    var wants: std.ArrayListUnmanaged([40]u8) = .empty;
    defer wants.deinit(allocator);

    for (heads.items) |r| {
        const oid = zigit.Oid.fromHex(&r.oid_hex) catch continue;
        // Try to read — ObjectNotFound means we need to download.
        var loaded = store.read(allocator, oid) catch |e| switch (e) {
            error.ObjectNotFound => {
                if ((try wants_seen.getOrPut(allocator, r.oid_hex)).found_existing) continue;
                try wants.append(allocator, r.oid_hex);
                continue;
            },
            else => return e,
        };
        loaded.deinit(allocator);
    }

    var msg_buf: [256]u8 = undefined;

    var fetched_objects: usize = 0;
    if (wants.items.len > 0) {
        // 4. Pull the pack and store it alongside whatever's already
        //    in .git/objects/pack/.
        const fetch_msg = try std.fmt.bufPrint(
            &msg_buf,
            "Fetching {d} ref(s) from {s}...\n",
            .{ wants.items.len, remote_name },
        );
        try File.stdout().writeStreamingAll(io, fetch_msg);

        const pack_bytes = try zigit.net.smart_http.fetch(allocator, io, url, wants.items);
        defer allocator.free(pack_bytes);

        const idx_result = try zigit.pack.index_pack.build(allocator, pack_bytes);
        defer allocator.free(idx_result.idx_bytes);
        fetched_objects = idx_result.object_count;

        try repo.objects_dir.createDirPath(io, "pack");
        var pack_dir = try repo.objects_dir.openDir(io, "pack", .{});
        defer pack_dir.close(io);

        var pack_oid_hex: [40]u8 = undefined;
        idx_result.pack_oid.toHex(&pack_oid_hex);

        var pack_name_buf: [64]u8 = undefined;
        const pack_name = try std.fmt.bufPrint(&pack_name_buf, "pack-{s}.pack", .{pack_oid_hex[0..40]});
        try pack_dir.writeFile(io, .{ .sub_path = pack_name, .data = pack_bytes });

        var idx_name_buf: [64]u8 = undefined;
        const idx_name = try std.fmt.bufPrint(&idx_name_buf, "pack-{s}.idx", .{pack_oid_hex[0..40]});
        try pack_dir.writeFile(io, .{ .sub_path = idx_name, .data = idx_result.idx_bytes });
    }

    // 5. Update .git/refs/remotes/<name>/<branch> for every advertised
    //    head. Always do this regardless of whether we downloaded a
    //    pack — refs may have moved to an oid we already had.
    try repo.git_dir.createDirPath(io, "refs");
    try repo.git_dir.createDirPath(io, "refs/remotes");
    var remotes_subpath_buf: [Dir.max_path_bytes]u8 = undefined;
    const remotes_subpath = try std.fmt.bufPrint(&remotes_subpath_buf, "refs/remotes/{s}", .{remote_name});
    try repo.git_dir.createDirPath(io, remotes_subpath);

    var refs_updated: usize = 0;
    for (heads.items) |r| {
        const short = r.name["refs/heads/".len..];
        var ref_path_buf: [Dir.max_path_bytes]u8 = undefined;
        const ref_path = try std.fmt.bufPrint(
            &ref_path_buf,
            "refs/remotes/{s}/{s}",
            .{ remote_name, short },
        );
        // The on-disk payload is "<40-hex>\n".
        var line_buf: [42]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{r.oid_hex});

        // Write via tmp + rename so partial updates don't leave a half
        // file. createDirPath above guarantees the parent exists.
        var tmp_name_buf: [Dir.max_path_bytes]u8 = undefined;
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        const rand_suffix = std.mem.readInt(u64, &rand_bytes, .little);
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp.{x}", .{ ref_path, rand_suffix });

        try repo.git_dir.writeFile(io, .{ .sub_path = tmp_name, .data = line });
        try repo.git_dir.rename(tmp_name, repo.git_dir, ref_path, io);
        refs_updated += 1;
    }

    const summary = if (fetched_objects > 0)
        try std.fmt.bufPrint(
            &msg_buf,
            "From {s}\n  {d} object(s), {d} ref(s) updated\n",
            .{ url, fetched_objects, refs_updated },
        )
    else
        try std.fmt.bufPrint(
            &msg_buf,
            "From {s}\n  Already up to date — {d} ref(s) refreshed\n",
            .{ url, refs_updated },
        );
    try File.stdout().writeStreamingAll(io, summary);
}
