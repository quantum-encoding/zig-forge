//! zprintenv - Print environment variables
//!
//! High-performance printenv implementation in Zig.
//!
//! Behavior is anchored to GNU coreutils `printenv` (9.10):
//!   - Options are only recognized BEFORE the first non-option operand
//!     (GNU/POSIX stop-at-first-operand scanning); once a NAME operand is
//!     seen, every remaining argument is a NAME, even if it begins with '-'.
//!   - `--` terminates option parsing; all following args are NAMEs.
//!   - Unrecognized options are a fatal error (exit 2) with a diagnostic on
//!     stderr — they are NOT silently ignored (that would dump the whole
//!     environment on a typo, leaking secrets).
//!   - `--help` / `--version` write to stdout and exit 0.
//!   - Missing NAME(s) cause exit 1; present ones still print.

const std = @import("std");
const libc = std.c;

extern "c" var environ: [*:null]?[*:0]u8;

const VERSION = "1.0.0";
const PROG = "zprintenv";

/// Write `data` to `fd`, retrying on EINTR and short writes. On a hard write
/// error, exit non-zero (GNU reports write errors and exits nonzero rather
/// than silently truncating).
fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            std.process.exit(1);
        }
        if (n == 0) break;
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

fn printUsage() void {
    const usage =
        \\Usage: zprintenv [OPTION]... [VARIABLE]...
        \\Print the values of the specified environment VARIABLE(s).
        \\If no VARIABLE is specified, print name and value pairs for them all.
        \\
        \\Options:
        \\  -0, --null     End each output line with NUL, not newline
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    // GNU prints --help to stdout, exit 0.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU prints --version to stdout, exit 0.
    writeStdout("zprintenv " ++ VERSION ++ "\n");
}

/// Emit a GNU-style option diagnostic to stderr and exit 2.
fn optionError(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&buf, PROG ++ ": " ++ fmt ++ "\nTry '" ++ PROG ++ " --help' for more information.\n", args)) |msg| {
        writeStderr(msg);
    } else |_| {
        writeStderr(PROG ++ ": invalid option\nTry '" ++ PROG ++ " --help' for more information.\n");
    }
    std.process.exit(2);
}

/// Look up `name` in `environ` without allocating or truncating (replicates
/// getenv semantics: first "NAME=VALUE" whose NAME matches). Handles names of
/// any length — no fixed buffer cap.
fn lookupEnv(name: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (environ[idx]) |entry_z| : (idx += 1) {
        const entry = std.mem.span(entry_z);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return entry[eq + 1 ..];
        }
    }
    return null;
}

fn printAll(terminator: []const u8) void {
    var idx: usize = 0;
    while (environ[idx]) |env_var| : (idx += 1) {
        writeStdout(std.mem.span(env_var));
        writeStdout(terminator);
    }
}

pub fn main(init: std.process.Init) void {
    var null_terminate = false;
    var in_names = false; // once true, every remaining arg is a NAME operand
    var any_name = false;
    var exit_code: u8 = 0;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (!in_names) {
            // ---- Option-scanning phase (before first operand) ----
            if (std.mem.eql(u8, arg, "--")) {
                in_names = true; // terminator: rest are names
                continue;
            }
            if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                // Long option; split off any "=value".
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const opt = if (eq) |e| arg[0..e] else arg;
                if (std.mem.eql(u8, opt, "--help")) {
                    if (eq != null) optionError("option '--help' doesn't allow an argument", .{});
                    printUsage();
                    return;
                } else if (std.mem.eql(u8, opt, "--version")) {
                    if (eq != null) optionError("option '--version' doesn't allow an argument", .{});
                    printVersion();
                    return;
                } else if (std.mem.eql(u8, opt, "--null")) {
                    if (eq != null) optionError("option '--null' doesn't allow an argument", .{});
                    null_terminate = true;
                    continue;
                } else {
                    optionError("unrecognized option '{s}'", .{arg});
                }
            }
            if (arg.len >= 2 and arg[0] == '-') {
                // Short-option cluster: process each char after '-'.
                // Only '0' (--null) is valid; anything else is fatal.
                for (arg[1..]) |c| {
                    if (c == '0') {
                        null_terminate = true;
                    } else {
                        optionError("invalid option -- '{c}'", .{c});
                    }
                }
                continue;
            }
            // Not an option (plain token, or exactly "-"): first operand.
            in_names = true;
        }

        // ---- Name phase ----
        any_name = true;
        const terminator: []const u8 = if (null_terminate) "\x00" else "\n";
        if (lookupEnv(arg)) |value| {
            writeStdout(value);
            writeStdout(terminator);
        } else {
            exit_code = 1;
        }
    }

    if (!any_name) {
        // No NAME operands: dump the entire environment.
        printAll(if (null_terminate) "\x00" else "\n");
    }

    if (exit_code != 0) std.process.exit(exit_code);
}
