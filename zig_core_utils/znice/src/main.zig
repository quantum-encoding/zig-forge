const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn getpriority(which: c_int, who: c_uint) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeOut(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn errnoPtr() *c_int {
    return libc._errno();
}

fn cstr(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

const AdjError = error{Invalid};

// Parse a niceness adjustment the way GNU coreutils `nice` does (via xstrtol,
// base 10): optional leading ASCII blanks, an optional sign, then one or more
// decimal digits, and NOTHING after the digits. Trailing garbage or trailing
// whitespace is rejected. Integer overflow is not an error: GNU clamps to the
// extreme value and lets the kernel clamp the resulting niceness. Anchored to
// observed GNU 9.10 behavior:
//   "+5" -> 5, " 5" -> 5, "-0" -> 0, "99999999999" -> i64 max (clamped later);
//   "5x", "0x5", "5 ", "  ", "" -> invalid.
fn parseAdjustment(s: []const u8) AdjError!i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0b and c != 0x0c) break;
    }
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (i >= s.len) return error.Invalid; // no digits
    var val: i64 = 0;
    var overflow = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return error.Invalid; // trailing garbage
        if (!overflow) {
            const d: i64 = @intCast(c - '0');
            const m = std.math.mul(i64, val, 10) catch {
                overflow = true;
                continue;
            };
            const a = std.math.add(i64, m, d) catch {
                overflow = true;
                continue;
            };
            val = a;
        }
    }
    if (overflow) return if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    return if (neg) -val else val;
}

fn invalidAdjustment(val: []const u8) noreturn {
    writeErr("znice: invalid adjustment '");
    writeErr(val);
    writeErr("'\n");
    std.process.exit(125);
}

fn saturateToCInt(v: i64) c_int {
    if (v > std.math.maxInt(c_int)) return std.math.maxInt(c_int);
    if (v < std.math.minInt(c_int)) return std.math.minInt(c_int);
    return @intCast(v);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var adjustment: i64 = 10; // Default adjustment (GNU default increment is 10)
    var adjustment_seen = false; // whether an explicit adjustment flag was given
    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);
    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: znice [OPTION] [COMMAND [ARG]...]
                    \\Run COMMAND with an adjusted niceness, which affects process scheduling.
                    \\With no COMMAND, print the current niceness.  Niceness values range from
                    \\-20 (most favorable to the process) to 19 (least favorable to the process).
                    \\
                    \\  -n, --adjustment=N   add integer N to the niceness (default 10)
                    \\      --help           display this help and exit
                    \\      --version        output version information and exit
                    \\
                ;
                writeOut(help);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeOut("znice (zig_core_utils) 1.0\n");
                return;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else if (std.mem.eql(u8, arg, "-n")) {
                // GNU: `-n` with no operand -> "option requires an argument".
                const val = args.next() orelse {
                    writeErr("znice: option requires an argument -- 'n'\n");
                    writeErr("Try 'znice --help' for more information.\n");
                    std.process.exit(125);
                };
                adjustment = parseAdjustment(val) catch invalidAdjustment(val);
                adjustment_seen = true;
            } else if (std.mem.startsWith(u8, arg, "-n")) {
                adjustment = parseAdjustment(arg[2..]) catch invalidAdjustment(arg[2..]);
                adjustment_seen = true;
            } else if (std.mem.startsWith(u8, arg, "--adjustment=")) {
                const val = arg[13..];
                adjustment = parseAdjustment(val) catch invalidAdjustment(val);
                adjustment_seen = true;
            } else if (arg.len >= 2 and arg[0] == '-' and isObsoleteAdjustment(arg)) {
                // Obsolete GNU syntax: `-NUM` == `-n NUM`. So `-5` -> +5,
                // `--5` -> -5, `-+5` -> +5 (the sign lives inside arg[1..]).
                adjustment = parseAdjustment(arg[1..]) catch invalidAdjustment(arg[1..]);
                adjustment_seen = true;
            } else if (arg.len >= 2 and arg[0] == '-') {
                // Unknown option.
                writeErr("znice: invalid option -- '");
                writeErr(arg[1..]);
                writeErr("'\n");
                writeErr("Try 'znice --help' for more information.\n");
                std.process.exit(125);
            } else {
                try cmd_args.append(allocator, arg);
                parsing_opts = false;
            }
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    const PRIO_PROCESS: c_int = 0;

    // No command.
    if (cmd_args.items.len == 0) {
        if (adjustment_seen) {
            // GNU: an adjustment was given but no command to run it on.
            writeErr("znice: a command must be given with an adjustment\n");
            writeErr("Try 'znice --help' for more information.\n");
            std.process.exit(125);
        }
        // Just print the current niceness.
        errnoPtr().* = 0;
        const nice_val = getpriority(PRIO_PROCESS, 0);
        if (nice_val == -1 and errnoPtr().* != 0) {
            writeErr("znice: cannot get niceness: ");
            writeErr(cstr(strerror(errnoPtr().*)));
            writeErr("\n");
            std.process.exit(125);
        }
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{nice_val}) catch return;
        writeOut(s);
        return;
    }

    // Get current niceness and apply adjustment. Do the arithmetic in i64 so a
    // huge/overflowing adjustment can't wrap; let the kernel clamp the final
    // niceness to its supported range (matching GNU, which does not clamp in
    // userspace).
    errnoPtr().* = 0;
    const current_nice: i64 = getpriority(PRIO_PROCESS, 0);
    var new_nice: i64 = current_nice +| adjustment;
    if (new_nice > std.math.maxInt(c_int)) new_nice = std.math.maxInt(c_int);
    if (new_nice < std.math.minInt(c_int)) new_nice = std.math.minInt(c_int);

    // setpriority(PRIO_PROCESS, pid=0 (self), niceval). GNU warns (to stderr)
    // when it cannot set the niceness (e.g. raising priority without privilege)
    // but still execs the command.
    errnoPtr().* = 0;
    if (setpriority(PRIO_PROCESS, 0, saturateToCInt(new_nice)) != 0) {
        const e = errnoPtr().*;
        writeErr("znice: cannot set niceness: ");
        writeErr(cstr(strerror(e)));
        writeErr("\n");
    }

    // Build argv for exec.
    var argv_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv_buf.deinit(allocator);

    for (cmd_args.items) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);
    const cmd_z = try allocator.dupeZ(u8, cmd_args.items[0]);

    _ = execvp(cmd_z.ptr, argv);

    // exec failed
    writeErr("znice: '");
    writeErr(cmd_args.items[0]);
    writeErr("': ");

    // Reuse the NUL-terminated command copy for lstat — never copy into a
    // fixed stack buffer (that overflowed for command names >= 4096 bytes).
    var stat_buf: [256]u8 align(8) = undefined;
    const rc = lstat(cmd_z.ptr, &stat_buf);
    if (rc != 0) {
        writeErr("No such file or directory\n");
        std.process.exit(127);
    } else {
        writeErr("Permission denied\n");
        std.process.exit(126);
    }
}

// True when `arg` matches the obsolete `-NUM` adjustment form:
//   '-' <optional '+'|'-'> <digit> ...
// i.e. arg[1] is a digit, or arg[1] is a sign and arg[2] is a digit.
fn isObsoleteAdjustment(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    const c1 = arg[1];
    if (c1 >= '0' and c1 <= '9') return true;
    if ((c1 == '+' or c1 == '-') and arg.len >= 3) {
        const c2 = arg[2];
        return c2 >= '0' and c2 <= '9';
    }
    return false;
}
