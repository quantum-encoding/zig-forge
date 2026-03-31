// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Parser for xl/worksheets/sheetN.xml
//!
//! Extracts cell data from worksheet XML:
//! <sheetData>
//!   <row r="1">
//!     <c r="A1" t="s"><v>0</v></c>    ← shared string index
//!     <c r="B1"><v>42.5</v></c>        ← number
//!     <c r="C1" t="inlineStr"><is><t>Hello</t></is></c>
//!   </row>
//! </sheetData>

const std = @import("std");
const xml = @import("xml.zig");
const SharedStrings = @import("shared_strings.zig").SharedStrings;

pub const Sheet = struct {
    rows: []const []const ?[]const u8,
    allocator: std.mem.Allocator,
    allocated_strings: std.ArrayListUnmanaged([]const u8),
    allocated_rows: std.ArrayListUnmanaged([]const ?[]const u8),

    pub fn deinit(self: *Sheet, allocator: std.mem.Allocator) void {
        for (self.allocated_strings.items) |s| {
            allocator.free(s);
        }
        self.allocated_strings.deinit(allocator);
        for (self.allocated_rows.items) |row| {
            allocator.free(row);
        }
        self.allocated_rows.deinit(allocator);
        allocator.free(self.rows);
    }
};

pub fn parseWorksheet(
    allocator: std.mem.Allocator,
    xml_data: []const u8,
    shared_strings: *const SharedStrings,
) !Sheet {
    var rows: std.ArrayListUnmanaged([]const ?[]const u8) = .empty;
    defer rows.deinit(allocator);

    var allocated_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (allocated_strings.items) |s| allocator.free(s);
        allocated_strings.deinit(allocator);
    }

    var allocated_rows: std.ArrayListUnmanaged([]const ?[]const u8) = .empty;
    errdefer {
        for (allocated_rows.items) |r| allocator.free(r);
        allocated_rows.deinit(allocator);
    }

    var parser = xml.XmlParser.init(xml_data);

    // State
    var in_sheet_data = false;
    var in_row = false;
    var in_cell = false;
    var in_value = false;
    var in_inline_str = false;
    var in_inline_t = false;

    var cell_type: CellType = .number;
    var cell_col: usize = 0;
    var current_cells: std.ArrayListUnmanaged(?[]const u8) = .empty;
    defer current_cells.deinit(allocator);

    var value_text: std.ArrayListUnmanaged(u8) = .empty;
    defer value_text.deinit(allocator);

    var max_cols: usize = 0;

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |e| {
                if (std.mem.eql(u8, e.name, "sheetData")) {
                    in_sheet_data = true;
                } else if (std.mem.eql(u8, e.name, "row") and in_sheet_data) {
                    in_row = true;
                    current_cells.clearRetainingCapacity();
                } else if (std.mem.eql(u8, e.name, "c") and in_row) {
                    in_cell = true;
                    value_text.clearRetainingCapacity();

                    // Parse cell reference for column
                    if (xml.getAttr(e.attrs, "r")) |ref| {
                        cell_col = parseCellColumn(ref);
                    }

                    // Parse cell type
                    cell_type = if (xml.getAttr(e.attrs, "t")) |t|
                        parseCellType(t)
                    else
                        .number;
                } else if (std.mem.eql(u8, e.name, "v") and in_cell) {
                    in_value = true;
                } else if (std.mem.eql(u8, e.name, "is") and in_cell) {
                    in_inline_str = true;
                } else if (std.mem.eql(u8, e.name, "t") and in_inline_str) {
                    in_inline_t = true;
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name, "sheetData")) {
                    in_sheet_data = false;
                } else if (std.mem.eql(u8, name, "row")) {
                    if (in_row) {
                        // Commit row
                        const row = try allocator.dupe(?[]const u8, current_cells.items);
                        try allocated_rows.append(allocator, row);
                        try rows.append(allocator, row);
                        if (current_cells.items.len > max_cols) {
                            max_cols = current_cells.items.len;
                        }
                    }
                    in_row = false;
                } else if (std.mem.eql(u8, name, "c")) {
                    if (in_cell) {
                        // Resolve cell value
                        const resolved = try resolveCell(
                            allocator,
                            cell_type,
                            value_text.items,
                            shared_strings,
                        );

                        // Fill gaps (sparse columns)
                        while (current_cells.items.len < cell_col) {
                            try current_cells.append(allocator, null);
                        }

                        if (resolved) |v| {
                            // Track if we allocated a new string
                            if (!isSharedStringRef(v, shared_strings)) {
                                try allocated_strings.append(allocator, v);
                            }
                        }
                        try current_cells.append(allocator, resolved);
                    }
                    in_cell = false;
                    in_value = false;
                    in_inline_str = false;
                    in_inline_t = false;
                } else if (std.mem.eql(u8, name, "v")) {
                    in_value = false;
                } else if (std.mem.eql(u8, name, "is")) {
                    in_inline_str = false;
                } else if (std.mem.eql(u8, name, "t")) {
                    in_inline_t = false;
                }
            },
            .text => |text| {
                if (in_value and in_cell) {
                    try value_text.appendSlice(allocator, text);
                } else if (in_inline_t and in_inline_str and in_cell) {
                    try value_text.appendSlice(allocator, text);
                }
            },
        }
    }

    return .{
        .rows = try allocator.dupe([]const ?[]const u8, rows.items),
        .allocator = allocator,
        .allocated_strings = allocated_strings,
        .allocated_rows = allocated_rows,
    };
}

