//! XLSX Parser — Excel spreadsheet to CSV/Markdown converter
//!
//! Parses .xlsx files (ZIP of XML) and outputs CSV or Markdown table format.
//! Supports: shared strings, inline numbers, formula results, multi-sheet.

const std = @import("std");
const xml = @import("xml.zig");
const zip = @import("zip.zig");

pub const Cell = struct {
    col: u16, // 0-based column index
    row: u32, // 1-based row number
    value: []const u8, // resolved text value
};

pub const Sheet = struct {
    name: []const u8,
    cells: []Cell,
    max_col: u16,
    max_row: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sheet) void {
        for (self.cells) |cell| {
            self.allocator.free(cell.value);
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.name);
    }

    /// Get cell value at (col, row). Returns empty string if not found.
    pub fn getCell(self: *const Sheet, col: u16, row: u32) []const u8 {
        for (self.cells) |cell| {
            if (cell.col == col and cell.row == row) return cell.value;
        }
        return "";
    }
};

pub const Workbook = struct {
    sheets: []Sheet,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Workbook) void {
        for (self.sheets) |*sheet| {
            var s = sheet.*;
            s.deinit();
        }
        self.allocator.free(self.sheets);
    }
};

/// Parse an XLSX file from a ZIP archive
pub fn parseXlsx(allocator: std.mem.Allocator, archive: *zip.ZipArchive) !Workbook {
    // 1. Parse shared strings
    const shared_strings = parseSharedStrings(allocator, archive) catch &[_][]const u8{};

    // 2. Parse sheet names from workbook.xml
    const sheet_names = parseWorkbook(allocator, archive) catch &[_][]const u8{};

    // 3. Parse each worksheet
    var sheets: std.ArrayListUnmanaged(Sheet) = .empty;

    var sheet_idx: u16 = 1;
    while (sheet_idx <= 20) : (sheet_idx += 1) { // Max 20 sheets
        var path_buf: [64]u8 = undefined;
        const sheet_path = std.fmt.bufPrint(&path_buf, "xl/worksheets/sheet{d}.xml", .{sheet_idx}) catch break;

        const sheet_entry = archive.findEntry(sheet_path) orelse break;
        const sheet_data = archive.extract(sheet_entry) catch break;
        defer allocator.free(sheet_data);

        const name = if (sheet_idx - 1 < sheet_names.len)
            try allocator.dupe(u8, sheet_names[sheet_idx - 1])
        else
            try std.fmt.allocPrint(allocator, "Sheet{d}", .{sheet_idx});

        const sheet = try parseSheet(allocator, sheet_data, shared_strings, name);
        try sheets.append(allocator, sheet);
    }

    // Cleanup shared strings
    for (shared_strings) |s| allocator.free(s);
    if (shared_strings.len > 0) allocator.free(shared_strings);

    for (sheet_names) |n| allocator.free(n);
    if (sheet_names.len > 0) allocator.free(sheet_names);

    return Workbook{
        .sheets = try sheets.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Generate CSV from a sheet
pub fn sheetToCsv(allocator: std.mem.Allocator, sheet: *const Sheet) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var row: u32 = 1;
    while (row <= sheet.max_row) : (row += 1) {
        var col: u16 = 0;
        while (col <= sheet.max_col) : (col += 1) {
            if (col > 0) try buf.appendSlice(allocator, ",");
            const val = sheet.getCell(col, row);
            // CSV escape: quote if contains comma, quote, or newline
            if (std.mem.indexOfAny(u8, val, ",\"\n\r") != null) {
                try buf.append(allocator, '"');
                for (val) |c| {
                    if (c == '"') try buf.append(allocator, '"');
                    try buf.append(allocator, c);
                }
                try buf.append(allocator, '"');
            } else {
                try buf.appendSlice(allocator, val);
            }
        }
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

/// Generate Markdown table from a sheet
pub fn sheetToMarkdown(allocator: std.mem.Allocator, sheet: *const Sheet) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var row: u32 = 1;
    while (row <= sheet.max_row) : (row += 1) {
        // Skip completely empty rows
        var has_data = false;
        var check_col: u16 = 0;
        while (check_col <= sheet.max_col) : (check_col += 1) {
            if (sheet.getCell(check_col, row).len > 0) {
                has_data = true;
                break;
            }
        }
        if (!has_data) continue;

        try buf.append(allocator, '|');
        var col: u16 = 0;
        while (col <= sheet.max_col) : (col += 1) {
            try buf.append(allocator, ' ');
            const val = sheet.getCell(col, row);
            // Escape pipes in cell values
            for (val) |c| {
                if (c == '|') {
                    try buf.appendSlice(allocator, "\\|");
                } else if (c == '\n') {
                    try buf.append(allocator, ' ');
                } else {
                    try buf.append(allocator, c);
                }
            }
            try buf.appendSlice(allocator, " |");
        }
        try buf.append(allocator, '\n');

        // Add separator after first data row (header)
        if (row == 1 or (row == 2 and sheet.getCell(0, 1).len == 0)) {
            try buf.append(allocator, '|');
            var sep_col: u16 = 0;
            while (sep_col <= sheet.max_col) : (sep_col += 1) {
                try buf.appendSlice(allocator, "---|");
            }
            try buf.append(allocator, '\n');
        }
    }

    return buf.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────
// Internal parsers
// ─────────────────────────────────────────────────

fn parseSharedStrings(allocator: std.mem.Allocator, archive: *zip.ZipArchive) ![][]const u8 {
    const entry = archive.findEntry("xl/sharedStrings.xml") orelse return error.FileNotFound;
    const data = try archive.extract(entry);
    defer allocator.free(data);

    var strings: std.ArrayListUnmanaged([]const u8) = .empty;

    // Simple state machine: find <t ...>text</t> inside <si> elements
    var pos: usize = 0;
    while (pos < data.len) {
        // Find <t or <t>
        const t_start = std.mem.indexOfPos(u8, data, pos, "<t") orelse break;
        // Find the closing > of the <t> tag
        const tag_end = std.mem.indexOfPos(u8, data, t_start, ">") orelse break;
        const text_start = tag_end + 1;
        // Find </t>
        const t_end = std.mem.indexOfPos(u8, data, text_start, "</t>") orelse break;

        const text = data[text_start..t_end];
        try strings.append(allocator, try allocator.dupe(u8, text));

        pos = t_end + 4;
    }

    return strings.toOwnedSlice(allocator);
}

fn parseWorkbook(allocator: std.mem.Allocator, archive: *zip.ZipArchive) ![][]const u8 {
    const wb_entry = archive.findEntry("xl/workbook.xml") orelse return error.FileNotFound;
    const data = try archive.extract(wb_entry);
    defer allocator.free(data);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;

    // Find <sheet name="..." patterns
    var pos: usize = 0;
    while (pos < data.len) {
        const sheet_start = std.mem.indexOfPos(u8, data, pos, "<sheet ") orelse break;
        const tag_end = std.mem.indexOfPos(u8, data, sheet_start, ">") orelse break;

        const tag = data[sheet_start..tag_end];
        // Extract name="..."
        if (std.mem.indexOf(u8, tag, "name=\"")) |name_start| {
            const val_start = name_start + 6;
            if (std.mem.indexOfPos(u8, tag, val_start, "\"")) |val_end| {
                try names.append(allocator, try allocator.dupe(u8, tag[val_start..val_end]));
            }
        }

        pos = tag_end + 1;
    }

    return names.toOwnedSlice(allocator);
}

fn parseSheet(
    allocator: std.mem.Allocator,
    data: []const u8,
    shared_strings: []const []const u8,
    name: []const u8,
) !Sheet {
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    var max_col: u16 = 0;
    var max_row: u32 = 0;

    // Parse <c r="A1" t="s"><v>0</v></c> patterns
    var pos: usize = 0;
    while (pos < data.len) {
        // Find <c
        const c_start = std.mem.indexOfPos(u8, data, pos, "<c ") orelse break;
        const c_close = std.mem.indexOfPos(u8, data, c_start, "</c>") orelse
            std.mem.indexOfPos(u8, data, c_start, "/>") orelse break;

        const cell_xml = data[c_start..c_close];

        // Extract r="A1" (cell reference)
        const ref = extractAttr(cell_xml, "r=\"") orelse {
            pos = c_close + 1;
            continue;
        };

        // Parse column letter(s) and row number from reference like "A1", "AB123"
        const col = parseColRef(ref);
        const row = parseRowRef(ref);

        if (col > max_col) max_col = col;
        if (row > max_row) max_row = row;

        // Extract type: t="s" (shared string), t="n" (number), or absent (number)
        const cell_type = extractAttr(cell_xml, "t=\"") orelse "n";

        // Extract value from <v>...</v>
        const value_text = extractElement(cell_xml, "<v>", "</v>") orelse {
            pos = c_close + 1;
            continue;
        };

        // Resolve value
        const resolved = if (std.mem.eql(u8, cell_type, "s")) blk: {
            // Shared string reference
            const idx = std.fmt.parseInt(usize, value_text, 10) catch {
                pos = c_close + 1;
                continue;
            };
            if (idx < shared_strings.len) {
                break :blk try allocator.dupe(u8, shared_strings[idx]);
            } else {
                break :blk try allocator.dupe(u8, "");
            }
        } else blk: {
            // Number or formula result — format nicely
            break :blk try formatNumber(allocator, value_text);
        };

        try cells.append(allocator, .{
            .col = col,
            .row = row,
            .value = resolved,
        });

        pos = c_close + 1;
    }

    return Sheet{
        .name = name,
        .cells = try cells.toOwnedSlice(allocator),
        .max_col = max_col,
        .max_row = max_row,
        .allocator = allocator,
    };
}

fn extractAttr(data: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, data, prefix) orelse return null;
    const val_start = start + prefix.len;
    const end = std.mem.indexOfPos(u8, data, val_start, "\"") orelse return null;
    return data[val_start..end];
}

fn extractElement(data: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, data, open) orelse return null;
    const val_start = start + open.len;
    const end = std.mem.indexOfPos(u8, data, val_start, close) orelse return null;
    return data[val_start..end];
}

fn parseColRef(ref: []const u8) u16 {
    var col: u16 = 0;
    for (ref) |c| {
        if (c >= 'A' and c <= 'Z') {
            col = col * 26 + (c - 'A');
        } else break;
    }
    return col;
}

fn parseRowRef(ref: []const u8) u32 {
    var start: usize = 0;
    for (ref, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            start = i;
            break;
        }
    }
    return std.fmt.parseInt(u32, ref[start..], 10) catch 0;
}

/// Format a number string nicely — remove trailing zeros from decimals
fn formatNumber(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Try parsing as float to check if it's a decimal
    const val = std.fmt.parseFloat(f64, text) catch return try allocator.dupe(u8, text);

    // If it's a whole number, format without decimal
    const rounded: i64 = @intFromFloat(@round(val));
    if (@abs(val - @as(f64, @floatFromInt(rounded))) < 0.0001) {
        return std.fmt.allocPrint(allocator, "{d}", .{rounded});
    }

    // Otherwise keep original representation
    return try allocator.dupe(u8, text);
}
