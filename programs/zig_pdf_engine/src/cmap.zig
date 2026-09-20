const std = @import("std");
const Watchdog = @import("test_watchdog.zig").Watchdog;

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

    /// Parse a ToUnicode CMap stream.
    ///
    /// Termination: the stream is consumed through `Scanner.next`, which moves
    /// its cursor forward on every token it returns and returns null only at
    /// the end of the data. Every loop below takes at least one token per
    /// iteration, so the parse is linear in `data.len` whatever the bytes are.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !CMap {
        var cmap = CMap.init(allocator);
        errdefer cmap.deinit();

        var scan = Scanner{ .data = data };
        while (scan.next()) |tok| {
            switch (tok) {
                .word => |w| {
                    if (std.mem.eql(u8, w, "beginbfchar")) {
                        try cmap.parseBfChar(&scan);
                    } else if (std.mem.eql(u8, w, "beginbfrange")) {
                        try cmap.parseBfRange(&scan);
                    }
                },
                else => {},
            }
        }

        return cmap;
    }

    /// Parse bfchar section: <srcCode> <dstUnicode> pairs
    fn parseBfChar(self: *CMap, scan: *Scanner) !void {
        while (scan.next()) |tok| {
            const src = switch (tok) {
                .word => |w| if (std.mem.eql(u8, w, "endbfchar")) return else continue,
                .hex => |h| hexToCode(h) orelse continue,
                else => continue,
            };

            const dst_tok = scan.next() orelse return;
            switch (dst_tok) {
                .word => |w| if (std.mem.eql(u8, w, "endbfchar")) return,
                .hex => |h| try self.putMapping(src, h, 0),
                else => {},
            }
        }
    }

    /// Parse bfrange section: <srcStart> <srcEnd> <dstStart> triples, where the
    /// destination is either one string (the range counts up from it) or an
    /// array holding one string per code.
    fn parseBfRange(self: *CMap, scan: *Scanner) !void {
        while (scan.next()) |tok| {
            const src_start = switch (tok) {
                .word => |w| if (std.mem.eql(u8, w, "endbfrange")) return else continue,
                .hex => |h| hexToCode(h) orelse continue,
                else => continue,
            };

            const end_tok = scan.next() orelse return;
            const src_end = switch (end_tok) {
                .word => |w| if (std.mem.eql(u8, w, "endbfrange")) return else continue,
                .hex => |h| hexToCode(h) orelse continue,
                else => continue,
            };

            const dst_tok = scan.next() orelse return;
            switch (dst_tok) {
                .word => |w| if (std.mem.eql(u8, w, "endbfrange")) return,
                .array_start => {
                    // One destination per code. The array is read to its `]`
                    // however many entries it holds; entries past src_end are
                    // read and dropped.
                    var offset: u32 = 0;
                    while (scan.next()) |item| {
                        switch (item) {
                            .array_end => break,
                            .word => |w| if (std.mem.eql(u8, w, "endbfrange")) return,
                            .hex => |h| {
                                if (src_end >= src_start and offset <= src_end - src_start) {
                                    try self.putMapping(src_start + offset, h, 0);
                                }
                                offset +|= 1;
                            },
                            else => {},
                        }
                    }
                },
                .hex => |h| {
                    if (src_end < src_start) continue;
                    var units: [max_dst_units]u16 = undefined;
                    const n = hexToUtf16(h, &units);
                    if (n == 0) continue;

                    if (singleCodepoint(units[0..n])) |cp| {
                        try self.ranges.append(self.allocator, .{
                            .start = src_start,
                            .end = src_end,
                            .base_unicode = cp,
                        });
                    } else if (src_end - src_start <= 0xFF) {
                        // A multi-character destination (a ligature such as
                        // <00660066>): the last code unit counts up across the
                        // range, which the spec confines to one byte's worth.
                        var offset: u32 = 0;
                        while (offset <= src_end - src_start) : (offset += 1) {
                            try self.putMapping(src_start + offset, h, @intCast(offset));
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Store `code -> dst`, where `dst` is the hex digits of a UTF-16BE string
    /// and `last_unit_offset` is added to its final code unit.
    fn putMapping(self: *CMap, code: u32, dst_hex: []const u8, last_unit_offset: u16) !void {
        var units: [max_dst_units]u16 = undefined;
        const n = hexToUtf16(dst_hex, &units);
        if (n == 0) return;
        units[n - 1] +%= last_unit_offset;

        var utf8: [max_dst_units * 3]u8 = undefined;
        const len = utf16ToUtf8(units[0..n], &utf8);

        const owned = try self.allocator.dupe(u8, utf8[0..len]);
        errdefer self.allocator.free(owned);
        const gop = try self.char_map.getOrPut(code);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = owned;
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
                const unicode = std.math.add(u32, range.base_unicode, code - range.start) catch return null;
                return encodeUtf8(unicode, buffer);
            }
        }

        return null;
    }
};

/// Longest destination string kept per mapping, in UTF-16 code units. Real
/// ToUnicode destinations are one to four units (a ligature); anything longer
/// is cut here.
const max_dst_units = 16;

/// Tokenizer for the PostScript-flavoured CMap syntax.
///
/// Invariant: `next` either returns null with the cursor at the end of the
/// data, or returns a token having moved the cursor forward by at least one
/// byte. A byte no rule claims is returned as a one-byte `other`, never left
/// under the cursor.
const Scanner = struct {
    data: []const u8,
    pos: usize = 0,

    const Tok = union(enum) {
        /// Hex digits between `<` and `>` (or the end of the data), unparsed.
        hex: []const u8,
        array_start,
        array_end,
        /// A run of regular characters: an operator, a number, a name body.
        word: []const u8,
        other,
    };

    fn next(self: *Scanner) ?Tok {
        const data = self.data;
        while (self.pos < data.len) {
            const c = data[self.pos];
            if (isSpace(c)) {
                self.pos += 1;
            } else if (c == '%') {
                while (self.pos < data.len and data[self.pos] != '\n' and data[self.pos] != '\r') self.pos += 1;
            } else break;
        }
        if (self.pos >= data.len) return null;

        const start = self.pos;
        switch (data[start]) {
            '[' => {
                self.pos += 1;
                return .array_start;
            },
            ']' => {
                self.pos += 1;
                return .array_end;
            },
            '<' => {
                if (start + 1 < data.len and data[start + 1] == '<') {
                    self.pos += 2;
                    return .other;
                }
                self.pos += 1;
                while (self.pos < data.len and data[self.pos] != '>') self.pos += 1;
                const digits = data[start + 1 .. self.pos];
                if (self.pos < data.len) self.pos += 1;
                return .{ .hex = digits };
            },
            '(' => {
                // Literal string, as in `/Registry (Adobe)`: skipped whole so
                // its text cannot be mistaken for an operator.
                self.pos += 1;
                var depth: usize = 1;
                while (self.pos < data.len and depth > 0) {
                    const ch = data[self.pos];
                    if (ch == '\\' and self.pos + 1 < data.len) {
                        self.pos += 2;
                        continue;
                    }
                    if (ch == '(') depth += 1;
                    if (ch == ')') depth -= 1;
                    self.pos += 1;
                }
                return .other;
            },
            else => {
                while (self.pos < data.len and !isSpace(data[self.pos]) and !isDelimiter(data[self.pos])) self.pos += 1;
                if (self.pos == start) {
                    self.pos += 1;
                    return .other;
                }
                return .{ .word = data[start..self.pos] };
            },
        }
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0 or c == 0x0c;
    }

    fn isDelimiter(c: u8) bool {
        return switch (c) {
            '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
            else => false,
        };
    }
};

fn hexDigit(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

/// A source character code: one to four bytes of hex, big-endian. Null when the
/// token holds no digits or more than a u32's worth.
fn hexToCode(digits: []const u8) ?u32 {
    var result: u32 = 0;
    var count: u32 = 0;
    for (digits) |c| {
        const d = hexDigit(c) orelse continue;
        if (count == 8) return null;
        result = (result << 4) | d;
        count += 1;
    }
    return if (count > 0) result else null;
}

/// Decode hex digits as big-endian UTF-16 code units. A one-byte value (`<41>`)
/// is taken as that code unit. Returns the number of units written.
fn hexToUtf16(digits: []const u8, out: []u16) usize {
    var n: usize = 0;
    var unit: u16 = 0;
    var nibbles: u32 = 0;
    for (digits) |c| {
        const d = hexDigit(c) orelse continue;
        unit = (unit << 4) | @as(u16, @intCast(d));
        nibbles += 1;
        if (nibbles == 4) {
            if (n == out.len) return n;
            out[n] = unit;
            n += 1;
            unit = 0;
            nibbles = 0;
        }
    }
    if (nibbles > 0 and n < out.len) {
        out[n] = unit;
        n += 1;
    }
    return n;
}

/// The codepoint a UTF-16 string encodes, if it encodes exactly one.
fn singleCodepoint(units: []const u16) ?u32 {
    if (units.len == 1 and !std.unicode.utf16IsHighSurrogate(units[0]) and !std.unicode.utf16IsLowSurrogate(units[0])) {
        return units[0];
    }
    if (units.len == 2 and std.unicode.utf16IsHighSurrogate(units[0]) and std.unicode.utf16IsLowSurrogate(units[1])) {
        return 0x10000 + ((@as(u32, units[0]) - 0xD800) << 10) + (@as(u32, units[1]) - 0xDC00);
    }
    return null;
}

/// UTF-16 to UTF-8. Unpaired surrogates and U+0000 produce no output. `out`
/// needs three bytes per unit.
fn utf16ToUtf8(units: []const u16, out: []u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        var cp: u32 = units[i];
        if (std.unicode.utf16IsHighSurrogate(units[i])) {
            if (i + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[i + 1])) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (@as(u32, units[i + 1]) - 0xDC00);
                i += 1;
            } else continue;
        } else if (std.unicode.utf16IsLowSurrogate(units[i])) {
            continue;
        }
        if (cp == 0) continue;
        len += encodeUtf8(cp, out[len..]) orelse 0;
    }
    return len;
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

// PDF 32000-1:2008 §9.10.3, Example 2. The spec states the results: codes
// <0000>..<005E> map to U+0020..U+007E, <005F>/<0060>/<0061> to the ligature
// spellings "ff"/"fi"/"ffl", and <3A51> to U+2003E through a surrogate pair.
const spec_example =
    \\2 beginbfrange
    \\<0000> <005E> <0020>
    \\<005F> <0061> [<00660066> <00660069> <00660066006C>]
    \\endbfrange
    \\1 beginbfchar
    \\<3A51> <D840DC3E>
    \\endbfchar
;

fn expectMaps(cmap: *const CMap, code: u32, expected: []const u8) !void {
    var buf: [48]u8 = undefined;
    const len = cmap.mapCodeToBuffer(code, &buf) orelse return error.TestExpectedMapping;
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "spec anchor: PDF 32000-1 9.10.3 example 2" {
    const dog = Watchdog.arm(10);
    defer dog.disarm();

    var cmap = try CMap.parse(std.testing.allocator, spec_example);
    defer cmap.deinit();

    try expectMaps(&cmap, 0x0000, " ");
    try expectMaps(&cmap, 0x0021, "A");
    try expectMaps(&cmap, 0x005E, "~");
    try expectMaps(&cmap, 0x005F, "ff");
    try expectMaps(&cmap, 0x0060, "fi");
    try expectMaps(&cmap, 0x0061, "ffl");
    try expectMaps(&cmap, 0x3A51, "\xF0\xA0\x80\xBE"); // U+2003E
    var unused: [8]u8 = undefined;
    try std.testing.expect(cmap.mapCodeToBuffer(0x0062, &unused) == null);
}

// The construct behind 264 of the 629 pdf-text hangs: a bfrange whose array
// holds exactly one entry per code, as Qt and wkhtmltopdf write every ToUnicode
// CMap. See docs/pdf-text-hang-classification.md.
test "bfrange array that exactly fills its range terminates" {
    const dog = Watchdog.arm(10);
    defer dog.disarm();

    const data =
        \\1 beginbfrange
        \\<0000> <0003> [<0000> <0056> <0041> <0054>]
        \\endbfrange
        \\1 beginbfchar
        \\<0010> <0021>
        \\endbfchar
    ;
    var cmap = try CMap.parse(std.testing.allocator, data);
    defer cmap.deinit();

    try expectMaps(&cmap, 0x0001, "V");
    try expectMaps(&cmap, 0x0002, "A");
    try expectMaps(&cmap, 0x0003, "T");
    // The section after the array is still read.
    try expectMaps(&cmap, 0x0010, "!");
}

test "bfrange array longer or shorter than its range" {
    const dog = Watchdog.arm(10);
    defer dog.disarm();

    const data =
        \\2 beginbfrange
        \\<0000> <0001> [<0041> <0042> <0043> <0044>]
        \\<0010> <0013> [<0061>]
        \\endbfrange
    ;
    var cmap = try CMap.parse(std.testing.allocator, data);
    defer cmap.deinit();

    try expectMaps(&cmap, 0x0000, "A");
    try expectMaps(&cmap, 0x0001, "B");
    try std.testing.expect(cmap.mapCode(0x0002) == null);
    try expectMaps(&cmap, 0x0010, "a");
    try std.testing.expect(cmap.mapCode(0x0011) == null);
}

test "every truncation of a CMap terminates" {
    const dog = Watchdog.arm(30);
    defer dog.disarm();

    for (0..spec_example.len + 1) |cut| {
        var cmap = try CMap.parse(std.testing.allocator, spec_example[0..cut]);
        cmap.deinit();
    }
}

test "malformed sections terminate" {
    const dog = Watchdog.arm(10);
    defer dog.disarm();

    const cases = [_][]const u8{
        "beginbfrange ] endbfrange",
        "beginbfrange <00> <01> ] > ) } endbfrange",
        "beginbfrange <00> <01> [<41> <42>",
        "beginbfrange <00> <01> [ [ [ ] endbfrange",
        "beginbfrange <00> <FFFFFFFF> [<41>] endbfrange",
        "beginbfrange <FFFFFFFF> <FFFFFFFF> <10FFFF> endbfrange",
        "beginbfrange <05> <01> <0041> endbfrange",
        "beginbfrange <00> <FFFFFFFF> <00410042> endbfrange",
        "beginbfchar > > > endbfchar",
        "beginbfchar <0001> /space endbfchar",
        "beginbfchar <0001",
        "beginbfchar <> <> endbfchar",
        "beginbfchar <000000000001> <0041> endbfchar",
        "beginbfchar (endbfchar",
        "beginbfchar % endbfchar",
    };
    for (cases) |data| {
        var cmap = try CMap.parse(std.testing.allocator, data);
        cmap.deinit();
    }
}

test "scanner advances on every token, for arbitrary bytes" {
    const dog = Watchdog.arm(60);
    defer dog.disarm();

    // Bytes drawn mostly from the syntax's own alphabet, so delimiters land in
    // every position relative to each other.
    const alphabet = "<>[]()/%{} \n\\0Aaf beginbfrange endbfchar\x00\xff";
    var prng = std.Random.DefaultPrng.init(0x5eed_c0de);
    const rand = prng.random();

    var buf: [96]u8 = undefined;
    for (0..4000) |_| {
        const len = rand.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];

        var scan = Scanner{ .data = buf[0..len] };
        var last = scan.pos;
        while (scan.next()) |_| {
            try std.testing.expect(scan.pos > last);
            last = scan.pos;
        }
        try std.testing.expectEqual(len, scan.pos);

        var cmap = try CMap.parse(std.testing.allocator, buf[0..len]);
        cmap.deinit();
    }
}