const CellType = enum {
    shared_string, // t="s"
    inline_string, // t="inlineStr"
    number, // default (no t attr)
    boolean, // t="b"
    error_val, // t="e"
    formula_string, // t="str"
};

fn parseCellType(t: []const u8) CellType {
    if (std.mem.eql(u8, t, "s")) return .shared_string;
    if (std.mem.eql(u8, t, "inlineStr")) return .inline_string;
    if (std.mem.eql(u8, t, "b")) return .boolean;
    if (std.mem.eql(u8, t, "e")) return .error_val;
    if (std.mem.eql(u8, t, "str")) return .formula_string;
    return .number;
}

fn resolveCell(
    allocator: std.mem.Allocator,
    cell_type: CellType,
    raw_value: []const u8,
    shared_strings: *const SharedStrings,
) !?[]const u8 {
    if (raw_value.len == 0 and cell_type != .inline_string) return null;

    switch (cell_type) {
        .shared_string => {
            // raw_value is an index into shared strings
            const idx = std.fmt.parseInt(usize, raw_value, 10) catch return null;
            // Return reference to shared string (not a copy)
            return shared_strings.get(idx);
        },
        .inline_string => {
            // raw_value is the inline text
            if (raw_value.len == 0) return null;
            return try allocator.dupe(u8, raw_value);
        },
        .boolean => {
            return if (std.mem.eql(u8, raw_value, "1")) "true" else "false";
        },
        .number, .formula_string => {
            // Return the raw numeric or formula result string
            return try allocator.dupe(u8, raw_value);
        },
        .error_val => {
            return try allocator.dupe(u8, raw_value);
        },
    }
}

fn isSharedStringRef(value: []const u8, shared_strings: *const SharedStrings) bool {
    // Check if this pointer belongs to the shared strings table
    for (shared_strings.strings.items) |ss| {
        if (value.ptr == ss.ptr) return true;
    }
    // Also check static strings
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return true;
    return false;
}

/// Parse column letters from a cell reference like "B3" → 1, "AA1" → 26
pub fn parseCellColumn(ref: []const u8) usize {
    var col: usize = 0;
    for (ref) |c| {
        if (c >= 'A' and c <= 'Z') {
            col = col * 26 + (c - 'A' + 1);
        } else {
            break;
        }
    }
    if (col > 0) col -= 1; // Convert 1-based to 0-based
    return col;
}

test "parseCellColumn" {
    try std.testing.expectEqual(@as(usize, 0), parseCellColumn("A1"));
    try std.testing.expectEqual(@as(usize, 1), parseCellColumn("B3"));
    try std.testing.expectEqual(@as(usize, 25), parseCellColumn("Z1"));
    try std.testing.expectEqual(@as(usize, 26), parseCellColumn("AA1"));
    try std.testing.expectEqual(@as(usize, 27), parseCellColumn("AB1"));
    try std.testing.expectEqual(@as(usize, 701), parseCellColumn("ZZ1"));
}

