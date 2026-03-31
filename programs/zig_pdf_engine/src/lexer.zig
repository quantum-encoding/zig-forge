const std = @import("std");

/// PDF Lexer - tokenizes raw PDF bytes without allocation
/// All tokens reference slices of the original buffer (zero-copy)
pub const Lexer = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Lexer {
        return .{ .data = data, .pos = 0 };
    }

    /// Initialize at a specific offset (for parsing objects at xref offsets)
    pub fn initAt(data: []const u8, offset: usize) Lexer {
        return .{ .data = data, .pos = offset };
    }

    pub fn next(self: *Lexer) ?Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.data.len) return null;

        const start = self.pos;
        const c = self.data[self.pos];

        // Delimiters
        return switch (c) {
            '(' => self.readLiteralString(),
            '<' => self.readHexOrDict(),
            '/' => self.readName(),
            '[' => self.singleChar(.array_start),
            ']' => self.singleChar(.array_end),
            '{' => self.singleChar(.proc_start),
            '}' => self.singleChar(.proc_end),
            else => self.readNumberOrKeyword(start),
        };
    }

    /// Peek at next token without consuming
    pub fn peek(self: *Lexer) ?Token {
        const saved_pos = self.pos;
        const token = self.next();
        self.pos = saved_pos;
        return token;
    }

    /// Skip to a specific byte offset
    pub fn seekTo(self: *Lexer, offset: usize) void {
        self.pos = @min(offset, self.data.len);
    }

    /// Current position in buffer (alias for getPosition)
    pub fn position(self: *const Lexer) usize {
        return self.pos;
    }

    /// Get current position
    pub fn getPosition(self: *const Lexer) usize {
        return self.pos;
    }

    /// Check if at end of data
    pub fn isEof(self: *const Lexer) bool {
        return self.pos >= self.data.len;
    }

    // === Private parsing methods ===

    fn singleChar(self: *Lexer, tag: Token.Tag) Token {
        self.pos += 1;
        return .{ .tag = tag, .data = self.data[self.pos - 1 .. self.pos] };
    }

    fn readLiteralString(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip '('
        var depth: u32 = 1;

        while (self.pos < self.data.len and depth > 0) {
            const c = self.data[self.pos];
            if (c == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 2; // skip escaped char
            } else {
                if (c == '(') depth += 1;
                if (c == ')') depth -= 1;
                self.pos += 1;
            }
        }
        return .{ .tag = .literal_string, .data = self.data[start..self.pos] };
    }

    fn readHexOrDict(self: *Lexer) Token {
        if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
            // Dictionary start <<
            self.pos += 2;
            return .{ .tag = .dict_start, .data = self.data[self.pos - 2 .. self.pos] };
        }

        // Hex string <...>
        const start = self.pos;
        self.pos += 1; // skip '<'
        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1; // skip '>'
        return .{ .tag = .hex_string, .data = self.data[start..self.pos] };
    }

    fn readName(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip '/'

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }
        return .{ .tag = .name, .data = self.data[start..self.pos] };
    }

    fn readNumberOrKeyword(self: *Lexer, start: usize) Token {
        // Check for dict end >>
        if (self.data[self.pos] == '>' and self.pos + 1 < self.data.len and self.data[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .tag = .dict_end, .data = self.data[start..self.pos] };
        }

        // Read until whitespace or delimiter
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        const slice = self.data[start..self.pos];
        if (slice.len == 0) return .{ .tag = .eof, .data = slice };

        // Classify the token
        const tag: Token.Tag = blk: {
            // Check keywords first
            if (std.mem.eql(u8, slice, "true")) break :blk .keyword_true;
            if (std.mem.eql(u8, slice, "false")) break :blk .keyword_false;
            if (std.mem.eql(u8, slice, "null")) break :blk .keyword_null;
            if (std.mem.eql(u8, slice, "obj")) break :blk .keyword_obj;
            if (std.mem.eql(u8, slice, "endobj")) break :blk .keyword_endobj;
            if (std.mem.eql(u8, slice, "stream")) break :blk .keyword_stream;
            if (std.mem.eql(u8, slice, "endstream")) break :blk .keyword_endstream;
            if (std.mem.eql(u8, slice, "xref")) break :blk .keyword_xref;
            if (std.mem.eql(u8, slice, "trailer")) break :blk .keyword_trailer;
            if (std.mem.eql(u8, slice, "startxref")) break :blk .keyword_startxref;
            if (std.mem.eql(u8, slice, "R")) break :blk .keyword_ref;

            // Try to parse as number
            if (isNumber(slice)) break :blk .number;

            break :blk .unknown;
        };

        return .{ .tag = tag, .data = slice };
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == '%') {
                // Comment - skip to end of line
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else if (isWhitespace(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x00' or c == '\x0c';
    }

    fn isDelimiter(c: u8) bool {
        return c == '(' or c == ')' or c == '<' or c == '>' or
            c == '[' or c == ']' or c == '{' or c == '}' or c == '/' or c == '%';
    }

    fn isNumber(slice: []const u8) bool {
        if (slice.len == 0) return false;
        var i: usize = 0;

        // Optional sign
        if (slice[0] == '+' or slice[0] == '-') i += 1;
        if (i >= slice.len) return false;

        var has_digit = false;
        var has_dot = false;

        while (i < slice.len) : (i += 1) {
            const c = slice[i];
            if (c >= '0' and c <= '9') {
                has_digit = true;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
            } else {
                return false;
            }
        }
        return has_digit;
    }
};

/// PDF Token - zero-copy reference into source buffer
pub const Token = struct {
    tag: Tag,
    data: []const u8,

    pub const Tag = enum {
        // Literals
        number,
        literal_string, // (...)
        hex_string, // <...>
        name, // /Name

        // Delimiters
        array_start, // [
        array_end, // ]
        dict_start, // <<
        dict_end, // >>
        proc_start, // {
        proc_end, // }

        // Keywords
        keyword_true,
        keyword_false,
        keyword_null,
        keyword_obj,
        keyword_endobj,
        keyword_stream,
        keyword_endstream,
        keyword_xref,
        keyword_trailer,
        keyword_startxref,
        keyword_ref, // R

        // Other
        unknown,
        eof,
    };

    /// Get the name without the leading '/'
    pub fn nameValue(self: Token) []const u8 {
        if (self.tag != .name or self.data.len == 0) return self.data;
        return self.data[1..];
    }

    /// Parse number token as integer
    pub fn asInt(self: Token) ?i64 {
        if (self.tag != .number) return null;
        return std.fmt.parseInt(i64, self.data, 10) catch null;
    }

    /// Parse number token as float
    pub fn asFloat(self: Token) ?f64 {
        if (self.tag != .number) return null;
        return std.fmt.parseFloat(f64, self.data) catch null;
    }

    /// Get literal string content (without parentheses, unescaped)
    pub fn stringContent(self: Token) []const u8 {
        if (self.tag != .literal_string) return self.data;
        if (self.data.len < 2) return "";
        return self.data[1 .. self.data.len - 1]; // Strip ( and )
    }

    /// Get hex string content (without angle brackets)
    pub fn hexContent(self: Token) []const u8 {
        if (self.tag != .hex_string) return self.data;
        if (self.data.len < 2) return "";
        return self.data[1 .. self.data.len - 1]; // Strip < and >
    }
};

// === Tests ===

test "lexer basic tokens" {
    const data = "/Type /Page /MediaBox [0 0 612 792]";
    var lex = Lexer.init(data);

    const t1 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.name, t1.tag);
    try std.testing.expectEqualStrings("Type", t1.nameValue());

    const t2 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.name, t2.tag);
    try std.testing.expectEqualStrings("Page", t2.nameValue());

    const t3 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.name, t3.tag);
    try std.testing.expectEqualStrings("MediaBox", t3.nameValue());

    const t4 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.array_start, t4.tag);
}

