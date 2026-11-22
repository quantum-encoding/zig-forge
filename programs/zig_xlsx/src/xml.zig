// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Minimal streaming XML parser for XLSX files
//!
//! Handles the subset of XML found in xlsx: elements with attributes, text
//! content (whitespace-only text included), the predefined entities,
//! character references and end-of-line handling. Skips processing
//! instructions, comments and DOCTYPE; CDATA is not supported (Excel does
//! not write it).

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

    // Internal result of one scan step. `.skip` means a construct
    // (comment/PI/DOCTYPE) was consumed and the caller should continue
    // scanning; `.done` means end-of-input. Skipped constructs loop in
    // `next` rather than recursing, so a file with many consecutive
    // skippable constructs cannot overflow the stack.
    const Step = union(enum) {
        event: Event,
        skip: void,
        done: void,
    };

    pub fn next(self: *XmlParser) ?Event {
        // If we had a self-closing tag, emit the end event
        if (self.pending_self_close) |name| {
            self.pending_self_close = null;
            return .{ .element_end = name };
        }

        // Iterative scan: skipped constructs `continue` the loop instead of
        // recursing via `self.next()` (stack-overflow DoS on hostile input,
        // e.g. 100k `<!---->` comments). Each step advances `self.pos`, so the
        // loop always makes progress and terminates.
        while (self.pos < self.data.len) {
            const step = if (self.data[self.pos] == '<')
                self.parseTag()
            else
                self.parseText();
            switch (step) {
                .event => |ev| return ev,
                .skip => continue,
                .done => return null,
            }
        }
        return null;
    }

    fn parseTag(self: *XmlParser) Step {
        self.pos += 1; // skip '<'
        if (self.pos >= self.data.len) return .done;

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
            return .{ .event = .{ .element_end = stripNamespace(name) } };
        }

        if (ch == '?' or ch == '!') {
            // Processing instruction or comment/DOCTYPE — skip to '>'
            self.skipToClose();
            return .skip;
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

        return .{ .event = .{ .element_start = .{
            .name = name,
            .attrs = self.attrs_buf[0..attr_count],
            .self_closing = self_closing,
        } } };
    }

    fn parseText(self: *XmlParser) Step {
        const start = self.pos;
        var end = start;
        while (end < self.data.len and self.data[end] != '<') end += 1;
        const raw = self.data[start..end];

        // Whitespace-only text is emitted too: a rich-text run of just " "
        // (`<t xml:space="preserve"> </t>`) is content. Consumers only
        // collect text inside the elements they care about, so the
        // indentation between elements never reaches them.
        if (std.mem.indexOfAny(u8, raw, "&\r") == null) {
            self.pos = end;
            return .{ .event = .{ .text = raw } };
        }

        // Entities, character references and CR line ends are decoded into
        // the fixed buffer. A long text decodes in chunks: the undecoded rest
        // is the next text event, and consumers concatenate text events.
        const decoded = decodeText(raw, &self.entity_buf);
        self.pos = start + decoded.consumed;
        return .{ .event = .{ .text = decoded.text } };
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

pub const Decoded = struct {
    text: []const u8,
    /// Bytes of the input the text covers.
    consumed: usize,
};

/// Decode character data into `buf`: the five predefined entities, decimal
/// and hex character references (as UTF-8), and XML end-of-line handling
/// (a literal CR LF or lone CR reads as LF; a CR from `&#13;` is kept).
/// An unknown or malformed reference is kept as written. Stops before any
/// piece that would not fit, so `consumed` may be less than `input.len`;
/// with a buffer of at least 4 bytes it always makes progress, and with
/// `buf.len >= input.len` it decodes everything (decoding never grows text).
pub fn decodeText(input: []const u8, buf: []u8) Decoded {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        var piece: [4]u8 = undefined;
        var piece_len: usize = 1;
        var used: usize = 1;
        const c = input[i];
        if (c == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') {
                i += 1; // the LF that follows is the line end
                continue;
            }
            piece[0] = '\n';
        } else if (c == '&') {
            if (decodeReference(input[i..], &piece)) |ref| {
                piece_len = ref.len;
                used = ref.used;
            } else {
                piece[0] = '&';
            }
        } else {
            piece[0] = c;
        }
        if (out + piece_len > buf.len) break;
        @memcpy(buf[out .. out + piece_len], piece[0..piece_len]);
        out += piece_len;
        i += used;
    }
    return .{ .text = buf[0..out], .consumed = i };
}

/// `raw` (an attribute value or other character data) decoded into a new
/// allocation owned by the caller.
pub fn decodeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, raw.len);
    const decoded = decodeText(raw, buf);
    std.debug.assert(decoded.consumed == raw.len);
    if (decoded.text.len == buf.len) return buf;
    if (allocator.resize(buf, decoded.text.len)) return buf[0..decoded.text.len];
    defer allocator.free(buf);
    return allocator.dupe(u8, decoded.text);
}

const Reference = struct { len: usize, used: usize };

/// The reference at the start of `s` (which begins with '&'), written to
/// `out` as UTF-8, or null when it is not one this decoder knows.
fn decodeReference(s: []const u8, out: *[4]u8) ?Reference {
    const named = [_]struct { []const u8, u8 }{
        .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' },
    };
    for (named) |n| {
        if (matchEntity(s, n[0])) {
            out[0] = n[1];
            return .{ .len = 1, .used = n[0].len };
        }
    }
    if (s.len < 4 or s[1] != '#') return null;
    const hex = s[2] == 'x' or s[2] == 'X';
    const digits_start: usize = if (hex) 3 else 2;
    // At most 6 hex or 7 decimal digits: anything longer is past U+10FFFF.
    const semi = std.mem.indexOfScalarPos(u8, s[0..@min(s.len, digits_start + 8)], digits_start, ';') orelse return null;
    if (semi == digits_start) return null;
    for (s[digits_start..semi]) |d| {
        const ok = if (hex) std.ascii.isHex(d) else std.ascii.isDigit(d);
        if (!ok) return null;
    }
    const cp = std.fmt.parseInt(u21, s[digits_start..semi], if (hex) 16 else 10) catch return null;
    const n = std.unicode.utf8Encode(cp, out) catch return null;
    return .{ .len = n, .used = semi + 1 };
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

test "long text with entities arrives whole, in chunks" {
    const a = std.testing.allocator;
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    defer doc.deinit(a);
    var want: std.ArrayListUnmanaged(u8) = .empty;
    defer want.deinit(a);
    try doc.appendSlice(a, "<t>");
    for (0..3000) |_| {
        try doc.appendSlice(a, "a&amp;\r\n");
        try want.appendSlice(a, "a&\n");
    }
    try doc.appendSlice(a, "</t>");

    var parser = XmlParser.init(doc.items);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(a);
    var events: usize = 0;
    while (parser.next()) |ev| switch (ev) {
        .text => |t| {
            try got.appendSlice(a, t);
            events += 1;
        },
        else => {},
    };
    try std.testing.expectEqualStrings(want.items, got.items);
    try std.testing.expect(events > 1);
}

test "whitespace-only text and character references" {
    var parser = XmlParser.init("<t> </t><t>&#65;&#x42;&#xZZ;&bogus;</t>");
    _ = parser.next();
    try std.testing.expectEqualStrings(" ", parser.next().?.text);
    _ = parser.next();
    _ = parser.next();
    try std.testing.expectEqualStrings("AB&#xZZ;&bogus;", parser.next().?.text);
}