test "parse simple worksheet" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <sheetData>
        \\    <row r="1">
        \\      <c r="A1" t="s"><v>0</v></c>
        \\      <c r="B1" t="s"><v>1</v></c>
        \\    </row>
        \\    <row r="2">
        \\      <c r="A2"><v>42.5</v></c>
        \\      <c r="B2"><v>100</v></c>
        \\    </row>
        \\  </sheetData>
        \\</worksheet>
    ;

    var ss = try @import("shared_strings.zig").SharedStrings.parse(
        std.testing.allocator,
        \\<?xml version="1.0"?><sst><si><t>Name</t></si><si><t>Value</t></si></sst>
    );
    defer ss.deinit();

    var sheet = try parseWorksheet(std.testing.allocator, xml_data, &ss);
    defer sheet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), sheet.rows.len);
    try std.testing.expectEqualStrings("Name", sheet.rows[0][0].?);
    try std.testing.expectEqualStrings("Value", sheet.rows[0][1].?);
    try std.testing.expectEqualStrings("42.5", sheet.rows[1][0].?);
    try std.testing.expectEqualStrings("100", sheet.rows[1][1].?);
}

test "cell value types - string, number, boolean" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <sheetData>
        \\    <row r="1">
        \\      <c r="A1" t="s"><v>0</v></c>
        \\      <c r="B1"><v>3.14</v></c>
        \\      <c r="C1" t="b"><v>1</v></c>
        \\      <c r="D1" t="inlineStr"><is><t>Inline</t></is></c>
        \\    </row>
        \\  </sheetData>
        \\</worksheet>
    ;

    var ss = try @import("shared_strings.zig").SharedStrings.parse(
        std.testing.allocator,
        \\<?xml version="1.0"?><sst><si><t>Hello</t></si></sst>
    );
    defer ss.deinit();

    var sheet = try parseWorksheet(std.testing.allocator, xml_data, &ss);
    defer sheet.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello", sheet.rows[0][0].?);     // shared string
    try std.testing.expectEqualStrings("3.14", sheet.rows[0][1].?);      // number
    try std.testing.expectEqualStrings("true", sheet.rows[0][2].?);      // boolean
    try std.testing.expectEqualStrings("Inline", sheet.rows[0][3].?);    // inline string
}

test "sparse cells - null values" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <sheetData>
        \\    <row r="1">
        \\      <c r="A1"><v>1</v></c>
        \\      <c r="C1"><v>3</v></c>
        \\    </row>
        \\  </sheetData>
        \\</worksheet>
    ;

    var ss = try @import("shared_strings.zig").SharedStrings.parse(
        std.testing.allocator,
        \\<?xml version="1.0"?><sst></sst>
    );
    defer ss.deinit();

    var sheet = try parseWorksheet(std.testing.allocator, xml_data, &ss);
    defer sheet.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("1", sheet.rows[0][0].?);
    try std.testing.expect(sheet.rows[0][1] == null);  // B1 is empty
    try std.testing.expectEqualStrings("3", sheet.rows[0][2].?);
}

test "column letter conversion A-Z" {
    try std.testing.expectEqual(@as(usize, 0), parseCellColumn("A"));
    try std.testing.expectEqual(@as(usize, 1), parseCellColumn("B"));
    try std.testing.expectEqual(@as(usize, 25), parseCellColumn("Z"));
}

test "column letter conversion AA and beyond" {
    try std.testing.expectEqual(@as(usize, 26), parseCellColumn("AA"));
    try std.testing.expectEqual(@as(usize, 27), parseCellColumn("AB"));
    try std.testing.expectEqual(@as(usize, 52), parseCellColumn("BA"));
    try std.testing.expectEqual(@as(usize, 701), parseCellColumn("ZZ"));
    try std.testing.expectEqual(@as(usize, 702), parseCellColumn("AAA"));
}
