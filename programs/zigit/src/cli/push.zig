// `zigit push URL [BRANCH]`
//
// Read-only push (well — write to the server, but no local mutation):
//
//   1. Resolve the local branch tip (default: HEAD's branch).
//   2. discoverV1ForReceive(URL) → server's current refs.
//   3. If the remote already has the same oid → "Everything up-to-date".
//   4. Compute reachable closure from local tip, EXCLUDING reachable
//      from the remote's current oid for that ref (so a normal
//      fast-forward push only ships new objects).
//   5. Build a pack with those objects.
//   6. POST to /git-receive-pack with `<old> <new> <ref>\0report-status`
//      + flush + the pack bytes.
//   7. Print `unpack ok` / `ok refs/heads/X` (or the server's complaint).
//
// We don't yet:
//   * Force-push (the local-old must equal the server-old or we'd
//     stomp; right now we just send and let the server reject).
//   * Push tags.
//   * Read remote URLs from .git/config — pass the URL explicitly.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

const heads_dir = "refs/heads";

pub fn run(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, args: []const []const u8) !void {
    if (args.len > 2) return error.UsagePushOptionalRemoteOptionalBranch;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    // First positional is either a URL or a remote name. If neither is
    // given, default to "origin". The lookup logic: if `remote.<arg>.url`
    // exists in config, treat the arg as a name and use the configured URL;
    // otherwise treat the arg as a URL.
    const remote_arg: []const u8 = if (args.len >= 1) args[0] else "origin";
    const url_with_creds_owned: ?[]u8 = blk: {
        const dotted = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote_arg});
        defer allocator.free(dotted);
        if (cfg.get(dotted)) |configured| {
            break :blk try allocator.dupe(u8, configured);
        }
        break :blk null;
    };
    defer if (url_with_creds_owned) |s| allocator.free(s);
    const url_with_creds: []const u8 = url_with_creds_owned orelse remote_arg;

    var auth_split = try zigit.net.auth.split(allocator, url_with_creds);
    defer zigit.net.auth.deinit(allocator, &auth_split);
    const url = auth_split.clean_url;

    // If the URL didn't carry userinfo, try .git-credentials / askpass.
    var fallback_creds: ?zigit.net.credentials.Result = null;
    defer if (fallback_creds) |*c| c.deinit(allocator);
    const authorization: ?[]const u8 = blk: {
        if (auth_split.authorization) |a| break :blk a;
        if (try zigit.net.credentials.resolve(allocator, io, environ, url)) |r| {
            fallback_creds = r;
            break :blk r.authorization;
        }
        break :blk null;
    };

    // Pick the branch.
    const branch_short: []const u8 = if (args.len == 2) args[1] else blk: {
        const head_target = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
        defer allocator.free(head_target);
        if (!std.mem.startsWith(u8, head_target, "refs/heads/")) return error.HeadIsDetached;
        // resolveSymbolic's return is owned; we need a stable copy.
        break :blk try allocator.dupe(u8, head_target[11..]);
    };
    defer if (args.len != 2) allocator.free(@constCast(branch_short));

    var ref_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const local_ref_path = try std.fmt.bufPrint(&ref_path_buf, "{s}/{s}", .{ heads_dir, branch_short });
    const local_oid = (try zigit.refs.tryResolve(allocator, io, repo.git_dir, local_ref_path)) orelse
        return error.LocalBranchNotFound;

    // Discover remote.
    const remote_refs = try zigit.net.smart_http.discoverV1ForReceive(allocator, io, url, authorization);
    defer zigit.net.smart_http.freeRefs(allocator, remote_refs);

    // Find the remote's current oid for this ref (or zeros for first push).
    var remote_oid_hex: [40]u8 = zigit.net.smart_http.zero_oid_hex;
    var remote_oid_opt: ?zigit.Oid = null;
    const target_full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_short});
    defer allocator.free(target_full_ref);
    for (remote_refs) |r| {
        if (std.mem.eql(u8, r.name, target_full_ref)) {
            remote_oid_hex = r.oid_hex;
            remote_oid_opt = try zigit.Oid.fromHex(&r.oid_hex);
            break;
        }
    }

    // No-op if local == remote.
    var local_hex: [40]u8 = undefined;
    local_oid.toHex(&local_hex);
    if (std.mem.eql(u8, &local_hex, &remote_oid_hex)) {
        try File.stdout().writeStreamingAll(io, "Everything up-to-date\n");
        return;
    }

    var store = repo.looseStore();

    // Build "haves" set = closure of remote oid (if any).
    var haves: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
    defer haves.deinit(allocator);
    if (remote_oid_opt) |remote_oid| {
        const remote_haves_set: std.AutoHashMapUnmanaged([20]u8, void) = .empty;
        const remote_reach = try zigit.object.walker.walk(allocator, &store, remote_oid, remote_haves_set);
        defer zigit.object.walker.freeReachable(allocator, remote_reach);
        for (remote_reach.oids) |o| try haves.put(allocator, o.bytes, {});
    }

    // Walk reachable from local oid, skipping anything in `haves`.
    const to_send = try zigit.object.walker.walk(allocator, &store, local_oid, haves);
    defer zigit.object.walker.freeReachable(allocator, to_send);

    if (to_send.oids.len == 0) {
        // Server already has everything reachable from our tip but
        // the ref oid differs — usually means we'd be a non-fast-
        // forward update. Send an empty pack and let the server
        // accept or reject.
    }

    // Load every payload up-front so the deltify planner can compare
    // bytes between candidates. This costs RAM but is the same shape
    // of work `git pack-objects` does pre-deltify.
    var loaded_payloads: std.ArrayListUnmanaged(zigit.object.LoadedObject) = .empty;
    defer {
        for (loaded_payloads.items) |*lp| lp.deinit(allocator);
        loaded_payloads.deinit(allocator);
    }
    try loaded_payloads.ensureTotalCapacityPrecise(allocator, to_send.oids.len);
    for (to_send.oids) |o| {
        const loaded = try store.read(allocator, o);
        loaded_payloads.appendAssumeCapacity(loaded);
    }

    const planner_objects = try allocator.alloc(zigit.pack.deltify.Object, to_send.oids.len);
    defer allocator.free(planner_objects);
    for (to_send.oids, loaded_payloads.items, 0..) |o, lp, i| planner_objects[i] = .{
        .oid = o,
        .kind = lp.kind,
        .payload = lp.payload,
    };
    const ops = try zigit.pack.deltify.plan(allocator, planner_objects);
    defer zigit.pack.deltify.freePlan(allocator, ops);

    // Build the pack.
    var pack_w = try zigit.pack.PackWriter.init(allocator, @intCast(ops.len));
    defer pack_w.deinit();
    const op_offsets = try allocator.alloc(u64, ops.len);
    defer allocator.free(op_offsets);
    for (ops, 0..) |op, i| {
        const e = switch (op) {
            .raw => |r| try pack_w.addObject(r.oid, r.kind, r.payload),
            .delta => |d| try pack_w.addOfsDelta(d.oid, op_offsets[d.base_op_index], d.delta_bytes),
        };
        op_offsets[i] = e.offset;
    }
    const finished = try pack_w.finish();
    defer allocator.free(finished.pack_bytes);

    var msg_buf: [256]u8 = undefined;
    const start_msg = try std.fmt.bufPrint(
        &msg_buf,
        "Pushing {d} objects to {s}\n",
        .{ to_send.oids.len, target_full_ref },
    );
    try File.stdout().writeStreamingAll(io, start_msg);

    var push_result = try zigit.net.smart_http.pushPack(
        allocator,
        io,
        url,
        authorization,
        target_full_ref,
        remote_oid_hex,
        local_hex,
        finished.pack_bytes,
    );
    defer push_result.deinit(allocator);

    const summary = try std.fmt.bufPrint(
        &msg_buf,
        "  remote: unpack: {s}\n  remote: {s}\n",
        .{ push_result.unpack_status, push_result.ref_status },
    );
    try File.stdout().writeStreamingAll(io, summary);

    if (!std.mem.eql(u8, push_result.unpack_status, "ok")) return error.PushFailed;
    if (!std.mem.startsWith(u8, push_result.ref_status, "ok ")) return error.PushFailed;
}
