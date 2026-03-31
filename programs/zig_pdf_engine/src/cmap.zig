const std = @import("std");

/// ToUnicode CMap parser for PDF text extraction
/// Maps CID/glyph codes to Unicode codepoints
pub const CMap = struct {
    allocator: std.mem.Allocator,

    // Character mappings: CID code -> Unicode codepoint(s)
    // Key is the source code (1-4 bytes big-endian), value is Unicode string
    char_map: std.AutoHashMap(u32, []const u8),

    // Range mappings: (start, end) -> base_unicode
    ranges: std.ArrayList(Range),

    const Range = struct {
        start: u32,
        end: u32,
        base_unicode: u32,
    };

    pub fn init(allocator: std.mem.Allocator) CMap {
        return .{
            .allocator = allocator,
            .char_map = std.AutoHashMap(u32, []const u8).init(allocator),
            .ranges = std.ArrayList(Range).empty,
        };
    }

    pub fn deinit(self: *CMap) void {
        var iter = self.char_map.valueIterator();
        while (iter.next()) |value| {
            self.allocator.free(value.*);
        }
        self.char_map.deinit();
        self.ranges.deinit(self.allocator);
    }

    /// Parse a ToUnicode CMap stream
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !CMap {
        var cmap = CMap.init(allocator);
        errdefer cmap.deinit();

        var i: usize = 0;
        while (i < data.len) {
            // Look for beginbfchar
            if (findSequence(data, i, "beginbfchar")) |pos| {
                i = pos + 11; // Skip "beginbfchar"
                try cmap.parseBfChar(data, &i);
                continue;
            }

            // Look for beginbfrange
            if (findSequence(data, i, "beginbfrange")) |pos| {
                i = pos + 12; // Skip "beginbfrange"
                try cmap.parseBfRange(data, &i);
                continue;
            }

            i += 1;
        }

        return cmap;
    }

    /// Parse bfchar section: <srcCode> <dstUnicode> pairs
    fn parseBfChar(self: *CMap, data: []const u8, pos: *usize) !void {
        while (pos.* < data.len) {
            skipWhitespace(data, pos);

            // Check for end marker
            if (checkSequence(data, pos.*, "endbfchar")) {
                pos.* += 9;
                return;
            }

            // Parse source code <XX> or <XXXX>
            const src = parseHexToken(data, pos) orelse continue;
            skipWhitespace(data, pos);

            // Parse destination Unicode <XXXX>
            const dst_start = pos.*;
            const dst = parseHexToken(data, pos) orelse continue;

            // Convert destination to UTF-8
            const utf8 = try hexToUtf8(self.allocator, dst);

            // Store mapping
            try self.char_map.put(src, utf8);
            _ = dst_start;
        }
    }

    /// Parse bfrange section: <srcStart> <srcEnd> <dstStart> triples
    fn parseBfRange(self: *CMap, data: []const u8, pos: *usize) !void {
        while (pos.* < data.len) {
            skipWhitespace(data, pos);

            // Check for end marker
            if (checkSequence(data, pos.*, "endbfrange")) {
                pos.* += 10;
                return;
            }

            // Parse source start <XX>
            const src_start = parseHexToken(data, pos) orelse continue;
            skipWhitespace(data, pos);

            // Parse source end <XX>
            const src_end = parseHexToken(data, pos) orelse continue;
            skipWhitespace(data, pos);

            // Check if destination is array or single value
            if (pos.* < data.len and data[pos.*] == '[') {
                // Array of individual mappings - expand inline
                pos.* += 1;
                var code = src_start;
                while (code <= src_end and pos.* < data.len) {
                    skipWhitespace(data, pos);
                    if (pos.* < data.len and data[pos.*] == ']') {
                        pos.* += 1;
                        break;
                    }
                    const dst = parseHexToken(data, pos) orelse break;
                    const utf8 = try hexToUtf8(self.allocator, dst);
                    try self.char_map.put(code, utf8);
                    code += 1;
                }
            } else {
                // Single base value - store as range
                const dst_base = parseHexToken(data, pos) orelse continue;
                try self.ranges.append(self.allocator, .{
                    .start = src_start,
                    .end = src_end,
                    .base_unicode = dst_base,
                });
            }
        }
    }

    /// Map a character code to Unicode (returns UTF-8 bytes)
    pub fn mapCode(self: *const CMap, code: u32) ?[]const u8 {
        // Check direct mappings first
        if (self.char_map.get(code)) |mapped| {
            return mapped;
        }

        // Check ranges
        for (self.ranges.items) |range| {
            if (code >= range.start and code <= range.end) {
                // This returns a codepoint, need to convert inline
                // For now, caller handles this case
                return null;
            }
        }

        return null;
    }

    /// Map code with range support, writing result to buffer
    /// Returns number of bytes written, or null if no mapping
    pub fn mapCodeToBuffer(self: *const CMap, code: u32, buffer: []u8) ?usize {
        // Check direct mappings first
        if (self.char_map.get(code)) |mapped| {
            if (mapped.len <= buffer.len) {
                @memcpy(buffer[0..mapped.len], mapped);
                return mapped.len;
            }
            return null;
        }

        // Check ranges
        for (self.ranges.items) |range| {
            if (code >= range.start and code <= range.end) {
                const unicode = range.base_unicode + (code - range.start);
                return encodeUtf8(unicode, buffer);
            }
        }

        return null;
    }
};

