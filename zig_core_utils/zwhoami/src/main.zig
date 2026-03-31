//! zwhoami - Print effective user name
//!
//! High-performance whoami implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn getuid() u32;
extern "c" fn geteuid() u32;
extern "c" fn getpwuid(uid: u32) ?*const Passwd;

const Passwd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
};

const VERSION = "1.0.0";

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zwhoami [OPTION]...
        \\Print the user name associated with the current effective user ID.
        \\
        \\Options:
        \\  --help     Display this help and exit
        \\  --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zwhoami " ++ VERSION ++ "\n");
}

pub fn main(init: std.process.Init) void {
    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            writeStderr("zwhoami: invalid option -- '");
            writeStderr(arg[1..]);
            writeStderr("'\n");
            writeStderr("Try 'zwhoami --help' for more information.\n");
            std.process.exit(1);
        }
    }

    // Get effective user ID and look up username
    const euid = geteuid();
    const pw = getpwuid(euid);

    if (pw) |passwd| {
        const name = std.mem.span(passwd.pw_name);
        writeStdout(name);
        writeStdout("\n");
    } else {
        // Fallback: print UID as string
        var buf: [16]u8 = undefined;
        const uid_str = std.fmt.bufPrint(&buf, "{d}\n", .{euid}) catch {
            writeStderr("zwhoami: cannot find name for user ID\n");
            std.process.exit(1);
        };
        writeStdout(uid_str);
    }
}
