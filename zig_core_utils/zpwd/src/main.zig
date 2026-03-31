//! zpwd - Print working directory
//!
//! High-performance pwd implementation in Zig.
//! Supports both logical (-L) and physical (-P) modes.

const std = @import("std");
const libc = std.c;

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const VERSION = "1.0.0";
const PATH_MAX = 4096;

const Mode = enum {
    logical, // -L: Use PWD from environment, may contain symlinks
    physical, // -P: Resolve all symlinks to get physical path
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zpwd [OPTION]...
        \\Print the full filename of the current working directory.
        \\
        \\Options:
        \\  -L        Print logical working directory (default)
        \\            Uses PWD environment variable if valid
        \\  -P        Print physical working directory
        \\            Resolves all symbolic links
        \\  --help    Display this help and exit
        \\  --version Output version information and exit
        \\
        \\If no option is given, -L is assumed.
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zpwd " ++ VERSION ++ "\n");
}

fn getPhysicalCwd(buf: []u8) ?[]const u8 {
    const result = getcwd(buf.ptr, buf.len);
    if (result) |ptr| {
        // Find null terminator
        var len: usize = 0;
        while (len < buf.len and ptr[len] != 0) : (len += 1) {}
        return buf[0..len];
    }
    return null;
}

fn getLogicalCwd(buf: []u8, physical_buf: []u8) ?[]const u8 {
    // Try PWD environment variable first
    if (getenv("PWD")) |pwd_ptr| {
        const pwd = std.mem.span(pwd_ptr);
        // Validate: PWD must start with /
        if (pwd.len == 0 or pwd[0] != '/') {
            return getPhysicalCwd(physical_buf);
        }

        // Copy PWD to output buffer
        if (pwd.len < buf.len) {
            @memcpy(buf[0..pwd.len], pwd);
            return buf[0..pwd.len];
        }

        // PWD too long, fall back to physical
        return getPhysicalCwd(physical_buf);
    }

    // No PWD, fall back to physical
    return getPhysicalCwd(physical_buf);
}

pub fn main(init: std.process.Init) !void {
    var mode = Mode.logical;

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-L")) {
            mode = .logical;
        } else if (std.mem.eql(u8, arg, "-P")) {
            mode = .physical;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            writeStderr("zpwd: invalid option -- '");
            writeStderr(arg[1..]);
            writeStderr("'\n");
            writeStderr("Try 'zpwd --help' for more information.\n");
            std.process.exit(1);
        }
    }

    // Get working directory
    var buf: [PATH_MAX]u8 = undefined;
    var physical_buf: [PATH_MAX]u8 = undefined;

    const cwd = switch (mode) {
        .logical => getLogicalCwd(&buf, &physical_buf),
        .physical => getPhysicalCwd(&buf),
    };

    if (cwd) |path| {
        writeStdout(path);
        writeStdout("\n");
    } else {
        writeStderr("zpwd: error getting current directory\n");
        std.process.exit(1);
    }
}
