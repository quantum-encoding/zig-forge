//! XLSX reader: the sheets of an Excel workbook as CSV or Markdown tables.
//!
//! Sheets come in workbook order (xl/workbook.xml, through
//! xl/_rels/workbook.xml.rels), each with its tab name. Cells are placed by
//! reference: a <row r="N"> puts its cells on row N and a <c r="C7"> in
//! column C, so the blank rows and cells Excel leaves out of the file stay
//! blank. A row or cell without a usable reference follows the previous one.
//!
//! Values: shared and inline strings (rich-text runs joined, phonetic runs
//! skipped, `_xHHHH_` escapes decoded); numbers as stored, with binary float
//! noise past 15 significant digits rounded away; numbers in a date or time
//! style (xl/styles.xml) as ISO 8601; booleans as TRUE / FALSE; error codes
//! and formula text results as stored. An empty (styled) cell holds no value
//! and does not widen or lengthen a sheet.

const std = @import("std");
const xml = @import("xml.zig");
const zip = @import("zip.zig");
const styles_mod = @import("xlsx_styles.zig");

/// Excel's sheet limits: rows 1..1048576, columns A..XFD.
pub const max_rows: u32 = 1_048_576;
pub const max_columns: u32 = 16_384;

/// Largest table `sheetToCsv` / `sheetToMarkdown` render, in fields
/// (rows × columns). Both are rectangular, so one value at XFD1048576 would
/// otherwise ask for 17 billion empty fields.
pub const max_table_fields: u64 = 128 * 1024 * 1024;

pub const Cell = struct {
    col: u16, // 0-based column index
    row: u32, // 1-based row number
    value: []const u8, // resolved text value, never empty
};

