// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! .xlsx bytes → the JSON the browser module (wasm.zig) returns:
//!   { "sheets": [ { "name": "Sheet1", "rows": [ ["a","b",null], [], ... ] } ] }
//! Row i of `rows` is spreadsheet row i+1 and cell j is column j+1: rows and
//! cells Excel leaves out of the file are empty rows and nulls. Each cell is
//! a JSON string or null. Numbers are written as stored, except numbers in a
//! date or time style, which are ISO 8601 text (`2026-08-25`,
//! `2026-08-25T17:26:00`, `17:26:00`).
//!
//! Allocator-generic and libc-free, so the same code runs in the
//! freestanding wasm module and under `zig build test`.

const std = @import("std");
const zip = @import("zip.zig");
const workbook_mod = @import("workbook.zig");
const shared_strings_mod = @import("shared_strings.zig");
const styles_mod = @import("styles.zig");
const worksheet_mod = @import("worksheet.zig");

pub const Error = error{
    NotZip,
    MissingWorkbook,
    BadWorkbook,
    MissingRels,
    BadRels,
    BadSharedStrings,
    BadStyles,
    OutOfMemory,
};

pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NotZip => "not a valid xlsx (zip) file",
        error.MissingWorkbook => "missing xl/workbook.xml",
        error.BadWorkbook => "failed to parse workbook",
        error.MissingRels => "missing workbook rels",
        error.BadRels => "failed to read workbook rels",
        error.BadSharedStrings => "failed to parse sharedStrings",
        error.BadStyles => "failed to parse styles",
        error.OutOfMemory => "out of memory",
    };
}

