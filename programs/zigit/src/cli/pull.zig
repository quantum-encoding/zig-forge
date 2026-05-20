// `zigit pull [REMOTE]`
//
// Daily-driver orchestration: fetch from REMOTE (default: the current
// branch's configured upstream remote, falling back to "origin"), then
// merge the remote-tracking ref into the current branch. Fast-forwards
// when possible; falls through to merge's three-way logic otherwise.
//
// This command is a thin shell around `fetch` and `merge`. We chose
// not to inline the smart-HTTP + graph-walk logic so there's exactly
// one implementation of each.
//
// Refspec selection (matches git's defaults):
//   * `zigit pull`            → remote = branch.<current>.remote,
//                                merge ref = branch.<current>.merge
//                                Errors if either is missing.
//   * `zigit pull REMOTE`     → remote = REMOTE,
//                                merge ref = branch.<current>.merge.
//
// Both forms require HEAD to be on a branch (not detached).

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");
const fetch_cmd = @import("fetch.zig");
const merge_cmd = @import("merge.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    if (args.len > 1) return error.UsagePullOptionalRemote;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    // HEAD must point at a branch.
    const current_full = try zigit.refs.resolveSymbolic(allocator, io, repo.git_dir, zigit.refs.head_path);
    defer allocator.free(current_full);
    if (!std.mem.startsWith(u8, current_full, "refs/heads/")) return error.HeadIsDetached;
    const branch_short = current_full["refs/heads/".len..];

    // Pick the remote: explicit arg → that. Otherwise branch.<name>.remote.
    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    const remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch_short});
    defer allocator.free(remote_key);
    const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{branch_short});
    defer allocator.free(merge_key);

    const remote_name: []const u8 = if (args.len == 1)
        args[0]
    else
        cfg.get(remote_key) orelse return error.NoUpstreamConfigured;

    const upstream_merge_ref = cfg.get(merge_key) orelse return error.NoUpstreamConfigured;
    if (!std.mem.startsWith(u8, upstream_merge_ref, "refs/heads/")) return error.UpstreamMergeRefNotABranch;
    const upstream_branch = upstream_merge_ref["refs/heads/".len..];

    // ── Phase 1: fetch ─────────────────────────────────────────────
    // Delegate. `fetch` prints its own progress to stdout.
    try fetch_cmd.run(allocator, io, &.{remote_name});

    // ── Phase 2: merge refs/remotes/<remote>/<upstream-branch> ─────
    // We re-construct the tracking-ref path here rather than reading
    // it from .git/refs/remotes — fetch just wrote it, so the on-disk
    // state and the value we'd read back are identical.
    const tracking_ref = try std.fmt.allocPrint(
        allocator,
        "refs/remotes/{s}/{s}",
        .{ remote_name, upstream_branch },
    );
    defer allocator.free(tracking_ref);

    var summary_buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &summary_buf,
        "Merging {s} into {s}\n",
        .{ tracking_ref, branch_short },
    );
    try File.stdout().writeStreamingAll(io, summary);

    try merge_cmd.run(allocator, io, environ, &.{tracking_ref});
}
