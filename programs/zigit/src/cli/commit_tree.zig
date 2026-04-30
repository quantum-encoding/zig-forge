// `zigit commit-tree TREE [-p PARENT]... -m MSG`
//
// Wraps a tree oid in a commit object and writes it.
//
// Author / committer come from the env (mirroring git):
//   GIT_AUTHOR_NAME       fallback "zigit"
//   GIT_AUTHOR_EMAIL      fallback "zigit@local"
//   GIT_AUTHOR_DATE       fallback to current real time
//   GIT_COMMITTER_*       fallback to the GIT_AUTHOR_* values
//
// We accept GIT_AUTHOR_DATE only as a unix-ts integer right now;
// real git's date parser handles many formats. Easy to extend later.
//
// We don't yet read user.name / user.email from .git/config — env or
// default is good enough for Phase 2.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingTreeOid;

    const tree_arg = args[0];
    var parents: std.ArrayListUnmanaged(zigit.Oid) = .empty;
    defer parents.deinit(allocator);
    var message: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingParentArg;
            try parents.append(allocator, try zigit.Oid.fromHex(args[i]));
        } else if (std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingMessageArg;
            message = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    const msg = message orelse return error.MissingMessage;

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();
    var store = repo.looseStore();

    // Resolve tree oid (allow prefixes for ergonomics).
    const tree_oid = if (tree_arg.len == 40)
        try zigit.Oid.fromHex(tree_arg)
    else
        try store.resolvePrefix(tree_arg);

    // Author identity, env first then fall back.
    const author_name = try envOrDefault(allocator, environ, "GIT_AUTHOR_NAME", "zigit");
    defer allocator.free(author_name);
    const author_email = try envOrDefault(allocator, environ, "GIT_AUTHOR_EMAIL", "zigit@local");
    defer allocator.free(author_email);

    // Committer identity falls back to author values, not the literal default.
    const committer_name = try envOrDefault(allocator, environ, "GIT_COMMITTER_NAME", author_name);
    defer allocator.free(committer_name);
    const committer_email = try envOrDefault(allocator, environ, "GIT_COMMITTER_EMAIL", author_email);
    defer allocator.free(committer_email);

    const author_when = try envUnixOrNow(io, environ, "GIT_AUTHOR_DATE");
    const committer_when = try envUnixOrFallback(environ, "GIT_COMMITTER_DATE", author_when);

    const payload = try zigit.object.commit.serialize(allocator, .{
        .tree_oid = tree_oid,
        .parent_oids = parents.items,
        .author = .{ .name = author_name, .email = author_email, .when_unix = author_when },
        .committer = .{ .name = committer_name, .email = committer_email, .when_unix = committer_when },
        .message = msg,
    });
    defer allocator.free(payload);

    const oid = zigit.object.computeOid(.commit, payload);
    try store.write(allocator, .commit, payload, oid);

    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    var line: [42]u8 = undefined;
    @memcpy(line[0..40], &hex);
    line[40] = '\n';
    try File.stdout().writeStreamingAll(io, line[0..41]);
}

/// Returns a freshly-allocated copy of the env var, or `default`
/// (also dup'd, so callers always free).
fn envOrDefault(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8, default: []const u8) ![]u8 {
    if (environ.getPosix(key)) |v| return try allocator.dupe(u8, v);
    return try allocator.dupe(u8, default);
}

fn envUnixOrNow(io: Io, environ: std.process.Environ, key: []const u8) !i64 {
    if (environ.getPosix(key)) |v| {
        return try std.fmt.parseInt(i64, v, 10);
    }
    const now: std.Io.Timestamp = .now(io, .real);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
}

fn envUnixOrFallback(environ: std.process.Environ, key: []const u8, fallback: i64) !i64 {
    if (environ.getPosix(key)) |v| return try std.fmt.parseInt(i64, v, 10);
    return fallback;
}
