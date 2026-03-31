//! DOCX Styles Parser
//!
//! Parses word/styles.xml to map style IDs (e.g. "Heading1") to
//! semantic types used by the document model.

const std = @import("std");
const xml = @import("xml.zig");

pub const StyleType = enum {
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    title,
    subtitle,
    list_paragraph,
    normal,
    toc,
    other,
};

pub const StyleInfo = struct {
    id: []const u8,
    style_type: StyleType,
    is_bold: bool,
    is_italic: bool,
};

/// Classify a style name to a semantic type
fn classifyStyleName(name: []const u8) StyleType {
    // Case-insensitive matching on common Word style names
    var lower_buf: [64]u8 = undefined;
    const len = @min(name.len, lower_buf.len);
    for (name[0..len], 0..) |c, i| {
        lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const lower = lower_buf[0..len];

    if (std.mem.eql(u8, lower, "heading 1") or std.mem.eql(u8, lower, "heading1")) return .heading1;
    if (std.mem.eql(u8, lower, "heading 2") or std.mem.eql(u8, lower, "heading2")) return .heading2;
    if (std.mem.eql(u8, lower, "heading 3") or std.mem.eql(u8, lower, "heading3")) return .heading3;
    if (std.mem.eql(u8, lower, "heading 4") or std.mem.eql(u8, lower, "heading4")) return .heading4;
    if (std.mem.eql(u8, lower, "heading 5") or std.mem.eql(u8, lower, "heading5")) return .heading5;
    if (std.mem.eql(u8, lower, "heading 6") or std.mem.eql(u8, lower, "heading6")) return .heading6;
    if (std.mem.eql(u8, lower, "title")) return .title;
    if (std.mem.eql(u8, lower, "subtitle")) return .subtitle;
    if (std.mem.eql(u8, lower, "list paragraph") or std.mem.eql(u8, lower, "listparagraph")) return .list_paragraph;
    if (std.mem.eql(u8, lower, "normal")) return .normal;
    if (std.mem.startsWith(u8, lower, "toc")) return .toc;

    return .other;
}

/// Also try to classify by style ID directly (Word often uses IDs like "Heading1")
pub fn classifyStyleId(id: []const u8) StyleType {
    if (std.mem.eql(u8, id, "Heading1")) return .heading1;
    if (std.mem.eql(u8, id, "Heading2")) return .heading2;
    if (std.mem.eql(u8, id, "Heading3")) return .heading3;
    if (std.mem.eql(u8, id, "Heading4")) return .heading4;
    if (std.mem.eql(u8, id, "Heading5")) return .heading5;
    if (std.mem.eql(u8, id, "Heading6")) return .heading6;
    if (std.mem.eql(u8, id, "Title")) return .title;
    if (std.mem.eql(u8, id, "Subtitle")) return .subtitle;
    if (std.mem.eql(u8, id, "ListParagraph")) return .list_paragraph;
    if (std.mem.eql(u8, id, "Normal")) return .normal;
    return .other;
}

pub fn parseStyles(allocator: std.mem.Allocator, xml_data: []const u8) ![]StyleInfo {
    var styles: std.ArrayListUnmanaged(StyleInfo) = .empty;

    var parser = xml.XmlParser.init(xml_data);

    var in_style = false;
    var current_id: []const u8 = "";
    var current_type: StyleType = .other;
    var current_bold = false;
    var current_italic = false;
    var in_rpr = false;

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| {
                if (std.mem.eql(u8, es.name, "style")) {
                    in_style = true;
                    current_bold = false;
                    current_italic = false;
                    current_type = .other;
                    current_id = xml.getAttr(es.attrs, "styleId") orelse "";
                    // Pre-classify by ID
                    current_type = classifyStyleId(current_id);
                } else if (in_style and std.mem.eql(u8, es.name, "name")) {
                    const name_val = xml.getAttr(es.attrs, "val") orelse "";
                    const from_name = classifyStyleName(name_val);
                    // Name classification overrides ID if it's more specific
                    if (from_name != .other) current_type = from_name;
                } else if (in_style and std.mem.eql(u8, es.name, "rPr")) {
                    in_rpr = true;
                } else if (in_style and in_rpr and std.mem.eql(u8, es.name, "b")) {
                    // <w:b/> means bold (unless val="0")
                    const val = xml.getAttr(es.attrs, "val") orelse "1";
                    current_bold = !std.mem.eql(u8, val, "0");
                } else if (in_style and in_rpr and std.mem.eql(u8, es.name, "i")) {
                    const val = xml.getAttr(es.attrs, "val") orelse "1";
                    current_italic = !std.mem.eql(u8, val, "0");
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name, "rPr")) {
                    in_rpr = false;
                } else if (std.mem.eql(u8, name, "style")) {
                    if (in_style and current_id.len > 0) {
                        try styles.append(allocator, .{
                            .id = try allocator.dupe(u8, current_id),
                            .style_type = current_type,
                            .is_bold = current_bold,
                            .is_italic = current_italic,
                        });
                    }
                    in_style = false;
                }
            },
            else => {},
        }
    }

    return styles.toOwnedSlice(allocator);
}

pub fn findStyleById(styles: []const StyleInfo, id: []const u8) ?*const StyleInfo {
    for (styles) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

test "classify style names" {
    try std.testing.expectEqual(StyleType.heading1, classifyStyleName("heading 1"));
    try std.testing.expectEqual(StyleType.heading1, classifyStyleName("Heading 1"));
    try std.testing.expectEqual(StyleType.list_paragraph, classifyStyleName("List Paragraph"));
    try std.testing.expectEqual(StyleType.normal, classifyStyleName("Normal"));
    try std.testing.expectEqual(StyleType.other, classifyStyleName("MyCustomStyle"));
}

test "classify style IDs" {
    try std.testing.expectEqual(StyleType.heading2, classifyStyleId("Heading2"));
    try std.testing.expectEqual(StyleType.list_paragraph, classifyStyleId("ListParagraph"));
    try std.testing.expectEqual(StyleType.other, classifyStyleId("CustomId"));
}