pub const Sheet = struct {
    name: []const u8,
    /// Cells holding a value, ordered by row then column, one per position.
    cells: []Cell,
    /// 0-based index of the rightmost column holding a value.
    max_col: u16,
    /// 1-based number of the last row holding a value; 0 for an empty sheet.
    max_row: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sheet) void {
        for (self.cells) |cell| {
            self.allocator.free(cell.value);
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.name);
    }

    /// Cell value at (col, row). Returns empty string if not found.
    pub fn getCell(self: *const Sheet, col: u16, row: u32) []const u8 {
        var lo: usize = 0;
        var hi: usize = self.cells.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.cells[mid];
            if (c.row == row and c.col == col) return c.value;
            if (c.row < row or (c.row == row and c.col < col)) lo = mid + 1 else hi = mid;
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

/// Parse every worksheet of an XLSX archive, in workbook order.
///
/// A sheet the workbook lists but the archive lacks is `error.SheetMissing`;
/// a workbook that lists no sheets (no workbook.xml or rels) falls back to
/// xl/worksheets/sheet1.xml, sheet2.xml, … named Sheet1, Sheet2, ….
pub fn parseXlsx(allocator: std.mem.Allocator, archive: *zip.ZipArchive) !Workbook {
    const shared = try readSharedStrings(allocator, archive);
    defer freeStrings(allocator, shared);

    var styles: styles_mod.Styles = .empty;
    if (archive.findEntry("xl/styles.xml")) |entry| {
        const data = try archive.extract(entry);
        defer allocator.free(data);
        styles = try styles_mod.Styles.parse(allocator, data);
    }
    defer styles.deinit();

    var book = try readWorkbook(allocator, archive);
    defer book.deinit(allocator);

    const options: Options = .{ .styles = &styles, .date1904 = book.date1904 };

    var sheets: std.ArrayListUnmanaged(Sheet) = .empty;
    errdefer {
        for (sheets.items) |*s| s.deinit();
        sheets.deinit(allocator);
    }

    for (book.sheets.items) |ref| {
        const entry = archive.findEntry(ref.path) orelse return error.SheetMissing;
        try appendSheet(allocator, &sheets, archive, entry, ref.name, shared, options);
    }

    if (book.sheets.items.len == 0) {
        var n: usize = 1;
        while (true) : (n += 1) {
            var path_buf: [48]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "xl/worksheets/sheet{d}.xml", .{n}) catch break;
            const entry = archive.findEntry(path) orelse break;
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Sheet{d}", .{n}) catch break;
            try appendSheet(allocator, &sheets, archive, entry, name, shared, options);
        }
    }

    return .{
        .sheets = try sheets.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn appendSheet(
    allocator: std.mem.Allocator,
    sheets: *std.ArrayListUnmanaged(Sheet),
    archive: *zip.ZipArchive,
    entry: *const zip.Entry,
    name: []const u8,
    shared: []const []const u8,
    options: Options,
) !void {
    try sheets.ensureUnusedCapacity(allocator, 1);
    const data = try archive.extract(entry);
    defer allocator.free(data);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const parsed = try parseCells(allocator, data, shared, options);
    sheets.appendAssumeCapacity(.{
        .name = owned_name,
        .cells = parsed.cells,
        .max_col = parsed.max_col,
        .max_row = parsed.max_row,
        .allocator = allocator,
    });
}

/// Generate CSV from a sheet: rows 1 to `max_row`, columns A to `max_col`,
/// one line per row (a blank row is a line of commas).
///
/// Quotes and commas are escaped per RFC 4180, so the output parses correctly
/// in any CSV reader.
///
/// It does **not** defend against spreadsheet formula injection: a cell whose
/// text begins with `=`, `+`, `-` or `@` (e.g. `=cmd|'/c calc'!A1`) is emitted
/// verbatim, and a spreadsheet application that later *opens* this CSV may
/// evaluate it. That is deliberate — the in-tree consumers feed the CSV to
/// parsers and LLMs, where mangling leading characters would corrupt real data.
/// A consumer that hands the output to a spreadsheet application must prefix
/// such cells itself (the usual mitigation is a leading `'`).
pub fn sheetToCsv(allocator: std.mem.Allocator, sheet: *const Sheet) ![]u8 {
    try checkTableSize(sheet);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    var row: u32 = 1;
    while (row <= sheet.max_row) : (row += 1) {
        var col: u16 = 0;
        while (col <= sheet.max_col) : (col += 1) {
            if (col > 0) try buf.append(allocator, ',');
            if (i < sheet.cells.len and sheet.cells[i].row == row and sheet.cells[i].col == col) {
                const val = sheet.cells[i].value;
                i += 1;
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
        }
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

/// Generate a Markdown table from a sheet: one table row per sheet row that
/// holds a value (blank rows are left out), columns A to `max_col`, with the
/// header separator after the first row.
pub fn sheetToMarkdown(allocator: std.mem.Allocator, sheet: *const Sheet) ![]u8 {
    try checkTableSize(sheet);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    var first = true;
    while (i < sheet.cells.len) {
        const row = sheet.cells[i].row;
        try buf.append(allocator, '|');
        var col: u16 = 0;
        while (col <= sheet.max_col) : (col += 1) {
            try buf.append(allocator, ' ');
            if (i < sheet.cells.len and sheet.cells[i].row == row and sheet.cells[i].col == col) {
                for (sheet.cells[i].value) |c| switch (c) {
                    '|' => try buf.appendSlice(allocator, "\\|"),
                    '\n', '\r' => try buf.append(allocator, ' '),
                    else => try buf.append(allocator, c),
                };
                i += 1;
            }
            try buf.appendSlice(allocator, " |");
        }
        try buf.append(allocator, '\n');

        if (first) {
            first = false;
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

fn checkTableSize(sheet: *const Sheet) error{SheetTooLarge}!void {
    const fields = @as(u64, sheet.max_row) * (@as(u64, sheet.max_col) + 1);
    if (fields > max_table_fields) return error.SheetTooLarge;
}

// ─────────────────────────────────────────────────
// Internal parsers
// ─────────────────────────────────────────────────

const Options = struct {
    styles: *const styles_mod.Styles,
    date1904: bool,
};

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}

/// xl/sharedStrings.xml as one string per <si>: the text of its <t> runs
/// joined (rich text), phonetic <rPh> runs left out. Empty when the archive
/// has no shared strings.
fn readSharedStrings(allocator: std.mem.Allocator, archive: *zip.ZipArchive) ![]const []const u8 {
    const entry = archive.findEntry("xl/sharedStrings.xml") orelse
        return allocator.alloc([]const u8, 0);
    const data = try archive.extract(entry);
    defer allocator.free(data);

    var strings: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (strings.items) |s| allocator.free(s);
        strings.deinit(allocator);
    }
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);

    var parser = xml.XmlParser.init(data);
    parser.keep_whitespace = true;
    var in_si = false;
    var in_t = false;
    var rph_depth: usize = 0;
    var t_start: usize = 0;

    while (parser.next()) |event| switch (event) {
        .element_start => |e| {
            if (std.mem.eql(u8, e.name, "si")) {
                in_si = true;
                rph_depth = 0;
                text.clearRetainingCapacity();
            } else if (in_si and std.mem.eql(u8, e.name, "rPh")) {
                rph_depth += 1;
            } else if (in_si and rph_depth == 0 and std.mem.eql(u8, e.name, "t")) {
                in_t = true;
                t_start = text.items.len;
            }
        },
        .element_end => |name| {
            if (std.mem.eql(u8, name, "t")) {
                if (in_t) text.items.len = t_start + decodeRun(text.items[t_start..]);
                in_t = false;
            } else if (std.mem.eql(u8, name, "rPh")) {
                if (rph_depth > 0) rph_depth -= 1;
            } else if (std.mem.eql(u8, name, "si")) {
                try strings.ensureUnusedCapacity(allocator, 1);
                strings.appendAssumeCapacity(try allocator.dupe(u8, text.items));
                in_si = false;
            }
        },
        .text => |t| if (in_t) try text.appendSlice(allocator, t),
    };

    return strings.toOwnedSlice(allocator);
}

const SheetRef = struct { name: []const u8, path: []const u8 };

const WorkbookInfo = struct {
    sheets: std.ArrayListUnmanaged(SheetRef) = .empty,
    /// `<workbookPr date1904="1"/>`: serials count days from 1904-01-01.
    date1904: bool = false,

    fn deinit(self: *WorkbookInfo, allocator: std.mem.Allocator) void {
        for (self.sheets.items) |s| {
            allocator.free(s.name);
            allocator.free(s.path);
        }
        self.sheets.deinit(allocator);
    }
};

/// The worksheets xl/workbook.xml lists, in order, with the archive path each
/// one's relationship (xl/_rels/workbook.xml.rels) points at. Chart and
/// dialog sheets are left out.
fn readWorkbook(allocator: std.mem.Allocator, archive: *zip.ZipArchive) !WorkbookInfo {
    var info: WorkbookInfo = .{};
    errdefer info.deinit(allocator);

    const wb_entry = archive.findEntry("xl/workbook.xml") orelse return info;
    const rels_entry = archive.findEntry("xl/_rels/workbook.xml.rels") orelse return info;
    const wb_data = try archive.extract(wb_entry);
    defer allocator.free(wb_data);
    const rels_data = try archive.extract(rels_entry);
    defer allocator.free(rels_data);

    // Relationship id → target, for worksheet relationships. Keys and values
    // are slices of rels_data.
    var targets: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer targets.deinit(allocator);
    var rels = xml.XmlParser.init(rels_data);
    while (rels.next()) |event| switch (event) {
        .element_start => |e| if (std.mem.eql(u8, e.name, "Relationship")) {
            const id = xml.getAttr(e.attrs, "Id") orelse continue;
            const target = xml.getAttr(e.attrs, "Target") orelse continue;
            const rel_type = xml.getAttr(e.attrs, "Type") orelse "";
            if (std.mem.endsWith(u8, rel_type, "/worksheet") or
                (rel_type.len == 0 and std.mem.indexOf(u8, target, "worksheets/") != null))
            {
                try targets.put(allocator, id, target);
            }
        },
        else => {},
    };

    var wb = xml.XmlParser.init(wb_data);
    while (wb.next()) |event| switch (event) {
        .element_start => |e| {
            if (std.mem.eql(u8, e.name, "workbookPr")) {
                if (xml.getAttr(e.attrs, "date1904")) |v| {
                    info.date1904 = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
                }
            } else if (std.mem.eql(u8, e.name, "sheet")) {
                // `r:id` arrives as `id` (namespace prefixes are stripped).
                const rid = xml.getAttr(e.attrs, "id") orelse continue;
                const target = targets.get(rid) orelse continue;
                const raw_name = xml.getAttr(e.attrs, "name") orelse "";
                try info.sheets.ensureUnusedCapacity(allocator, 1);
                const path = if (target.len > 0 and target[0] == '/')
                    try allocator.dupe(u8, target[1..])
                else
                    try std.fmt.allocPrint(allocator, "xl/{s}", .{target});
                errdefer allocator.free(path);
                const name = try xml.decodeAlloc(allocator, raw_name);
                info.sheets.appendAssumeCapacity(.{ .name = name, .path = path });
            }
        },
        else => {},
    };

    return info;
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

const ParsedCells = struct { cells: []Cell, max_col: u16, max_row: u32 };

/// The cells of one worksheet's <sheetData> that hold a value, sorted by
/// row then column. A later cell at a position already taken replaces it.
fn parseCells(
    allocator: std.mem.Allocator,
    data: []const u8,
    shared: []const []const u8,
    options: Options,
) !ParsedCells {
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    errdefer {
        for (cells.items) |c| allocator.free(c.value);
        cells.deinit(allocator);
    }
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);

    var parser = xml.XmlParser.init(data);
    parser.keep_whitespace = true;

    var in_sheet_data = false;
    var in_row = false;
    var in_cell = false;
    var in_value = false;
    var in_inline = false;
    var in_t = false;
    var rph_depth: usize = 0;
    var t_start: usize = 0;

    // 1-based row being read, and the row a <row> without `r` would be.
    var row: u32 = 0;
    var next_row: u32 = 1;
    // 0-based column of the cell being read, and the column a <c> without
    // `r` would be.
    var col: u32 = 0;
    var next_col: u32 = 0;
    var cell_type: CellType = .number;
    var cell_style: usize = 0;

    while (parser.next()) |event| switch (event) {
        .element_start => |e| {
            if (std.mem.eql(u8, e.name, "sheetData")) {
                in_sheet_data = true;
            } else if (in_sheet_data and std.mem.eql(u8, e.name, "row")) {
                in_row = true;
                row = next_row;
                if (xml.getAttr(e.attrs, "r")) |r| {
                    const n = std.fmt.parseInt(u32, r, 10) catch 0;
                    if (n >= next_row and n <= max_rows) row = n;
                }
                next_row = row +| 1;
                next_col = 0;
            } else if (in_row and std.mem.eql(u8, e.name, "c")) {
                in_cell = true;
                text.clearRetainingCapacity();
                col = next_col;
                if (xml.getAttr(e.attrs, "r")) |ref| {
                    if (cellColumn(ref)) |c| col = c;
                }
                next_col = col +| 1;
                cell_style = if (xml.getAttr(e.attrs, "s")) |s|
                    std.fmt.parseInt(usize, s, 10) catch 0
                else
                    0;
                cell_type = if (xml.getAttr(e.attrs, "t")) |t| parseCellType(t) else .number;
            } else if (in_cell and std.mem.eql(u8, e.name, "v")) {
                in_value = true;
            } else if (in_cell and std.mem.eql(u8, e.name, "is")) {
                in_inline = true;
                rph_depth = 0;
            } else if (in_inline and std.mem.eql(u8, e.name, "rPh")) {
                rph_depth += 1;
            } else if (in_inline and rph_depth == 0 and std.mem.eql(u8, e.name, "t")) {
                in_t = true;
                t_start = text.items.len;
            }
        },
        .element_end => |name| {
            if (std.mem.eql(u8, name, "sheetData")) {
                in_sheet_data = false;
            } else if (std.mem.eql(u8, name, "row")) {
                in_row = false;
            } else if (std.mem.eql(u8, name, "c")) {
                if (in_cell and row <= max_rows and col < max_columns) {
                    if (try resolveValue(allocator, cell_type, text.items, shared, options, cell_style)) |value| {
                        errdefer allocator.free(value);
                        try cells.append(allocator, .{ .col = @intCast(col), .row = row, .value = value });
                    }
                }
                in_cell = false;
                in_value = false;
                in_inline = false;
                in_t = false;
            } else if (std.mem.eql(u8, name, "v")) {
                in_value = false;
            } else if (std.mem.eql(u8, name, "is")) {
                in_inline = false;
            } else if (std.mem.eql(u8, name, "rPh")) {
                if (rph_depth > 0) rph_depth -= 1;
            } else if (std.mem.eql(u8, name, "t")) {
                if (in_t) text.items.len = t_start + decodeRun(text.items[t_start..]);
                in_t = false;
            }
        },
        .text => |t| if (in_cell and (in_value or in_t)) try text.appendSlice(allocator, t),
    };

    // Files list cells in order, so this is usually a single pass. The sort
    // is stable, so among cells at one position the last one read is last.
    std.mem.sort(Cell, cells.items, {}, cellBefore);
    var kept: usize = 0;
    for (cells.items, 0..) |c, i| {
        if (i + 1 < cells.items.len and cells.items[i + 1].row == c.row and cells.items[i + 1].col == c.col) {
            allocator.free(c.value);
            continue;
        }
        cells.items[kept] = c;
        kept += 1;
    }
    cells.items.len = kept;

    var max_col: u16 = 0;
    var max_row: u32 = 0;
    for (cells.items) |c| {
        if (c.col > max_col) max_col = c.col;
        max_row = c.row;
    }

    return .{
        .cells = try cells.toOwnedSlice(allocator),
        .max_col = max_col,
        .max_row = max_row,
    };
}

fn cellBefore(_: void, a: Cell, b: Cell) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

/// A cell's display text from its raw <v> or inline text, or null when it
/// holds nothing. Inline text arrives already decoded; `raw` may be modified.
fn resolveValue(
    allocator: std.mem.Allocator,
    cell_type: CellType,
    raw: []u8,
    shared: []const []const u8,
    options: Options,
    style: usize,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    switch (cell_type) {
        .shared_string => {
            const idx = std.fmt.parseInt(usize, trimmed, 10) catch return null;
            if (idx >= shared.len or shared[idx].len == 0) return null;
            return try allocator.dupe(u8, shared[idx]);
        },
        .boolean => {
            if (std.mem.eql(u8, trimmed, "1")) return try allocator.dupe(u8, "TRUE");
            if (std.mem.eql(u8, trimmed, "0")) return try allocator.dupe(u8, "FALSE");
            if (trimmed.len == 0) return null;
            return try allocator.dupe(u8, trimmed);
        },
        .formula_string => {
            const n = decodeRun(raw);
            if (n == 0) return null;
            return try allocator.dupe(u8, raw[0..n]);
        },
        .inline_string => {
            if (raw.len == 0) return null;
            return try allocator.dupe(u8, raw);
        },
        .error_val, .date_iso => {
            if (trimmed.len == 0) return null;
            return try allocator.dupe(u8, trimmed);
        },
        .number => {
            if (trimmed.len == 0) return null;
            const kind = options.styles.kind(style);
            if (kind != .none) {
                if (std.fmt.parseFloat(f64, trimmed)) |serial| {
                    var buf: [32]u8 = undefined;
                    if (styles_mod.formatSerial(&buf, serial, kind, options.date1904)) |iso| {
                        return try allocator.dupe(u8, iso);
                    }
                } else |_| {}
            }
            return try formatNumber(allocator, trimmed);
        },
    }
}

/// Decode a string run in place and return its new length: XML end-of-line
/// handling (CR LF and a lone CR read as LF), then ST_Xstring escapes.
fn decodeRun(buf: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r') {
            buf[out] = '\n';
            if (i + 1 < buf.len and buf[i + 1] == '\n') i += 1;
        } else {
            buf[out] = buf[i];
        }
        out += 1;
    }
    return unescapeXstring(buf[0..out]);
}

/// Decode ST_Xstring escapes in place (ECMA-376 Part 1, 22.9.2.19): `_xHHHH_`
/// is the UTF-16 code unit HHHH, which is how Excel stores characters XML
/// cannot carry (`_x000D_` is a carriage return); `_x005F_` is an
/// underscore, so `_x005F_x000D_` is the literal text `_x000D_`. A surrogate
/// pair written as two escapes becomes one character; a lone surrogate is
/// kept as written. Returns the new length (decoding never grows text).
/// The same rules as programs/zig_xlsx/src/shared_strings.zig.
fn unescapeXstring(buf: []u8) usize {
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

/// 0-based column of a cell reference ("B3" → 1, "AA1" → 26), or null when
/// it has no column letters or names a column past XFD.
fn cellColumn(ref: []const u8) ?u32 {
    var col: u32 = 0;
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

/// A stored number as display text. Excel keeps 15 significant digits, so a
/// value written with more (binary float noise: 45.000000000000007,
/// 0.30000000000000004) is rounded to 15 and its trailing zeros dropped.
/// Anything else (up to 15 digits, exponent forms, magnitudes below 1e-5 or
/// from 1e15 up, text that is not a number) is kept as stored.
fn formatNumber(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (significantDigits(text) <= 15) return allocator.dupe(u8, text);
    const v = std.fmt.parseFloat(f64, text) catch return allocator.dupe(u8, text);
    const mag = @abs(v);
    if (!std.math.isFinite(v) or mag < 1e-5 or mag >= 1e15) return allocator.dupe(u8, text);

    var exp10: i32 = @intFromFloat(@floor(std.math.log10(mag)));
    if (mag >= std.math.pow(f64, 10, @floatFromInt(exp10 + 1))) exp10 += 1;
    if (mag < std.math.pow(f64, 10, @floatFromInt(exp10))) exp10 -= 1;
    const decimals: usize = @intCast(@max(0, 14 - exp10));

    var buf: [64]u8 = undefined;
    var s: []const u8 = std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = v, .p = decimals }) catch
        return allocator.dupe(u8, text);
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    return allocator.dupe(u8, s);
}

/// Significant digits in a plain decimal number's text ("45.000000000000007"
/// → 17, "0.0012" → 2); 0 for exponent forms and text that is not a number.
fn significantDigits(text: []const u8) usize {
    var count: usize = 0;
    var leading = true;
    for (text, 0..) |c, i| switch (c) {
        '0' => {
            if (!leading) count += 1;
        },
        '1'...'9' => {
            leading = false;
            count += 1;
        },
        '.' => {},
        '-', '+' => if (i != 0) return 0,
        else => return 0,
    };
    return count;
}

test {
    _ = styles_mod;
}

// ─────────────────────────────────────────────────
// Tests: workbooks built in memory
// ─────────────────────────────────────────────────

const zip_writer = @import("zip_writer.zig");

const TestBook = struct {
    /// Sheet XML bodies by workbook order; each is written as
    /// xl/worksheets/sheet<file>.xml where <file> is `files[i]`.
    sheets: []const []const u8,
    names: []const []const u8 = &.{},
    files: []const u8 = &.{},
    shared: ?[]const u8 = null,
    styles: ?[]const u8 = null,
    workbook_pr: []const u8 = "",
};

fn buildXlsx(a: std.mem.Allocator, book: TestBook) ![]u8 {
    var zw = zip_writer.ZipWriter.init(a);
    defer zw.deinit();
    var wb: std.ArrayList(u8) = .empty;
    defer wb.deinit(a);
    var rels: std.ArrayList(u8) = .empty;
    defer rels.deinit(a);
    try wb.print(a, "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">{s}<sheets>", .{book.workbook_pr});
    try rels.appendSlice(a, "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
    for (book.sheets, 0..) |body, i| {
        const file: usize = if (i < book.files.len) book.files[i] else i + 1;
        const name: []const u8 = if (i < book.names.len) book.names[i] else "Sheet";
        try wb.print(a, "<sheet name=\"{s}\" sheetId=\"{d}\" r:id=\"rId{d}\"/>", .{ name, i + 1, file });
        try rels.print(a, "<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>", .{ file, file });
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "xl/worksheets/sheet{d}.xml", .{file});
        const xml_body = try std.fmt.allocPrint(a, "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>{s}</sheetData></worksheet>", .{body});
        defer a.free(xml_body);
        try zw.addFile(path, xml_body);
    }
    try wb.appendSlice(a, "</sheets></workbook>");
    try rels.appendSlice(a, "</Relationships>");
    try zw.addFile("xl/workbook.xml", wb.items);
    try zw.addFile("xl/_rels/workbook.xml.rels", rels.items);
    if (book.shared) |s| try zw.addFile("xl/sharedStrings.xml", s);
    if (book.styles) |s| try zw.addFile("xl/styles.xml", s);
    return zw.finish();
}

fn expectCsv(book: TestBook, sheet_index: usize, want: []const u8) !void {
    const a = std.testing.allocator;
    const bytes = try buildXlsx(a, book);
    var archive = try zip.ZipArchive.openFromMemory(a, bytes);
    defer archive.close();
    var wb = try parseXlsx(a, &archive);
    defer wb.deinit();
    try std.testing.expect(sheet_index < wb.sheets.len);
    const csv = try sheetToCsv(a, &wb.sheets[sheet_index]);
    defer a.free(csv);
    try std.testing.expectEqualStrings(want, csv);
}

test "xlsx csv: rows Excel leaves out stay blank lines in place" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c></row>
        \\<row r="4"><c r="A4"><v>4</v></c></row>
        \\<row r="6"><c r="B6"><v>6</v></c></row>
    } }, 0, "1,2\n,\n,\n4,\n,\n,6\n");
}

