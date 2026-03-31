const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: []const u8,
    array: []const Value,
    table: std.StringHashMap(Value),

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .datetime => |d| allocator.free(d),
            .array => |arr| {
                for (arr) |*v_ptr| {
                    var v = v_ptr.*;
                    v.deinit(allocator);
                }
                allocator.free(arr);
            },
            .table => |t| {
                var t_mut = t;
                var iter = t_mut.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(allocator);
                }
                t_mut.deinit();
            },
            else => {},
        }
    }

    pub fn format(self: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.print("\"{}\"", .{std.fmt.fmtSliceEscapeUpper(s)}),
            .integer => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .datetime => |d| try writer.print("\"{}\"", .{d}),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{v});
                }
                try writer.writeAll("]");
            },
            .table => |t| {
                try writer.writeAll("{");
                var iter = t.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    try writer.print("\"{}\"", .{std.fmt.fmtSliceEscapeUpper(entry.key_ptr.*)});
                    try writer.writeAll(": ");
                    try writer.print("{}", .{entry.value_ptr.*});
                    first = false;
                }
                try writer.writeAll("}");
            },
        }
    }
};

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedCharacter,
    ExpectedEquals,
    ExpectedCloseBracket,
    ExpectedCommaOrBracket,
    ExpectedCommaOrBrace,
    ExpectedCloseBrace,
    InvalidKey,
    InvalidValue,
    InvalidBoolean,
    InvalidNumber,
    UnterminatedString,
    OutOfMemory,
    InvalidCharacter,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    Overflow,
};