/// The JSON for the workbook in `data`, allocated with `allocator` at its
/// exact length. `data` is only borrowed. A sheet whose XML is missing or
/// unreadable is written with no rows.
pub fn xlsxToJson(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    var archive = zip.ZipArchive.openFromMemory(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotZip,
    };
    defer archive.close();

    const wb_data = try extractRequired(&archive, "xl/workbook.xml", error.MissingWorkbook, error.BadWorkbook);
    defer allocator.free(wb_data);
    const rels_data = try extractRequired(&archive, "xl/_rels/workbook.xml.rels", error.MissingRels, error.BadRels);
    defer allocator.free(rels_data);

    var workbook = workbook_mod.WorkbookInfo.parse(allocator, wb_data, rels_data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer workbook.deinit();

    var shared: shared_strings_mod.SharedStrings = .{ .strings = .empty, .allocator = allocator };
    if (archive.findEntry("xl/sharedStrings.xml")) |entry| {
        const ss_data = archive.extract(entry) catch |err| return mapZip(err, error.BadSharedStrings);
        defer allocator.free(ss_data);
        shared = shared_strings_mod.SharedStrings.parse(allocator, ss_data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    defer shared.deinit();

    var styles: styles_mod.Styles = .empty;
    if (archive.findEntry("xl/styles.xml")) |entry| {
        const st_data = archive.extract(entry) catch |err| return mapZip(err, error.BadStyles);
        defer allocator.free(st_data);
        styles = styles_mod.Styles.parse(allocator, st_data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    defer styles.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"sheets\":[");

    for (workbook.sheets, 0..) |sheet_info, si| {
        if (si != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try appendEscaped(allocator, &out, sheet_info.name);
        try out.appendSlice(allocator, ",\"rows\":[");
        try appendSheetRows(allocator, &out, &archive, sheet_info.path, &shared, .{
            .styles = &styles,
            .date1904 = workbook.date1904,
        });
        try out.appendSlice(allocator, "]}");
    }
    try out.appendSlice(allocator, "]}");

    return out.toOwnedSlice(allocator);
}

fn appendSheetRows(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    archive: *const zip.ZipArchive,
    path: []const u8,
    shared: *const shared_strings_mod.SharedStrings,
    options: worksheet_mod.Options,
) Error!void {
    const entry = archive.findEntry(path) orelse return;
    const ws_data = archive.extract(entry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer allocator.free(ws_data);

    var sheet = worksheet_mod.parseWorksheetWith(allocator, ws_data, shared, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer sheet.deinit(allocator);

    for (sheet.rows, 0..) |row, ri| {
        if (ri != 0) try out.append(allocator, ',');
        try out.append(allocator, '[');
        for (row, 0..) |cell, ci| {
            if (ci != 0) try out.append(allocator, ',');
            if (cell) |value| {
                try appendEscaped(allocator, out, value);
            } else {
                try out.appendSlice(allocator, "null");
            }
        }
        try out.append(allocator, ']');
    }
}

fn extractRequired(archive: *const zip.ZipArchive, name: []const u8, missing: Error, unreadable: Error) Error![]u8 {
    const entry = archive.findEntry(name) orelse return missing;
    return archive.extract(entry) catch |err| mapZip(err, unreadable);
}

fn mapZip(err: zip.ZipError, otherwise: Error) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else otherwise;
}

/// `s` as a JSON string literal (RFC 8259 §7): quote, backslash and control
/// characters escaped, everything else copied byte for byte.
fn appendEscaped(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try list.appendSlice(allocator, &.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] });
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

// ─── Tests ─────────────────────────────────────────────────────────

const test_zip = @import("test_zip.zig");

const content_types =
    \\<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>
;
const workbook_rels =
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    \\</Relationships>
;

fn workbookXml(comptime pr: []const u8) []const u8 {
    return "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" ++ pr ++
        "<sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";
}

/// A one-sheet workbook as zip bytes (caller frees).
fn makeXlsx(a: std.mem.Allocator, wb: []const u8, sheet: []const u8, shared: ?[]const u8, styles: ?[]const u8) ![]u8 {
    var files: [6]test_zip.File = undefined;
    var n: usize = 0;
    files[n] = .{ .name = "[Content_Types].xml", .data = content_types };
    n += 1;
    files[n] = .{ .name = "xl/workbook.xml", .data = wb };
    n += 1;
    files[n] = .{ .name = "xl/_rels/workbook.xml.rels", .data = workbook_rels };
    n += 1;
    files[n] = .{ .name = "xl/worksheets/sheet1.xml", .data = sheet };
    n += 1;
    if (shared) |s| {
        files[n] = .{ .name = "xl/sharedStrings.xml", .data = s };
        n += 1;
    }
    if (styles) |s| {
        files[n] = .{ .name = "xl/styles.xml", .data = s };
        n += 1;
    }
    return test_zip.build(a, files[0..n]);
}

fn expectJson(wb: []const u8, sheet: []const u8, shared: ?[]const u8, styles: ?[]const u8, want: []const u8) !void {
    const a = std.testing.allocator;
    const bytes = try makeXlsx(a, wb, sheet, shared, styles);
    // The caller owns the input, as the wasm host does (wasm_free after the call).
    defer a.free(bytes);
    const json = try xlsxToJson(a, bytes);
    defer a.free(json);
    try std.testing.expectEqualStrings(want, json);
}

test "xlsxToJson: rows after a gap stay on their own row" {
    try expectJson(
        workbookXml(""),
        \\<worksheet><sheetData>
        \\<row r="2"><c r="A2" t="s"><v>0</v></c><c r="C2"><v>1.5</v></c></row>
        \\<row r="4" s="1" customFormat="1"><c r="A4" s="1"/></row>
        \\<row r="5"><c r="B5"><v>7</v></c></row>
        \\<row r="9" s="1" customFormat="1"/>
        \\</sheetData></worksheet>
    ,
        "<sst><si><t>Retention</t></si></sst>",
        null,
        \\{"sheets":[{"name":"Data","rows":[[],["Retention",null,"1.5"],[],[],[null,"7"]]}]}
    );
}

test "xlsxToJson: date-styled numbers become ISO 8601, plain numbers stay as stored" {
    const styles =
        \\<styleSheet>
        \\<numFmts><numFmt numFmtId="164" formatCode="&quot;£&quot;#,##0.00"/><numFmt numFmtId="165" formatCode="dd\ mmm\ yyyy"/></numFmts>
        \\<cellXfs><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="22"/><xf numFmtId="20"/></cellXfs>
        \\</styleSheet>
    ;
    const sheet =
        \\<worksheet><sheetData><row r="1">
        \\<c r="A1"><v>46259</v></c>
        \\<c r="B1" s="1"><v>33481.689</v></c>
        \\<c r="C1" s="2"><v>46259</v></c>
        \\<c r="D1" s="3"><f>NOW()</f><v>46259.7263888889</v></c>
        \\<c r="E1" s="4"><v>0.75</v></c>
        \\<c r="F1" s="2" t="s"><v>0</v></c>
        \\</row></sheetData></worksheet>
    ;
    try expectJson(workbookXml(""), sheet, "<sst><si><t>46259</t></si></sst>", styles,
        \\{"sheets":[{"name":"Data","rows":[["46259","33481.689","2026-08-25","2026-08-25T17:26:00","18:00:00","46259"]]}]}
    );
    // The same serial in a 1904-system workbook is 1462 days later.
    try expectJson(workbookXml("<workbookPr date1904=\"1\"/>"), sheet, "<sst><si><t>46259</t></si></sst>", styles,
        \\{"sheets":[{"name":"Data","rows":[["46259","33481.689","2030-08-26","2030-08-26T17:26:00","18:00:00","46259"]]}]}
    );
}

test "xlsxToJson: rich text, line ends and escapes" {
    try expectJson(
        workbookXml(""),
        \\<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row></sheetData></worksheet>
    ,
        "<sst><si><r><t>Loft Access:</t></r><r><t xml:space=\"preserve\"> </t></r><r><t>Increase \"x\"</t></r></si>" ++
            "<si><t>a\r\nb_x0009_c</t></si></sst>",
        null,
        \\{"sheets":[{"name":"Data","rows":[["Loft Access: Increase \"x\"","a\nb\tc"]]}]}
    );
}

test "xlsxToJson: refuses what is not an xlsx" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotZip, xlsxToJson(a, "<html><body>not a spreadsheet</body></html>"));
    const no_wb = try test_zip.build(a, &.{.{ .name = "word/document.xml", .data = "<w:document/>" }});
    defer a.free(no_wb);
    try std.testing.expectError(error.MissingWorkbook, xlsxToJson(a, no_wb));
}