test "xlsx csv: cells and rows without an r reference follow the previous one" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="2"><c><v>1</v></c><c><v>2</v></c></row>
        \\<row><c><v>3</v></c><c r="C3"><v>4</v></c><c><v>5</v></c></row>
    } }, 0, ",,,\n1,2,,\n3,,4,5\n");
}

test "xlsx csv: an empty styled cell does not take the next cell's value" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1" s="1"/><c r="B1"><v>7</v></c><c r="C1" s="1"/></row>
        \\<row r="2"><c r="A2"><v>8</v></c></row>
    } }, 0, ",7\n8,\n");
}

test "xlsx csv: trailing formatted rows and cells add nothing" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1"><v>1</v></c><c r="D1" s="2"/></row>
        \\<row r="2" s="3" customFormat="1"><c r="A2" s="3"/></row>
        \\<row r="900" s="3" customFormat="1"/>
    } }, 0, "1\n");
}

test "xlsx csv: rich-text shared strings are one string, spaces and entities kept" {
    try expectCsv(.{
        .shared =
        \\<sst><si><r><rPr><b/></rPr><t>Loft Access:</t></r><r><t xml:space="preserve"> </t></r><r><t>Increase</t></r><rPh sb="0" eb="1"><t>X</t></rPh></si>
        \\<si><t>R&amp;D &lt;b&gt; &#233;</t></si><si><t/></si><si><t>a_x000D_
        \\b _x005F_x000D_</t></si><si><t>last</t></si></sst>
        ,
        .sheets = &.{
            \\<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>4</v></c></row>
        },
    }, 0, "Loft Access: Increase,R&D <b> \u{e9},,\"a\r\nb _x000D_\",last\n");
}