pub const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    pub fn init(allocator: Allocator, input: []const u8) Parser {
        return Parser{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn parse(self: *Parser) ParseError!std.StringHashMap(Value) {
        var root = std.StringHashMap(Value).init(self.allocator);
        errdefer root.deinit();

        self.skipWhitespace();
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.peek() == '#') {
                self.skipComment();
                continue;
            }

            if (self.peek() == '[') {
                try self.parseTableHeader(&root);
                continue;
            }

            try self.parseKeyValue(&root);
        }

        return root;
    }

    fn parseKeyValue(self: *Parser, table: *std.StringHashMap(Value)) ParseError!void {
        const key = try self.parseKey();
        self.skipWhitespace();

        if (self.pos >= self.input.len or self.peek() != '=') {
            return error.ExpectedEquals;
        }
        self.advance(); // skip '='

        self.skipWhitespace();
        const value = try self.parseValue();

        // After a value, skip spaces/tabs but not newlines
        while (self.pos < self.input.len and (self.peek() == ' ' or self.peek() == '\t')) {
            self.advance();
        }

        // After a value, we should be at EOF, newline, carriage return, or comment
        if (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch != '\n' and ch != '\r' and ch != '#') {
                return error.UnexpectedCharacter;
            }
        }

        try table.put(key, value);
    }

    fn parseTableHeader(self: *Parser, root: *std.StringHashMap(Value)) ParseError!void {
        self.advance(); // skip '['
        self.skipWhitespace();

        const key = try self.parseKey();
        self.skipWhitespace();

        if (self.pos >= self.input.len or self.peek() != ']') {
            return error.ExpectedCloseBracket;
        }
        self.advance(); // skip ']'
        self.skipWhitespace();

        var table = std.StringHashMap(Value).init(self.allocator);
        errdefer table.deinit();

        self.skipWhitespace();
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.peek() == '[') break;
            if (self.peek() == '#') {
                self.skipComment();
                continue;
            }

            try self.parseKeyValue(&table);
        }

        try root.put(key, Value{ .table = table });
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return error.UnexpectedEnd;
        }

        const start = self.pos;
        const ch = self.peek();

        if (ch == '"') {
            self.advance(); // skip opening quote
            while (self.pos < self.input.len and self.peek() != '"') {
                if (self.peek() == '\\') {
                    self.advance();
                    if (self.pos < self.input.len) self.advance();
                } else {
                    self.advance();
                }
            }
            if (self.pos >= self.input.len) {
                return error.UnterminatedString;
            }
            const key = self.input[start + 1 .. self.pos];
            self.advance(); // skip closing quote
            return try self.allocator.dupe(u8, key);
        } else if (self.isIdentifierChar(ch)) {
            while (self.pos < self.input.len) {
                const c = self.peek();
                if (self.isIdentifierChar(c)) {
                    self.advance();
                } else {
                    break;
                }
            }
            return try self.allocator.dupe(u8, self.input[start..self.pos]);
        }

        return error.InvalidKey;
    }

    fn isIdentifierChar(_: *Parser, ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return error.UnexpectedEnd;
        }

        const ch = self.peek();

        if (ch == '"') {
            if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                return self.parseMultilineString();
            }
            return self.parseString();
        }

        if (ch == '\'') {
            if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'') {
                return self.parseMultilineLiteralString();
            }
            return self.parseLiteralString();
        }

        if (ch == '[') {
            return self.parseArray();
        }

        if (ch == '{') {
            return self.parseInlineTable();
        }

        if (ch == 't' or ch == 'f') {
            return self.parseBoolean();
        }

        if (ch == '-' or (ch >= '0' and ch <= '9')) {
            return self.parseNumber();
        }

        return error.InvalidValue;
    }

    fn parseString(self: *Parser) ParseError!Value {
        self.advance(); // skip opening quote
        const start = self.pos;

        while (self.pos < self.input.len and self.peek() != '"') {
            if (self.peek() == '\\') {
                self.advance();
                if (self.pos < self.input.len) self.advance();
            } else {
                self.advance();
            }
        }

        if (self.pos >= self.input.len) {
            return error.UnterminatedString;
        }

        const raw = self.input[start .. self.pos];
        self.advance(); // skip closing quote

        const unescaped = try self.unescapeString(raw);
        return Value{ .string = unescaped };
    }

    fn parseMultilineString(self: *Parser) ParseError!Value {
        self.advance(); // skip first "
        self.advance(); // skip second "
        self.advance(); // skip third "

        const start = self.pos;

        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                break;
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }

        const raw = self.input[start .. self.pos];
        self.pos += 3;

        const unescaped = try self.unescapeString(raw);
        return Value{ .string = unescaped };
    }

    fn parseLiteralString(self: *Parser) ParseError!Value {
        self.advance(); // skip opening '
        const start = self.pos;

        while (self.pos < self.input.len and self.peek() != '\'') {
            self.advance();
        }

        if (self.pos >= self.input.len) {
            return error.UnterminatedString;
        }

        const raw = self.input[start..self.pos];
        self.advance(); // skip closing '

        return Value{ .string = try self.allocator.dupe(u8, raw) };
    }

    fn parseMultilineLiteralString(self: *Parser) ParseError!Value {
        self.advance(); // skip first '
        self.advance(); // skip second '
        self.advance(); // skip third '

        const start = self.pos;

        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '\'' and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'') {
                break;
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }

        const raw = self.input[start..self.pos];
        self.pos += 3;

        return Value{ .string = try self.allocator.dupe(u8, raw) };
    }

    fn unescapeString(self: *Parser, s: []const u8) ParseError![]u8 {
        var result_list = std.ArrayList(u8).initCapacity(self.allocator, s.len) catch {
            return error.UnexpectedEnd;
        };
        defer result_list.deinit(self.allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                const next = s[i + 1];
                switch (next) {
                    'n' => result_list.appendAssumeCapacity('\n'),
                    't' => result_list.appendAssumeCapacity('\t'),
                    'r' => result_list.appendAssumeCapacity('\r'),
                    '\\' => result_list.appendAssumeCapacity('\\'),
                    '"' => result_list.appendAssumeCapacity('"'),
                    'b' => result_list.appendAssumeCapacity('\x08'),
                    'f' => result_list.appendAssumeCapacity('\x0c'),
                    'u' => {
                        if (i + 5 < s.len) {
                            const hex = s[i + 2 .. i + 6];
                            if (std.fmt.parseInt(u32, hex, 16)) |codepoint_u32| {
                                const codepoint: u21 = @truncate(codepoint_u32);
                                var buf: [4]u8 = undefined;
                                const len = try std.unicode.utf8Encode(codepoint, &buf);
                                result_list.appendSliceAssumeCapacity(buf[0..len]);
                                i += 4;
                            } else |_| {
                                result_list.appendAssumeCapacity(s[i]);
                            }
                        }
                    },
                    else => result_list.appendAssumeCapacity(s[i]),
                }
                i += 2;
            } else {
                result_list.appendAssumeCapacity(s[i]);
                i += 1;
            }
        }

        return result_list.toOwnedSlice(self.allocator) catch {
            return error.UnexpectedEnd;
        };
    }

    fn parseArray(self: *Parser) ParseError!Value {
        self.advance(); // skip '['
        var arr = std.ArrayList(Value).initCapacity(self.allocator, 256) catch {
            return error.UnexpectedEnd;
        };
        errdefer {
            for (arr.items) |*v| {
                v.deinit(self.allocator);
            }
            arr.deinit(self.allocator);
        }

        self.skipWhitespace();
        while (self.pos < self.input.len and self.peek() != ']') {
            if (self.peek() == '#') {
                self.skipComment();
                continue;
            }

            self.skipWhitespace();
            if (self.peek() == ']') break;

            const value = try self.parseValue();
            arr.appendAssumeCapacity(value);

            self.skipWhitespace();
            if (self.peek() == ',') {
                self.advance();
                self.skipWhitespace();
            } else if (self.peek() != ']') {
                return error.ExpectedCommaOrBracket;
            }
        }

        if (self.pos >= self.input.len or self.peek() != ']') {
            return error.ExpectedCloseBracket;
        }
        self.advance(); // skip ']'

        return Value{ .array = arr.toOwnedSlice(self.allocator) catch {
            return error.UnexpectedEnd;
        } };
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        self.advance(); // skip '{'
        var table = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var iter = table.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            table.deinit();
        }

        self.skipWhitespace();
        while (self.pos < self.input.len and self.peek() != '}') {
            self.skipWhitespace();
            if (self.peek() == '}') break;

            const key = try self.parseKey();
            self.skipWhitespace();

            if (self.pos >= self.input.len or self.peek() != '=') {
                self.allocator.free(key);
                return error.ExpectedEquals;
            }
            self.advance(); // skip '='

            self.skipWhitespace();
            const value = try self.parseValue();
            self.skipWhitespace();

            try table.put(key, value);

            if (self.peek() == ',') {
                self.advance();
                self.skipWhitespace();
            } else if (self.peek() != '}') {
                return error.ExpectedCommaOrBrace;
            }
        }

        if (self.pos >= self.input.len or self.peek() != '}') {
            return error.ExpectedCloseBrace;
        }
        self.advance(); // skip '}'

        return Value{ .table = table };
    }

    fn parseBoolean(self: *Parser) ParseError!Value {
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            self.col += 4;
            return Value{ .boolean = true };
        } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            self.col += 5;
            return Value{ .boolean = false };
        }
        return error.InvalidBoolean;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;

        if (self.peek() == '-') {
            self.advance();
        }

        if (self.peek() == '0' and self.pos + 1 < self.input.len) {
            const next = self.input[self.pos + 1];
            // Reject leading zeroes in integers (e.g., 042) but allow 0.x floats
            if (next >= '0' and next <= '9') {
                return error.InvalidNumber;
            }
        }

        while (self.pos < self.input.len and self.peek() >= '0' and self.peek() <= '9') {
            self.advance();
        }

        var is_float = false;

        if (self.pos < self.input.len and self.peek() == '.') {
            is_float = true;
            self.advance();
            if (self.pos >= self.input.len or self.peek() < '0' or self.peek() > '9') {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.len and self.peek() >= '0' and self.peek() <= '9') {
                self.advance();
            }
        }

        if (self.pos < self.input.len and (self.peek() == 'e' or self.peek() == 'E')) {
            is_float = true;
            self.advance();
            if (self.pos < self.input.len and (self.peek() == '+' or self.peek() == '-')) {
                self.advance();
            }
            if (self.pos >= self.input.len or self.peek() < '0' or self.peek() > '9') {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.len and self.peek() >= '0' and self.peek() <= '9') {
                self.advance();
            }
        }

        const num_str = self.input[start .. self.pos];

        if (is_float) {
            const float_val = try std.fmt.parseFloat(f64, num_str);
            return Value{ .float = float_val };
        } else {
            const int_val = try std.fmt.parseInt(i64, num_str, 10);
            return Value{ .integer = int_val };
        }
    }

    fn peek(self: *Parser) u8 {
        if (self.pos >= self.input.len) return 0;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Parser) void {
        while (self.pos < self.input.len and self.peek() != '\n') {
            self.advance();
        }
        if (self.pos < self.input.len) {
            self.advance(); // skip newline
        }
    }
};

