//! ztest - Check file types and compare values
//!
//! High-performance test/[ implementation in Zig.
//! Exit 0 if expression is true, 1 if false, 2 on error.
//!
//! Behaviour is anchored to GNU coreutils `test` (9.10). Notably the POSIX
//! argument-count special cases (1/2/3/4 operands) are implemented before the
//! general recursive-descent grammar, matching GNU: e.g. `test ! = !` is the
//! string comparison `! = !` (true), `test -f = -f` is `-f = -f` (true), and a
//! lone `test !` is a non-empty-string test (true). `--help` / `--version` are
//! NOT special options — GNU `test` treats them as ordinary string operands
//! (verified: `gtest --help` exits 0 and prints nothing), so ztest does too.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn geteuid() u32;
extern "c" fn getegid() u32;

// Target-correct `struct stat` layout. A single hand-rolled struct is wrong on
// every target but the one it was transcribed from — this is the bug the
// zig_base58 / audit line-item flagged (Linux-x86_64 layout read on macOS
// arm64 lands st_mode/st_size/st_mtime on the wrong bytes). Mirror the layout
// per-target exactly as the promoted sibling util `zstat` does.
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
        pub fn mtime(self: @This()) libc.timespec {
            return self.mtim;
        }
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
        pub fn mtime(self: @This()) libc.timespec {
            return self.mtim;
        }
    },
    else => libc.Stat,
};

// File mode bits
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;
const S_IFBLK: u32 = 0o060000;
const S_IFCHR: u32 = 0o020000;
const S_IFIFO: u32 = 0o010000;
const S_IFSOCK: u32 = 0o140000;
const S_ISUID: u32 = 0o4000;
const S_ISGID: u32 = 0o2000;
const S_ISVTX: u32 = 0o1000;

const R_OK: c_int = 4;
const W_OK: c_int = 2;
const X_OK: c_int = 1;

// mode is u16 on the BSD/macOS layout, u32 on Linux. Widen uniformly before
// masking so the constants above line up regardless of target.
fn modeBits(st: Stat) u32 {
    return @as(u32, st.mode);
}

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn syntaxError() noreturn {
    writeStderr("ztest: syntax error\n", .{});
    std.process.exit(2);
}

fn getStat(path: []const u8) ?Stat {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    var st: Stat = undefined;
    if (stat(path_z, &st) == 0) return st;
    return null;
}

fn getLstat(path: []const u8) ?Stat {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    var st: Stat = undefined;
    if (lstat(path_z, &st) == 0) return st;
    return null;
}

fn checkAccess(path: []const u8, mode: c_int) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    return access(path_z, mode) == 0;
}

fn isUnaryOp(s: []const u8) bool {
    const ops = [_][]const u8{
        "-e", "-f", "-d", "-r", "-w", "-x", "-s", "-L", "-h",
        "-b", "-c", "-p", "-S", "-u", "-g", "-k", "-t", "-z", "-n",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, s, op)) return true;
    }
    return false;
}

fn isBinaryOp(s: []const u8) bool {
    const ops = [_][]const u8{
        "=", "==", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, s, op)) return true;
    }
    return false;
}

fn evaluateUnary(op: []const u8, arg: []const u8) bool {
    if (std.mem.eql(u8, op, "-e")) {
        return getStat(arg) != null;
    } else if (std.mem.eql(u8, op, "-f")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFREG;
    } else if (std.mem.eql(u8, op, "-d")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFDIR;
    } else if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
        const st = getLstat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFLNK;
    } else if (std.mem.eql(u8, op, "-b")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFBLK;
    } else if (std.mem.eql(u8, op, "-c")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFCHR;
    } else if (std.mem.eql(u8, op, "-p")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFIFO;
    } else if (std.mem.eql(u8, op, "-S")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_IFMT) == S_IFSOCK;
    } else if (std.mem.eql(u8, op, "-r")) {
        return checkAccess(arg, R_OK);
    } else if (std.mem.eql(u8, op, "-w")) {
        return checkAccess(arg, W_OK);
    } else if (std.mem.eql(u8, op, "-x")) {
        return checkAccess(arg, X_OK);
    } else if (std.mem.eql(u8, op, "-s")) {
        const st = getStat(arg) orelse return false;
        return st.size > 0;
    } else if (std.mem.eql(u8, op, "-u")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_ISUID) != 0;
    } else if (std.mem.eql(u8, op, "-g")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_ISGID) != 0;
    } else if (std.mem.eql(u8, op, "-k")) {
        const st = getStat(arg) orelse return false;
        return (modeBits(st) & S_ISVTX) != 0;
    } else if (std.mem.eql(u8, op, "-t")) {
        const fd_num = std.fmt.parseInt(c_int, arg, 10) catch return false;
        return libc.isatty(fd_num) != 0;
    } else if (std.mem.eql(u8, op, "-z")) {
        return arg.len == 0;
    } else if (std.mem.eql(u8, op, "-n")) {
        return arg.len > 0;
    }
    return false;
}