test "xlsx csv: inline strings, booleans, errors and formula text results" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1" t="inlineStr"><is><r><t>Hi</t></r><r><t xml:space="preserve"> there</t></r></is></c><c r="B1" t="b"><v>1</v></c><c r="C1" t="b"><v>0</v></c><c r="D1" t="e"><f>1/0</f><v>#DIV/0!</v></c><c r="E1" t="str"><f>A1&amp;"!"</f><v>Hi there!</v></c></row>
    } }, 0, "Hi there,TRUE,FALSE,#DIV/0!,Hi there!\n");
}

test "xlsx csv: numbers in a date or time style are ISO 8601" {
    const styles =
        \\<styleSheet><numFmts count="1"><numFmt numFmtId="165" formatCode="dd\ mmm\ yyyy"/></numFmts>
        \\<cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="165"/><xf numFmtId="22"/></cellXfs></styleSheet>
    ;
    const sheet =
        \\<row r="1"><c r="A1" s="1"><v>46259</v></c><c r="B1" s="2"><v>46259</v></c><c r="C1" s="3"><v>46259.7263888889</v></c><c r="D1"><v>46259</v></c></row>
    ;
    try expectCsv(.{ .sheets = &.{sheet}, .styles = styles }, 0, "2026-08-25,2026-08-25,2026-08-25T17:26:00,46259\n");
    try expectCsv(.{ .sheets = &.{sheet}, .styles = styles, .workbook_pr = "<workbookPr date1904=\"1\"/>" }, 0, "2030-08-26,2030-08-26,2030-08-26T17:26:00,46259\n");
}