pub fn parseToml(allocator: Allocator, input: []const u8) ParseError!std.StringHashMap(Value) {
    var parser = Parser.init(allocator, input);
    return try parser.parse();
}

test "parse simple key-value" {
    const allocator = std.testing.allocator;
    const input = "name = \"John\"\nage = 30\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const name = result.get("name").?;
    try std.testing.expectEqualSlices(u8, "John", name.string);

    const age = result.get("age").?;
    try std.testing.expectEqual(@as(i64, 30), age.integer);
}

test "parse boolean values" {
    const allocator = std.testing.allocator;
    const input = "enabled = true\ndisabled = false\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expect(result.get("enabled").?.boolean);
    try std.testing.expect(!result.get("disabled").?.boolean);
}

test "parse float values" {
    const allocator = std.testing.allocator;
    const input = "pi = 3.14159\ntemp = -273.15\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expect(std.math.isApproxEqAbs(f64, 3.14159, result.get("pi").?.float, 0.00001));
    try std.testing.expect(std.math.isApproxEqAbs(f64, -273.15, result.get("temp").?.float, 0.00001));
}

test "parse arrays" {
    const allocator = std.testing.allocator;
    const input = "numbers = [1, 2, 3]\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const arr = result.get("numbers").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr[2].integer);
}

