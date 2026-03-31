//! ztest - Check file types and compare values
//!
//! High-performance test/[ implementation in Zig.
//! Exit 0 if expression is true, 1 if false, 2 on error.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn geteuid() u32;
extern "c" fn getegid() u32;

const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: i64,
    st_atime_nsec: i64,
    st_mtime: i64,
    st_mtime_nsec: i64,
    st_ctime: i64,
    st_ctime_nsec: i64,
    __unused: [3]i64,
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

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: ztest EXPRESSION
        \\   or: [ EXPRESSION ]
        \\Evaluate conditional expression.
        \\
        \\File tests:
        \\  -e FILE    FILE exists
        \\  -f FILE    FILE is a regular file
        \\  -d FILE    FILE is a directory
        \\  -r FILE    FILE is readable
        \\  -w FILE    FILE is writable
        \\  -x FILE    FILE is executable
        \\  -s FILE    FILE has size > 0
        \\  -L FILE    FILE is a symbolic link
        \\  -b FILE    FILE is block special
        \\  -c FILE    FILE is character special
        \\  -p FILE    FILE is a named pipe
        \\  -S FILE    FILE is a socket
        \\  -u FILE    FILE has set-user-ID bit
        \\  -g FILE    FILE has set-group-ID bit
        \\  -k FILE    FILE has sticky bit
        \\  -t FD      FD is opened on a terminal
        \\
        \\String tests:
        \\  -z STRING  STRING has zero length
        \\  -n STRING  STRING has non-zero length
        \\  S1 = S2    Strings are equal
        \\  S1 != S2   Strings are not equal
        \\
        \\Integer tests:
        \\  N1 -eq N2  N1 equals N2
        \\  N1 -ne N2  N1 not equal N2
        \\  N1 -lt N2  N1 less than N2
        \\  N1 -le N2  N1 less or equal N2
        \\  N1 -gt N2  N1 greater than N2
        \\  N1 -ge N2  N1 greater or equal N2
        \\
        \\Compound:
        \\  EXPR -a EXPR  Both EXPR are true (AND)
        \\  EXPR -o EXPR  Either EXPR is true (OR)
        \\  ! EXPR        EXPR is false
        \\  ( EXPR )      Group expression
        \\
    ;
    writeStderr(usage);
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
        return (st.st_mode & S_IFMT) == S_IFREG;
    } else if (std.mem.eql(u8, op, "-d")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFDIR;
    } else if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
        const st = getLstat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFLNK;
    } else if (std.mem.eql(u8, op, "-b")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFBLK;
    } else if (std.mem.eql(u8, op, "-c")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFCHR;
    } else if (std.mem.eql(u8, op, "-p")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFIFO;
    } else if (std.mem.eql(u8, op, "-S")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_IFMT) == S_IFSOCK;
    } else if (std.mem.eql(u8, op, "-r")) {
        return checkAccess(arg, R_OK);
    } else if (std.mem.eql(u8, op, "-w")) {
        return checkAccess(arg, W_OK);
    } else if (std.mem.eql(u8, op, "-x")) {
        return checkAccess(arg, X_OK);
    } else if (std.mem.eql(u8, op, "-s")) {
        const st = getStat(arg) orelse return false;
        return st.st_size > 0;
    } else if (std.mem.eql(u8, op, "-u")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_ISUID) != 0;
    } else if (std.mem.eql(u8, op, "-g")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_ISGID) != 0;
    } else if (std.mem.eql(u8, op, "-k")) {
        const st = getStat(arg) orelse return false;
        return (st.st_mode & S_ISVTX) != 0;
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

fn evaluateBinary(left: []const u8, op: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
        return std.mem.eql(u8, left, right);
    } else if (std.mem.eql(u8, op, "!=")) {
        return !std.mem.eql(u8, left, right);
    } else if (std.mem.eql(u8, op, "-eq")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l == r;
    } else if (std.mem.eql(u8, op, "-ne")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l != r;
    } else if (std.mem.eql(u8, op, "-lt")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l < r;
    } else if (std.mem.eql(u8, op, "-le")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l <= r;
    } else if (std.mem.eql(u8, op, "-gt")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l > r;
    } else if (std.mem.eql(u8, op, "-ge")) {
        const l = std.fmt.parseInt(i64, left, 10) catch return false;
        const r = std.fmt.parseInt(i64, right, 10) catch return false;
        return l >= r;
    } else if (std.mem.eql(u8, op, "-nt")) {
        const st1 = getStat(left) orelse return false;
        const st2 = getStat(right) orelse return true;
        return st1.st_mtime > st2.st_mtime;
    } else if (std.mem.eql(u8, op, "-ot")) {
        const st1 = getStat(left) orelse return true;
        const st2 = getStat(right) orelse return false;
        return st1.st_mtime < st2.st_mtime;
    } else if (std.mem.eql(u8, op, "-ef")) {
        const st1 = getStat(left) orelse return false;
        const st2 = getStat(right) orelse return false;
        return st1.st_dev == st2.st_dev and st1.st_ino == st2.st_ino;
    }
    return false;
}

// Recursive descent parser for test expressions
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

        // Unary operator
        if (isUnaryOp(tok) and self.remaining() >= 2) {
            const op = self.advance();
            const arg = self.advance();
            return evaluateUnary(op, arg);
        }

        // Look ahead for binary operator
        if (self.remaining() >= 3) {
            const next = self.args[self.pos + 1];
            if (isBinaryOp(next)) {
                const left = self.advance();
                const op = self.advance();
                const right = self.advance();
                return evaluateBinary(left, op, right);
            }
        }

        // Single string: true if non-empty
        const arg = self.advance();
        return arg.len > 0;
    }
};

pub fn main(init: std.process.Init) void {
    var args_arr: [64][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (args_count < args_arr.len) {
            args_arr[args_count] = arg;
            args_count += 1;
        }
    }
    const args = args_arr[0..args_count];

    if (args.len < 2) {
        std.process.exit(1);
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    // Determine effective arguments (strip program name, handle [ ... ])
    var end: usize = args.len;
    const prog = args[0];
    if (std.mem.endsWith(u8, prog, "[") or std.mem.eql(u8, prog, "[")) {
        if (end > 1 and std.mem.eql(u8, args[end - 1], "]")) {
            end -= 1;
        }
    }

    const expr_args = args[1..end];
    if (expr_args.len == 0) {
        std.process.exit(1);
    }

    var parser = Parser.init(expr_args);
    const result = parser.parseExpr() orelse {
        writeStderr("ztest: syntax error\n");
        std.process.exit(2);
    };

    // Check all args were consumed
    if (parser.pos != expr_args.len) {
        writeStderr("ztest: syntax error\n");
        std.process.exit(2);
    }

    std.process.exit(if (result) 0 else 1);
}
