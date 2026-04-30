// `zigit branch [-d|-D] [NAME [START]]`
//
//   no args       List local branches; mark current with '*'
//   NAME [START]  Create NAME pointing at START (default HEAD).
//                 Refuses to overwrite an existing branch.
//   -d NAME       Delete (refuses to delete the current branch).
//   -D NAME       Same as -d for now — no merged-check yet, both are
//                 unconditional deletes once the branch isn't current.
//
// We only know about loose refs under .git/refs/heads/. packed-refs
// support is queued for Phase 6 (pack files).

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const heads_dir = "refs/heads";

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var delete = false;
    var positional: std.ArrayListUnmanaged([]const u8) = .empty;
    defer positional.deinit(allocator);

    for (args) |a| {
        // -D is force-delete in real git (skips the merged-into-HEAD
        // check). We don't have that check yet, so -D and -d behave
        // identically for now.
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "-D")) {
            delete = true;
        } else {
            try positional.append(allocator, a);
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    if (positional.items.len == 0) {
        if (delete) return error.MissingBranchName;
        try listBranches(allocator, io, repo.git_dir);
        return;
    }

    if (delete) {
        if (positional.items.len != 1) return error.DeleteTakesOneArg;
        try deleteBranch(allocator, io, repo.git_dir, positional.items[0]);
        return;
    }

    const name = positional.items[0];
    const start = if (positional.items.len >= 2) positional.items[1] else null;
    try createBranch(allocator, io, &repo, name, start);
}

fn listBranches(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !void {
    // Current branch (if HEAD is symbolic).
    const current_full = try zigit.refs.resolveSymbolic(allocator, io, git_dir, zigit.refs.head_path);
    defer allocator.free(current_full);
    const current_short: ?[]const u8 = if (std.mem.startsWith(u8, current_full, "refs/heads/"))
        current_full[11..]
    else
        null;

    var heads = git_dir.openDir(io, heads_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer heads.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = heads.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Skip the .lock files left over from any in-flight ref update.
        if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const out = File.stdout();
    var line_buf: [512]u8 = undefined;
    for (names.items) |n| {
        const marker: u8 = if (current_short) |c| (if (std.mem.eql(u8, c, n)) @as(u8, '*') else ' ') else ' ';
        const line = try std.fmt.bufPrint(&line_buf, "{c} {s}\n", .{ marker, n });
        try out.writeStreamingAll(io, line);
    }
}

fn deleteBranch(allocator: std.mem.Allocator, io: Io, git_dir: Dir, name: []const u8) !void {
    // Refuse to delete the currently-checked-out branch.
    const current_full = try zigit.refs.resolveSymbolic(allocator, io, git_dir, zigit.refs.head_path);
    defer allocator.free(current_full);
    if (std.mem.startsWith(u8, current_full, "refs/heads/")) {
        if (std.mem.eql(u8, current_full[11..], name)) return error.CannotDeleteCurrentBranch;
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ heads_dir, name });

    git_dir.deleteFile(io, ref_path) catch |err| switch (err) {
        error.FileNotFound => return error.BranchNotFound,
        else => return err,
    };

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Deleted branch {s}.\n", .{name});
    try File.stdout().writeStreamingAll(io, msg);
}

fn createBranch(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    name: []const u8,
    start: ?[]const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ heads_dir, name });

    // Refuse to clobber an existing branch (matches `git branch X` —
    // it errors with "already exists"; -f overrides, not implemented yet).
    if (repo.git_dir.access(io, ref_path, .{})) {
        return error.BranchAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Resolve the start point. Default = HEAD.
    var store = repo.looseStore();
    const target_oid: zigit.Oid = if (start) |s| blk: {
        // Try as a branch name first, then as an oid prefix.
        const as_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ heads_dir, s });
        defer allocator.free(as_ref);
        if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, as_ref)) |oid| break :blk oid;
        break :blk try store.resolvePrefix(s);
    } else blk: {
        const head_oid = try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path);
        break :blk head_oid orelse return error.NoCommitsToBranchFrom;
    };

    try zigit.refs.update(io, repo.git_dir, ref_path, target_oid);
}