test "xlsx csv: numbers keep their value; float noise is cut to 15 significant digits" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1"><v>0.00001</v></c><c r="B1"><v>45.000000000000007</v></c><c r="C1"><v>0.30000000000000004</v></c><c r="D1"><v>1E+20</v></c><c r="E1"><v>-12.5</v></c><c r="F1"><v>12345678901234567890</v></c><c r="G1"><v>2.9999999999999996</v></c></row>
    } }, 0, "0.00001,45,0.3,1E+20,-12.5,12345678901234567890,3\n");
}

test "xlsx csv: sheets pair with their names in workbook order, through the rels" {
    const book: TestBook = .{
        .sheets = &.{
            \\<row r="1"><c r="A1" t="inlineStr"><is><t>second file</t></is></c></row>
            ,
            \\<row r="1"><c r="A1" t="inlineStr"><is><t>first file</t></is></c></row>
        },
        .names = &.{ "Summary &amp; Notes", "Data" },
        .files = &.{ 2, 1 },
    };
    try expectCsv(book, 0, "second file\n");
    try expectCsv(book, 1, "first file\n");

    const a = std.testing.allocator;
    const bytes = try buildXlsx(a, book);
    var archive = try zip.ZipArchive.openFromMemory(a, bytes);
    defer archive.close();
    var wb = try parseXlsx(a, &archive);
    defer wb.deinit();
    try std.testing.expectEqual(@as(usize, 2), wb.sheets.len);
    try std.testing.expectEqualStrings("Summary & Notes", wb.sheets[0].name);
    try std.testing.expectEqualStrings("Data", wb.sheets[1].name);
}

