//! ztruncate - Shrink or extend the size of files.
//!
//! A Zig implementation of GNU coreutils `truncate`:
//!   ztruncate OPTION... FILE...
//!
//! Faithful to truncate(1) semantics (anchored against GNU coreutils 9.10,
//! see src/gnu_parity_test.zig):
//!   - a nonexistent FILE is created by default (O_CREAT, mode 0666 &
//!     ~umask); `-c`/`--no-create` opts out and silently skips a missing
//!     FILE (exit 0);
//!   - `-s SIZE` sets the size; SIZE may carry a leading operator
//!     (`+` extend, `-` reduce, `<` at-most, `>` at-least, `/` round down
//!     to a multiple, `%` round up to a multiple) and a human suffix
//!     (K/KB/KiB … through Y), binary for the bare letter / `iB`, decimal
//!     for the trailing `B`;
//!   - `-r RFILE`/`--reference` bases the size on RFILE's size; combined
//!     with a relative `-s` the operator is applied to RFILE's size;
//!   - integer overflow in the size arithmetic is reported, never a panic;
//!   - every failed FILE reports a diagnostic and exit status 1, but the
//!     remaining FILEs are still processed.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "2.0.0";

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32 = 0,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        birthtim: libc.timespec,
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
    else => libc.Stat,
};

extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;

fn errno() i32 {
    return libc._errno().*;
}

// ---------------------------------------------------------------------------
// Size specification parsing
// ---------------------------------------------------------------------------

const Op = enum { set, extend, reduce, at_most, at_least, round_down, round_up };

const Parsed = struct { op: Op, value: i64 };

const ParseError = error{ Invalid, Overflow, DivZero };

/// Parse a GNU truncate SIZE spec: [+-<>/%] NUMBER [suffix].
/// NUMBER is decimal only (no hex, no fractions); leading blanks are
/// tolerated (GNU trims them). The suffix scales NUMBER by 1024^n for the
/// bare letter or an `iB` tail, 1000^n for a trailing `B`.
fn parseSize(spec: []const u8) ParseError!Parsed {
    if (spec.len == 0) return error.Invalid;

    var op: Op = .set;
    var i: usize = 0;
    switch (spec[0]) {
        '+' => {
            op = .extend;
            i = 1;
        },
        '-' => {
            op = .reduce;
            i = 1;
        },
        '<' => {
            op = .at_most;
            i = 1;
        },
        '>' => {
            op = .at_least;
            i = 1;
        },
        '/' => {
            op = .round_down;
            i = 1;
        },
        '%' => {
            op = .round_up;
            i = 1;
        },
        else => {},
    }

    // GNU tolerates leading blanks in the numeric field (e.g. "-s ' 5'").
    while (i < spec.len and (spec[i] == ' ' or spec[i] == '\t')) i += 1;

    const num_start = i;
    while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') i += 1;
    if (i == num_start) return error.Invalid; // no digits

    const number = std.fmt.parseInt(i64, spec[num_start..i], 10) catch return error.Overflow;

    const multiplier = try parseSuffix(spec[i..]);
    const value = std.math.mul(i64, number, multiplier) catch return error.Overflow;

    if ((op == .round_down or op == .round_up) and value == 0) return error.DivZero;

    return .{ .op = op, .value = value };
}

/// Return the byte multiplier for a GNU size suffix, or error.Invalid for
/// unknown/trailing garbage, error.Overflow if it cannot fit in i64.
fn parseSuffix(suffix: []const u8) ParseError!i64 {
    if (suffix.len == 0) return 1;

    const exp: u6 = switch (suffix[0]) {
        'K', 'k' => 1,
        'M', 'm' => 2,
        'G', 'g' => 3,
        'T', 't' => 4,
        'P', 'p' => 5,
        'E', 'e' => 6,
        'Z', 'z' => 7,
        'Y', 'y' => 8,
        else => return error.Invalid,
    };

    // After the letter: "" or "i"/"iB" (binary), or "B" (decimal).
    const tail = suffix[1..];
    var base: i64 = 1024;
    if (tail.len == 0) {
        base = 1024;
    } else if (std.mem.eql(u8, tail, "B")) {
        base = 1000;
    } else if (std.mem.eql(u8, tail, "i") or std.mem.eql(u8, tail, "iB")) {
        base = 1024;
    } else {
        return error.Invalid;
    }

    var mult: i64 = 1;
    var n: u6 = 0;
    while (n < exp) : (n += 1) {
        mult = std.math.mul(i64, mult, base) catch return error.Overflow;
    }
    return mult;
}

