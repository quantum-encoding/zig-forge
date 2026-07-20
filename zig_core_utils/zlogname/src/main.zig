//! zlogname - Print the user's login name
//!
//! High-performance logname implementation in Zig.
//! GNU-parity argument handling: --help / --version (any position, getopt-style
//! abbreviations), rejection of extra operands and unknown options with exit 1.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn getlogin() ?[*:0]const u8;

const HELP =
    "Usage: zlogname [OPTION]\n" ++
    "Print the user's login name.\n" ++
    "\n" ++
    "      --help     display this help and exit\n" ++
    "      --version  output version information and exit\n";

const VERSION_TEXT = "zlogname " ++ VERSION ++ "\n";

/// Write the whole buffer to `fd`, retrying on short/interrupted writes.
/// Returns error on any unrecoverable failure so callers can exit non-zero
/// instead of silently truncating output (GNU checks write/close errors).
fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = libc.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            // EINTR: retry; anything else is fatal.
            if (libc._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn dieUsage(comptime what: []const u8, arg: []const u8) noreturn {
    // Best-effort diagnostics; we are exiting non-zero regardless.
    writeAll(libc.STDERR_FILENO, "zlogname: " ++ what ++ " '") catch {};
    writeAll(libc.STDERR_FILENO, arg) catch {};
    writeAll(libc.STDERR_FILENO, "'\nTry 'zlogname --help' for more information.\n") catch {};
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var seen_dashdash = false;
    var first_operand: ?[]const u8 = null;

    // getopt-style scan: options are honored in any position; the FIRST option
    // token encountered decides the outcome (help/version -> exit 0, unknown ->
    // exit 1), matching GNU's getopt_long processing order. Operands are only
    // reported after the whole scan finds no acting option.
    while (args.next()) |arg| {
        if (seen_dashdash) {
            if (first_operand == null) first_operand = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            // Long option (with getopt_long abbreviation): the given name must
            // be a non-empty prefix of exactly one known option.
            const name = arg[2..];
            if (name.len > 0 and std.mem.startsWith(u8, "help", name)) {
                try writeAll(libc.STDOUT_FILENO, HELP);
                return;
            }
            if (name.len > 0 and std.mem.startsWith(u8, "version", name)) {
                try writeAll(libc.STDOUT_FILENO, VERSION_TEXT);
                return;
            }
            dieUsage("unrecognized option", arg);
        }
        if (arg.len > 1 and arg[0] == '-') {
            // Short option cluster; zlogname (like GNU logname) defines none.
            // GNU reports: invalid option -- 'x'
            dieUsage("invalid option --", arg[1..2]);
        }
        // "-" alone, or a bare word: an operand.
        if (first_operand == null) first_operand = arg;
    }

    if (first_operand) |op| {
        dieUsage("extra operand", op);
    }

    // POSIX getlogin() - works on both Linux and macOS.
    if (getlogin()) |name| {
        const name_slice = std.mem.span(name);
        writeAll(libc.STDOUT_FILENO, name_slice) catch std.process.exit(1);
        writeAll(libc.STDOUT_FILENO, "\n") catch std.process.exit(1);
        return;
    }

    writeAll(libc.STDERR_FILENO, "zlogname: no login name\n") catch {};
    std.process.exit(1);
}