/// Find a sequence in data starting from pos
fn findSequence(data: []const u8, start: usize, needle: []const u8) ?usize {
    if (start + needle.len > data.len) return null;
    const remaining = data[start..];
    const found = std.mem.indexOf(u8, remaining, needle);
    if (found) |offset| {
        return start + offset;
    }
    return null;
}

/// Check if sequence matches at exact position
fn checkSequence(data: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > data.len) return false;
    return std.mem.eql(u8, data[pos..][0..needle.len], needle);
}

/// Skip whitespace characters
fn skipWhitespace(data: []const u8, pos: *usize) void {
    while (pos.* < data.len) {
        const c = data[pos.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pos.* += 1;
        } else {
            break;
        }
    }
}

/// Parse a hex token <XXXX> and return as u32
fn parseHexToken(data: []const u8, pos: *usize) ?u32 {
    skipWhitespace(data, pos);

    if (pos.* >= data.len or data[pos.*] != '<') return null;
    pos.* += 1;

    var result: u32 = 0;
    var digit_count: u32 = 0;

    while (pos.* < data.len and data[pos.*] != '>') {
        const c = data[pos.*];
        const digit = hexDigit(c) orelse {
            pos.* += 1;
            continue;
        };
        result = (result << 4) | digit;
        digit_count += 1;
        pos.* += 1;
    }

    if (pos.* < data.len and data[pos.*] == '>') {
        pos.* += 1;
    }

    return if (digit_count > 0) result else null;
}

fn hexDigit(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

/// Convert hex string value to UTF-8
fn hexToUtf8(allocator: std.mem.Allocator, value: u32) ![]const u8 {
    var buf: [8]u8 = undefined;
    const len = encodeUtf8(value, &buf) orelse {
        // Invalid codepoint - return empty
        return try allocator.dupe(u8, "");
    };
    return try allocator.dupe(u8, buf[0..len]);
}

/// Encode a Unicode codepoint as UTF-8
fn encodeUtf8(codepoint: u32, buffer: []u8) ?usize {
    if (codepoint < 0x80) {
        if (buffer.len < 1) return null;
        buffer[0] = @intCast(codepoint);
        return 1;
    } else if (codepoint < 0x800) {
        if (buffer.len < 2) return null;
        buffer[0] = @intCast(0xC0 | (codepoint >> 6));
        buffer[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    } else if (codepoint < 0x10000) {
        if (buffer.len < 3) return null;
        buffer[0] = @intCast(0xE0 | (codepoint >> 12));
        buffer[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buffer[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    } else if (codepoint < 0x110000) {
        if (buffer.len < 4) return null;
        buffer[0] = @intCast(0xF0 | (codepoint >> 18));
        buffer[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
        buffer[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buffer[3] = @intCast(0x80 | (codepoint & 0x3F));
        return 4;
    }
    return null;
}

// === Tests ===

test "parse simple bfchar" {
    const cmap_data =
        \\1 beginbfchar
        \\<001C> <0061>
        \\endbfchar
    ;

    var cmap = try CMap.parse(std.testing.allocator, cmap_data);
    defer cmap.deinit();

    const mapped = cmap.mapCode(0x1C);
    try std.testing.expect(mapped != null);
    try std.testing.expectEqualStrings("a", mapped.?);
}

test "parse multiple bfchar" {
    const cmap_data =
        \\3 beginbfchar
        \\<0021> <0040>
        \\<0022> <0042>
        \\<0023> <0062>
        \\endbfchar
    ;

    var cmap = try CMap.parse(std.testing.allocator, cmap_data);
    defer cmap.deinit();

    try std.testing.expectEqualStrings("@", cmap.mapCode(0x21).?);
    try std.testing.expectEqualStrings("B", cmap.mapCode(0x22).?);
    try std.testing.expectEqualStrings("b", cmap.mapCode(0x23).?);
}

test "parse bfrange" {
    const cmap_data =
        \\1 beginbfrange
        \\<0000> <0002> <0041>
        \\endbfrange
    ;

    var cmap = try CMap.parse(std.testing.allocator, cmap_data);
    defer cmap.deinit();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), cmap.mapCodeToBuffer(0x00, &buf).?);
    try std.testing.expectEqualStrings("A", buf[0..1]);

    try std.testing.expectEqual(@as(usize, 1), cmap.mapCodeToBuffer(0x01, &buf).?);
    try std.testing.expectEqualStrings("B", buf[0..1]);

    try std.testing.expectEqual(@as(usize, 1), cmap.mapCodeToBuffer(0x02, &buf).?);
    try std.testing.expectEqualStrings("C", buf[0..1]);
}

test "utf8 encoding" {
    var buf: [8]u8 = undefined;

    // ASCII
    try std.testing.expectEqual(@as(usize, 1), encodeUtf8(0x41, &buf).?);
    try std.testing.expectEqualStrings("A", buf[0..1]);

    // 2-byte (e.g., é = U+00E9)
    try std.testing.expectEqual(@as(usize, 2), encodeUtf8(0xE9, &buf).?);
    try std.testing.expectEqualStrings("é", buf[0..2]);

    // 3-byte (e.g., € = U+20AC)
    try std.testing.expectEqual(@as(usize, 3), encodeUtf8(0x20AC, &buf).?);
    try std.testing.expectEqualStrings("€", buf[0..3]);
}