/// Apply the operator to `base` (the reference or current file size),
/// returning the target size or error.Overflow.
fn applySize(op: Op, value: i64, base: i64) error{Overflow}!i64 {
    return switch (op) {
        .set => value,
        .extend => try std.math.add(i64, base, value),
        .reduce => if (base > value) base - value else 0,
        .at_most => @min(base, value),
        .at_least => @max(base, value),
        .round_down => @divTrunc(base, value) * value,
        .round_up => blk: {
            const rem = @rem(base, value);
            if (rem == 0) break :blk base;
            const q = try std.math.add(i64, @divTrunc(base, value), 1);
            break :blk try std.math.mul(i64, q, value);
        },
    };
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = libc.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (errno() == @intFromEnum(libc.E.INTR)) continue;
            return;
        }
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

fn writeFmt(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096 + 256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        writeAll(fd, "ztruncate: (diagnostic too long to display)\n");
        return;
    };
    writeAll(fd, msg);
}

fn errFile(msg: []const u8, path: []const u8) void {
    writeFmt(libc.STDERR_FILENO, "ztruncate: {s} '{s}'\n", .{ msg, path });
}

// ---------------------------------------------------------------------------
// File operations
// ---------------------------------------------------------------------------

fn statSize(path_z: [*:0]const u8) ?i64 {
    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var st: Stat = undefined;
    if (fstat(fd, &st) != 0) return null;
    return st.size;
}

const Plan = struct {
    op: Op,
    value: i64,
    /// When set, all ops are based on this size instead of each FILE's own.
    ref_size: ?i64,
    no_create: bool,
};

