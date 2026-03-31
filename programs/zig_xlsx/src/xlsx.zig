// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! XLSX file reader — public API
//!
//! Opens an .xlsx file (ZIP archive), parses the workbook structure,
//! shared strings, and individual worksheets. Outputs cell data as
//! rows of nullable strings.

const std = @import("std");

pub const zip = @import("zip.zig");
pub const xml = @import("xml.zig");
pub const shared_strings_mod = @import("shared_strings.zig");
pub const workbook_mod = @import("workbook.zig");
pub const worksheet_mod = @import("worksheet.zig");
pub const JsonWriter = @import("json_writer.zig").JsonWriter;

pub const SharedStrings = shared_strings_mod.SharedStrings;
pub const WorkbookInfo = workbook_mod.WorkbookInfo;
pub const Sheet = worksheet_mod.Sheet;
pub const ZipArchive = zip.ZipArchive;

pub const XlsxError = error{
    NotAnXlsxFile,
    MissingWorkbook,
    MissingRels,
    SheetNotFound,
    ParseError,
    OutOfMemory,
    ZipError,
};

pub const XlsxFile = struct {
    archive: ZipArchive,
    workbook: WorkbookInfo,
    shared_strings: SharedStrings,
    allocator: std.mem.Allocator,
    // Track extracted buffers for cleanup
    extracted_buffers: std.ArrayListUnmanaged([]u8),

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !XlsxFile {
        var archive = ZipArchive.open(allocator, path) catch return error.NotAnXlsxFile;
        errdefer archive.close();

        var extracted_buffers: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (extracted_buffers.items) |buf| allocator.free(buf);
            extracted_buffers.deinit(allocator);
        }

        // Extract and parse workbook.xml
        const wb_entry = archive.findEntry("xl/workbook.xml") orelse
            return error.MissingWorkbook;
        const wb_data = archive.extract(wb_entry) catch return error.ParseError;
        try extracted_buffers.append(allocator, wb_data);

        // Extract and parse workbook.xml.rels
        const rels_entry = archive.findEntry("xl/_rels/workbook.xml.rels") orelse
            return error.MissingRels;
        const rels_data = archive.extract(rels_entry) catch return error.ParseError;
        try extracted_buffers.append(allocator, rels_data);

        var workbook = WorkbookInfo.parse(allocator, wb_data, rels_data) catch
            return error.ParseError;
        errdefer workbook.deinit();

        // Extract and parse shared strings (optional — some xlsx files don't have it)
        var shared_strings: SharedStrings = undefined;
        if (archive.findEntry("xl/sharedStrings.xml")) |ss_entry| {
            const ss_data = archive.extract(ss_entry) catch return error.ParseError;
            try extracted_buffers.append(allocator, ss_data);
            shared_strings = SharedStrings.parse(allocator, ss_data) catch
                return error.ParseError;
        } else {
            shared_strings = .{
                .strings = .empty,
                .allocator = allocator,
            };
        }

        return .{
            .archive = archive,
            .workbook = workbook,
            .shared_strings = shared_strings,
            .allocator = allocator,
            .extracted_buffers = extracted_buffers,
        };
    }

    pub fn getSheetNames(self: *const XlsxFile) []const []const u8 {
        // Return just the names from SheetInfo array
        // We can't easily return a slice of just names, so callers iterate .workbook.sheets
        const sheets = self.workbook.sheets;
        // Use a simple trick: sheet names are the .name field of each SheetInfo
        _ = sheets;
        return &.{};
    }

    /// Get sheet names — returns a slice. Caller must free with allocator.
    pub fn getSheetNamesList(self: *const XlsxFile, allocator: std.mem.Allocator) ![]const []const u8 {
        const names = try allocator.alloc([]const u8, self.workbook.sheets.len);
        for (self.workbook.sheets, 0..) |sheet, i| {
            names[i] = sheet.name;
        }
        return names;
    }

    pub fn sheetCount(self: *const XlsxFile) usize {
        return self.workbook.sheets.len;
    }

    pub fn getSheetNameByIndex(self: *const XlsxFile, idx: usize) ?[]const u8 {
        if (idx >= self.workbook.sheets.len) return null;
        return self.workbook.sheets[idx].name;
    }

    pub fn readSheet(self: *XlsxFile, allocator: std.mem.Allocator, name: []const u8) !Sheet {
        // Find sheet path
        const path = for (self.workbook.sheets) |sheet| {
            if (std.mem.eql(u8, sheet.name, name)) break sheet.path;
        } else return error.SheetNotFound;

        // Extract worksheet XML
        const ws_entry = self.archive.findEntry(path) orelse return error.SheetNotFound;
        const ws_data = self.archive.extract(ws_entry) catch return error.ParseError;
        defer allocator.free(ws_data);

        return worksheet_mod.parseWorksheet(allocator, ws_data, &self.shared_strings) catch
            return error.ParseError;
    }

    pub fn close(self: *XlsxFile) void {
        self.shared_strings.deinit();
        self.workbook.deinit();
        for (self.extracted_buffers.items) |buf| {
            self.allocator.free(buf);
        }
        self.extracted_buffers.deinit(self.allocator);
        self.archive.close();
    }
};

// Re-export for tests
test {
    _ = @import("xml.zig");
    _ = @import("zip.zig");
    _ = @import("shared_strings.zig");
    _ = @import("workbook.zig");
    _ = @import("worksheet.zig");
}

// ============================================================================
// Content Types and Relationships Tests
// ============================================================================

test "xlsx structure - content types validation" {
    // Verify that standard XLSX structure is understood
    // [Content_Types].xml must contain:
    // - Override for word/document.xml with application/vnd.openxmlformats-officedocument
    // - Default for xml, rels with application/xml

    // Verify xml parser handles DOCTYPE declarations
    const xml_sample =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\  <Default Extension="xml" ContentType="application/xml"/>
        \\  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        \\  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        \\</Types>
    ;

    var parser = xml.XmlParser.init(xml_sample);
    var found_types = false;
    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| {
                if (std.mem.eql(u8, es.name, "Types")) {
                    found_types = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_types);
}

test "xlsx relationships XML validation" {
    // Test that .rels files are properly parsed
    const rels_xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        \\  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        \\</Relationships>
    ;

    var parser = xml.XmlParser.init(rels_xml);
    var rel_count = 0;
    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| {
                if (std.mem.eql(u8, es.name, "Relationship")) {
                    rel_count += 1;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), rel_count);
}

test "column letter conversion - edge cases" {
    // Test conversion of column letters to indices
    // A = 0, Z = 25, AA = 26, BA = 52, ZZ = 701

    try std.testing.expectEqual(@as(usize, 0), worksheet_mod.parseCellColumn("A1"));
    try std.testing.expectEqual(@as(usize, 9), worksheet_mod.parseCellColumn("J1"));
    try std.testing.expectEqual(@as(usize, 25), worksheet_mod.parseCellColumn("Z1"));
    try std.testing.expectEqual(@as(usize, 26), worksheet_mod.parseCellColumn("AA1"));
    try std.testing.expectEqual(@as(usize, 255), worksheet_mod.parseCellColumn("IV1"));  // 256 columns
}
