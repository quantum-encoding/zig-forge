// Zigit CLI dispatch. Parses argv[1] to pick a subcommand and hands
// the rest of the arguments to that command's `run` function.
//
// Zig 0.16 ships a new `pub fn main(init: std.process.Init)` entry
// shape — `init.gpa`, `init.io`, and `init.minimal.args` are
// pre-built for us. We translate args into a flat `[]const []const u8`
// up front so subcommands don't have to know about iterators.

const std = @import("std");
const zigit = @import("zigit");

const init_cmd = @import("cli/init.zig");
const hash_object_cmd = @import("cli/hash_object.zig");
const cat_file_cmd = @import("cli/cat_file.zig");

const usage =
    \\zigit — git in zig
    \\
    \\Usage: zigit <command> [args]
    \\
    \\Plumbing:
    \\  init [path]                                   Initialise an empty repository
    \\  hash-object [-w] [-t kind] [--stdin] <file>   Compute the object hash
    \\  cat-file (-p|-t|-s|-e) <oid>                  Print, type, size, exists
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        try writeAll(io, .stderr, usage);
        std.process.exit(1);
    }

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "init")) {
        try init_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "hash-object")) {
        try hash_object_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "cat-file")) {
        try cat_file_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try writeAll(io, .stdout, usage);
    } else {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "zigit: unknown command '{s}'\n\n", .{cmd});
        try writeAll(io, .stderr, msg);
        try writeAll(io, .stderr, usage);
        std.process.exit(1);
    }
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file: std.Io.File = switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}
