// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Parser for xl/sharedStrings.xml
//!
//! Shared strings are stored as an indexed list of <si> elements.
//! Each <si> contains either:
//!   - Plain text: <si><t>Hello</t></si>
//!   - Rich text:  <si><r><t>Bold</t></r><r><t> Normal</t></r></si>
//! An <si> may also carry phonetic guide runs (<rPh><t>…</t></rPh>), which
//! are reading aids, not part of the string.
//!
//! Cell values with type="s" reference this table by index.

const std = @import("std");
const xml = @import("xml.zig");

pub const SharedStrings = struct {
    strings: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, xml_data: []const u8) !SharedStrings {
        var self = SharedStrings{
            .strings = .empty,
            .allocator = allocator,
        };
        errdefer self.deinit();

        var parser = xml.XmlParser.init(xml_data);
        var in_si = false;
        var in_t = false;
        var rph_depth: usize = 0;
        var t_start: usize = 0;
        var current_text: std.ArrayListUnmanaged(u8) = .empty;
        defer current_text.deinit(allocator);

        while (parser.next()) |event| {
            switch (event) {
                .element_start => |e| {
                    if (std.mem.eql(u8, e.name, "si")) {
                        in_si = true;
                        rph_depth = 0;
                        current_text.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, e.name, "rPh") and in_si) {
                        rph_depth += 1;
                    } else if (std.mem.eql(u8, e.name, "t") and in_si and rph_depth == 0) {
                        in_t = true;
                        t_start = current_text.items.len;
                    }
                },
                .element_end => |name| {
                    if (std.mem.eql(u8, name, "t")) {
                        if (in_t) {
                            const n = unescapeXstring(current_text.items[t_start..]);
                            current_text.items.len = t_start + n;
                        }
                        in_t = false;
                    } else if (std.mem.eql(u8, name, "rPh")) {
                        if (rph_depth > 0) rph_depth -= 1;
                    } else if (std.mem.eql(u8, name, "si")) {
                        // Store the accumulated text for this string item
                        const text = try allocator.dupe(u8, current_text.items);
                        errdefer allocator.free(text);
                        try self.strings.append(allocator, text);
                        in_si = false;
                    }
                },
                .text => |text| {
                    if (in_t and in_si) {
                        try current_text.appendSlice(allocator, text);
                    }
                },
            }
        }

        return self;
    }

    pub fn get(self: *const SharedStrings, index: usize) ?[]const u8 {
        if (index >= self.strings.items.len) return null;
        return self.strings.items[index];
    }

    pub fn count(self: *const SharedStrings) usize {
        return self.strings.items.len;
    }

    pub fn deinit(self: *SharedStrings) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
    }
};

/// Decode ST_Xstring escapes in place (ECMA-376 Part 1, 22.9.2.19): `_xHHHH_`
/// is the UTF-16 code unit HHHH, which is how Excel stores characters XML
/// cannot carry (`_x000D_` is a carriage return); `_x005F_` is an
/// underscore, so `_x005F_x000D_` is the literal text `_x000D_`. A surrogate
/// pair written as two escapes becomes one character; a lone surrogate is
/// kept as written. Returns the new length (decoding never grows text).
pub fn unescapeXstring(buf: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (escapeUnit(buf[i..])) |unit| {
            var cp: u21 = unit;
            var used: usize = 7;
            var ok = true;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                const low = escapeUnit(buf[i + 7 ..]) orelse 0;
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    cp = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
                    used = 14;
                } else ok = false;
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) ok = false;
            var enc: [4]u8 = undefined;
            if (ok) if (std.unicode.utf8Encode(cp, &enc)) |n| {
                @memcpy(buf[out .. out + n], enc[0..n]);
                out += n;
                i += used;
                continue;
            } else |_| {};
        }
        buf[out] = buf[i];
        out += 1;
        i += 1;
    }
    return out;
}

/// The code unit of an `_xHHHH_` escape at the start of `s`, if there is one.
fn escapeUnit(s: []const u8) ?u16 {
    if (s.len < 7 or s[0] != '_' or s[1] != 'x' or s[6] != '_') return null;
    for (s[2..6]) |d| if (!std.ascii.isHex(d)) return null;
    return std.fmt.parseInt(u16, s[2..6], 16) catch null;
}

test "parse shared strings" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <si><t>Hello</t></si>
        \\  <si><t>World</t></si>
        \\  <si><r><t>Bold</t></r><r><t> Normal</t></r></si>
        \\</sst>
    ;

    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();

    try std.testing.expectEqual(@as(usize, 3), ss.count());
    try std.testing.expectEqualStrings("Hello", ss.get(0).?);
    try std.testing.expectEqualStrings("World", ss.get(1).?);
    try std.testing.expectEqualStrings("Bold Normal", ss.get(2).?);
    try std.testing.expect(ss.get(3) == null);
}

test "shared strings - string deduplication lookup" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <si><t>Admin</t></si>
        \\  <si><t>User</t></si>
        \\  <si><t>Guest</t></si>
        \\  <si><t>Admin</t></si>
        \\</sst>
    ;

    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();

    // Verify all strings are stored (deduplication happens at generation time, not parse time)
    try std.testing.expectEqual(@as(usize, 4), ss.count());
    try std.testing.expectEqualStrings("Admin", ss.get(0).?);
    try std.testing.expectEqualStrings("User", ss.get(1).?);
    try std.testing.expectEqualStrings("Guest", ss.get(2).?);
    try std.testing.expectEqualStrings("Admin", ss.get(3).?);
}

test "shared strings - empty lookup" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\</sst>
    ;

    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();

    try std.testing.expectEqual(@as(usize, 0), ss.count());
    try std.testing.expect(ss.get(0) == null);
}

test "shared strings - rich text formatting" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <si>
        \\    <r><t>Red </t></r>
        \\    <r><t>Green </t></r>
        \\    <r><t>Blue</t></r>
        \\  </si>
        \\</sst>
    ;

    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();

    try std.testing.expectEqual(@as(usize, 1), ss.count());
    try std.testing.expectEqualStrings("Red Green Blue", ss.get(0).?);
}

test "shared strings - a rich-text run holding only a space is kept" {
    const xml_data =
        \\<sst><si><r><rPr><b/></rPr><t>Loft Access:</t></r><r><t xml:space="preserve"> </t></r><r><t>Increase</t></r></si></sst>
    ;
    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();
    try std.testing.expectEqualStrings("Loft Access: Increase", ss.get(0).?);
}

test "shared strings - line ends, character references and _xHHHH_ escapes" {
    const xml_data = "<sst>" ++
        "<si><t>one\r\ntwo\rthree</t></si>" ++ // XML end-of-line handling: CRLF and CR read as LF
        "<si><t>a&#10;b&#x2014;c&#13;</t></si>" ++ // character references are taken literally
        "<si><t>x_x000D_y_x005F_x000D_z</t></si>" ++ // ST_Xstring: _x000D_ is CR, _x005F_ an underscore
        "<si><t>Base</t><rPh sb=\"0\" eb=\"4\"><t>PHON</t></rPh></si>" ++ // phonetic guide text is not cell text
        "</sst>";
    var ss = try SharedStrings.parse(std.testing.allocator, xml_data);
    defer ss.deinit();
    try std.testing.expectEqualStrings("one\ntwo\nthree", ss.get(0).?);
    try std.testing.expectEqualStrings("a\nb\xe2\x80\x94c\r", ss.get(1).?);
    try std.testing.expectEqualStrings("x\ry_x000D_z", ss.get(2).?);
    try std.testing.expectEqualStrings("Base", ss.get(3).?);
}
