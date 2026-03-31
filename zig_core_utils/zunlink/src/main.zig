//! zunlink - Remove a single file
//!
//! A Zig implementation of unlink.
//! Calls the unlink() function to remove a single file.
//!
//! Usage: zunlink FILE

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        writeStderr("zunlink: missing operand\n", .{});
        writeStderr("Try 'zunlink --help' for more information.\n", .{});
        std.process.exit(1);
    }

    const arg = args[1];

    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
        writeStdout("zunlink {s}\n", .{VERSION});
        return;
    }

    if (args.len > 2) {
        writeStderr("zunlink: extra operand '{s}'\n", .{args[2]});
        writeStderr("Try 'zunlink --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Create null-terminated path
    var path_z: [4097]u8 = undefined;
    if (arg.len >= path_z.len) {
        writeStderr("zunlink: path too long\n", .{});
        std.process.exit(1);
    }
    @memcpy(path_z[0..arg.len], arg);
    path_z[arg.len] = 0;

    const result = unlink(@ptrCast(&path_z));

    if (result != 0) {
        const errno = std.posix.errno(result);
        const err_msg: []const u8 = switch (errno) {
            .NOENT => "No such file or directory",
            .ACCES => "Permission denied",
            .PERM => "Operation not permitted",
            .BUSY => "Device or resource busy",
            .ISDIR => "Is a directory",
            .ROFS => "Read-only file system",
            .NAMETOOLONG => "File name too long",
            .LOOP => "Too many symbolic links",
            .NOTDIR => "Not a directory",
            .IO => "Input/output error",
            else => "Unknown error",
        };
        writeStderr("zunlink: cannot unlink '{s}': {s}\n", .{ arg, err_msg });
        std.process.exit(1);
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zunlink FILE
        \\Call the unlink function to remove the specified FILE.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
        \\Unlike 'rm', unlink removes exactly one file and does not
        \\accept any options other than --help and --version.
        \\
    , .{});
}