test "lexer numbers" {
    const data = "123 -45 3.14 +0.5";
    var lex = Lexer.init(data);

    try std.testing.expectEqual(@as(i64, 123), lex.next().?.asInt().?);
    try std.testing.expectEqual(@as(i64, -45), lex.next().?.asInt().?);
    try std.testing.expect(std.math.approxEqAbs(f64, 3.14, lex.next().?.asFloat().?, 0.001));
    try std.testing.expect(std.math.approxEqAbs(f64, 0.5, lex.next().?.asFloat().?, 0.001));
}

test "lexer strings" {
    const data = "(Hello World) <48454C4C4F>";
    var lex = Lexer.init(data);

    const t1 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.literal_string, t1.tag);
    try std.testing.expectEqualStrings("Hello World", t1.stringContent());

    const t2 = lex.next().?;
    try std.testing.expectEqual(Token.Tag.hex_string, t2.tag);
    try std.testing.expectEqualStrings("48454C4C4F", t2.hexContent());
}

test "lexer dictionary" {
    const data = "<< /Type /Catalog /Pages 2 0 R >>";
    var lex = Lexer.init(data);

    try std.testing.expectEqual(Token.Tag.dict_start, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.name, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.name, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.name, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.number, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.number, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.keyword_ref, lex.next().?.tag);
    try std.testing.expectEqual(Token.Tag.dict_end, lex.next().?.tag);
}

test "lexer nested strings" {
    const data = "(Hello (nested) World)";
    var lex = Lexer.init(data);

    const t = lex.next().?;
    try std.testing.expectEqual(Token.Tag.literal_string, t.tag);
    try std.testing.expectEqualStrings("Hello (nested) World", t.stringContent());
}
