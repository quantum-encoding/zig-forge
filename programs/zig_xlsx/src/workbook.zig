// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Parser for xl/workbook.xml and xl/_rels/workbook.xml.rels
//!
//! Extracts sheet names and maps them to worksheet file paths.
//! workbook.xml has: <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
//! .rels has: <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>

const std = @import("std");
const xml = @import("xml.zig");

pub const SheetInfo = struct {
    name: []const u8,
    path: []const u8, // e.g., "xl/worksheets/sheet1.xml"
};

pub const WorkbookInfo = struct {
    sheets: []SheetInfo,
    allocator: std.mem.Allocator,
    allocated_strings: std.ArrayListUnmanaged([]const u8),

    pub fn parse(allocator: std.mem.Allocator, workbook_xml: []const u8, rels_xml: []const u8) !WorkbookInfo {
        var self = WorkbookInfo{
            .sheets = &.{},
            .allocator = allocator,
            .allocated_strings = .empty,
        };

        // Parse .rels to build rId → target map
        var rels = std.StringHashMapUnmanaged([]const u8).empty;
        defer rels.deinit(allocator);

        {
            var parser = xml.XmlParser.init(rels_xml);
            while (parser.next()) |event| {
                switch (event) {
                    .element_start => |e| {
                        if (std.mem.eql(u8, e.name, "Relationship")) {
                            const id = xml.getAttr(e.attrs, "Id") orelse continue;
                            const target = xml.getAttr(e.attrs, "Target") orelse continue;
                            // Only include worksheet relationships
                            const rel_type = xml.getAttr(e.attrs, "Type") orelse "";
                            if (std.mem.indexOf(u8, rel_type, "worksheet") != null or
                                std.mem.indexOf(u8, target, "worksheets/") != null)
                            {
                                rels.put(allocator, id, target) catch continue;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // Parse workbook.xml to get sheet names and rIds
        var sheets: std.ArrayListUnmanaged(SheetInfo) = .empty;
        defer sheets.deinit(allocator);

        {
            var parser = xml.XmlParser.init(workbook_xml);
            while (parser.next()) |event| {
                switch (event) {
                    .element_start => |e| {
                        if (std.mem.eql(u8, e.name, "sheet")) {
                            const name = xml.getAttr(e.attrs, "name") orelse continue;
                            const rid = xml.getAttr(e.attrs, "id") orelse continue;

                            const target = rels.get(rid) orelse continue;

                            // Build full path from target
                            // Target can be: "worksheets/sheet1.xml" (relative)
                            //            or: "/xl/worksheets/sheet1.xml" (absolute)
                            const path = blk: {
                                if (std.mem.startsWith(u8, target, "/xl/"))
                                    break :blk std.fmt.allocPrint(allocator, "{s}", .{target[1..]}) catch continue
                                else if (std.mem.startsWith(u8, target, "/"))
                                    break :blk std.fmt.allocPrint(allocator, "{s}", .{target[1..]}) catch continue
                                else
                                    break :blk std.fmt.allocPrint(allocator, "xl/{s}", .{target}) catch continue;
                            };
                            try self.allocated_strings.append(allocator, path);

                            const name_copy = allocator.dupe(u8, name) catch continue;
                            try self.allocated_strings.append(allocator, name_copy);

                            sheets.append(allocator, .{
                                .name = name_copy,
                                .path = path,
                            }) catch continue;
                        }
                    },
                    else => {},
                }
            }
        }

        self.sheets = allocator.dupe(SheetInfo, sheets.items) catch return error.OutOfMemory;
        return self;
    }

    pub fn deinit(self: *WorkbookInfo) void {
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
        if (self.sheets.len > 0) {
            self.allocator.free(self.sheets);
        }
    }
};

test "parse workbook" {
    const workbook_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\  <sheets>
        \\    <sheet name="Data" sheetId="1" r:id="rId1"/>
        \\    <sheet name="Summary" sheetId="2" r:id="rId2"/>
        \\  </sheets>
        \\</workbook>
    ;

    const rels_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        \\  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        \\  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        \\</Relationships>
    ;

    var wb = try WorkbookInfo.parse(std.testing.allocator, workbook_xml, rels_xml);
    defer wb.deinit();

    try std.testing.expectEqual(@as(usize, 2), wb.sheets.len);
    try std.testing.expectEqualStrings("Data", wb.sheets[0].name);
    try std.testing.expectEqualStrings("xl/worksheets/sheet1.xml", wb.sheets[0].path);
    try std.testing.expectEqualStrings("Summary", wb.sheets[1].name);
    try std.testing.expectEqualStrings("xl/worksheets/sheet2.xml", wb.sheets[1].path);
}

test "workbook multi-sheet structure" {
    const workbook_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\  <sheets>
        \\    <sheet name="Q1" sheetId="1" r:id="rId1"/>
        \\    <sheet name="Q2" sheetId="2" r:id="rId2"/>
        \\    <sheet name="Q3" sheetId="3" r:id="rId3"/>
        \\    <sheet name="Q4" sheetId="4" r:id="rId4"/>
        \\  </sheets>
        \\</workbook>
    ;

    const rels_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        \\  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        \\  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
        \\  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/>
        \\</Relationships>
    ;

    var wb = try WorkbookInfo.parse(std.testing.allocator, workbook_xml, rels_xml);
    defer wb.deinit();

    try std.testing.expectEqual(@as(usize, 4), wb.sheets.len);
    try std.testing.expectEqualStrings("Q1", wb.sheets[0].name);
    try std.testing.expectEqualStrings("Q4", wb.sheets[3].name);
}

test "workbook empty sheets" {
    const workbook_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\  <sheets>
        \\  </sheets>
        \\</workbook>
    ;

    const rels_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\</Relationships>
    ;

    var wb = try WorkbookInfo.parse(std.testing.allocator, workbook_xml, rels_xml);
    defer wb.deinit();

    try std.testing.expectEqual(@as(usize, 0), wb.sheets.len);
}
