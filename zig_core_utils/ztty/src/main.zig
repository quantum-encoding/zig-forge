//! ztty - Print the file name of the terminal connected to stdin
//!
//! High-performance tty implementation in Zig.

const std = @import("std");
const libc = std.c;

extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
extern "c" fn isatty(fd: c_int) c_int;

const VERSION = "1.0.0";

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: ztty [OPTION]...
        \\Print the file name of the terminal connected to standard input.
        \\
        \\Options:
        \\  -s, --silent   Print nothing, only return exit status
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
        \\Exit status:
        \\  0  if standard input is a terminal
        \\  1  if standard input is not a terminal
        \\  2  if given incorrect arguments
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("ztty " ++ VERSION ++ "\n");
}

pub fn main(init: std.process.Init) void {
    var silent = false;

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
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--silent")) {
            silent = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            writeStderr("ztty: invalid option -- '");
            writeStderr(arg[1..]);
            writeStderr("'\n");
            std.process.exit(2);
        }
    }

    // Check if stdin is a tty
    if (isatty(0) == 0) {
        if (!silent) {
            writeStdout("not a tty\n");
        }
        std.process.exit(1);
    }

    // Get tty name
    if (ttyname(0)) |name| {
        if (!silent) {
            writeStdout(std.mem.span(name));
            writeStdout("\n");
        }
    } else {
        if (!silent) {
            writeStdout("not a tty\n");
        }
        std.process.exit(1);
    }
}
