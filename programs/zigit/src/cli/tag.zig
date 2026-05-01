// `zigit tag [-d] [NAME [COMMIT]]`
//
//   no args         List local tags (under refs/tags/), one per line
//   NAME [COMMIT]   Create a lightweight tag pointing at COMMIT
//                   (default HEAD). Refuses to overwrite an existing
//                   tag — pass -f for that (not implemented yet).
//   -d NAME         Delete the tag.
//
// Lightweight tags only — they're just a ref under refs/tags/<NAME>
// pointing directly at a commit, no separate tag object. Annotated
// tags (which carry a message + tagger + signature) need a separate
// "tag" object kind that wraps the commit oid; we already model
// Kind.tag in the reader path but don't have a writer for it yet.
// That lands as a small Phase 11.5 follow-up when we need it.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zigit = @import("zigit");

const tags_dir = "refs/tags";

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var delete = false;
    var positional: std.ArrayListUnmanaged([]const u8) = .empty;
    defer positional.deinit(allocator);

    for (args) |a| {
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--delete")) {
            delete = true;
        } else {
            try positional.append(allocator, a);
        }
    }

    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    if (positional.items.len == 0) {
        if (delete) return error.MissingTagName;
        try listTags(allocator, io, repo.git_dir);
        return;
    }

    if (delete) {
        if (positional.items.len != 1) return error.DeleteTakesOneArg;
        try deleteTag(io, repo.git_dir, positional.items[0]);
        return;
    }

    const name = positional.items[0];
    const start = if (positional.items.len >= 2) positional.items[1] else null;
    try createTag(allocator, io, &repo, name, start);
}

fn listTags(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !void {
    var tags_root = git_dir.openDir(io, tags_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try emitPackedTagNames(allocator, io, git_dir);
            return;
        },
        else => return err,
    };
    defer tags_root.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = tags_root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".lock")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    // Also pull tag names out of packed-refs.
    try collectPackedTagNames(allocator, io, git_dir, &names);

    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Dedupe (a tag could appear in both loose and packed-refs).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    const out = File.stdout();
    var buf: [256]u8 = undefined;
    for (names.items) |n| {
        if ((try seen.getOrPut(allocator, n)).found_existing) continue;
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{n});
        try out.writeStreamingAll(io, line);
    }
}

fn collectPackedTagNames(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Dir,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    const bytes = git_dir.readFileAlloc(io, "packed-refs", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        if (line.len < 42) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (space != 40) continue;
        const ref_name = std.mem.trimEnd(u8, line[space + 1 ..], " \r\t");
        if (!std.mem.startsWith(u8, ref_name, "refs/tags/")) continue;
        try out.append(allocator, try allocator.dupe(u8, ref_name[10..]));
    }
}

fn emitPackedTagNames(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !void {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    try collectPackedTagNames(allocator, io, git_dir, &names);
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const out = File.stdout();
    var buf: [256]u8 = undefined;
    for (names.items) |n| {
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{n});
        try out.writeStreamingAll(io, line);
    }
}

fn deleteTag(io: Io, git_dir: Dir, name: []const u8) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tags_dir, name });
    git_dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.TagNotFound,
        else => return err,
    };

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Deleted tag '{s}'\n", .{name});
    try File.stdout().writeStreamingAll(io, msg);
}

fn createTag(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    name: []const u8,
    start: ?[]const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const ref_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tags_dir, name });

    if (repo.git_dir.access(io, ref_path, .{})) {
        return error.TagAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var store = repo.looseStore();
    const target_oid: zigit.Oid = if (start) |s| blk: {
        // Try as a branch name first, then as oid prefix.
        const as_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{s});
        defer allocator.free(as_ref);
        if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, as_ref)) |oid| break :blk oid;
        if (try zigit.refs.tryResolve(allocator, io, repo.git_dir, s)) |oid| break :blk oid;
        break :blk try store.resolvePrefix(s);
    } else blk: {
        break :blk (try zigit.refs.tryResolve(allocator, io, repo.git_dir, zigit.refs.head_path)) orelse return error.NoCommitsToTag;
    };

    try zigit.refs.update(io, repo.git_dir, ref_path, target_oid);
}
