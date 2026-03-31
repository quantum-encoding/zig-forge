//! zarch - Print machine hardware architecture
//!
//! A Zig implementation of arch.
//! Print the machine architecture (equivalent to 'uname -m').
//!
//! Usage: zarch [OPTION]

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn uname(buf: *Utsname) c_int;

const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};

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

pub fn main(init: std.process.Init) void {
    // Parse args manually for minimal overhead
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zarch {s}\n", .{VERSION});
            return;
        } else {
            writeStderr("zarch: unrecognized option '{s}'\n", .{arg});
            writeStderr("Try 'zarch --help' for more information.\n", .{});
            std.process.exit(1);
        }
    }

    // Get machine architecture
    var uts: Utsname = undefined;
    if (uname(&uts) != 0) {
        writeStderr("zarch: cannot get system information\n", .{});
        std.process.exit(1);
    }

    // Find null terminator in machine field
    var len: usize = 0;
    while (len < uts.machine.len and uts.machine[len] != 0) : (len += 1) {}

    writeStdout("{s}\n", .{uts.machine[0..len]});
}

fn printHelp() void {
    writeStdout(
        \\Usage: zarch [OPTION]
        \\Print machine hardware name (same as 'uname -m').
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    , .{});
}