fn nullTerm(buf: []u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Truncate one FILE according to `plan`. Returns true on success (which
/// includes the `-c` "file absent, nothing to do" case).
fn truncateFile(path: []const u8, plan: Plan) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = nullTerm(&path_buf, path) orelse {
        errFile("cannot open", path);
        return false;
    };

    // Open the FILE, creating it (mode 0666 & ~umask) unless -c was given.
    // A single fd is used for both the size query and the truncate, so no
    // second path lookup can be raced in between (TOCTOU-free).
    const open_flags: libc.O = if (plan.no_create)
        .{ .ACCMODE = .WRONLY }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true };
    const fd = libc.open(path_z, open_flags, @as(libc.mode_t, 0o666));
    if (fd < 0) {
        // GNU: with -c, a missing FILE is silently skipped (exit 0).
        if (plan.no_create and errno() == @intFromEnum(libc.E.NOENT)) return true;
        errFile("cannot open", path);
        return false;
    }
    defer _ = libc.close(fd);

    // Base for relative ops: the reference size, else this FILE's own size.
    var base: i64 = 0;
    if (plan.op != .set) {
        if (plan.ref_size) |rs| {
            base = rs;
        } else {
            var st: Stat = undefined;
            if (fstat(fd, &st) != 0) {
                errFile("cannot fstat", path);
                return false;
            }
            base = st.size;
        }
    }

    const final_size = applySize(plan.op, plan.value, base) catch {
        errFile("overflow rounding up size of file", path);
        return false;
    };

    if (ftruncate(fd, final_size) != 0) {
        errFile("cannot truncate", path);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const usage_text =
    \\Usage: ztruncate OPTION... FILE...
    \\Shrink or extend the size of each FILE to the specified size.
    \\
    \\A FILE argument that does not exist is created.
    \\
    \\  -c, --no-create        do not create any files
    \\  -o, --io-blocks        (unsupported)
    \\  -r, --reference=RFILE  base size on RFILE
    \\  -s, --size=SIZE        set or adjust the file size by SIZE bytes
    \\      --help             display this help and exit
    \\      --version          output version information and exit
    \\
    \\SIZE may be prefixed with an operator: '+' extend, '-' reduce,
    \\'<' at most, '>' at least, '/' round down to a multiple, '%' round up.
    \\SIZE may carry a suffix: K/M/G/T/P/E (1024^n), or KB/MB/... (1000^n).
    \\
;

fn tryHelpAndExit() noreturn {
    writeAll(libc.STDERR_FILENO, "Try 'ztruncate --help' for more information.\n");
    std.process.exit(1);
}

fn sizeErrorAndExit(err: ParseError, spec: []const u8) noreturn {
    switch (err) {
        error.DivZero => writeAll(libc.STDERR_FILENO, "ztruncate: division by zero\n"),
        else => writeFmt(libc.STDERR_FILENO, "ztruncate: Invalid number: '{s}'\n", .{spec}),
    }
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    var size_spec: ?[]const u8 = null;
    var ref_path: ?[]const u8 = null;
    var no_create = false;
    var seen_dashdash = false;

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!seen_dashdash and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            if (arg.len == 2) {
                seen_dashdash = true;
                continue;
            }
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            if (std.mem.eql(u8, name, "help")) {
                writeAll(libc.STDOUT_FILENO, usage_text);
                return;
            } else if (std.mem.eql(u8, name, "version")) {
                writeFmt(libc.STDOUT_FILENO, "ztruncate {s}\n", .{VERSION});
                return;
            } else if (std.mem.eql(u8, name, "no-create")) {
                no_create = true;
            } else if (std.mem.eql(u8, name, "io-blocks")) {
                writeAll(libc.STDERR_FILENO, "ztruncate: --io-blocks is not supported\n");
                std.process.exit(1);
            } else if (std.mem.eql(u8, name, "size")) {
                size_spec = attached orelse blk: {
                    i += 1;
                    if (i >= args.len) {
                        writeAll(libc.STDERR_FILENO, "ztruncate: option '--size' requires an argument\n");
                        tryHelpAndExit();
                    }
                    break :blk args[i];
                };
            } else if (std.mem.eql(u8, name, "reference")) {
                ref_path = attached orelse blk: {
                    i += 1;
                    if (i >= args.len) {
                        writeAll(libc.STDERR_FILENO, "ztruncate: option '--reference' requires an argument\n");
                        tryHelpAndExit();
                    }
                    break :blk args[i];
                };
            } else {
                writeFmt(libc.STDERR_FILENO, "ztruncate: unrecognized option '{s}'\n", .{arg});
                tryHelpAndExit();
            }
        } else if (!seen_dashdash and arg.len >= 2 and arg[0] == '-') {
            var j: usize = 1;
            cluster: while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'c' => no_create = true,
                    'o' => {
                        writeAll(libc.STDERR_FILENO, "ztruncate: -o/--io-blocks is not supported\n");
                        std.process.exit(1);
                    },
                    's' => {
                        // The value may itself begin with '-' (e.g. "-s -2"),
                        // so an attached remainder or the whole next arg is
                        // consumed verbatim.
                        if (j + 1 < arg.len) {
                            size_spec = arg[j + 1 ..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            size_spec = args[i];
                        } else {
                            writeAll(libc.STDERR_FILENO, "ztruncate: option requires an argument -- 's'\n");
                            tryHelpAndExit();
                        }
                        break :cluster;
                    },
                    'r' => {
                        if (j + 1 < arg.len) {
                            ref_path = arg[j + 1 ..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            ref_path = args[i];
                        } else {
                            writeAll(libc.STDERR_FILENO, "ztruncate: option requires an argument -- 'r'\n");
                            tryHelpAndExit();
                        }
                        break :cluster;
                    },
                    else => {
                        writeFmt(libc.STDERR_FILENO, "ztruncate: invalid option -- '{c}'\n", .{arg[j]});
                        tryHelpAndExit();
                    },
                }
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    if (size_spec == null and ref_path == null) {
        writeAll(libc.STDERR_FILENO, "ztruncate: you must specify either '--size' or '--reference'\n");
        tryHelpAndExit();
    }

    if (files.items.len == 0) {
        writeAll(libc.STDERR_FILENO, "ztruncate: missing file operand\n");
        tryHelpAndExit();
    }

    // Resolve the reference size once, if any.
    var ref_size: ?i64 = null;
    if (ref_path) |rp| {
        var rp_buf: [4096]u8 = undefined;
        const rp_z = nullTerm(&rp_buf, rp) orelse {
            errFile("cannot open for reading", rp);
            std.process.exit(1);
        };
        ref_size = statSize(rp_z) orelse {
            errFile("cannot open for reading", rp);
            std.process.exit(1);
        };
    }

    // Build the truncate plan.
    var plan: Plan = .{ .op = .set, .value = 0, .ref_size = null, .no_create = no_create };

    if (size_spec) |spec| {
        const parsed = parseSize(spec) catch |e| sizeErrorAndExit(e, spec);
        plan.op = parsed.op;
        plan.value = parsed.value;
        if (ref_path != null) {
            if (parsed.op == .set) {
                writeAll(libc.STDERR_FILENO, "ztruncate: you must specify a relative '--size' with '--reference'\n");
                tryHelpAndExit();
            }
            plan.ref_size = ref_size; // relative op applied to RFILE's size
        }
    } else {
        // -r only: set each FILE to RFILE's size exactly.
        plan.op = .set;
        plan.value = ref_size.?;
    }

    var had_error = false;
    for (files.items) |path| {
        if (!truncateFile(path, plan)) had_error = true;
    }

    if (had_error) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Unit tests for the pure size logic (externally anchored by the byte values
// GNU coreutils 9.10 produced for these exact inputs; see gnu_parity_test.zig
// for the live-diff suite).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseSize: plain and suffixed absolute values" {
    try testing.expectEqual(@as(i64, 10), (try parseSize("10")).value);
    try testing.expectEqual(@as(i64, 1024), (try parseSize("1K")).value); // GNU: 1K=1024
    try testing.expectEqual(@as(i64, 1000), (try parseSize("1KB")).value); // GNU: 1KB=1000
    try testing.expectEqual(@as(i64, 1024), (try parseSize("1KiB")).value); // GNU: 1KiB=1024
    try testing.expectEqual(@as(i64, 1048576), (try parseSize("1M")).value);
    try testing.expectEqual(@as(i64, 1000000), (try parseSize("1MB")).value);
    try testing.expectEqual(@as(i64, 2147483648), (try parseSize("2G")).value);
    try testing.expectEqual(@as(i64, 1125899906842624), (try parseSize("1P")).value);
    try testing.expectEqual(Op.set, (try parseSize("10")).op);
}

test "parseSize: operators recognized" {
    try testing.expectEqual(Op.extend, (try parseSize("+5")).op);
    try testing.expectEqual(Op.reduce, (try parseSize("-5")).op);
    try testing.expectEqual(Op.at_most, (try parseSize("<4")).op);
    try testing.expectEqual(Op.at_least, (try parseSize(">4")).op);
    try testing.expectEqual(Op.round_down, (try parseSize("/3")).op);
    try testing.expectEqual(Op.round_up, (try parseSize("%4")).op);
}

test "parseSize: GNU rejects trailing garbage / fractions / hex" {
    try testing.expectError(error.Invalid, parseSize("5Kxyz")); // GNU: Invalid number
    try testing.expectError(error.Invalid, parseSize("1.5K")); // GNU: Invalid number
    try testing.expectError(error.Invalid, parseSize("0x10")); // GNU: Invalid number
    try testing.expectError(error.Invalid, parseSize("1b")); // GNU: 'b' not a suffix
    try testing.expectError(error.Invalid, parseSize("abc"));
    try testing.expectError(error.Invalid, parseSize(""));
    try testing.expectError(error.Invalid, parseSize("5 ")); // trailing space
}

test "parseSize: overflow reported, never panics" {
    // GNU: "Invalid number: '9999999999T': Value too large".
    try testing.expectError(error.Overflow, parseSize("9999999999T"));
    try testing.expectError(error.Overflow, parseSize("8E")); // 2^63 > i64 max
    try testing.expectError(error.Overflow, parseSize("1Z")); // 2^70
}

test "parseSize: division by zero for /0 and %0 (GNU: division by zero)" {
    try testing.expectError(error.DivZero, parseSize("/0"));
    try testing.expectError(error.DivZero, parseSize("%0"));
}

test "parseSize: leading blanks tolerated like GNU" {
    try testing.expectEqual(@as(i64, 5), (try parseSize(" 5")).value);
}

test "applySize: operator arithmetic matches GNU-observed results" {
    // Values captured from GNU coreutils 9.10 (see gnu_parity_test.zig).
    try testing.expectEqual(@as(i64, 8), try applySize(.extend, 5, 3)); // +5 on 3 -> 8
    try testing.expectEqual(@as(i64, 8), try applySize(.reduce, 2, 10)); // -2 on 10 -> 8
    try testing.expectEqual(@as(i64, 0), try applySize(.reduce, 100, 3)); // floor at 0
    try testing.expectEqual(@as(i64, 4), try applySize(.at_most, 4, 8)); // <4 on 8 -> 4
    try testing.expectEqual(@as(i64, 3), try applySize(.at_most, 4, 3)); // <4 on 3 -> 3
    try testing.expectEqual(@as(i64, 8), try applySize(.at_least, 4, 8)); // >4 on 8 -> 8
    try testing.expectEqual(@as(i64, 4), try applySize(.at_least, 4, 3)); // >4 on 3 -> 4
    try testing.expectEqual(@as(i64, 9), try applySize(.round_down, 3, 10)); // /3 on 10 -> 9
    try testing.expectEqual(@as(i64, 8), try applySize(.round_down, 4, 8)); // /4 on 8 -> 8
    try testing.expectEqual(@as(i64, 12), try applySize(.round_up, 4, 10)); // %4 on 10 -> 12
    try testing.expectEqual(@as(i64, 8), try applySize(.round_up, 4, 8)); // %4 on 8 -> 8
}

test "applySize: extend overflow reported" {
    try testing.expectError(error.Overflow, applySize(.extend, std.math.maxInt(i64), 3));
}
