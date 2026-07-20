//! zdirname - output each NAME with its last non-slash component and trailing
//! slashes removed (GNU coreutils `dirname` work-alike).
//!
//! GNU-parity option handling (mirrors the sibling `zbasename`):
//!   -z, --zero   end each output line with NUL, not newline
//!       --help   display this help and exit
//!       --version  output version information and exit
//!       --       end-of-options sentinel; following args are operands
//! Unrecognized options are diagnosed on stderr and exit 1 (they are NOT
//! silently treated as path operands).

const std = @import("std");
const posix = std.posix;
const libc = std.c;

// Set when a write to stdout fails or is short; forces a nonzero exit like GNU.
var write_failed: bool = false;

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| {
            self.buf[self.pos] = c;
            self.pos += 1;
            if (self.pos == self.buf.len) self.flush();
        }
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        // Loop until every buffered byte is written. A single write(2) may make
        // partial progress or be interrupted (EINTR); a closed pipe (EPIPE) or
        // any other error must not be reported as success (GNU returns 1).
        var off: usize = 0;
        while (off < self.pos) {
            const n = libc.write(libc.STDOUT_FILENO, self.buf[off..].ptr, self.pos - off);
            if (n <= 0) {
                if (n == -1 and libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
                write_failed = true;
                break;
            }
            off += @intCast(n);
        }
        self.pos = 0;
    }
};

fn dirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // Remove trailing slashes
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }

    // Find last slash
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |idx| {
        if (idx == 0) return "/";
        // Remove trailing slashes from result
        var result = p[0..idx];
        while (result.len > 1 and result[result.len - 1] == '/') {
            result = result[0 .. result.len - 1];
        }
        return result;
    }

    return ".";
}

fn errWrite(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn tryHelpAndExit() noreturn {
    errWrite("Try 'zdirname --help' for more information.\n");
    std.process.exit(1);
}

const help_text =
    \\Usage: zdirname [OPTION] NAME...
    \\Output each NAME with its last non-slash component and trailing slashes
    \\removed; if NAME contains no /'s, output '.' (meaning the current directory).
    \\
    \\  -z, --zero     end each output line with NUL, not newline
    \\      --help     display this help and exit
    \\      --version  output version information and exit
    \\
    \\Examples:
    \\  zdirname /usr/bin/          -> "/usr"
    \\  zdirname dir1/str dir2/str  -> "dir1" followed by "dir2"
    \\  zdirname stdio.h            -> "."
    \\
;

const version_text = "zdirname (zig_core_utils) 0.1.0\n";

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    var out = OutputBuffer{};

    // Collect argv so options may be interspersed with operands (GNU permutes).
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            errWrite("zdirname: out of memory\n");
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    var zero_terminated = false;
    var had_paths = false;
    var no_more_opts = false;

    // First pass: scan for -z/--zero anywhere (options are global), and validate
    // every option token. Operands are handled in the second pass.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (no_more_opts or arg.len < 2 or arg[0] != '-') continue; // operand

        if (arg[1] == '-') {
            // Long option (or the "--" sentinel).
            if (std.mem.eql(u8, arg, "--")) {
                no_more_opts = true;
            } else if (std.mem.eql(u8, arg, "--zero")) {
                zero_terminated = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                out.write(help_text);
                out.flush();
                std.process.exit(if (write_failed) 1 else 0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                out.write(version_text);
                out.flush();
                std.process.exit(if (write_failed) 1 else 0);
            } else if (std.mem.startsWith(u8, arg, "--zero=")) {
                errWrite("zdirname: option '--zero' doesn't allow an argument\n");
                tryHelpAndExit();
            } else {
                errWrite("zdirname: unrecognized option '");
                errWrite(arg);
                errWrite("'\n");
                tryHelpAndExit();
            }
        } else {
            // Short option cluster; -z is the only valid short option.
            for (arg[1..]) |ch| {
                if (ch == 'z') {
                    zero_terminated = true;
                } else {
                    errWrite("zdirname: invalid option -- '");
                    errWrite(&[_]u8{ch});
                    errWrite("'\n");
                    tryHelpAndExit();
                }
            }
        }
    }

    // Second pass: emit dirname for each operand, in order.
    no_more_opts = false;
    i = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!no_more_opts and arg.len >= 1 and arg[0] == '-' and arg.len >= 2) {
            if (std.mem.eql(u8, arg, "--")) {
                no_more_opts = true;
                continue;
            }
            // Any other dash-led token was validated as an option above.
            continue;
        }
        had_paths = true;
        const dir = dirname(arg);
        out.write(dir);
        out.writeByte(if (zero_terminated) 0 else '\n');
    }

    if (!had_paths) {
        errWrite("zdirname: missing operand\n");
        tryHelpAndExit();
    }

    out.flush();
    if (write_failed) std.process.exit(1);
}
