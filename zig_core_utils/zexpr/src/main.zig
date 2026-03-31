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

// Value type for expression evaluation
const Value = union(enum) {
    integer: i64,
    string: []const u8,

    fn isNull(self: Value) bool {
        return switch (self) {
            .integer => |n| n == 0,
            .string => |s| s.len == 0,
        };
    }

    fn toInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |n| n,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
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
    OutOfMemory,
};

const Parser = struct {
    args: []const []const u8,
    pos: usize,

    fn init(args: []const []const u8) Parser {
        return .{ .args = args, .pos = 0 };
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

            if (is_add) {
                left = Value{ .integer = a + b };
            } else {
                left = Value{ .integer = a - b };
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
                    .mul => a * b,
                    .div => @divTrunc(a, b),
                    .mod => @mod(a, b),
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

                var buf: [256]u8 = undefined;
                const str = left.asString(&buf);
                var pat_buf: [256]u8 = undefined;
                const pat = pattern.asString(&pat_buf);

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
            var buf1: [256]u8 = undefined;
            var buf2: [256]u8 = undefined;
            const str = str_val.asString(&buf1);
            const pat = pat_val.asString(&buf2);
            return doMatch(str, pat);
        }

        if (std.mem.eql(u8, tok, "substr")) {
            const str_val = try self.parseAtom();
            const pos_val = try self.parseAtom();
            const len_val = try self.parseAtom();

            var buf: [256]u8 = undefined;
            const str = str_val.asString(&buf);
            const pos = pos_val.toInt() orelse return ExprError.SyntaxError;
            const len = len_val.toInt() orelse return ExprError.SyntaxError;

            if (pos < 1 or len < 0) {
                return Value{ .string = "" };
            }

            const start_idx: usize = @intCast(pos - 1);
            if (start_idx >= str.len) {
                return Value{ .string = "" };
            }

            const end_idx = @min(start_idx + @as(usize, @intCast(len)), str.len);
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

fn simpleMatch(str: []const u8, pattern: []const u8, str_pos: usize, group_start: *usize, group_end: *usize) ?usize {
    var si = str_pos;
    var pi: usize = 0;
    var in_group = false;

    while (pi < pattern.len) {
        // Handle escape sequences
        if (pi + 1 < pattern.len and pattern[pi] == '\\') {
            const next = pattern[pi + 1];
            if (next == '(') {
                group_start.* = si;
                in_group = true;
                pi += 2;
                continue;
            }
            if (next == ')') {
                group_end.* = si;
                in_group = false;
                pi += 2;
                continue;
            }
            // Escaped literal
            if (si >= str.len or str[si] != next) {
                return null;
            }
            si += 1;
            pi += 2;
            continue;
        }

        // Check for * (Kleene star) - look ahead
        const has_star = pi + 1 < pattern.len and pattern[pi + 1] == '*';

        if (has_star) {
            const char_to_match = pattern[pi];
            pi += 2; // Skip char and *

            // Try matching zero or more
            while (si < str.len) {
                if (char_to_match == '.') {
                    // . matches any character
                    si += 1;
                } else if (str[si] == char_to_match) {
                    si += 1;
                } else {
                    break;
                }
            }

            if (in_group) {
                group_end.* = si;
            }
            continue;
        }

        // Match single character
        if (pattern[pi] == '.') {
            if (si >= str.len) {
                return null;
            }
            si += 1;
            pi += 1;
        } else if (pattern[pi] == '$' and pi + 1 == pattern.len) {
            // End anchor
            if (si != str.len) {
                return null;
            }
            pi += 1;
        } else {
            if (si >= str.len or str[si] != pattern[pi]) {
                return null;
            }
            si += 1;
            pi += 1;
        }
    }

    return si - str_pos;
}

pub fn main(init: std.process.Init) void {
    var args_buf: [256][]const u8 = undefined;
    var arg_count: usize = 0;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (arg_count >= args_buf.len) {
            writeStderr("zexpr: too many arguments\n", .{});
            std.process.exit(3);
        }
        args_buf[arg_count] = arg;
        arg_count += 1;
    }

    if (arg_count == 0) {
        writeStderr("zexpr: missing operand\n", .{});
        writeStderr("Try 'zexpr --help' for more information.\n", .{});
        std.process.exit(2);
    }

    // Check for --help and --version
    if (arg_count == 1) {
        if (std.mem.eql(u8, args_buf[0], "--help")) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, args_buf[0], "--version")) {
            writeStdout("zexpr {s}\n", .{VERSION});
            return;
        }
    }

    const args = args_buf[0..arg_count];
    var parser = Parser.init(args);

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
