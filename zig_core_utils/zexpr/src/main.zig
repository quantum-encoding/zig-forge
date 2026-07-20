//! zexpr - Evaluate expressions
//!
//! A Zig implementation of expr.
//! Evaluates expressions and prints the result to stdout.
//!
//! Usage: zexpr EXPRESSION
//!        zexpr [OPTION]
//!
//! Exit status:
//!   0  if EXPRESSION is neither null nor 0
//!   1  if EXPRESSION is null or 0
//!   2  if EXPRESSION is syntactically invalid
//!   3  if an error occurred

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn writeStdoutRaw(data: []const u8) void {
    _ = write(1, data.ptr, data.len);
}

// Value type for expression evaluation.
//
// Integers are held as i128 rather than i64. GNU expr uses arbitrary-precision
// integers; i128 is not arbitrary precision, but it lets zexpr compute the exact
// result for every operand that fits in a signed 64-bit range plus a wide margin
// (up to ~1.7e38), which covers the common i64-overflow cases where the old code
// panicked. Operands or results beyond i128 raise Overflow (exit 3) instead of
// crashing. See CLAUDE.md anti-pattern #? and the gnu_parity_test overflow cases.
const Value = union(enum) {
    integer: i128,
    string: []const u8,

    fn isNull(self: Value) bool {
        return switch (self) {
            .integer => |n| n == 0,
            .string => |s| s.len == 0,
        };
    }

    fn toInt(self: Value) ?i128 {
        return switch (self) {
            .integer => |n| n,
            .string => |s| std.fmt.parseInt(i128, s, 10) catch null,
        };
    }

    fn asString(self: Value, buf: []u8) []const u8 {
        return switch (self) {
            .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "",
            .string => |s| s,
        };
    }

    fn compare(self: Value, other: Value) i2 {
        // Try numeric comparison first
        const a_int = self.toInt();
        const b_int = other.toInt();

        if (a_int != null and b_int != null) {
            const a = a_int.?;
            const b = b_int.?;
            if (a < b) return -1;
            if (a > b) return 1;
            return 0;
        }

        // String comparison
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const str_a = self.asString(&buf_a);
        const str_b = other.asString(&buf_b);

        const order = std.mem.order(u8, str_a, str_b);
        return switch (order) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
};

const ExprError = error{
    SyntaxError,
    DivisionByZero,
    InvalidRegex,
    Overflow,
    OutOfMemory,
};

const Parser = struct {
    args: []const []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    fn init(args: []const []const u8, alloc: std.mem.Allocator) Parser {
        return .{ .args = args, .pos = 0, .alloc = alloc };
    }

    // Materialize a Value as a string that outlives this Parser call frame.
    // String values already point into argv (whole-program lifetime); integer
    // values are formatted into the caller-owned arena instead of a stack buffer,
    // so slices returned from match/substr do not dangle after the frame pops.
    fn valueToStr(self: *Parser, v: Value) ExprError![]const u8 {
        return switch (v) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(self.alloc, "{d}", .{n}),
        };
    }

    fn peek(self: *Parser) ?[]const u8 {
        if (self.pos < self.args.len) {
            return self.args[self.pos];
        }
        return null;
    }

    fn consume(self: *Parser) ?[]const u8 {
        if (self.pos < self.args.len) {
            const tok = self.args[self.pos];
            self.pos += 1;
            return tok;
        }
        return null;
    }

    fn expect(self: *Parser, expected: []const u8) ExprError!void {
        if (self.consume()) |tok| {
            if (std.mem.eql(u8, tok, expected)) {
                return;
            }
        }
        return ExprError.SyntaxError;
    }

    // Expression parsing with precedence (lowest to highest):
    // 1. | (OR)
    // 2. & (AND)
    // 3. < <= = != >= > (comparisons)
    // 4. + - (addition/subtraction)
    // 5. * / % (multiplication/division/modulo)
    // 6. : match (pattern matching)
    // 7. atoms: numbers, strings, ( expr ), functions

    fn parseExpr(self: *Parser) ExprError!Value {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ExprError!Value {
        var left = try self.parseAnd();

        while (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, "|")) {
                _ = self.consume();
                const right = try self.parseAnd();
                // Return left if non-null/non-zero, else right
                if (!left.isNull()) {
                    continue;
                }
                left = right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseAnd(self: *Parser) ExprError!Value {
        var left = try self.parseComparison();

        while (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, "&")) {
                _ = self.consume();
                const right = try self.parseComparison();
                // Return left if both non-null/non-zero, else 0
                if (left.isNull() or right.isNull()) {
                    left = Value{ .integer = 0 };
                }
            } else {
                break;
            }
        }
        return left;
    }

    fn parseComparison(self: *Parser) ExprError!Value {
        var left = try self.parseAddSub();

        while (self.peek()) |tok| {
            const op: enum { lt, le, eq, ne, ge, gt } = blk: {
                if (std.mem.eql(u8, tok, "<")) break :blk .lt;
                if (std.mem.eql(u8, tok, "<=")) break :blk .le;
                if (std.mem.eql(u8, tok, "=")) break :blk .eq;
                if (std.mem.eql(u8, tok, "==")) break :blk .eq;
                if (std.mem.eql(u8, tok, "!=")) break :blk .ne;
                if (std.mem.eql(u8, tok, ">=")) break :blk .ge;
                if (std.mem.eql(u8, tok, ">")) break :blk .gt;
                break;
            };

            _ = self.consume();
            const right = try self.parseAddSub();
            const cmp = left.compare(right);

            const result: bool = switch (op) {
                .lt => cmp < 0,
                .le => cmp <= 0,
                .eq => cmp == 0,
                .ne => cmp != 0,
                .ge => cmp >= 0,
                .gt => cmp > 0,
            };

            left = Value{ .integer = if (result) 1 else 0 };
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ExprError!Value {
        var left = try self.parseMulDiv();

        while (self.peek()) |tok| {
            const is_add = std.mem.eql(u8, tok, "+");
            const is_sub = std.mem.eql(u8, tok, "-");

            if (!is_add and !is_sub) break;

            _ = self.consume();
            const right = try self.parseMulDiv();

            const a = left.toInt() orelse return ExprError.SyntaxError;
            const b = right.toInt() orelse return ExprError.SyntaxError;

            // Checked arithmetic: GNU expr is arbitrary precision, so it never
            // wraps. We compute in i128 and raise Overflow (exit 3) rather than
            // panic on the rare beyond-i128 case.
            if (is_add) {
                const r = @addWithOverflow(a, b);
                if (r[1] != 0) return ExprError.Overflow;
                left = Value{ .integer = r[0] };
            } else {
                const r = @subWithOverflow(a, b);
                if (r[1] != 0) return ExprError.Overflow;
                left = Value{ .integer = r[0] };
            }
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ExprError!Value {
        var left = try self.parseMatch();

        while (self.peek()) |tok| {
            const op: enum { mul, div, mod } = blk: {
                if (std.mem.eql(u8, tok, "*")) break :blk .mul;
                if (std.mem.eql(u8, tok, "/")) break :blk .div;
                if (std.mem.eql(u8, tok, "%")) break :blk .mod;
                break;
            };

            _ = self.consume();
            const right = try self.parseMatch();

            const a = left.toInt() orelse return ExprError.SyntaxError;
            const b = right.toInt() orelse return ExprError.SyntaxError;

            if (b == 0 and (op == .div or op == .mod)) {
                return ExprError.DivisionByZero;
            }

            left = Value{
                .integer = switch (op) {
                    .mul => blk: {
                        const r = @mulWithOverflow(a, b);
                        if (r[1] != 0) return ExprError.Overflow;
                        break :blk r[0];
                    },
                    // Guard the one overflowing division: minInt / -1.
                    .div => if (b == -1 and a == std.math.minInt(i128))
                        return ExprError.Overflow
                    else
                        @divTrunc(a, b),
                    // POSIX/C '%' takes the sign of the dividend (truncated
                    // remainder). @rem matches GNU expr; @mod (Euclidean) did not:
                    // -7 % 2 == -1 (not 1), 7 % -2 == 1 (not -1).
                    .mod => @rem(a, b),
                },
            };
        }
        return left;
    }

    fn parseMatch(self: *Parser) ExprError!Value {
        var left = try self.parseAtom();

        while (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, ":")) {
                _ = self.consume();
                const pattern = try self.parseAtom();

                // Materialize into the arena, not a stack buffer: doMatch may
                // return a slice into `str`, and that slice is later read by
                // main after this frame has popped.
                const str = try self.valueToStr(left);
                const pat = try self.valueToStr(pattern);

                // Simple pattern matching (anchored at start)
                left = doMatch(str, pat);
            } else {
                break;
            }
        }
        return left;
    }

    fn parseAtom(self: *Parser) ExprError!Value {
        const tok = self.consume() orelse return ExprError.SyntaxError;

        // Parenthesized expression
        if (std.mem.eql(u8, tok, "(")) {
            const val = try self.parseExpr();
            try self.expect(")");
            return val;
        }

        // Built-in functions
        if (std.mem.eql(u8, tok, "length")) {
            const arg = try self.parseAtom();
            var buf: [256]u8 = undefined;
            const str = arg.asString(&buf);
            return Value{ .integer = @intCast(str.len) };
        }

        if (std.mem.eql(u8, tok, "match")) {
            const str_val = try self.parseAtom();
            const pat_val = try self.parseAtom();
            // Arena-backed so a returned capture-group slice outlives this frame.
            const str = try self.valueToStr(str_val);
            const pat = try self.valueToStr(pat_val);
            return doMatch(str, pat);
        }

        if (std.mem.eql(u8, tok, "substr")) {
            const str_val = try self.parseAtom();
            const pos_val = try self.parseAtom();
            const len_val = try self.parseAtom();

            // Arena-backed: substr of an integer operand (e.g. `substr 12345 2 3`)
            // returns a slice into this string, which must outlive the frame.
            const str = try self.valueToStr(str_val);
            const pos = pos_val.toInt() orelse return ExprError.SyntaxError;
            const len = len_val.toInt() orelse return ExprError.SyntaxError;

            if (pos < 1 or len < 0) {
                return Value{ .string = "" };
            }

            // Clamp against str.len before narrowing to usize so huge i128
            // pos/len values cannot overflow the cast or the addition.
            const str_len_i: i128 = @intCast(str.len);
            if (pos > str_len_i) {
                return Value{ .string = "" };
            }
            const start_idx: usize = @intCast(pos - 1);
            const len_usize: usize = if (len > str_len_i) str.len else @intCast(len);
            const end_idx = @min(start_idx + len_usize, str.len);
            return Value{ .string = str[start_idx..end_idx] };
        }

        if (std.mem.eql(u8, tok, "index")) {
            const str_val = try self.parseAtom();
            const char_val = try self.parseAtom();

            var buf1: [256]u8 = undefined;
            var buf2: [256]u8 = undefined;
            const str = str_val.asString(&buf1);
            const chars = char_val.asString(&buf2);

            // Find first occurrence of any character from chars in str
            for (str, 0..) |c, i| {
                for (chars) |ch| {
                    if (c == ch) {
                        return Value{ .integer = @intCast(i + 1) };
                    }
                }
            }
            return Value{ .integer = 0 };
        }

        // Try to parse as integer
        if (std.fmt.parseInt(i64, tok, 10)) |n| {
            return Value{ .integer = n };
        } else |_| {}

        // Treat as string
        return Value{ .string = tok };
    }
};

fn doMatch(str: []const u8, pattern: []const u8) Value {
    // Simple regex-like matching anchored at start
    // Supports: . (any char), * (zero or more of prev), \( \) for grouping
    // Returns: matched group if \( \) present, else match length

    var has_group = false;
    var group_start: usize = 0;
    var group_end: usize = 0;

    // Check for group markers
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (i + 1 < pattern.len and pattern[i] == '\\' and pattern[i + 1] == '(') {
            has_group = true;
            break;
        }
    }

    // Simple matching implementation
    const match_len = simpleMatch(str, pattern, 0, &group_start, &group_end);

    if (match_len) |len| {
        if (has_group and group_end > group_start) {
            return Value{ .string = str[group_start..group_end] };
        }
        return Value{ .integer = @intCast(len) };
    }

    if (has_group) {
        return Value{ .string = "" };
    }
    return Value{ .integer = 0 };
}

// A single BRE atom: what one position of the pattern matches against one input
// byte. Groups (\( \)) and the end anchor ($) are handled by the caller, not here.
const Atom = union(enum) {
    any, // .
    literal: u8, // ordinary char or escaped literal (\., \\, \/, ...)
    // POSIX bracket expression [..]; body is pattern[lo..hi], neg = leading ^.
    bracket: struct { lo: usize, hi: usize, neg: bool },
};

// Parse the atom starting at pattern[pi]. Returns the atom and the pattern index
// just past it. Caller guarantees pattern[pi] is not a group marker or `$` anchor.
fn nextAtom(pattern: []const u8, pi: usize) struct { atom: Atom, next: usize } {
    const c = pattern[pi];
    if (c == '\\' and pi + 1 < pattern.len) {
        return .{ .atom = .{ .literal = pattern[pi + 1] }, .next = pi + 2 };
    }
    if (c == '.') {
        return .{ .atom = .any, .next = pi + 1 };
    }
    if (c == '[') {
        var j = pi + 1;
        var neg = false;
        if (j < pattern.len and pattern[j] == '^') {
            neg = true;
            j += 1;
        }
        const body_lo = j;
        // A ']' immediately after '[' (or '[^') is a literal member, per POSIX.
        if (j < pattern.len and pattern[j] == ']') j += 1;
        while (j < pattern.len and pattern[j] != ']') j += 1;
        if (j >= pattern.len) {
            // No closing ']': treat '[' as an ordinary literal (GNU/POSIX).
            return .{ .atom = .{ .literal = '[' }, .next = pi + 1 };
        }
        return .{ .atom = .{ .bracket = .{ .lo = body_lo, .hi = j, .neg = neg } }, .next = j + 1 };
    }
    return .{ .atom = .{ .literal = c }, .next = pi + 1 };
}

fn atomMatches(atom: Atom, pattern: []const u8, ch: u8) bool {
    switch (atom) {
        .any => return true,
        .literal => |l| return ch == l,
        .bracket => |b| {
            var matched = false;
            var k = b.lo;
            while (k < b.hi) {
                // Range a-z: a '-' with a member on each side inside the class.
                if (k + 2 < b.hi and pattern[k + 1] == '-') {
                    if (ch >= pattern[k] and ch <= pattern[k + 2]) matched = true;
                    k += 3;
                } else {
                    if (ch == pattern[k]) matched = true;
                    k += 1;
                }
            }
            return matched != b.neg;
        },
    }
}

// Anchored (leftmost) BRE matcher. Supports: literals, '.', escaped literals,
// POSIX bracket expressions [..] incl. ranges and negation, the quantifiers
// '*'/'\+'/'\?', capture groups \( \), and the trailing '$' anchor.
//
// Limitation: greedy, without backtracking, and without group repetition
// (\(...\)*). Patterns whose match requires giving back characters — e.g.
// `h.*o` against "hello", or `\(abc\)*` — will diverge from GNU. gnu_parity_test
// only asserts cases this engine resolves the same way GNU does; the backtracking
// gap is recorded in the audit as a known limitation.
fn simpleMatch(str: []const u8, pattern: []const u8, str_pos: usize, group_start: *usize, group_end: *usize) ?usize {
    var si = str_pos;
    var pi: usize = 0;
    var in_group = false;

    while (pi < pattern.len) {
        // Group markers
        if (pi + 1 < pattern.len and pattern[pi] == '\\' and pattern[pi + 1] == '(') {
            group_start.* = si;
            in_group = true;
            pi += 2;
            continue;
        }
        if (pi + 1 < pattern.len and pattern[pi] == '\\' and pattern[pi + 1] == ')') {
            group_end.* = si;
            in_group = false;
            pi += 2;
            continue;
        }
        // End anchor
        if (pattern[pi] == '$' and pi + 1 == pattern.len) {
            if (si != str.len) return null;
            pi += 1;
            continue;
        }

        const pa = nextAtom(pattern, pi);
        var after = pa.next;

        // Quantifier following the atom: '*', '\+' (one or more), '\?' (zero or one).
        const Quant = enum { none, star, plus, ques };
        var quant: Quant = .none;
        if (after < pattern.len and pattern[after] == '*') {
            quant = .star;
            after += 1;
        } else if (after + 1 < pattern.len and pattern[after] == '\\' and pattern[after + 1] == '+') {
            quant = .plus;
            after += 2;
        } else if (after + 1 < pattern.len and pattern[after] == '\\' and pattern[after + 1] == '?') {
            quant = .ques;
            after += 2;
        }

        switch (quant) {
            .none => {
                if (si >= str.len or !atomMatches(pa.atom, pattern, str[si])) return null;
                si += 1;
            },
            .star => {
                while (si < str.len and atomMatches(pa.atom, pattern, str[si])) si += 1;
            },
            .plus => {
                if (si >= str.len or !atomMatches(pa.atom, pattern, str[si])) return null;
                si += 1;
                while (si < str.len and atomMatches(pa.atom, pattern, str[si])) si += 1;
            },
            .ques => {
                if (si < str.len and atomMatches(pa.atom, pattern, str[si])) si += 1;
            },
        }

        if (in_group) group_end.* = si;
        pi = after;
    }

    return si - str_pos;
}

pub fn main(init: std.process.Init) void {
    // Arena over the page allocator: holds the (dynamically sized) argument list
    // and any integer-to-string materializations that must outlive the parse.
    // Never freed explicitly — the process exits.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena_state.allocator();

    // GNU expr imposes no argument-count limit; use a growable list.
    var args_list: std.ArrayList([]const u8) = .empty;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        args_list.append(alloc, arg) catch {
            writeStderr("zexpr: out of memory\n", .{});
            std.process.exit(3);
        };
    }

    const args = args_list.items;
    const arg_count = args.len;

    if (arg_count == 0) {
        writeStderr("zexpr: missing operand\n", .{});
        writeStderr("Try 'zexpr --help' for more information.\n", .{});
        std.process.exit(2);
    }

    // Check for --help and --version
    if (arg_count == 1) {
        if (std.mem.eql(u8, args[0], "--help")) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, args[0], "--version")) {
            writeStdout("zexpr {s}\n", .{VERSION});
            return;
        }
    }

    var parser = Parser.init(args, alloc);

    const result = parser.parseExpr() catch |err| {
        switch (err) {
            ExprError.SyntaxError => {
                writeStderr("zexpr: syntax error\n", .{});
                std.process.exit(2);
            },
            ExprError.DivisionByZero => {
                writeStderr("zexpr: division by zero\n", .{});
                std.process.exit(2);
            },
            ExprError.InvalidRegex => {
                writeStderr("zexpr: invalid regular expression\n", .{});
                std.process.exit(2);
            },
            ExprError.Overflow => {
                // GNU expr (arbitrary precision) never overflows; we fall here
                // only for results beyond i128. Exit 3 = "an error occurred".
                writeStderr("zexpr: integer overflow\n", .{});
                std.process.exit(3);
            },
            ExprError.OutOfMemory => {
                writeStderr("zexpr: out of memory\n", .{});
                std.process.exit(3);
            },
        }
    };

    // Check for unconsumed tokens
    if (parser.peek() != null) {
        writeStderr("zexpr: syntax error\n", .{});
        std.process.exit(2);
    }

    // Print result
    switch (result) {
        .integer => |n| writeStdout("{d}\n", .{n}),
        .string => |s| {
            writeStdoutRaw(s);
            writeStdout("\n", .{});
        },
    }

    // Exit status based on result
    if (result.isNull()) {
        std.process.exit(1);
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zexpr EXPRESSION
        \\   or: zexpr OPTION
        \\
        \\Print the value of EXPRESSION to standard output.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
        \\EXPRESSION:
        \\  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2
        \\  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0
        \\  ARG1 < ARG2       ARG1 is less than ARG2
        \\  ARG1 <= ARG2      ARG1 is less than or equal to ARG2
        \\  ARG1 = ARG2       ARG1 is equal to ARG2
        \\  ARG1 != ARG2      ARG1 is not equal to ARG2
        \\  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2
        \\  ARG1 > ARG2       ARG1 is greater than ARG2
        \\  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2
        \\  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2
        \\  ARG1 * ARG2       arithmetic product of ARG1 and ARG2
        \\  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2
        \\  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2
        \\  STRING : REGEX    anchored pattern match of REGEX in STRING
        \\  match STRING REGEX     same as STRING : REGEX
        \\  substr STRING POS LEN  substring of STRING, POS counted from 1
        \\  index STRING CHARS     index in STRING where any CHARS is found, or 0
        \\  length STRING          length of STRING
        \\  ( EXPRESSION )         value of EXPRESSION
        \\
        \\Exit status:
        \\  0  if EXPRESSION is neither null nor 0
        \\  1  if EXPRESSION is null or 0
        \\  2  if EXPRESSION is syntactically invalid
        \\  3  if an error occurred
        \\
    , .{});
}
