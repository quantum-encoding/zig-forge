//! zarch - Print machine hardware architecture
//!
//! A Zig implementation of arch.
//! Print the machine architecture (equivalent to 'uname -m').
//!
//! Usage: zarch [OPTION]

const std = @import("std");

const VERSION = "1.0.0";

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) void {
    // Parse args manually for minimal overhead.
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var end_of_options = false;
    while (args_iter.next()) |arg| {
        if (!end_of_options) {
            if (std.mem.eql(u8, arg, "--")) {
                // GNU getopt: "--" terminates option processing; the rest are operands.
                end_of_options = true;
                continue;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeStdout("zarch {s}\n", .{VERSION});
                return;
            } else if (arg.len > 0 and arg[0] == '-') {
                writeStderr("zarch: unrecognized option '{s}'\n", .{arg});
                writeStderr("Try 'zarch --help' for more information.\n", .{});
                std.process.exit(1);
            }
        }
        // Any non-option argument (or anything after "--") is an extra operand.
        // GNU arch: "arch: extra operand 'foo'".
        writeStderr("zarch: extra operand '{s}'\n", .{arg});
        writeStderr("Try 'zarch --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Get machine architecture. std.posix.uname() resolves to the correct
    // per-target `utsname` layout (Darwin: 5 fields of [255:0]u8 = 1280 bytes;
    // Linux/glibc: 6 fields of [65]u8 = 390 bytes), so the buffer size and the
    // `machine` field offset are always correct for the host.
    const uts = std.posix.uname();

    // `machine` is a null-terminated array; slice it to the terminator.
    const machine = std.mem.sliceTo(&uts.machine, 0);

    writeStdout("{s}\n", .{machine});
}

fn printHelp() void {
    writeStdout(
        \\Usage: zarch [OPTION]
        \\Print machine architecture.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    , .{});
}