test "xlsx csv: commas, quotes and newlines are quoted per RFC 4180" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="1"><c r="A1" t="inlineStr"><is><t>a,b</t></is></c><c r="B1" t="inlineStr"><is><t>say "hi"</t></is></c><c r="C1" t="inlineStr"><is><t>two
        \\lines</t></is></c></row>
    } }, 0, "\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\"\n");
}

test "xlsx csv: a row number that goes backwards follows the previous row; a repeated cell replaces the earlier one" {
    try expectCsv(.{ .sheets = &.{
        \\<row r="3"><c r="A3"><v>3</v></c><c r="A3"><v>33</v></c></row>
        \\<row r="2"><c r="B2"><v>4</v></c></row>
    } }, 0, ",\n,\n33,\n,4\n");
}

fn parseBook(a: std.mem.Allocator, bytes: []const u8) !Workbook {
    // ZipArchive.close frees the bytes it was opened on, so it gets a copy.
    const copy = try a.dupe(u8, bytes);
    var archive = zip.ZipArchive.openFromMemory(a, copy) catch |err| {
        a.free(copy);
        return err;
    };
    defer archive.close();
    return parseXlsx(a, &archive);
}

test "xlsx: a value far out at XFD1048576 is refused, not padded to 17 billion fields" {
    const a = std.testing.allocator;
    const bytes = try buildXlsx(a, .{ .sheets = &.{
        \\<row r="1"><c r="A1"><v>1</v></c></row><row r="1048576"><c r="XFD1048576"><v>2</v></c></row>
    } });
    defer a.free(bytes);
    var wb = try parseBook(a, bytes);
    defer wb.deinit();
    const sheet = &wb.sheets[0];
    try std.testing.expectEqual(@as(u32, 1_048_576), sheet.max_row);
    try std.testing.expectEqual(@as(u16, 16_383), sheet.max_col);
    try std.testing.expectEqualStrings("2", sheet.getCell(16_383, 1_048_576));
    try std.testing.expectEqualStrings("1", sheet.getCell(0, 1));
    try std.testing.expectEqualStrings("", sheet.getCell(1, 1));
    try std.testing.expectError(error.SheetTooLarge, sheetToCsv(a, sheet));
    try std.testing.expectError(error.SheetTooLarge, sheetToMarkdown(a, sheet));
}

