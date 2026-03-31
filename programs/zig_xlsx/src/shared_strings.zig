// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Parser for xl/sharedStrings.xml
//!
//! Shared strings are stored as an indexed list of <si> elements.
//! Each <si> contains either:
//!   - Plain text: <si><t>Hello</t></si>
//!   - Rich text:  <si><r><t>Bold</t></r><r><t> Normal</t></r></si>
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

        var parser = xml.XmlParser.init(xml_data);
        var in_si = false;
        var in_t = false;
        var current_text: std.ArrayListUnmanaged(u8) = .empty;
        defer current_text.deinit(allocator);

        while (parser.next()) |event| {
            switch (event) {
                .element_start => |e| {
                    if (std.mem.eql(u8, e.name, "si")) {
                        in_si = true;
                        current_text.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, e.name, "t") and in_si) {
                        in_t = true;
                    }
                },
                .element_end => |name| {
                    if (std.mem.eql(u8, name, "t")) {
                        in_t = false;
                    } else if (std.mem.eql(u8, name, "si")) {
                        // Store the accumulated text for this string item
                        const text = try allocator.dupe(u8, current_text.items);
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
