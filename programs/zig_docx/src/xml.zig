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
        /// M2 — borrowed from the parser's internal buffer: valid only until
        /// the next `XmlParser.next()` call. Copy anything that must outlive
        /// the current iteration.
        attrs: []const Attr,
        self_closing: bool,
        /// True when the element declared more than `max_attrs` attributes and
        /// the surplus was dropped. Previously this was silent, so a document
        /// could pad an element with junk attributes to push a real one (e.g.
        /// `r:embed`) out of the visible set.
        attrs_truncated: bool = false,
    };
};

pub const XmlParser = struct {
    /// Attributes retained per element. OOXML elements carry well under this;
    /// the surplus is dropped and flagged via `ElementStart.attrs_truncated`.
    pub const max_attrs = 64;

    data: []const u8,
    pos: usize,
    attrs_buf: [max_attrs]Attr,
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
            // M3 — CDATA carries literal character data and must run to `]]>`,
            // not to the first `>`. Skipping to the first `>` (the old
            // behaviour) both dropped the content and resumed parsing in the
            // middle of the section, so `<![CDATA[<w:p>]]>` was interpreted as
            // real markup.
            if (std.mem.startsWith(u8, self.data[self.pos..], "![CDATA[")) {
                const body_start = self.pos + "![CDATA[".len;
                const end_rel = std.mem.indexOfPos(u8, self.data, body_start, "]]>");
                const body_end = end_rel orelse self.data.len;
                self.pos = if (end_rel != null) body_end + 3 else self.data.len;
                const body = self.data[body_start..body_end];
                if (body.len == 0) return self.next();
                // CDATA is literal: no entity decoding.
                return .{ .text = body };
            }
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
        var attrs_truncated = false;
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
            } else {
                attrs_truncated = true;
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
            .attrs_truncated = attrs_truncated,
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
            // M1 — the decode buffer is fixed size. Rather than silently
            // truncating (and potentially cutting a UTF-8 sequence in half),
            // decode as much as fits, then rewind so the undecoded remainder is
            // emitted as the next text event. Consumers concatenate text
            // events, so a long entity-bearing run just arrives in chunks.
            const decoded = decodeEntities(raw, &self.entity_buf);
            self.pos = start + decoded.consumed;
            return .{ .text = decoded.text };
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

pub const Decoded = struct {
    /// Decoded bytes (a slice of the caller's buffer).
    text: []const u8,
    /// How many bytes of `input` were consumed. Less than `input.len` when the
    /// buffer filled; the caller resumes decoding from there.
    consumed: usize,
};

/// Decode XML entities from `input` into `buf`.
///
/// Stops cleanly at the last whole unit that fits — a multi-byte UTF-8
/// sequence or a decoded reference is never split across the boundary — and
/// reports how much input that covered.
fn decodeEntities(input: []const u8, buf: []u8) Decoded {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        // Bytes this step will emit, and input bytes it will consume.
        var unit: [4]u8 = undefined;
        var unit_len: usize = 1;
        var step: usize = 1;

        if (input[i] == '&') {
            if (matchEntity(input[i..], "&amp;")) {
                unit[0] = '&';
                step = 5;
            } else if (matchEntity(input[i..], "&lt;")) {
                unit[0] = '<';
                step = 4;
            } else if (matchEntity(input[i..], "&gt;")) {
                unit[0] = '>';
                step = 4;
            } else if (matchEntity(input[i..], "&quot;")) {
                unit[0] = '"';
                step = 6;
            } else if (matchEntity(input[i..], "&apos;")) {
                unit[0] = '\'';
                step = 6;
            } else if (decodeCharRef(input[i..])) |ref| {
                // M4 — numeric character references (&#233; / &#xE9;). These
                // are legal everywhere in XML and Word does emit them; they
                // used to pass through as literal `&#233;` text.
                unit_len = ref.utf8_len;
                unit = ref.utf8;
                step = ref.consumed;
            } else {
                // Unknown/malformed reference: emit the '&' literally.
                unit[0] = '&';
            }
        } else {
            // Copy a whole UTF-8 sequence at a time so the buffer boundary can
            // never land mid-character.
            unit_len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
            if (i + unit_len > input.len) unit_len = 1;
            step = unit_len;
            @memcpy(unit[0..unit_len], input[i .. i + unit_len]);
        }

        if (out + unit_len > buf.len) break;
        @memcpy(buf[out .. out + unit_len], unit[0..unit_len]);
        out += unit_len;
        i += step;
    }
    return .{ .text = buf[0..out], .consumed = i };
}

const CharRef = struct {
    utf8: [4]u8,
    utf8_len: usize,
    consumed: usize,
};

