// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Minimal streaming XML parser for XLSX files
//!
//! Handles the subset of XML found in xlsx: elements with attributes,
//! text content, and basic XML entities. Ignores processing instructions,
//! comments, and CDATA sections.

const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Event = union(enum) {
    element_start: ElementStart,
    element_end: []const u8,
    text: []const u8,

    pub const ElementStart = struct {
        name: []const u8,
        attrs: []const Attr,
        self_closing: bool,
    };
};

pub const XmlParser = struct {
    data: []const u8,
    pos: usize,
    attrs_buf: [32]Attr,
    // Buffer for decoded entity text
    entity_buf: [4096]u8,
    pending_self_close: ?[]const u8,

    pub fn init(data: []const u8) XmlParser {
        return .{
            .data = data,
            .pos = 0,
            .attrs_buf = undefined,
            .entity_buf = undefined,
            .pending_self_close = null,
        };
    }

    pub fn next(self: *XmlParser) ?Event {
        // If we had a self-closing tag, emit the end event
        if (self.pending_self_close) |name| {
            self.pending_self_close = null;
            return .{ .element_end = name };
        }

        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '<') {
                return self.parseTag();
            } else {
                return self.parseText();
            }
        }
        return null;
    }

    fn parseTag(self: *XmlParser) ?Event {
        self.pos += 1; // skip '<'
        if (self.pos >= self.data.len) return null;

        const ch = self.data[self.pos];

        if (ch == '/') {
            // End tag: </name>
            self.pos += 1;
            const name_start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != '>') {
                self.pos += 1;
            }
            const name = std.mem.trim(u8, self.data[name_start..self.pos], " \t\n\r");
            if (self.pos < self.data.len) self.pos += 1; // skip '>'
            return .{ .element_end = stripNamespace(name) };
        }

        if (ch == '?' or ch == '!') {
            // Processing instruction or comment/DOCTYPE — skip to '>'
            self.skipToClose();
            return self.next();
        }

        // Start tag: <name attr="val" ...> or <name .../>
        const name_start = self.pos;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
            self.pos += 1;
        }
        const raw_name = self.data[name_start..self.pos];
        const name = stripNamespace(raw_name);

        // Parse attributes
        var attr_count: usize = 0;
        self.skipWhitespace();

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            // Attribute name
            const attr_name_start = self.pos;
            while (self.pos < self.data.len) {
                const c = self.data[self.pos];
                if (c == '=' or c == ' ' or c == '>' or c == '/') break;
                self.pos += 1;
            }
            const attr_name = self.data[attr_name_start..self.pos];

            self.skipWhitespace();
            if (self.pos >= self.data.len or self.data[self.pos] != '=') {
                self.skipWhitespace();
                continue;
            }
            self.pos += 1; // skip '='
            self.skipWhitespace();

            // Attribute value
            if (self.pos >= self.data.len) break;
            const quote = self.data[self.pos];
            if (quote != '"' and quote != '\'') break;
            self.pos += 1;

            const val_start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != quote) {
                self.pos += 1;
            }
            const attr_value = self.data[val_start..self.pos];
            if (self.pos < self.data.len) self.pos += 1; // skip closing quote

            if (attr_count < self.attrs_buf.len) {
                self.attrs_buf[attr_count] = .{
                    .name = stripNamespace(attr_name),
                    .value = attr_value,
                };
                attr_count += 1;
            }

            self.skipWhitespace();
        }

        // Check for self-closing
        var self_closing = false;
        if (self.pos < self.data.len and self.data[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
        }
        if (self.pos < self.data.len and self.data[self.pos] == '>') {
            self.pos += 1;
        }

        if (self_closing) {
            self.pending_self_close = name;
        }

        return .{ .element_start = .{
            .name = name,
            .attrs = self.attrs_buf[0..attr_count],
            .self_closing = self_closing,
        } };
    }

    fn parseText(self: *XmlParser) ?Event {
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '<') {
            self.pos += 1;
        }
        const raw = self.data[start..self.pos];

        // Skip whitespace-only text nodes (inter-element whitespace)
        var all_ws = true;
        for (raw) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                all_ws = false;
                break;
            }
        }
        if (all_ws) return self.next();

        // If it contains entities, decode them
        if (std.mem.indexOf(u8, raw, "&")) |_| {
            const decoded = decodeEntities(raw, &self.entity_buf);
            return .{ .text = decoded };
        }

        return .{ .text = raw };
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.pos += 1;
        }
    }

    fn skipToClose(self: *XmlParser) void {
        // Handle comments <!-- ... --> specially
        if (self.pos + 2 < self.data.len and self.data[self.pos] == '!' and
            self.data[self.pos + 1] == '-' and self.data[self.pos + 2] == '-')
        {
            self.pos += 3;
            while (self.pos + 2 < self.data.len) {
                if (self.data[self.pos] == '-' and self.data[self.pos + 1] == '-' and self.data[self.pos + 2] == '>') {
                    self.pos += 3;
                    return;
                }
                self.pos += 1;
            }
        }

        // Skip to matching '>'
        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1;
    }
};

