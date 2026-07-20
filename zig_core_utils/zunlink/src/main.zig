//! zunlink - Remove a single file
//!
//! A Zig implementation of GNU coreutils `unlink`.
//! Calls the unlink() function to remove a single file.
//!
//! Usage: zunlink FILE
//!
//! Argument handling mirrors GNU getopt_long semantics for the two options
//! `unlink` recognizes (--help / --version, unambiguous abbreviations
//! allowed), the `--` end-of-options separator, and the "invalid option" /
//! "unrecognized option" error shapes. Anchored against GNU coreutils 9.10
//! (see src/gnu_parity_test.zig).

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

fn tryHelp() void {
    writeStderr("Try 'zunlink --help' for more information.\n", .{});
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

    // Parse arguments getopt_long-style. `unlink` takes no operands options,
    // only --help / --version; everything else is an operand. `--` ends
    // option scanning so files whose names begin with '-' can be removed.
    var operands: std.ArrayListUnmanaged([]const u8) = .empty;
    defer operands.deinit(allocator);

    var end_of_opts = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (!end_of_opts and a.len >= 1 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            if (std.mem.eql(u8, a, "--")) {
                end_of_opts = true;
                continue;
            }
            if (a.len >= 2 and a[1] == '-') {
                // Long option (possibly abbreviated, possibly with =value).
                const body = a[2..];
                const name = if (std.mem.indexOfScalar(u8, body, '=')) |eq| body[0..eq] else body;
                // name is non-empty here ("--" was handled above).
                if (std.mem.startsWith(u8, "help", name)) {
                    printHelp();
                    return;
                }
                if (std.mem.startsWith(u8, "version", name)) {
                    printVersion();
                    return;
                }
                writeStderr("zunlink: unrecognized option '{s}'\n", .{a});
                tryHelp();
                std.process.exit(1);
            }
            // Short option cluster: `unlink` has none, so the first char is
            // an invalid option (matches GNU getopt: "invalid option -- 'x'").
            writeStderr("zunlink: invalid option -- '{c}'\n", .{a[1]});
            tryHelp();
            std.process.exit(1);
        }

        try operands.append(allocator, a);
    }

    if (operands.items.len == 0) {
        writeStderr("zunlink: missing operand\n", .{});
        tryHelp();
        std.process.exit(1);
    }
    if (operands.items.len > 1) {
        writeStderr("zunlink: extra operand '{s}'\n", .{operands.items[1]});
        tryHelp();
        std.process.exit(1);
    }

    const operand = operands.items[0];

    // Heap-allocate the NUL-terminated path so the kernel decides on length
    // limits (real ENAMETOOLONG) instead of an arbitrary in-process cap.
    const path_z = try allocator.dupeZ(u8, operand);
    defer allocator.free(path_z);

    const result = unlink(path_z.ptr);

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
            .LOOP => "Too many levels of symbolic links",
            .NOTDIR => "Not a directory",
            .IO => "Input/output error",
            else => "Unknown error",
        };
        writeStderr("zunlink: cannot unlink '{s}': {s}\n", .{ operand, err_msg });
        std.process.exit(1);
    }
}

fn printVersion() void {
    // GNU-shaped identity line (honest: this is not GNU coreutils).
    writeStdout("zunlink (zig-forge coreutils) {s}\n", .{VERSION});
}

fn printHelp() void {
    writeStdout(
        \\Usage: zunlink FILE
        \\  or:  zunlink OPTION
        \\Call the unlink function to remove the specified FILE.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    , .{});
}