/// Decode a numeric character reference at the start of `data` (`&#…;` or
/// `&#x…;`). Returns null for anything malformed or out of range — including
/// surrogates and codepoints above U+10FFFF, which are not legal XML content.
fn decodeCharRef(data: []const u8) ?CharRef {
    if (data.len < 4 or data[0] != '&' or data[1] != '#') return null;

    const hex = data[2] == 'x' or data[2] == 'X';
    var i: usize = if (hex) 3 else 2;
    const digits_start = i;
    var cp: u32 = 0;
    while (i < data.len and data[i] != ';') : (i += 1) {
        const digit = std.fmt.charToDigit(data[i], if (hex) 16 else 10) catch return null;
        // Bail out well before overflow; anything this large is invalid anyway.
        cp = cp *% (if (hex) @as(u32, 16) else 10) +% digit;
        if (cp > 0x10FFFF) return null;
    }
    if (i >= data.len or i == digits_start) return null; // no ';' or no digits

    // Surrogate halves are not valid standalone codepoints.
    if (cp >= 0xD800 and cp <= 0xDFFF) return null;

    // Bounded above by the 0x10FFFF check in the digit loop; re-check at the
    // narrowing rather than relying on that being upstream.
    const scalar = std.math.cast(u21, cp) orelse return null;

    var ref: CharRef = .{ .utf8 = undefined, .utf8_len = 0, .consumed = i + 1 };
    ref.utf8_len = std.unicode.utf8Encode(scalar, &ref.utf8) catch return null;
    return ref;
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

test "M4: numeric character references decode to UTF-8" {
    // Decimal, lowercase hex and uppercase hex forms of the same three
    // characters: é (U+00E9), € (U+20AC), 😀 (U+1F600).
    const xml = "<t>&#233;&#x20AC;&#X1F600;</t>";
    var parser = XmlParser.init(xml);
    _ = parser.next();
    const text = parser.next().?;
    try std.testing.expectEqualStrings("\u{00E9}\u{20AC}\u{1F600}", text.text);
}

test "M4: malformed or illegal character references stay literal" {
    // Unterminated, non-numeric, surrogate half, and out-of-range: all must be
    // passed through rather than producing invalid UTF-8.
    const cases = [_][]const u8{ "&#233", "&#zz;", "&#xD800;", "&#x110000;" };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        const decoded = decodeEntities(case, &buf);
        try std.testing.expectEqualStrings(case, decoded.text);
        try std.testing.expect(std.unicode.utf8ValidateSlice(decoded.text));
    }
}

test "M1: oversized entity text is chunked, not truncated" {
    // 300 '&amp;' entities decoded through a 16-byte buffer: every chunk must
    // be whole and the concatenation must equal the full decoded text.
    const input = "&amp;" ** 300;
    var buf: [16]u8 = undefined;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < input.len) {
        const decoded = decodeEntities(input[i..], &buf);
        try std.testing.expect(decoded.consumed > 0);
        try out.appendSlice(std.testing.allocator, decoded.text);
        i += decoded.consumed;
    }
    try std.testing.expectEqual(@as(usize, 300), out.items.len);
    for (out.items) |c| try std.testing.expectEqual(@as(u8, '&'), c);
}

test "M1: multi-byte UTF-8 is never split at the buffer boundary" {
    // 4-byte codepoints against a 6-byte buffer: only whole characters fit, so
    // each chunk must validate as UTF-8.
    const input = "&amp;\u{1F600}\u{1F600}\u{1F600}";
    var buf: [6]u8 = undefined;
    var i: usize = 0;
    while (i < input.len) {
        const decoded = decodeEntities(input[i..], &buf);
        try std.testing.expect(decoded.consumed > 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(decoded.text));
        i += decoded.consumed;
    }
}

test "M3: CDATA content is literal and not parsed as markup" {
    const xml = "<t><![CDATA[<w:p>a & b</w:p>]]>tail</t>";
    var parser = XmlParser.init(xml);

    const open = parser.next().?;
    try std.testing.expectEqualStrings("t", open.element_start.name);

    // The CDATA body arrives verbatim — no entity decoding, no markup events.
    const cdata = parser.next().?;
    try std.testing.expectEqualStrings("<w:p>a & b</w:p>", cdata.text);

    const tail = parser.next().?;
    try std.testing.expectEqualStrings("tail", tail.text);

    const close = parser.next().?;
    try std.testing.expectEqualStrings("t", close.element_end);
    try std.testing.expect(parser.next() == null);
}

test "M2: attribute overflow is flagged, not silent" {
    var xml: std.ArrayListUnmanaged(u8) = .empty;
    defer xml.deinit(std.testing.allocator);
    try xml.appendSlice(std.testing.allocator, "<e");
    for (0..XmlParser.max_attrs + 5) |n| {
        var name_buf: [32]u8 = undefined;
        const attr = try std.fmt.bufPrint(&name_buf, " a{d}=\"v\"", .{n});
        try xml.appendSlice(std.testing.allocator, attr);
    }
    try xml.appendSlice(std.testing.allocator, "/>");

    var parser = XmlParser.init(xml.items);
    const e = parser.next().?;
    try std.testing.expectEqual(XmlParser.max_attrs, e.element_start.attrs.len);
    try std.testing.expect(e.element_start.attrs_truncated);
}