/// Strip XML namespace prefix (e.g., "x:sheet" → "sheet")
fn stripNamespace(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, ":")) |colon| {
        return name[colon + 1 ..];
    }
    return name;
}

/// Decode XML entities in-place into the provided buffer
fn decodeEntities(input: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < buf.len) {
        if (input[i] == '&') {
            if (matchEntity(input[i..], "&amp;")) {
                buf[out] = '&';
                out += 1;
                i += 5;
            } else if (matchEntity(input[i..], "&lt;")) {
                buf[out] = '<';
                out += 1;
                i += 4;
            } else if (matchEntity(input[i..], "&gt;")) {
                buf[out] = '>';
                out += 1;
                i += 4;
            } else if (matchEntity(input[i..], "&quot;")) {
                buf[out] = '"';
                out += 1;
                i += 6;
            } else if (matchEntity(input[i..], "&apos;")) {
                buf[out] = '\'';
                out += 1;
                i += 6;
            } else {
                buf[out] = input[i];
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

fn matchEntity(data: []const u8, entity: []const u8) bool {
    if (data.len < entity.len) return false;
    return std.mem.eql(u8, data[0..entity.len], entity);
}

/// Helper to get attribute value by name from an event
pub fn getAttr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

test "basic XML parsing" {
    const xml = "<root><child attr=\"val\">text</child></root>";
    var parser = XmlParser.init(xml);

    // <root>
    const e1 = parser.next().?;
    try std.testing.expectEqualStrings("root", e1.element_start.name);

    // <child attr="val">
    const e2 = parser.next().?;
    try std.testing.expectEqualStrings("child", e2.element_start.name);
    try std.testing.expectEqualStrings("val", e2.element_start.attrs[0].value);

    // text
    const e3 = parser.next().?;
    try std.testing.expectEqualStrings("text", e3.text);

    // </child>
    const e4 = parser.next().?;
    try std.testing.expectEqualStrings("child", e4.element_end);

    // </root>
    const e5 = parser.next().?;
    try std.testing.expectEqualStrings("root", e5.element_end);

    try std.testing.expect(parser.next() == null);
}

test "self-closing tags" {
    const xml = "<sheet name=\"S1\" sheetId=\"1\"/>";
    var parser = XmlParser.init(xml);

    const e1 = parser.next().?;
    try std.testing.expectEqualStrings("sheet", e1.element_start.name);
    try std.testing.expect(e1.element_start.self_closing);

    const e2 = parser.next().?;
    try std.testing.expectEqualStrings("sheet", e2.element_end);

    try std.testing.expect(parser.next() == null);
}

test "namespace stripping" {
    const xml = "<x:workbook><x:sheet r:id=\"rId1\"/></x:workbook>";
    var parser = XmlParser.init(xml);

    const e1 = parser.next().?;
    try std.testing.expectEqualStrings("workbook", e1.element_start.name);

    const e2 = parser.next().?;
    try std.testing.expectEqualStrings("sheet", e2.element_start.name);
    try std.testing.expectEqualStrings("rId1", getAttr(e2.element_start.attrs, "id").?);
}

test "entity decoding" {
    const xml = "<t>Tom &amp; Jerry &lt;3&gt;</t>";
    var parser = XmlParser.init(xml);

    _ = parser.next(); // <t>
    const text = parser.next().?;
    try std.testing.expectEqualStrings("Tom & Jerry <3>", text.text);
}
