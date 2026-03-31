const std = @import("std");
const lexer = @import("../lexer.zig");
const objects = @import("../objects.zig");
const operators = @import("../render/operators.zig");
const filters = @import("../filters.zig");
const cmap_mod = @import("../cmap.zig");

const Lexer = lexer.Lexer;
const Token = lexer.Token;
const Object = objects.Object;
const Operator = operators.Operator;
const CMap = cmap_mod.CMap;

/// Text extraction from PDF content streams
/// This is a "virtual renderer" that captures text instead of drawing pixels
pub const TextExtractor = struct {
    allocator: std.mem.Allocator,

    // Text state
    in_text_block: bool = false,
    text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 }, // Identity matrix
    line_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    text_leading: f64 = 0,
    last_y: ?f64 = null,

    // Font encoding (ToUnicode CMap per font name)
    font_cmaps: std.StringHashMap(*CMap),
    current_font: ?[]const u8 = null,
    current_font_owned: ?[]u8 = null, // Owned copy of current font name
    owned_font_names: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) TextExtractor {
        return .{
            .allocator = allocator,
            .font_cmaps = std.StringHashMap(*CMap).init(allocator),
            .owned_font_names = std.ArrayList([]u8).empty,
        };
    }

    pub fn deinit(self: *TextExtractor) void {
        // Free CMap objects
        var iter = self.font_cmaps.valueIterator();
        while (iter.next()) |cmap_ptr| {
            cmap_ptr.*.deinit();
            self.allocator.destroy(cmap_ptr.*);
        }
        self.font_cmaps.deinit();

        // Free owned font name strings
        for (self.owned_font_names.items) |name| {
            self.allocator.free(name);
        }
        self.owned_font_names.deinit(self.allocator);

        // Free current font name
        if (self.current_font_owned) |name| {
            self.allocator.free(name);
        }
    }

    /// Add a font CMap (takes ownership of the CMap)
    pub fn addFontCMap(self: *TextExtractor, font_name: []const u8, cmap_data: *CMap) !void {
        // Store with owned copy of font name
        const owned_name = try self.allocator.dupe(u8, font_name);
        try self.owned_font_names.append(self.allocator, owned_name);
        try self.font_cmaps.put(owned_name, cmap_data);
    }

    /// Get current font's CMap (if any)
    fn getCurrentCMap(self: *const TextExtractor) ?*const CMap {
        if (self.current_font) |font| {
            return self.font_cmaps.get(font);
        }
        return null;
    }

    /// Extract text from decompressed content stream data
    pub fn extract(self: *TextExtractor, data: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        // Operand stack - holds values until an operator consumes them
        var stack = std.ArrayList(Operand).empty;
        defer {
            for (stack.items) |*op| op.deinit(self.allocator);
            stack.deinit(self.allocator);
        }

        var lex = Lexer.init(data);

        while (lex.next()) |token| {
            // Check if this token is an operator (keyword-like)
            if (isOperator(token)) {
                const op = Operator.fromString(token.data);
                try self.executeOperator(op, &stack, &result);

                // Clear stack after operator execution
                for (stack.items) |*operand| operand.deinit(self.allocator);
                stack.clearRetainingCapacity();
            } else {
                // It's an operand - push to stack
                const operand = try parseOperand(&lex, token, self.allocator);
                try stack.append(self.allocator, operand);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn executeOperator(self: *TextExtractor, op: Operator, stack: *std.ArrayList(Operand), result: *std.ArrayList(u8)) !void {
        switch (op) {
            .BeginText => {
                self.in_text_block = true;
                self.text_matrix = .{ 1, 0, 0, 1, 0, 0 };
                self.line_matrix = .{ 1, 0, 0, 1, 0, 0 };
            },

            .EndText => {
                self.in_text_block = false;
            },

            .MoveText => { // Td: tx ty
                if (stack.items.len >= 2) {
                    const ty = stack.items[stack.items.len - 1].asFloat() orelse 0;
                    const tx = stack.items[stack.items.len - 2].asFloat() orelse 0;

                    // Check for line break (significant Y movement)
                    if (self.last_y) |last| {
                        if (@abs(ty) > 0.1 or @abs(self.line_matrix[5] - last) > 5) {
                            try result.append(self.allocator, '\n');
                        }
                    }

                    // Update line matrix
                    self.line_matrix[4] += tx;
                    self.line_matrix[5] += ty;
                    self.text_matrix = self.line_matrix;
                    self.last_y = self.line_matrix[5];
                }
            },

            .MoveTextSetLeading => { // TD: tx ty (also sets TL = -ty)
                if (stack.items.len >= 2) {
                    const ty = stack.items[stack.items.len - 1].asFloat() orelse 0;
                    const tx = stack.items[stack.items.len - 2].asFloat() orelse 0;

                    self.text_leading = -ty;

                    if (self.last_y != null) {
                        try result.append(self.allocator, '\n');
                    }

                    self.line_matrix[4] += tx;
                    self.line_matrix[5] += ty;
                    self.text_matrix = self.line_matrix;
                    self.last_y = self.line_matrix[5];
                }
            },

            .SetTextMatrix => { // Tm: a b c d e f
                if (stack.items.len >= 6) {
                    const f = stack.items[stack.items.len - 1].asFloat() orelse 0;
                    const e = stack.items[stack.items.len - 2].asFloat() orelse 0;
                    const d = stack.items[stack.items.len - 3].asFloat() orelse 1;
                    const c = stack.items[stack.items.len - 4].asFloat() orelse 0;
                    const b = stack.items[stack.items.len - 5].asFloat() orelse 0;
                    const a = stack.items[stack.items.len - 6].asFloat() orelse 1;

                    // Check for line change
                    if (self.last_y) |last| {
                        if (@abs(f - last) > 5) {
                            try result.append(self.allocator, '\n');
                        }
                    }

                    self.text_matrix = .{ a, b, c, d, e, f };
                    self.line_matrix = self.text_matrix;
                    self.last_y = f;
                }
            },

            .MoveToNextLine => { // T*
                try result.append(self.allocator, '\n');
                self.line_matrix[4] = 0;
                self.line_matrix[5] -= self.text_leading;
                self.text_matrix = self.line_matrix;
            },

            .SetTextLeading => { // TL
                if (stack.items.len >= 1) {
                    self.text_leading = stack.items[stack.items.len - 1].asFloat() orelse 0;
                }
            },

            .SetFontSize => { // Tf: /FontName size
                if (stack.items.len >= 2) {
                    const font_operand = &stack.items[stack.items.len - 2];
                    if (font_operand.* == .name) {
                        // Free previous owned font name
                        if (self.current_font_owned) |old| {
                            self.allocator.free(old);
                        }
                        // Make owned copy since operand will be freed
                        self.current_font_owned = self.allocator.dupe(u8, font_operand.name) catch null;
                        self.current_font = self.current_font_owned;
                    }
                }
            },

            .ShowText => { // Tj: (string)
                if (stack.items.len >= 1) {
                    const operand = &stack.items[stack.items.len - 1];
                    try self.appendTextFromOperand(result, operand);
                }
            },

            .ShowTextNextLine => { // ': (string) - move to next line then show
                try result.append(self.allocator, '\n');
                if (stack.items.len >= 1) {
                    const operand = &stack.items[stack.items.len - 1];
                    try self.appendTextFromOperand(result, operand);
                }
            },

            .ShowTextSpacing => { // ": aw ac (string) - set spacing, move, show
                try result.append(self.allocator, '\n');
                if (stack.items.len >= 1) {
                    const operand = &stack.items[stack.items.len - 1];
                    try self.appendTextFromOperand(result, operand);
                }
            },

            .ShowTextArray => { // TJ: [(string) num (string) ...]
                if (stack.items.len >= 1) {
                    const operand = &stack.items[stack.items.len - 1];
                    try self.appendTextFromArray(result, operand);
                }
            },

            else => {
                // Other operators don't affect text extraction directly
            },
        }
    }

    fn appendTextFromOperand(self: *TextExtractor, result: *std.ArrayList(u8), operand: *const Operand) !void {
        const maybe_cmap = self.getCurrentCMap();

        switch (operand.*) {
            .literal_string => |s| {
                // Decode string (handle escapes, encoding)
                const decoded = try decodePdfString(self.allocator, s);
                defer self.allocator.free(decoded);

                if (maybe_cmap) |cmap| {
                    // Apply CMap to decode CID characters
                    try self.applyCMapToText(result, decoded, cmap);
                } else {
                    try result.appendSlice(self.allocator, decoded);
                }
            },
            .hex_string => |h| {
                const decoded = try filters.AsciiHexDecode.decode(self.allocator, h);
                defer self.allocator.free(decoded);

                if (maybe_cmap) |cmap| {
                    try self.applyCMapToText(result, decoded, cmap);
                } else {
                    try result.appendSlice(self.allocator, decoded);
                }
            },
            else => {},
        }
    }

    /// Apply CMap to convert CID codes to Unicode
    fn applyCMapToText(self: *TextExtractor, result: *std.ArrayList(u8), data: []const u8, cmap: *const CMap) !void {
        var buf: [8]u8 = undefined;
        var i: usize = 0;

        while (i < data.len) {
            // Try 2-byte code first (most CID fonts use 2-byte encoding)
            if (i + 1 < data.len) {
                const code16: u32 = (@as(u32, data[i]) << 8) | data[i + 1];
                if (cmap.mapCodeToBuffer(code16, &buf)) |len| {
                    try result.appendSlice(self.allocator, buf[0..len]);
                    i += 2;
                    continue;
                }
            }

            // Try single-byte code
            const code8: u32 = data[i];
            if (cmap.mapCodeToBuffer(code8, &buf)) |len| {
                try result.appendSlice(self.allocator, buf[0..len]);
            } else {
                // No mapping - output as-is if printable, otherwise skip
                if (data[i] >= 0x20 and data[i] < 0x7F) {
                    try result.append(self.allocator, data[i]);
                }
            }
            i += 1;
        }
    }

    fn appendTextFromArray(self: *TextExtractor, result: *std.ArrayList(u8), operand: *const Operand) !void {
        const maybe_cmap = self.getCurrentCMap();

        switch (operand.*) {
            .array => |items| {
                for (items) |*item| {
                    switch (item.*) {
                        .literal_string => |s| {
                            const decoded = try decodePdfString(self.allocator, s);
                            defer self.allocator.free(decoded);

                            if (maybe_cmap) |cmap| {
                                try self.applyCMapToText(result, decoded, cmap);
                            } else {
                                try result.appendSlice(self.allocator, decoded);
                            }
                        },
                        .hex_string => |h| {
                            const decoded = try filters.AsciiHexDecode.decode(self.allocator, h);
                            defer self.allocator.free(decoded);

                            if (maybe_cmap) |cmap| {
                                try self.applyCMapToText(result, decoded, cmap);
                            } else {
                                try result.appendSlice(self.allocator, decoded);
                            }
                        },
                        .number => |n| {
                            // Large negative numbers indicate word spacing
                            if (n < -100) {
                                try result.append(self.allocator, ' ');
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
};

/// Operand types for content stream parsing
pub const Operand = union(enum) {
    number: f64,
    literal_string: []const u8, // Owned copy
    hex_string: []const u8, // Owned copy
    name: []const u8, // Owned copy
    array: []Operand, // Owned array of operands
    boolean: bool,
    null_val,

    pub fn deinit(self: *Operand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal_string => |s| allocator.free(s),
            .hex_string => |s| allocator.free(s),
            .name => |s| allocator.free(s),
            .array => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            else => {},
        }
    }

    pub fn asFloat(self: *const Operand) ?f64 {
        return switch (self.*) {
            .number => |n| n,
            else => null,
        };
    }
};

/// Check if a token represents an operator (not an operand)
fn isOperator(token: Token) bool {
    // Operators are alphabetic keywords (not numbers, not strings, not names starting with /)
    if (token.tag == .name) return false; // /Name is never an operator
    if (token.tag == .number) return false;
    if (token.tag == .literal_string) return false;
    if (token.tag == .hex_string) return false;
    if (token.tag == .array_start) return false;
    if (token.tag == .array_end) return false;
    if (token.tag == .dict_start) return false;
    if (token.tag == .dict_end) return false;

    // Keywords that are operators
    if (token.tag == .keyword_true or token.tag == .keyword_false or token.tag == .keyword_null) {
        return false; // These are operand values
    }

    // Unknown tokens that look like operator names
    if (token.tag == .unknown) {
        // Operators are typically 1-3 alphabetic chars
        if (token.data.len == 0 or token.data.len > 3) return false;
        for (token.data) |c| {
            if (!std.ascii.isAlphabetic(c) and c != '*' and c != '\'' and c != '"') {
                return false;
            }
        }
        return true;
    }

    return false;
}

/// Explicit error set for operand parsing (avoids recursive inference)
const ParseOperandError = error{OutOfMemory};

/// Parse an operand from token stream
fn parseOperand(lex: *Lexer, token: Token, allocator: std.mem.Allocator) ParseOperandError!Operand {
    switch (token.tag) {
        .number => {
            return .{ .number = token.asFloat() orelse @floatFromInt(token.asInt() orelse 0) };
        },
        .literal_string => {
            const content = token.stringContent();
            const copy = try allocator.dupe(u8, content);
            return .{ .literal_string = copy };
        },
        .hex_string => {
            const content = token.hexContent();
            const copy = try allocator.dupe(u8, content);
            return .{ .hex_string = copy };
        },
        .name => {
            const content = token.nameValue();
            const copy = try allocator.dupe(u8, content);
            return .{ .name = copy };
        },
        .array_start => {
            return parseArray(lex, allocator);
        },
        .keyword_true => return .{ .boolean = true },
        .keyword_false => return .{ .boolean = false },
        .keyword_null => return .null_val,
        else => return .null_val,
    }
}

/// Parse array contents
fn parseArray(lex: *Lexer, allocator: std.mem.Allocator) ParseOperandError!Operand {
    var items = std.ArrayList(Operand).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (lex.next()) |token| {
        if (token.tag == .array_end) break;

        const operand = try parseOperand(lex, token, allocator);
        try items.append(allocator, operand);
    }

    return .{ .array = try items.toOwnedSlice(allocator) };
}

/// Decode PDF string (handle escape sequences)
fn decodePdfString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                'b' => try result.append(allocator, 0x08),
                'f' => try result.append(allocator, 0x0c),
                '(' => try result.append(allocator, '('),
                ')' => try result.append(allocator, ')'),
                '\\' => try result.append(allocator, '\\'),
                '0'...'7' => {
                    // Octal escape
                    var val: u8 = raw[i] - '0';
                    if (i + 1 < raw.len and raw[i + 1] >= '0' and raw[i + 1] <= '7') {
                        i += 1;
                        val = val * 8 + (raw[i] - '0');
                        if (i + 1 < raw.len and raw[i + 1] >= '0' and raw[i + 1] <= '7') {
                            i += 1;
                            val = val * 8 + (raw[i] - '0');
                        }
                    }
                    try result.append(allocator, val);
                },
                '\r' => {
                    // Line continuation
                    if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
                },
                '\n' => {}, // Line continuation
                else => try result.append(allocator, raw[i]),
            }
        } else {
            try result.append(allocator, raw[i]);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// === Tests ===

test "decode pdf string escapes" {
    const decoded = try decodePdfString(std.testing.allocator, "Hello\\nWorld");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello\nWorld", decoded);
}

test "decode pdf string octal" {
    const decoded = try decodePdfString(std.testing.allocator, "\\101\\102\\103");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("ABC", decoded);
}

test "text extractor basic" {
    const content = "BT /F1 12 Tf (Hello World) Tj ET";
    var extractor = TextExtractor.init(std.testing.allocator);
    defer extractor.deinit();
    const text = try extractor.extract(content);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
}
