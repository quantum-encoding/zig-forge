const std = @import("std");
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const Lexer = lexer.Lexer;

/// Reference to an indirect object (obj_num gen_num R)
pub const ObjectRef = struct {
    obj_num: u32,
    gen_num: u16,

    pub fn format(self: ObjectRef, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d} {d} R", .{ self.obj_num, self.gen_num });
    }
};

/// PDF Object - tagged union of all PDF value types
/// Note: Arrays and Dicts store raw byte slices for lazy parsing
pub const Object = union(enum) {
    null_obj,
    boolean: bool,
    integer: i64,
    real: f64,
    name: []const u8, // Without leading /
    literal_string: []const u8, // Raw content between ()
    hex_string: []const u8, // Raw hex digits between <>
    array: []const u8, // Raw bytes of array content for lazy parsing
    dict: []const u8, // Raw bytes of dict content for lazy parsing
    stream: Stream,
    reference: ObjectRef,

    pub const Stream = struct {
        dict: []const u8, // Dictionary bytes
        data: []const u8, // Raw stream data (possibly compressed)
    };

    /// Parse a single object from lexer
    pub fn parse(lex: *Lexer) !Object {
        const token = lex.next() orelse return error.UnexpectedEof;

        return switch (token.tag) {
            .keyword_null => .null_obj,
            .keyword_true => .{ .boolean = true },
            .keyword_false => .{ .boolean = false },
            .name => .{ .name = token.nameValue() },
            .literal_string => .{ .literal_string = token.stringContent() },
            .hex_string => .{ .hex_string = token.hexContent() },
            .number => parseNumberOrRef(lex, token),
            .array_start => parseArray(lex),
            .dict_start => parseDictOrStream(lex),
            else => error.UnexpectedToken,
        };
    }

    fn parseNumberOrRef(lex: *Lexer, first_token: Token) !Object {
        // Could be: number, or "num1 num2 R" (reference)
        const saved_pos = lex.position();

        if (lex.next()) |second| {
            if (second.tag == .number) {
                if (lex.next()) |third| {
                    if (third.tag == .keyword_ref) {
                        // It's a reference
                        const obj_num = first_token.asInt() orelse return error.InvalidNumber;
                        const gen_num = second.asInt() orelse return error.InvalidNumber;
                        return .{ .reference = .{
                            .obj_num = @intCast(obj_num),
                            .gen_num = @intCast(gen_num),
                        } };
                    }
                }
            }
        }

        // Not a reference, restore position and return number
        lex.seekTo(saved_pos);

        if (std.mem.indexOfScalar(u8, first_token.data, '.')) |_| {
            return .{ .real = first_token.asFloat() orelse return error.InvalidNumber };
        } else {
            return .{ .integer = first_token.asInt() orelse return error.InvalidNumber };
        }
    }

    fn parseArray(lex: *Lexer) !Object {
        // Capture bytes from after [ to before ]
        const start = lex.position();
        var depth: u32 = 1;

        while (lex.next()) |token| {
            switch (token.tag) {
                .array_start => depth += 1,
                .array_end => {
                    depth -= 1;
                    if (depth == 0) {
                        // Return slice excluding the final ]
                        const end = lex.position() - 1;
                        return .{ .array = lex.data[start..end] };
                    }
                },
                .eof => return error.UnexpectedEof,
                else => {},
            }
        }
        return error.UnexpectedEof;
    }

    fn parseDictOrStream(lex: *Lexer) !Object {
        // Capture bytes from after << to before >>
        const start = lex.position();
        var depth: u32 = 1;

        while (lex.next()) |token| {
            switch (token.tag) {
                .dict_start => depth += 1,
                .dict_end => {
                    depth -= 1;
                    if (depth == 0) {
                        const end = lex.position() - 2; // Before >>
                        const dict_bytes = lex.data[start..end];

                        // Check if followed by stream
                        const saved = lex.position();
                        if (lex.next()) |next_tok| {
                            if (next_tok.tag == .keyword_stream) {
                                // Find stream data
                                const stream_data = findStreamData(lex) catch {
                                    lex.seekTo(saved);
                                    return .{ .dict = dict_bytes };
                                };
                                return .{ .stream = .{
                                    .dict = dict_bytes,
                                    .data = stream_data,
                                } };
                            }
                        }
                        lex.seekTo(saved);
                        return .{ .dict = dict_bytes };
                    }
                },
                .eof => return error.UnexpectedEof,
                else => {},
            }
        }
        return error.UnexpectedEof;
    }

    fn findStreamData(lex: *Lexer) ![]const u8 {
        // Skip newline after "stream" keyword
        var pos = lex.position();
        while (pos < lex.data.len and (lex.data[pos] == '\r' or lex.data[pos] == '\n')) {
            pos += 1;
        }

        const start = pos;

        // Find "endstream"
        const needle = "endstream";
        while (pos + needle.len <= lex.data.len) : (pos += 1) {
            if (std.mem.eql(u8, lex.data[pos .. pos + needle.len], needle)) {
                // Found it - stream data is from start to here
                // Back up over any trailing whitespace
                var end = pos;
                while (end > start and (lex.data[end - 1] == '\r' or lex.data[end - 1] == '\n')) {
                    end -= 1;
                }
                lex.seekTo(pos + needle.len);
                return lex.data[start..end];
            }
        }
        return error.StreamEndNotFound;
    }

    /// Check if object is null
    pub fn isNull(self: Object) bool {
        return self == .null_obj;
    }

    /// Get as boolean
    pub fn asBool(self: Object) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Get as integer
    pub fn asInt(self: Object) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .real => |r| @intFromFloat(r),
            else => null,
        };
    }

    /// Get as float
    pub fn asFloat(self: Object) ?f64 {
        return switch (self) {
            .real => |r| r,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Get as name (string without /)
    pub fn asName(self: Object) ?[]const u8 {
        return switch (self) {
            .name => |n| n,
            else => null,
        };
    }

    /// Get as string (literal or hex decoded)
    pub fn asString(self: Object) ?[]const u8 {
        return switch (self) {
            .literal_string => |s| s,
            .hex_string => |s| s, // Note: hex decoding handled separately in context
            else => null,
        };
    }

    /// Decode a hex string to binary
    pub fn decodeHexString(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
        // Remove whitespace and validate hex
        var cleaned = std.ArrayList(u8).init(allocator);
        defer cleaned.deinit();

        for (hex) |c| {
            if (!std.ascii.isWhitespace(c)) {
                try cleaned.append(c);
            }
        }

        // Pad to even length with leading 0 if needed
        const hex_bytes = cleaned.items;
        const output_len = (hex_bytes.len + 1) / 2;
        const result = try allocator.alloc(u8, output_len);

        var i: usize = 0;
        var out_idx: usize = 0;

        if (hex_bytes.len % 2 == 1) {
            // Odd length: first nibble is from first char, padded with 0 on left
            result[out_idx] = (try parseHexNibble(hex_bytes[0])) & 0x0F;
            out_idx += 1;
            i = 1;
        }

        // Process pairs
        while (i + 1 < hex_bytes.len) : (i += 2) {
            const high = try parseHexNibble(hex_bytes[i]);
            const low = try parseHexNibble(hex_bytes[i + 1]);
            result[out_idx] = (high << 4) | (low & 0x0F);
            out_idx += 1;
        }

        return result;
    }

    fn parseHexNibble(c: u8) !u8 {
        if (c >= '0' and c <= '9') {
            return c - '0';
        } else if (c >= 'A' and c <= 'F') {
            return c - 'A' + 10;
        } else if (c >= 'a' and c <= 'f') {
            return c - 'a' + 10;
        }
        return error.InvalidHexCharacter;
    }

    /// Get as reference
    pub fn asRef(self: Object) ?ObjectRef {
        return switch (self) {
            .reference => |r| r,
            else => null,
        };
    }
};

/// Dictionary helper for parsing dict bytes
pub const DictParser = struct {
    lex: Lexer,

    pub fn init(dict_bytes: []const u8) DictParser {
        return .{ .lex = Lexer.init(dict_bytes) };
    }

    /// Get value for a key, returns null if not found
    pub fn get(self: *DictParser, key: []const u8) ?Object {
        self.lex.seekTo(0);

        while (self.lex.next()) |token| {
            if (token.tag == .name) {
                if (std.mem.eql(u8, token.nameValue(), key)) {
                    return Object.parse(&self.lex) catch null;
                } else {
                    // Skip the value
                    _ = Object.parse(&self.lex) catch return null;
                }
            }
        }
        return null;
    }

    /// Iterate all key-value pairs
    pub fn iterator(self: *DictParser) DictIterator {
        self.lex.seekTo(0);
        return .{ .lex = &self.lex };
    }

    pub const DictIterator = struct {
        lex: *Lexer,

        pub fn next(self: *DictIterator) ?struct { key: []const u8, value: Object } {
            while (self.lex.next()) |token| {
                if (token.tag == .name) {
                    const value = Object.parse(self.lex) catch return null;
                    return .{ .key = token.nameValue(), .value = value };
                }
            }
            return null;
        }
    };
};

// === Tests ===

test "parse simple objects" {
    var lex = Lexer.init("null true false 42 3.14 /Name (Hello)");

    try std.testing.expect((try Object.parse(&lex)).isNull());
    try std.testing.expectEqual(true, (try Object.parse(&lex)).asBool().?);
    try std.testing.expectEqual(false, (try Object.parse(&lex)).asBool().?);
    try std.testing.expectEqual(@as(i64, 42), (try Object.parse(&lex)).asInt().?);
    try std.testing.expect(std.math.approxEqAbs(f64, 3.14, (try Object.parse(&lex)).asFloat().?, 0.001));
    try std.testing.expectEqualStrings("Name", (try Object.parse(&lex)).asName().?);
    try std.testing.expectEqualStrings("Hello", (try Object.parse(&lex)).asString().?);
}

test "parse reference" {
    var lex = Lexer.init("10 0 R");
    const obj = try Object.parse(&lex);
    const ref = obj.asRef().?;
    try std.testing.expectEqual(@as(u32, 10), ref.obj_num);
    try std.testing.expectEqual(@as(u16, 0), ref.gen_num);
}

test "parse array" {
    var lex = Lexer.init("[1 2 3]");
    const obj = try Object.parse(&lex);
    switch (obj) {
        .array => {},
        else => return error.ExpectedArray,
    }
}

test "parse dictionary" {
    var lex = Lexer.init("<< /Type /Page /Count 5 >>");
    const obj = try Object.parse(&lex);

    switch (obj) {
        .dict => |bytes| {
            var parser = DictParser.init(bytes);
            const type_val = parser.get("Type").?;
            try std.testing.expectEqualStrings("Page", type_val.asName().?);

            const count_val = parser.get("Count").?;
            try std.testing.expectEqual(@as(i64, 5), count_val.asInt().?);
        },
        else => return error.ExpectedDict,
    }
}