// GNU test emits "invalid integer 'X'" to stderr and exits 2 (not a silent
// false) when an operand to -eq/-ne/-lt/-le/-gt/-ge is not a valid integer.
fn parseIntOrExit(s: []const u8) i64 {
    return std.fmt.parseInt(i64, s, 10) catch {
        writeStderr("ztest: invalid integer '{s}'\n", .{s});
        std.process.exit(2);
    };
}

// Compare two timespecs (seconds then nanoseconds). GNU `-nt`/`-ot` use full
// sub-second precision, so two files written <1s apart still order correctly.
fn mtimeCmp(a: Stat, b: Stat) i8 {
    const ta = a.mtime();
    const tb = b.mtime();
    if (ta.sec != tb.sec) return if (ta.sec < tb.sec) -1 else 1;
    if (ta.nsec != tb.nsec) return if (ta.nsec < tb.nsec) -1 else 1;
    return 0;
}

fn evaluateBinary(left: []const u8, op: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
        return std.mem.eql(u8, left, right);
    } else if (std.mem.eql(u8, op, "!=")) {
        return !std.mem.eql(u8, left, right);
    } else if (std.mem.eql(u8, op, "-eq")) {
        return parseIntOrExit(left) == parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-ne")) {
        return parseIntOrExit(left) != parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-lt")) {
        return parseIntOrExit(left) < parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-le")) {
        return parseIntOrExit(left) <= parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-gt")) {
        return parseIntOrExit(left) > parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-ge")) {
        return parseIntOrExit(left) >= parseIntOrExit(right);
    } else if (std.mem.eql(u8, op, "-nt")) {
        const st1 = getStat(left) orelse return false;
        const st2 = getStat(right) orelse return true;
        return mtimeCmp(st1, st2) > 0;
    } else if (std.mem.eql(u8, op, "-ot")) {
        const st1 = getStat(left) orelse return true;
        const st2 = getStat(right) orelse return false;
        return mtimeCmp(st1, st2) < 0;
    } else if (std.mem.eql(u8, op, "-ef")) {
        const st1 = getStat(left) orelse return false;
        const st2 = getStat(right) orelse return false;
        return st1.dev == st2.dev and st1.ino == st2.ino;
    }
    return false;
}