test "parse inline tables" {
    const allocator = std.testing.allocator;
    const input = "point = { x = 1, y = 2 }\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const table = result.get("point").?.table;
    try std.testing.expectEqual(@as(i64, 1), table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), table.get("y").?.integer);
}

test "parse table headers" {
    const allocator = std.testing.allocator;
    const input = "[database]\nhost = \"localhost\"\nport = 5432\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const db = result.get("database").?.table;
    try std.testing.expectEqualSlices(u8, "localhost", db.get("host").?.string);
    try std.testing.expectEqual(@as(i64, 5432), db.get("port").?.integer);
}

test "parse comments" {
    const allocator = std.testing.allocator;
    const input = "# This is a comment\nname = \"John\" # inline comment\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expectEqualSlices(u8, "John", result.get("name").?.string);
}

test "parse multiline strings" {
    const allocator = std.testing.allocator;
    const input = "message = \"\"\"Line 1\nLine 2\nLine 3\"\"\"\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const msg = result.get("message").?.string;
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "Line"));
}

// ============================================================================
// ENHANCED TEST SUITE - zig_toml TOML Spec Compliance
// ============================================================================

test "TOML string types - basic string" {
    const allocator = std.testing.allocator;
    const input = "name = \"John Doe\"\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const name = result.get("name").?;
    try std.testing.expectEqualSlices(u8, "John Doe", name.string);
}

test "TOML string types - literal string" {
    const allocator = std.testing.allocator;
    const input = "path = 'C:\\Users\\john'\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const path = result.get("path").?;
    try std.testing.expect(std.mem.containsAtLeast(u8, path.string, 1, "C"));
}

