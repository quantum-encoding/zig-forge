const std = @import("std");
const posix = std.posix;

const STDOUT_FILENO = posix.STDOUT_FILENO;
const STDERR_FILENO = posix.STDERR_FILENO;

extern "c" fn gethostid() c_long;

// GNU coreutils `hostid` parity target (coreutils 9.10):
//   - no args        -> print 8-hex-digit host id + '\n', exit 0
//   - --help         -> usage text on stdout, exit 0
//   - --version      -> version line on stdout, exit 0
//   - unknown option -> getopt-style diagnostic on stderr, exit 1
//   - extra operand  -> "PROG: extra operand 'X'" on stderr, exit 1
// See src/gnu_parity_test.zig for the anchored comparison against the real
// GNU binary.

const help_text =
    "Usage: {s} [OPTION]\n" ++
    "Print the numeric identifier (in hexadecimal) for the current host.\n" ++
    "\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n" ++
    "\n" ++
    "Full documentation and bug reports: <https://github.com/quantum-encoding/zig-forge>\n";

const version_text = "zhostid (zig-forge zig_core_utils) 1.0\n";

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);

    // argv[0] as invoked (matches GNU getopt diagnostics / "Try '...'" line).
    const argv0: []const u8 = args.next() orelse "zhostid";
    const prog = std.fs.path.basename(argv0);

    // getopt_long semantics: options are processed left-to-right regardless of
    // position (permutation), and --help/--version act the moment they are
    // seen. The operand check happens only after all options resolve.
    var terminated = false; // saw a bare "--"
    var first_operand: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (terminated) {
            if (first_operand == null) first_operand = arg;
            continue;
        }

        if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long option (or the "--" terminator).
            const name = arg[2..];
            if (name.len == 0) {
                terminated = true;
                continue;
            }
            if (isPrefixOf(name, "help")) {
                try printFmt(STDOUT_FILENO, help_text, .{prog});
                return;
            }
            if (isPrefixOf(name, "version")) {
                try writeAll(STDOUT_FILENO, version_text);
                return;
            }
            try printFmt(
                STDERR_FILENO,
                "{s}: unrecognized option '{s}'\nTry '{s} --help' for more information.\n",
                .{ argv0, arg, argv0 },
            );
            std.process.exit(1);
        } else if (arg.len >= 2 and arg[0] == '-') {
            // Short option cluster. hostid defines no short options, so the
            // first character after '-' is always invalid (matches getopt).
            try printFmt(
                STDERR_FILENO,
                "{s}: invalid option -- '{c}'\nTry '{s} --help' for more information.\n",
                .{ argv0, arg[1], argv0 },
            );
            std.process.exit(1);
        } else {
            // Non-option operand (includes "" and a lone "-").
            if (first_operand == null) first_operand = arg;
        }
    }

    if (first_operand) |op| {
        // GNU reports only the first extra operand; error() prefix is the
        // basename, but the "Try" line uses argv[0] as invoked.
        try printFmt(
            STDERR_FILENO,
            "{s}: extra operand '{s}'\nTry '{s} --help' for more information.\n",
            .{ prog, op, argv0 },
        );
        std.process.exit(1);
    }

    const hostid: u32 = @truncate(@as(u64, @bitCast(@as(i64, gethostid()))));
    try outputHostid(hostid);
}

/// True when `s` is a non-empty prefix of `full` (getopt long-option
/// abbreviation, e.g. "--hel" -> "--help").
fn isPrefixOf(s: []const u8, full: []const u8) bool {
    return s.len > 0 and s.len <= full.len and std.mem.eql(u8, s, full[0..s.len]);
}

fn outputHostid(hostid: u32) !void {
    var buf: [9]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    var val = hostid;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buf[7 - i] = hex_chars[@as(usize, @intCast(val & 0xf))];
        val >>= 4;
    }
    buf[8] = '\n';
    try writeAll(STDOUT_FILENO, &buf);
}

/// Format into a stack buffer then write it fully. The largest message this
/// program emits comfortably fits.
fn printFmt(fd: posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => return error.MessageTooLong,
    };
    try writeAll(fd, s);
}

/// Write every byte, retrying short writes and EINTR. Surfaces write failures
/// (closed pipe, disk full) instead of silently ignoring them like the
/// previous `_ = write(...)` did.
fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            switch (std.c.errno(rc)) {
                .INTR, .AGAIN => continue,
                else => return error.WriteFailed,
            }
        }
        if (rc == 0) return error.WriteZero;
        off += @intCast(rc);
    }
}
