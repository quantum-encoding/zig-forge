// `zigit init [path]`
//
// Creates a fresh repository skeleton:
//   <path>/.git/
//     HEAD                       → "ref: refs/heads/main\n"
//     config                     → [core] block
//     objects/info/, objects/pack/
//     refs/heads/, refs/tags/
//
// If <path> is omitted, the current directory is used. If `.git/`
// already exists we re-init: rewrite HEAD/config but leave objects/
// and refs/ alone, matching real `git init`'s behaviour.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const default_head = "ref: refs/heads/main\n";

// git's own `git init` writes tabs in the config; we use spaces
// because Zig 0.16 forbids raw tabs in multiline string literals.
// Both forms parse identically as INI.
const default_config =
    \\[core]
    \\    repositoryformatversion = 0
    \\    filemode = true
    \\    bare = false
    \\    logallrefupdates = true
    \\
;

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    const target_path = if (args.len >= 1) args[0] else ".";

    // Make sure the target directory exists.
    Dir.cwd().createDirPath(io, target_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var target_dir = try Dir.cwd().openDir(io, target_path, .{});
    defer target_dir.close(io);

    try target_dir.createDirPath(io, ".git/objects/info");
    try target_dir.createDirPath(io, ".git/objects/pack");
    try target_dir.createDirPath(io, ".git/refs/heads");
    try target_dir.createDirPath(io, ".git/refs/tags");

    var git_dir = try target_dir.openDir(io, ".git", .{});
    defer git_dir.close(io);

    try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = default_head });
    try git_dir.writeFile(io, .{ .sub_path = "config", .data = default_config });

    const abs = try target_dir.realPathFileAlloc(io, ".git", allocator);
    defer allocator.free(abs);

    var msg_buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Initialised empty Zigit repository in {s}/\n", .{abs});
    try File.stdout().writeStreamingAll(io, msg);
}
