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
//!     <c r="D1" s="2"><v>46259</v></c> ← number in a date style
//!   </row>
//! </sheetData>
//!
//! Rows and cells are placed by their `r` reference: Excel leaves blank rows
//! and cells out of the file, so row 5 can follow row 3. A skipped row is an
//! empty row in `Sheet.rows`, a skipped cell a null. A row with no values
//! (a styled but empty row) is not kept unless a later row needs it as
//! padding, so trailing formatted rows add nothing.

const std = @import("std");
const xml = @import("xml.zig");
const shared_strings_mod = @import("shared_strings.zig");
const SharedStrings = shared_strings_mod.SharedStrings;
const styles_mod = @import("styles.zig");

/// Excel's sheet limits: rows 1..1048576, columns A..XFD.
pub const max_rows: usize = 1_048_576;
pub const max_columns: usize = 16_384;

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

pub const Options = struct {
    /// Cell styles from xl/styles.xml; numbers in a date or time style are
    /// written as ISO 8601 text. Without styles every number stays as stored.
    styles: ?*const styles_mod.Styles = null,
    /// The workbook uses the 1904 date system.
    date1904: bool = false,
};

pub fn parseWorksheet(
    allocator: std.mem.Allocator,
    xml_data: []const u8,
    shared_strings: *const SharedStrings,
) !Sheet {
    return parseWorksheetWith(allocator, xml_data, shared_strings, .{});
}