test "xlsx markdown: blank rows are left out and the separator follows the first row" {
    const a = std.testing.allocator;
    const bytes = try buildXlsx(a, .{ .sheets = &.{
        \\<row r="3"><c r="A3" t="inlineStr"><is><t>Item</t></is></c><c r="B3" t="inlineStr"><is><t>a|b</t></is></c></row>
        \\<row r="5"><c r="B5" t="inlineStr"><is><t>two
        \\lines</t></is></c></row>
    } });
    defer a.free(bytes);
    var wb = try parseBook(a, bytes);
    defer wb.deinit();
    const md = try sheetToMarkdown(a, &wb.sheets[0]);
    defer a.free(md);
    try std.testing.expectEqualStrings("| Item | a\\|b |\n|---|---|\n|  | two lines |\n", md);
}

test "xlsx: a sheet the workbook lists but the archive lacks is an error" {
    const a = std.testing.allocator;
    var zw = zip_writer.ZipWriter.init(a);
    defer zw.deinit();
    try zw.addFile("xl/workbook.xml",
        \\<workbook xmlns:r="r"><sheets><sheet name="Gone" sheetId="1" r:id="rId1"/></sheets></workbook>
    );
    try zw.addFile("xl/_rels/workbook.xml.rels",
        \\<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet9.xml"/></Relationships>
    );
    const bytes = try zw.finish();
    defer a.free(bytes);
    try std.testing.expectError(error.SheetMissing, parseBook(a, bytes));
}