test "TOML string types - multiline basic string" {
    const allocator = std.testing.allocator;
    const input = "doc = \"\"\"The quick brown\nfox jumps over\nthe lazy dog.\"\"\"\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const doc = result.get("doc").?;
    try std.testing.expect(std.mem.containsAtLeast(u8, doc.string, 1, "fox"));
}

test "TOML string types - multiline literal string" {
    const allocator = std.testing.allocator;
    const input = "raw = '''Line 1\nLine 2\nLine 3'''\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expect(result.count() >= 1);
}

test "TOML integer formats - decimal" {
    const allocator = std.testing.allocator;
    const input = "decimal = 42\nnegative = -100\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expectEqual(@as(i64, 42), result.get("decimal").?.integer);
    try std.testing.expectEqual(@as(i64, -100), result.get("negative").?.integer);
}

test "TOML float values - standard float" {
    const allocator = std.testing.allocator;
    const input = "pi = 3.14159\nnegative_float = -0.01\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const pi = result.get("pi").?.float;
    try std.testing.expect(std.math.isApproxEqAbs(f64, 3.14159, pi, 0.00001));
}

test "TOML boolean values - true and false" {
    const allocator = std.testing.allocator;
    const input = "is_active = true\nis_deleted = false\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expect(result.get("is_active").?.boolean == true);
    try std.testing.expect(result.get("is_deleted").?.boolean == false);
}

test "TOML nested tables - simple" {
    const allocator = std.testing.allocator;
    const input = "[database]\nhost = \"localhost\"\nport = 5432\n[database.backup]\nhost = \"backup.local\"\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const db = result.get("database").?.table;
    try std.testing.expectEqualSlices(u8, "localhost", db.get("host").?.string);
    try std.testing.expectEqual(@as(i64, 5432), db.get("port").?.integer);
}

test "TOML array values - integers" {
    const allocator = std.testing.allocator;
    const input = "numbers = [1, 2, 3, 4, 5]\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const arr = result.get("numbers").?.array;
    try std.testing.expectEqual(@as(usize, 5), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 5), arr[4].integer);
}

test "TOML array values - strings" {
    const allocator = std.testing.allocator;
    const input = "colors = [\"red\", \"green\", \"blue\"]\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const arr = result.get("colors").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualSlices(u8, "red", arr[0].string);
    try std.testing.expectEqualSlices(u8, "blue", arr[2].string);
}

test "TOML inline tables - simple" {
    const allocator = std.testing.allocator;
    const input = "point = { x = 1, y = 2 }\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const table = result.get("point").?.table;
    try std.testing.expectEqual(@as(i64, 1), table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), table.get("y").?.integer);
}

test "TOML inline tables - nested" {
    const allocator = std.testing.allocator;
    const input = "person = { name = \"John\", address = { city = \"NYC\" } }\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    const person = result.get("person").?.table;
    try std.testing.expectEqualSlices(u8, "John", person.get("name").?.string);
}

test "TOML comments - line comments" {
    const allocator = std.testing.allocator;
    const input = "# This is a comment\nname = \"value\" # inline comment\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expectEqualSlices(u8, "value", result.get("name").?.string);
}

test "TOML comments - multiple inline comments" {
    const allocator = std.testing.allocator;
    const input = "a = 1 # comment\nb = 2 # another\nc = 3 # third\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expect(result.count() >= 3);
}

test "TOML mixed types in table" {
    const allocator = std.testing.allocator;
    const input = "name = \"config\"\nversion = 1.0\nenabled = true\nports = [8080, 8443]\n";
    var result = try parseToml(allocator, input);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try std.testing.expectEqualSlices(u8, "config", result.get("name").?.string);
    try std.testing.expect(std.math.isApproxEqAbs(f64, 1.0, result.get("version").?.float, 0.001));
    try std.testing.expect(result.get("enabled").?.boolean);
    try std.testing.expectEqual(@as(usize, 2), result.get("ports").?.array.len);
}