pub fn parseWorksheetWith(
    allocator: std.mem.Allocator,
    xml_data: []const u8,
    shared_strings: *const SharedStrings,
    options: Options,
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
    var rph_depth: usize = 0;
    var t_start: usize = 0;

    // 0-based index of the row being read, and of the row a row without an
    // `r` attribute would be.
    var row_index: usize = 0;
    var next_row_index: usize = 0;

    var cell_type: CellType = .number;
    var cell_col: usize = 0;
    var cell_style: usize = 0;
    var current_cells: std.ArrayListUnmanaged(?[]const u8) = .empty;
    defer current_cells.deinit(allocator);
    var row_has_value = false;

    var value_text: std.ArrayListUnmanaged(u8) = .empty;
    defer value_text.deinit(allocator);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |e| {
                if (std.mem.eql(u8, e.name, "sheetData")) {
                    in_sheet_data = true;
                } else if (std.mem.eql(u8, e.name, "row") and in_sheet_data) {
                    in_row = true;
                    current_cells.clearRetainingCapacity();
                    row_has_value = false;
                    row_index = next_row_index;
                    if (xml.getAttr(e.attrs, "r")) |r| {
                        const n = std.fmt.parseInt(usize, r, 10) catch 0;
                        if (n >= 1 and n <= max_rows and n - 1 >= next_row_index) row_index = n - 1;
                    }
                    next_row_index = row_index + 1;
                } else if (std.mem.eql(u8, e.name, "c") and in_row) {
                    in_cell = true;
                    value_text.clearRetainingCapacity();

                    // A cell without a usable reference follows the previous one.
                    cell_col = current_cells.items.len;
                    if (xml.getAttr(e.attrs, "r")) |ref| {
                        if (cellColumn(ref)) |col| cell_col = col;
                    }
                    cell_style = if (xml.getAttr(e.attrs, "s")) |s|
                        std.fmt.parseInt(usize, s, 10) catch 0
                    else
                        0;

                    // Parse cell type
                    cell_type = if (xml.getAttr(e.attrs, "t")) |t|
                        parseCellType(t)
                    else
                        .number;
                } else if (std.mem.eql(u8, e.name, "v") and in_cell) {
                    in_value = true;
                } else if (std.mem.eql(u8, e.name, "is") and in_cell) {
                    in_inline_str = true;
                    rph_depth = 0;
                } else if (std.mem.eql(u8, e.name, "rPh") and in_inline_str) {
                    rph_depth += 1;
                } else if (std.mem.eql(u8, e.name, "t") and in_inline_str and rph_depth == 0) {
                    in_inline_t = true;
                    t_start = value_text.items.len;
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name, "sheetData")) {
                    in_sheet_data = false;
                } else if (std.mem.eql(u8, name, "row")) {
                    if (in_row and row_has_value) {
                        // Pad the rows Excel left out, then commit this one.
                        while (rows.items.len < row_index) try rows.append(allocator, &.{});
                        const row = try allocator.dupe(?[]const u8, current_cells.items);
                        errdefer allocator.free(row);
                        try allocated_rows.append(allocator, row);
                        try rows.append(allocator, row);
                    }
                    in_row = false;
                } else if (std.mem.eql(u8, name, "c")) {
                    if (in_cell) {
                        const resolved = try resolveCell(
                            allocator,
                            cell_type,
                            value_text.items,
                            shared_strings,
                            options,
                            cell_style,
                        );
                        if (resolved.owned) {
                            errdefer allocator.free(resolved.value.?);
                            try allocated_strings.append(allocator, resolved.value.?);
                        }

                        // Fill gaps (sparse columns). An empty (styled) cell
                        // past the last value adds nothing to the row.
                        if (resolved.value != null or cell_col < current_cells.items.len) {
                            while (current_cells.items.len <= cell_col) {
                                try current_cells.append(allocator, null);
                            }
                            current_cells.items[cell_col] = resolved.value;
                        }
                        if (resolved.value != null) row_has_value = true;
                    }
                    in_cell = false;
                    in_value = false;
                    in_inline_str = false;
                    in_inline_t = false;
                } else if (std.mem.eql(u8, name, "v")) {
                    in_value = false;
                } else if (std.mem.eql(u8, name, "is")) {
                    in_inline_str = false;
                } else if (std.mem.eql(u8, name, "rPh")) {
                    if (rph_depth > 0) rph_depth -= 1;
                } else if (std.mem.eql(u8, name, "t")) {
                    if (in_inline_t) {
                        const n = shared_strings_mod.unescapeXstring(value_text.items[t_start..]);
                        value_text.items.len = t_start + n;
                    }
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
    number, // default (no t attr), t="n"
    boolean, // t="b"
    error_val, // t="e"
    formula_string, // t="str"
    date_iso, // t="d": an ISO 8601 date stored as text
};

fn parseCellType(t: []const u8) CellType {
    if (std.mem.eql(u8, t, "s")) return .shared_string;
    if (std.mem.eql(u8, t, "inlineStr")) return .inline_string;
    if (std.mem.eql(u8, t, "b")) return .boolean;
    if (std.mem.eql(u8, t, "e")) return .error_val;
    if (std.mem.eql(u8, t, "str")) return .formula_string;
    if (std.mem.eql(u8, t, "d")) return .date_iso;
    return .number;
}

const Resolved = struct {
    value: ?[]const u8,
    /// `value` was allocated here and belongs to the Sheet; otherwise it
    /// points into the shared strings table or static memory.
    owned: bool = false,
};

fn resolveCell(
    allocator: std.mem.Allocator,
    cell_type: CellType,
    raw_value: []const u8,
    shared_strings: *const SharedStrings,
    options: Options,
    style: usize,
) !Resolved {
    if (raw_value.len == 0) return .{ .value = null };

    switch (cell_type) {
        .shared_string => {
            // raw_value is an index into shared strings
            const idx = std.fmt.parseInt(usize, raw_value, 10) catch return .{ .value = null };
            return .{ .value = shared_strings.get(idx) };
        },
        .boolean => {
            return .{ .value = if (std.mem.eql(u8, raw_value, "1")) "true" else "false" };
        },
        .formula_string => {
            const v = try allocator.dupe(u8, raw_value);
            const n = shared_strings_mod.unescapeXstring(v);
            return .{ .value = try shrink(allocator, v, n), .owned = true };
        },
        .number => {
            if (options.styles) |st| {
                const kind = st.kind(style);
                if (kind != .none) {
                    if (std.fmt.parseFloat(f64, raw_value)) |serial| {
                        var buf: [32]u8 = undefined;
                        if (styles_mod.formatSerial(&buf, serial, kind, options.date1904)) |iso| {
                            return .{ .value = try allocator.dupe(u8, iso), .owned = true };
                        }
                    } else |_| {}
                }
            }
            return .{ .value = try allocator.dupe(u8, raw_value), .owned = true };
        },
        // Inline text is already unescaped; error codes and ISO dates are
        // kept as stored.
        .inline_string, .error_val, .date_iso => {
            return .{ .value = try allocator.dupe(u8, raw_value), .owned = true };
        },
    }
}

/// `buf` cut to its first `n` bytes as an allocation of exactly that length
/// (so freeing it later passes the right size). Frees `buf` if it has to copy.
fn shrink(allocator: std.mem.Allocator, buf: []u8, n: usize) ![]u8 {
    if (n == buf.len) return buf;
    if (allocator.resize(buf, n)) return buf[0..n];
    defer allocator.free(buf);
    return allocator.dupe(u8, buf[0..n]);
}

/// 0-based column of a cell reference ("B3" → 1, "AA1" → 26), or null when
/// it has no column letters or names a column past XFD.
pub fn cellColumn(ref: []const u8) ?usize {
    var col: usize = 0;
    var letters: usize = 0;
    for (ref) |c| {
        if (c < 'A' or c > 'Z') break;
        letters += 1;
        if (letters > 3) return null;
        col = col * 26 + (c - 'A' + 1);
    }
    if (letters == 0 or col > max_columns) return null;
    return col - 1;
}

/// Parse column letters from a cell reference like "B3" → 1, "AA1" → 26.
/// A reference without letters, or past XFD, reads as column 0.
pub fn parseCellColumn(ref: []const u8) usize {
    return cellColumn(ref) orelse 0;
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

test "rows land at their r number: blank rows Excel omits are kept as empty rows" {
    const xml_data =
        \\<worksheet><sheetData>
        \\<row r="1"><c r="A1"><v>1</v></c></row>
        \\<row r="3"><c r="B3"><v>3</v></c></row>
        \\<row r="6"><c r="C6" t="inlineStr"><is><t>six</t></is></c></row>
        \\</sheetData></worksheet>
    ;
    var ss = SharedStrings{ .strings = .empty, .allocator = std.testing.allocator };
    defer ss.deinit();
    var sheet = try parseWorksheet(std.testing.allocator, xml_data, &ss);
    defer sheet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), sheet.rows.len);
    try std.testing.expectEqualStrings("1", sheet.rows[0][0].?);
    try std.testing.expectEqual(@as(usize, 0), sheet.rows[1].len);
    try std.testing.expect(sheet.rows[2][0] == null);
    try std.testing.expectEqualStrings("3", sheet.rows[2][1].?);
    try std.testing.expectEqual(@as(usize, 0), sheet.rows[3].len);
    try std.testing.expectEqual(@as(usize, 0), sheet.rows[4].len);
    try std.testing.expectEqualStrings("six", sheet.rows[5][2].?);
}

test "inline rich text keeps a run that is only a space, and skips phonetic runs" {
    const xml_data =
        \\<worksheet><sheetData><row r="1">
        \\<c r="A1" t="inlineStr"><is><r><t>Loft Access:</t></r><r><t xml:space="preserve"> </t></r><r><t>Increase</t></r><rPh sb="0" eb="1"><t>X</t></rPh></is></c>
        \\</row></sheetData></worksheet>
    ;
    var ss = SharedStrings{ .strings = .empty, .allocator = std.testing.allocator };
    defer ss.deinit();
    var sheet = try parseWorksheet(std.testing.allocator, xml_data, &ss);
    defer sheet.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Loft Access: Increase", sheet.rows[0][0].?);
}