// Recursive descent parser for the general test grammar (used once the POSIX
// 1/2/3/4-argument special cases below don't apply).
// Grammar:
//   expr     := or_expr
//   or_expr  := and_expr ('-o' and_expr)*
//   and_expr := not_expr ('-a' not_expr)*
//   not_expr := '!' not_expr | primary
//   primary  := '(' expr ')' | unary_op ARG | ARG binary_op ARG | ARG
const Parser = struct {
    args: []const []const u8,
    pos: usize,

    fn init(args_slice: []const []const u8) Parser {
        return .{ .args = args_slice, .pos = 0 };
    }

    fn peek(self: *Parser) ?[]const u8 {
        if (self.pos < self.args.len) return self.args[self.pos];
        return null;
    }

    fn advance(self: *Parser) []const u8 {
        const arg = self.args[self.pos];
        self.pos += 1;
        return arg;
    }

    fn remaining(self: *Parser) usize {
        return self.args.len - self.pos;
    }

    fn parseExpr(self: *Parser) ?bool {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ?bool {
        var result = self.parseAnd() orelse return null;
        while (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, "-o")) {
                _ = self.advance(); // consume -o
                const right = self.parseAnd() orelse return null;
                result = result or right;
            } else break;
        }
        return result;
    }

    fn parseAnd(self: *Parser) ?bool {
        var result = self.parseNot() orelse return null;
        while (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, "-a")) {
                _ = self.advance(); // consume -a
                const right = self.parseNot() orelse return null;
                result = result and right;
            } else break;
        }
        return result;
    }

    fn parseNot(self: *Parser) ?bool {
        const tok = self.peek() orelse return null;
        if (std.mem.eql(u8, tok, "!")) {
            _ = self.advance(); // consume !
            const inner = self.parseNot() orelse return null;
            return !inner;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ?bool {
        const tok = self.peek() orelse return null;

        // Parenthesized expression
        if (std.mem.eql(u8, tok, "(")) {
            _ = self.advance(); // consume (
            const result = self.parseExpr() orelse return null;
            // Expect closing )
            const close = self.peek() orelse return null;
            if (!std.mem.eql(u8, close, ")")) return null;
            _ = self.advance(); // consume )
            return result;
        }

        // Look ahead for binary operator (takes precedence over a leading
        // unary token, matching GNU: `X = Y` is a comparison even if X looks
        // like an operator).
        if (self.remaining() >= 3) {
            const next = self.args[self.pos + 1];
            if (isBinaryOp(next)) {
                const left = self.advance();
                const op = self.advance();
                const right = self.advance();
                return evaluateBinary(left, op, right);
            }
        }

        // Unary operator
        if (isUnaryOp(tok) and self.remaining() >= 2) {
            const op = self.advance();
            const arg = self.advance();
            return evaluateUnary(op, arg);
        }

        // Single string: true if non-empty
        const arg = self.advance();
        return arg.len > 0;
    }
};

// ---- POSIX argument-count special cases (mirrors GNU test.c) ----

fn oneArgument(a: []const u8) bool {
    // A single operand is true iff it is a non-empty string.
    return a.len > 0;
}

fn twoArguments(args: []const []const u8) bool {
    // args.len == 2
    if (std.mem.eql(u8, args[0], "!")) {
        return !oneArgument(args[1]);
    }
    if (isUnaryOp(args[0])) {
        return evaluateUnary(args[0], args[1]);
    }
    syntaxError();
}

// Returns the boolean result, or null to signal "defer to the general parser"
// (the -a/-o case), matching GNU three_arguments().
fn threeArguments(args: []const []const u8) ?bool {
    // args.len == 3
    if (isBinaryOp(args[1])) {
        return evaluateBinary(args[0], args[1], args[2]);
    }
    if (std.mem.eql(u8, args[0], "!")) {
        return !twoArguments(args[1..3]);
    }
    if (std.mem.eql(u8, args[0], "(") and std.mem.eql(u8, args[2], ")")) {
        return oneArgument(args[1]);
    }
    if (std.mem.eql(u8, args[1], "-a") or std.mem.eql(u8, args[1], "-o")) {
        return null; // defer to general grammar
    }
    syntaxError();
}

fn evalGeneral(args: []const []const u8) bool {
    var parser = Parser.init(args);
    const result = parser.parseExpr() orelse syntaxError();
    if (parser.pos != args.len) syntaxError();
    return result;
}

fn evaluate(args: []const []const u8) bool {
    return switch (args.len) {
        0 => false,
        1 => oneArgument(args[0]),
        2 => twoArguments(args),
        3 => threeArguments(args) orelse evalGeneral(args),
        4 => blk: {
            if (std.mem.eql(u8, args[0], "!")) {
                break :blk !(threeArguments(args[1..4]) orelse evalGeneral(args[1..4]));
            }
            break :blk evalGeneral(args);
        },
        else => evalGeneral(args),
    };
}

pub fn main(init: std.process.Init) void {
    // GNU test imposes no argument-count limit; collect into a growable list
    // rather than a fixed stack array that would silently truncate the tail.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena_state.allocator();

    var args_list: std.ArrayList([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(alloc, arg) catch std.process.exit(2);
    }
    const args = args_list.items;

    if (args.len < 1) {
        std.process.exit(1);
    }

    // Strip program name; handle the `[ EXPRESSION ]` invocation form.
    var end: usize = args.len;
    const prog = args[0];
    const is_bracket = std.mem.endsWith(u8, prog, "[");
    if (is_bracket) {
        if (end > 1 and std.mem.eql(u8, args[end - 1], "]")) {
            end -= 1;
        } else {
            // `[` without a closing `]` is a syntax error in GNU.
            writeStderr("ztest: missing ']'\n", .{});
            std.process.exit(2);
        }
    }

    const expr_args = args[1..end];

    // Note: unlike most GNU utilities, `test` does NOT treat `--help` /
    // `--version` as options — they are ordinary string operands. Verified
    // against coreutils 9.10: `gtest --help` and `gtest --version` both exit 0
    // and print nothing (a 1-argument non-empty-string test). So there is no
    // special-casing here; they flow through evaluate() like any other string.

    const result = evaluate(expr_args);
    std.process.exit(if (result) 0 else 1);
}
