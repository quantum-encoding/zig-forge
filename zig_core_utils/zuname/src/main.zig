//! zuname - Print system information
//!
//! High-performance uname implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// utsname structure
const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};

extern "c" fn uname(buf: *Utsname) c_int;

const Config = struct {
    sysname: bool = false,
    nodename: bool = false,
    release: bool = false,
    version: bool = false,
    machine: bool = false,
    all: bool = false,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zuname [OPTION]...
        \\Print certain system information.  With no OPTION, same as -s.
        \\
        \\Options:
        \\  -a, --all             Print all information
        \\  -s, --kernel-name     Print the kernel name
        \\  -n, --nodename        Print the network node hostname
        \\  -r, --kernel-release  Print the kernel release
        \\  -v, --kernel-version  Print the kernel version
        \\  -m, --machine         Print the machine hardware name
        \\  -o, --operating-system Print the operating system
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zuname " ++ VERSION ++ "\n");
}

fn printField(field: []const u8) void {
    // Find null terminator
    var len: usize = 0;
    while (len < field.len and field[len] != 0) : (len += 1) {}
    writeStdout(field[0..len]);
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};
    var any_flag = false;

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            cfg.all = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--kernel-name")) {
            cfg.sysname = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nodename")) {
            cfg.nodename = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--kernel-release")) {
            cfg.release = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--kernel-version")) {
            cfg.version = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--machine")) {
            cfg.machine = true;
            any_flag = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--operating-system")) {
            // Just print "GNU/Linux" like coreutils does
            writeStdout("GNU/Linux\n");
            return;
        }
    }

    // Default to -s if no flags
    if (!any_flag) {
        cfg.sysname = true;
    }

    // Get system info
    var uts: Utsname = undefined;
    if (uname(&uts) != 0) {
        writeStderr("zuname: cannot get system information\n");
        std.process.exit(1);
    }

    var first = true;

    if (cfg.all or cfg.sysname) {
        if (!first) writeStdout(" ");
        first = false;
        printField(&uts.sysname);
    }

    if (cfg.all or cfg.nodename) {
        if (!first) writeStdout(" ");
        first = false;
        printField(&uts.nodename);
    }

    if (cfg.all or cfg.release) {
        if (!first) writeStdout(" ");
        first = false;
        printField(&uts.release);
    }

    if (cfg.all or cfg.version) {
        if (!first) writeStdout(" ");
        first = false;
        printField(&uts.version);
    }

    if (cfg.all or cfg.machine) {
        if (!first) writeStdout(" ");
        first = false;
        printField(&uts.machine);
    }

    if (cfg.all) {
        // Add operating system at the end for -a
        writeStdout(" GNU/Linux");
    }

    writeStdout("\n");
}
