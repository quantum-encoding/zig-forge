//! ztty - Print the file name of the terminal connected to stdin
//!
//! High-performance tty implementation in Zig.
//!
//! Behaviour is anchored to GNU coreutils `tty` (9.10):
//!   * --help / --version write to STDOUT and exit 0.
//!   * `--` terminates option parsing.
//!   * Non-option operands are an error (exit 2, "extra operand").
//!   * Unrecognized long options -> "unrecognized option '--x'" (exit 2).
//!   * Invalid short options are parsed char-by-char (bundling), and an
//!     unknown short char -> "invalid option -- 'x'" (exit 2).
//!   * -s / --silent / --quiet all suppress output.

const std = @import("std");
const libc = std.c;

extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
extern "c" fn isatty(fd: c_int) c_int;

const VERSION = "1.0.0";

fn writeFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) {
            // -1 == error (retry on EINTR), 0 shouldn't happen for a regular
            // write; bail out rather than spin forever.
            const err = std.posix.errno(n);
            if (n < 0 and err == .INTR) continue;
            return;
        }
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeFd(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeFd(libc.STDERR_FILENO, data);
}

const TRY_HINT = "Try 'ztty --help' for more information.\n";

fn printUsage() void {
    const usage =
        \\Usage: ztty [OPTION]...
        \\Print the file name of the terminal connected to standard input.
        \\
        \\Options:
        \\  -s, --silent, --quiet   print nothing, only return an exit status
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\Exit status:
        \\  0  if standard input is a terminal
        \\  1  if standard input is not a terminal
        \\  2  if given incorrect arguments
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("ztty " ++ VERSION ++ "\n");
}

/// Report a getopt-style error to stderr and exit 2.
fn optionError(prefix: []const u8, opt: []const u8, suffix: []const u8) noreturn {
    writeStderr(prefix);
    writeStderr(opt);
    writeStderr(suffix);
    writeStderr(TRY_HINT);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) void {
    var silent = false;
    var end_of_opts = false;
    var have_operand = false;
    var operand: []const u8 = "";

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (end_of_opts) {
            if (!have_operand) {
                have_operand = true;
                operand = arg;
            }
            continue;
        }

        if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long option (or the bare "--" terminator).
            if (arg.len == 2) {
                // "--" : end of options.
                end_of_opts = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, arg, "--silent") or
                std.mem.eql(u8, arg, "--quiet"))
            {
                silent = true;
            } else {
                // "ztty: unrecognized option '--bogus'"
                optionError("ztty: unrecognized option '", arg, "'\n");
            }
        } else if (arg.len >= 2 and arg[0] == '-') {
            // Bundled short options: parse char by char (e.g. -sx, -ss).
            for (arg[1..]) |c| {
                switch (c) {
                    's' => silent = true,
                    else => {
                        // "ztty: invalid option -- 'x'"
                        const one = [_]u8{c};
                        optionError("ztty: invalid option -- '", &one, "'\n");
                    },
                }
            }
        } else {
            // Non-option operand (including a lone "-").
            if (!have_operand) {
                have_operand = true;
                operand = arg;
            }
        }
    }

    if (have_operand) {
        // "ztty: extra operand 'foo'"
        optionError("ztty: extra operand '", operand, "'\n");
    }

    // Check if stdin is a tty.
    if (isatty(0) == 0) {
        if (!silent) {
            writeStdout("not a tty\n");
        }
        std.process.exit(1);
    }

    // Get tty name.
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