test "xlsx: without workbook.xml the worksheet files are read in number order" {
    const a = std.testing.allocator;
    var zw = zip_writer.ZipWriter.init(a);
    defer zw.deinit();
    try zw.addFile("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData></worksheet>");
    try zw.addFile("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row r=\"2\"><c r=\"B2\"><v>2</v></c></row></sheetData></worksheet>");
    const bytes = try zw.finish();
    defer a.free(bytes);
    var wb = try parseBook(a, bytes);
    defer wb.deinit();
    try std.testing.expectEqual(@as(usize, 2), wb.sheets.len);
    try std.testing.expectEqualStrings("Sheet2", wb.sheets[1].name);
    try std.testing.expectEqualStrings("2", wb.sheets[1].getCell(1, 2));
}

fn parseAndRender(a: std.mem.Allocator, bytes: []const u8) !void {
    var wb = try parseBook(a, bytes);
    defer wb.deinit();
    for (wb.sheets) |*sheet| {
        const csv = try sheetToCsv(a, sheet);
        a.free(csv);
        const md = try sheetToMarkdown(a, sheet);
        a.free(md);
    }
}

test "xlsx: every allocation failure while reading is reported without a leak" {
    const a = std.testing.allocator;
    const bytes = try buildXlsx(a, .{
        .names = &.{ "One &amp; Two", "Three" },
        .shared = "<sst><si><r><t>rich</t></r><r><t xml:space=\"preserve\"> text</t></r></si><si><t>plain</t></si></sst>",
        .styles = "<styleSheet><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs></styleSheet>",
        .sheets = &.{
            \\<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" s="1"><v>46259</v></c><c r="C1"><v>0.30000000000000004</v></c></row>
            \\<row r="3"><c r="A3" t="s"><v>1</v></c><c r="A3" t="inlineStr"><is><t>again</t></is></c></row>
            ,
            \\<row r="2"><c r="B2" t="b"><v>1</v></c><c r="C2" t="str"><v>x</v></c></row>
        },
    });
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, parseAndRender, .{bytes});
}
