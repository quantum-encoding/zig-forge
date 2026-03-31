//! DOCX Relationship Parser
//!
//! Parses word/_rels/document.xml.rels to map relationship IDs (rId*)
//! to file targets (media/image1.png) or external URLs.

const std = @import("std");
const xml = @import("xml.zig");

pub const RelType = enum {
    image,
    hyperlink,
    styles,
    numbering,
    other,
};

pub const Relationship = struct {
    id: []const u8,
    target: []const u8,
    rel_type: RelType,
    external: bool,
};

pub fn parseRelationships(allocator: std.mem.Allocator, xml_data: []const u8) ![]Relationship {
    var rels: std.ArrayListUnmanaged(Relationship) = .empty;

    var parser = xml.XmlParser.init(xml_data);
    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| {
                if (std.mem.eql(u8, es.name, "Relationship")) {
                    const id = xml.getAttr(es.attrs, "Id") orelse continue;
                    const target = xml.getAttr(es.attrs, "Target") orelse continue;
                    const type_url = xml.getAttr(es.attrs, "Type") orelse "";
                    const target_mode = xml.getAttr(es.attrs, "TargetMode") orelse "";

                    const rel_type: RelType = if (std.mem.endsWith(u8, type_url, "/image"))
                        .image
                    else if (std.mem.endsWith(u8, type_url, "/hyperlink"))
                        .hyperlink
                    else if (std.mem.endsWith(u8, type_url, "/styles"))
                        .styles
                    else if (std.mem.endsWith(u8, type_url, "/numbering"))
                        .numbering
                    else
                        .other;

                    try rels.append(allocator, .{
                        .id = try allocator.dupe(u8, id),
                        .target = try allocator.dupe(u8, target),
                        .rel_type = rel_type,
                        .external = std.mem.eql(u8, target_mode, "External"),
                    });
                }
            },
            else => {},
        }
    }

    return rels.toOwnedSlice(allocator);
}

pub fn findRelById(rels: []const Relationship, id: []const u8) ?*const Relationship {
    for (rels) |*rel| {
        if (std.mem.eql(u8, rel.id, id)) return rel;
    }
    return null;
}

test "parse relationships XML" {
    const allocator = std.testing.allocator;
    const test_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \\  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
        \\  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/>
        \\</Relationships>
    ;

    const rels = try parseRelationships(allocator, test_xml);
    defer {
        for (rels) |rel| {
            allocator.free(rel.id);
            allocator.free(rel.target);
        }
        allocator.free(rels);
    }

    try std.testing.expectEqual(@as(usize, 3), rels.len);
    try std.testing.expectEqual(RelType.styles, rels[0].rel_type);
    try std.testing.expectEqual(RelType.image, rels[1].rel_type);
    try std.testing.expectEqualStrings("media/image1.png", rels[1].target);
    try std.testing.expectEqual(RelType.hyperlink, rels[2].rel_type);
    try std.testing.expect(rels[2].external);
}
