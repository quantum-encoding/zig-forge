// `zigit checkout TARGET`
//
// Two modes:
//   * TARGET is an existing branch name → equivalent to `switch TARGET`
//     (HEAD becomes "ref: refs/heads/<name>\n").
//   * TARGET is a commit oid (full or ≥ 4-char prefix) → DETACHED HEAD
//     checkout. We resolve the prefix against the loose store, run the
//     same workdir-update workflow `switch` uses, but write the raw
//     40-char hex into HEAD instead of a symbolic ref.
//
// We don't yet support `checkout <file>` (restore-from-index) — that's
// a Phase 6 nicety bundled with `restore`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");
const switch_cli = @import("switch.zig");

const heads_dir = "refs/heads";

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 1) return error.UsageExpectsOneArgument;
    const target = args[0];

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    // Try as a branch name first.
    var ref_path_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_path = try std.fmt.bufPrint(&ref_path_buf, "{s}/{s}", .{ heads_dir, target });
    if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, ref_path)) |branch_commit| {
        const new_head = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{ref_path});
        defer allocator.free(new_head);
        try switch_cli.applyCommit(allocator, io, &repo, branch_commit, new_head);

        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "Switched to branch '{s}'\n", .{target});
        try File.stdout().writeStreamingAll(io, msg);
        return;
    }

    // Otherwise resolve as an oid (or prefix) → detached HEAD.
    var store = repo.looseStore();
    const detached_oid = if (target.len == 40)
        try zigit.Oid.fromHex(target)
    else
        store.resolvePrefix(target) catch |err| switch (err) {
            error.ObjectNotFound => return error.NoSuchBranchOrCommit,
            else => return err,
        };

    var hex: [40]u8 = undefined;
    detached_oid.toHex(&hex);
    var new_head_buf: [42]u8 = undefined;
    @memcpy(new_head_buf[0..40], &hex);
    new_head_buf[40] = '\n';

    try switch_cli.applyCommit(allocator, io, &repo, detached_oid, new_head_buf[0..41]);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "Note: switching to '{s}'.\nHEAD is now at {s}\n",
        .{ target, hex[0..7] },
    );
    try File.stdout().writeStreamingAll(io, msg);
}
