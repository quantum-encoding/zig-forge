// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Markdown → PDF renderer.
//!
//! Self-contained minimal markdown parser + PDF renderer. Handles the common
//! documentation-style subset:
//!   - Headings H1–H6 (#, ##, ...)
//!   - Paragraphs with inline **bold**, *italic*, ***bold italic***, `code`, [link](url)
//!   - Bullet lists (`- ` or `* `)
//!   - Ordered lists (`1. `)
//!   - Horizontal rules (`---`)
//!   - Fenced code blocks (``` ... ```)
//!   - Blockquotes (`> `)
//!   - Optional YAML frontmatter at top (`---\nkey: value\n---`) — extracts
//!     title/author/date for the PDF metadata
//!
//! Not supported (yet): tables, nested lists, images.

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Model
// =============================================================================

pub const SpanKind = enum { text, bold, italic, bold_italic, code, link };

pub const Span = struct {
    kind: SpanKind,
    text: []const u8,
    url: []const u8 = "", // link target, unused for other kinds
};

pub const ListItem = struct {
    spans: []const Span,
};

pub const BlockKind = enum {
    heading,
    paragraph,
    bullet_list,
    ordered_list,
    code_block,
    blockquote,
    horizontal_rule,
    table,
};

pub const TableCell = struct {
    spans: []const Span,
};

pub const TableRow = struct {
    cells: []const TableCell,
};

pub const Table = struct {
    header: TableRow,
    rows: []const TableRow,
};

pub const Block = struct {
    kind: BlockKind,
    // heading
    level: u8 = 1,
    // heading / paragraph / blockquote
    spans: []const Span = &[_]Span{},
    // bullet_list / ordered_list
    items: []const ListItem = &[_]ListItem{},
    // code_block
    code: []const u8 = "",
    // table
    table: ?Table = null,
};

pub const Frontmatter = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    date: []const u8 = "",
    description: []const u8 = "",
};

pub const ParsedDocument = struct {
    frontmatter: Frontmatter,
    blocks: []const Block,
};

// =============================================================================
// Parser
// =============================================================================

/// Parse markdown text into a structured document. All slices in the result
/// reference the input string — they do not allocate new text buffers.
/// Caller owns the top-level arrays (blocks, items, spans).
pub fn parse(allocator: std.mem.Allocator, md: []const u8) !ParsedDocument {
    var result = ParsedDocument{
        .frontmatter = .{},
        .blocks = &[_]Block{},
    };

    var rest = md;

    // YAML frontmatter — only if file starts with "---\n"
    if (std.mem.startsWith(u8, rest, "---\n") or std.mem.startsWith(u8, rest, "---\r\n")) {
        const after_open = if (std.mem.startsWith(u8, rest, "---\r\n")) rest[5..] else rest[4..];
        if (std.mem.indexOf(u8, after_open, "\n---")) |close_idx| {
            const yaml_body = after_open[0..close_idx];
            result.frontmatter = parseFrontmatter(yaml_body);
            // Skip past closing "---\n"
            const after_close = after_open[close_idx + 4 ..];
            rest = if (after_close.len > 0 and after_close[0] == '\n') after_close[1..] else after_close;
            // Also trim a trailing \r if present
            if (rest.len > 0 and rest[0] == '\r') rest = rest[1..];
        }
    }

    var blocks: std.ArrayListUnmanaged(Block) = .empty;

    var lines = lineIterator(rest);
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip blank lines
        if (trimmed.len == 0) continue;

        // Horizontal rule
        if (isHorizontalRule(trimmed)) {
            try blocks.append(allocator, .{ .kind = .horizontal_rule });
            continue;
        }

        // Heading
        if (trimmed[0] == '#') {
            var level: u8 = 0;
            while (level < trimmed.len and trimmed[level] == '#' and level < 6) level += 1;
            if (level > 0 and level < trimmed.len and trimmed[level] == ' ') {
                const heading_text = std.mem.trim(u8, trimmed[level + 1 ..], " \t");
                const spans = try parseInlineSpans(allocator, heading_text);
                try blocks.append(allocator, .{ .kind = .heading, .level = level, .spans = spans });
                continue;
            }
        }

        // Fenced code block
        if (std.mem.startsWith(u8, trimmed, "```")) {
            var code_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer code_buf.deinit(allocator);
            while (lines.next()) |code_line| {
                const code_trim = std.mem.trimEnd(u8, code_line, "\r");
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, code_trim, " \t"), "```")) break;
                if (code_buf.items.len > 0) try code_buf.append(allocator, '\n');
                try code_buf.appendSlice(allocator, code_trim);
            }
            const code_owned = try code_buf.toOwnedSlice(allocator);
            try blocks.append(allocator, .{ .kind = .code_block, .code = code_owned });
            continue;
        }

        // Blockquote
        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const quote_text = trimmed[2..];
            const spans = try parseInlineSpans(allocator, quote_text);
            try blocks.append(allocator, .{ .kind = .blockquote, .spans = spans });
            continue;
        }

        // Pipe table — header row followed by separator row
        if (looksLikeTableRow(trimmed)) {
            const next_peek = lines.peek();
            if (next_peek) |nl| {
                const nl_trim = std.mem.trim(u8, nl, " \t\r");
                if (isTableSeparator(nl_trim)) {
                    _ = lines.next(); // consume the separator row
                    const header = try parseTableRow(allocator, trimmed);
                    var rows: std.ArrayListUnmanaged(TableRow) = .empty;
                    while (true) {
                        const nxt = lines.peek() orelse break;
                        const nxt_trim = std.mem.trim(u8, nxt, " \t\r");
                        if (nxt_trim.len == 0) break;
                        if (!looksLikeTableRow(nxt_trim)) break;
                        _ = lines.next();
                        try rows.append(allocator, try parseTableRow(allocator, nxt_trim));
                    }
                    try blocks.append(allocator, .{
                        .kind = .table,
                        .table = .{
                            .header = header,
                            .rows = try rows.toOwnedSlice(allocator),
                        },
                    });
                    continue;
                }
            }
        }

        // Bullet list
        if (isBulletStart(trimmed)) {
            try parseList(allocator, &blocks, &lines, trimmed, .bullet_list);
            continue;
        }

        // Ordered list
        if (isOrderedStart(trimmed)) {
            try parseList(allocator, &blocks, &lines, trimmed, .ordered_list);
            continue;
        }

        // Default: paragraph — collect consecutive non-blank, non-structural lines
        var para_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer para_buf.deinit(allocator);
        try para_buf.appendSlice(allocator, trimmed);

        // Peek ahead for continuation lines
        while (true) {
            const next_line = lines.peek() orelse break;
            const next_trim = std.mem.trim(u8, next_line, " \t\r");
            if (next_trim.len == 0) break;
            if (next_trim[0] == '#') break;
            if (std.mem.startsWith(u8, next_trim, "```")) break;
            if (std.mem.startsWith(u8, next_trim, "> ")) break;
            if (isBulletStart(next_trim)) break;
            if (isOrderedStart(next_trim)) break;
            if (isHorizontalRule(next_trim)) break;
            if (looksLikeTableRow(next_trim)) break;
            _ = lines.next();
            try para_buf.append(allocator, ' ');
            try para_buf.appendSlice(allocator, next_trim);
        }

        const para_text = try allocator.dupe(u8, para_buf.items);
        const spans = try parseInlineSpans(allocator, para_text);
        try blocks.append(allocator, .{ .kind = .paragraph, .spans = spans });
    }

    result.blocks = try blocks.toOwnedSlice(allocator);
    return result;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const c = line[0];
    if (c != '-' and c != '_' and c != '*') return false;
    for (line) |b| if (b != c and b != ' ') return false;
    // Count the rule char — need at least 3
    var count: usize = 0;
    for (line) |b| {
        if (b == c) count += 1;
    }
    return count >= 3;
}

fn isBulletStart(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* "));
}

fn looksLikeTableRow(line: []const u8) bool {
    if (line.len < 3) return false;
    if (line[0] != '|') return false;
    // Must contain at least one more '|' somewhere after position 0
    for (line[1..]) |b| {
        if (b == '|') return true;
    }
    return false;
}

fn isTableSeparator(line: []const u8) bool {
    if (line.len < 3) return false;
    if (line[0] != '|') return false;
    var saw_dash = false;
    for (line) |b| {
        switch (b) {
            '|', ' ', '\t', ':' => {},
            '-' => saw_dash = true,
            else => return false,
        }
    }
    return saw_dash;
}

fn parseTableRow(allocator: std.mem.Allocator, line: []const u8) !TableRow {
    // Strip leading/trailing pipe and split on |
    var trimmed = line;
    if (trimmed.len > 0 and trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var cells: std.ArrayListUnmanaged(TableCell) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    while (it.next()) |raw| {
        const cell_text = std.mem.trim(u8, raw, " \t");
        const spans = try parseInlineSpans(allocator, cell_text);
        try cells.append(allocator, .{ .spans = spans });
    }
    return .{ .cells = try cells.toOwnedSlice(allocator) };
}

fn isOrderedStart(line: []const u8) bool {
    if (line.len < 3) return false;
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0) return false;
    if (i >= line.len) return false;
    if (line[i] != '.') return false;
    if (i + 1 >= line.len or line[i + 1] != ' ') return false;
    return true;
}

fn stripBulletPrefix(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "- ")) return line[2..];
    if (std.mem.startsWith(u8, line, "* ")) return line[2..];
    return line;
}

fn stripOrderedPrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i < line.len and line[i] == '.') i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    return line[i..];
}

fn parseList(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayListUnmanaged(Block),
    lines: *LineIterator,
    first_line: []const u8,
    kind: BlockKind,
) !void {
    var items: std.ArrayListUnmanaged(ListItem) = .empty;

    const first_text = if (kind == .bullet_list) stripBulletPrefix(first_line) else stripOrderedPrefix(first_line);
    try items.append(allocator, .{ .spans = try parseInlineSpans(allocator, first_text) });

    while (true) {
        const peek = lines.peek() orelse break;
        const trimmed = std.mem.trim(u8, peek, " \t\r");
        if (trimmed.len == 0) break;
        const is_match = switch (kind) {
            .bullet_list => isBulletStart(trimmed),
            .ordered_list => isOrderedStart(trimmed),
            else => false,
        };
        if (!is_match) break;
        _ = lines.next();
        const item_text = if (kind == .bullet_list) stripBulletPrefix(trimmed) else stripOrderedPrefix(trimmed);
        try items.append(allocator, .{ .spans = try parseInlineSpans(allocator, item_text) });
    }

    try blocks.append(allocator, .{
        .kind = kind,
        .items = try items.toOwnedSlice(allocator),
    });
}

// Inline span parser — handles **bold**, *italic*, ***bold-italic***, `code`, [link](url).
// Returns a list of spans that together reconstruct the input text with formatting.
fn parseInlineSpans(allocator: std.mem.Allocator, text: []const u8) ![]const Span {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < text.len) {
        const c = text[i];

        // Inline code
        if (c == '`') {
            if (i > plain_start) {
                try spans.append(allocator, .{ .kind = .text, .text = text[plain_start..i] });
            }
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                i += 1;
                continue;
            };
            try spans.append(allocator, .{ .kind = .code, .text = text[i + 1 .. end] });
            i = end + 1;
            plain_start = i;
            continue;
        }

        // Link [text](url)
        if (c == '[') {
            if (findLink(text, i)) |found| {
                if (i > plain_start) {
                    try spans.append(allocator, .{ .kind = .text, .text = text[plain_start..i] });
                }
                try spans.append(allocator, .{
                    .kind = .link,
                    .text = text[found.text_start..found.text_end],
                    .url = text[found.url_start..found.url_end],
                });
                i = found.end;
                plain_start = i;
                continue;
            }
        }

        // Bold / italic / bold-italic — asterisks
        if (c == '*') {
            // Count asterisks
            var star_count: usize = 0;
            while (i + star_count < text.len and text[i + star_count] == '*' and star_count < 3) star_count += 1;
            if (star_count >= 1 and star_count <= 3) {
                // Find matching closing sequence of the same count
                var search_from = i + star_count;
                while (search_from < text.len) {
                    const maybe_close = std.mem.indexOfScalarPos(u8, text, search_from, '*') orelse break;
                    var close_count: usize = 0;
                    while (maybe_close + close_count < text.len and text[maybe_close + close_count] == '*' and close_count < 3) close_count += 1;
                    if (close_count >= star_count) {
                        // Match
                        if (i > plain_start) {
                            try spans.append(allocator, .{ .kind = .text, .text = text[plain_start..i] });
                        }
                        const inner = text[i + star_count .. maybe_close];
                        const kind: SpanKind = if (star_count == 3) .bold_italic else if (star_count == 2) .bold else .italic;
                        try spans.append(allocator, .{ .kind = kind, .text = inner });
                        i = maybe_close + star_count;
                        plain_start = i;
                        break;
                    }
                    search_from = maybe_close + close_count;
                } else {
                    // No matching close — treat as literal
                    i += 1;
                    continue;
                }
                continue;
            }
        }

        i += 1;
    }

    if (plain_start < text.len) {
        try spans.append(allocator, .{ .kind = .text, .text = text[plain_start..] });
    }

    return spans.toOwnedSlice(allocator);
}

const LinkMatch = struct {
    text_start: usize,
    text_end: usize,
    url_start: usize,
    url_end: usize,
    end: usize,
};

fn findLink(text: []const u8, start: usize) ?LinkMatch {
    // [text](url) — the text_end ] must be followed immediately by (
    var depth: u32 = 1;
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (i >= text.len or depth != 0) return null;
    const text_close = i;
    if (text_close + 1 >= text.len or text[text_close + 1] != '(') return null;
    const url_open = text_close + 2;
    const url_close = std.mem.indexOfScalarPos(u8, text, url_open, ')') orelse return null;
    return .{
        .text_start = start + 1,
        .text_end = text_close,
        .url_start = url_open,
        .url_end = url_close,
        .end = url_close + 1,
    };
}

fn parseFrontmatter(yaml: []const u8) Frontmatter {
    var fm = Frontmatter{};
    var it = std.mem.splitScalar(u8, yaml, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        // Strip surrounding quotes
        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            }
        }
        if (std.mem.eql(u8, key, "title")) fm.title = value
        else if (std.mem.eql(u8, key, "author")) fm.author = value
        else if (std.mem.eql(u8, key, "date")) fm.date = value
        else if (std.mem.eql(u8, key, "description")) fm.description = value;
    }
    return fm;
}

// Line iterator with peek — splits on \n, leaves \r to be trimmed later.
const LineIterator = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const nl = std.mem.indexOfScalarPos(u8, self.src, start, '\n') orelse {
            self.pos = self.src.len;
            return self.src[start..];
        };
        self.pos = nl + 1;
        return self.src[start..nl];
    }

    fn peek(self: *LineIterator) ?[]const u8 {
        const saved = self.pos;
        defer self.pos = saved;
        return self.next();
    }
};

fn lineIterator(src: []const u8) LineIterator {
    return .{ .src = src };
}

// =============================================================================
// Renderer
// =============================================================================

// Layout constants
const INK_BLACK = document.Color{ .r = 0.059, .g = 0.059, .b = 0.059 }; // #0f0f0f
const MUTED_GREY = document.Color{ .r = 0.322, .g = 0.322, .b = 0.357 }; // #52525b
const SUBTLE_GREY = document.Color{ .r = 0.443, .g = 0.443, .b = 0.478 }; // #71717a
const BORDER_GREY = document.Color{ .r = 0.894, .g = 0.894, .b = 0.906 }; // #e4e4e7
const CODE_BG = document.Color{ .r = 0.961, .g = 0.961, .b = 0.949 }; // #f5f5f4
const LINK_COLOR = document.Color{ .r = 0.149, .g = 0.388, .b = 0.835 }; // #2463d5
const ACCENT_RED = document.Color{ .r = 0.863, .g = 0.149, .b = 0.149 }; // #dc2626

const BODY_SIZE: f32 = 11;
const LINE_HEIGHT: f32 = 15;
const PARAGRAPH_GAP: f32 = 8;
const BLOCK_GAP: f32 = 14;
const CODE_SIZE: f32 = 10;
const CODE_LINE_HEIGHT: f32 = 13;

const HEADING_SIZES = [_]f32{ 22, 17, 14, 12, 11, 11 };
const HEADING_GAPS_BEFORE = [_]f32{ 22, 20, 16, 12, 10, 10 };
const HEADING_GAPS_AFTER = [_]f32{ 10, 8, 6, 4, 4, 4 };

const BULLET_INDENT: f32 = 18;
const BULLET_TEXT_INDENT: f32 = 32;

const Renderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    doc_parsed: ParsedDocument,

    font_regular: []const u8,
    font_bold: []const u8,
    font_oblique: []const u8,
    font_bold_oblique: []const u8,
    font_code: []const u8,

    current_y: f32,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    margin_left: f32 = 60,
    margin_right: f32 = 60,
    margin_top: f32 = 60,
    margin_bottom: f32 = 60,
    usable_width: f32,

    pages: std.ArrayListUnmanaged(document.ContentStream),
    page_number: u32 = 1,
    total_pages: u32 = 1,

    fn init(allocator: std.mem.Allocator, parsed: ParsedDocument) Renderer {
        var r = Renderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .doc_parsed = parsed,
            .font_regular = undefined,
            .font_bold = undefined,
            .font_oblique = undefined,
            .font_bold_oblique = undefined,
            .font_code = undefined,
            .current_y = 0,
            .usable_width = 0,
            .pages = .empty,
        };
        r.usable_width = r.page_width - r.margin_left - r.margin_right;
        r.font_regular = r.doc.getFontId(.helvetica);
        r.font_bold = r.doc.getFontId(.helvetica_bold);
        r.font_oblique = r.doc.getFontId(.helvetica_oblique);
        r.font_bold_oblique = r.doc.getFontId(.helvetica_bold_oblique);
        r.font_code = r.doc.getFontId(.courier);
        r.current_y = r.page_height - r.margin_top;
        return r;
    }

    fn deinit(self: *Renderer) void {
        for (self.pages.items) |*page| page.deinit();
        self.pages.deinit(self.allocator);
        self.doc.deinit();
    }

    fn fontForSpan(self: *const Renderer, kind: SpanKind) []const u8 {
        return switch (kind) {
            .text, .link => self.font_regular,
            .bold => self.font_bold,
            .italic => self.font_oblique,
            .bold_italic => self.font_bold_oblique,
            .code => self.font_code,
        };
    }

    fn fontEnumForSpan(kind: SpanKind) document.Font {
        return switch (kind) {
            .text, .link => .helvetica,
            .bold => .helvetica_bold,
            .italic => .helvetica_oblique,
            .bold_italic => .helvetica_bold_oblique,
            .code => .courier,
        };
    }

    fn checkPageBreak(self: *Renderer, content: *document.ContentStream, needed: f32) !void {
        if (self.current_y - needed >= self.margin_bottom) return;
        try self.pages.append(self.allocator, content.*);
        content.* = document.ContentStream.init(self.allocator);
        self.current_y = self.page_height - self.margin_top;
    }

    // Lay out spans across multiple lines, wrapping on word boundaries.
    // size_px = font size in points for all non-code spans. code is drawn at CODE_SIZE.
    fn drawSpans(
        self: *Renderer,
        content: *document.ContentStream,
        spans: []const Span,
        x_start: f32,
        max_width: f32,
        size_px: f32,
        line_h: f32,
        color: document.Color,
    ) !void {
        // Flatten each span into word-sized drawables; then greedy fill lines.
        const WordDraw = struct {
            kind: SpanKind,
            text: []const u8,
            width: f32,
            url: []const u8,
            is_space: bool,
        };

        var words: std.ArrayListUnmanaged(WordDraw) = .empty;
        defer words.deinit(self.allocator);

        for (spans) |span| {
            const font_enum = fontEnumForSpan(span.kind);
            const effective_size = if (span.kind == .code) size_px - 1 else size_px;
            // Split span text on whitespace, preserving single-space tokens
            var i: usize = 0;
            while (i < span.text.len) {
                if (span.text[i] == ' ') {
                    const space_w = font_enum.measureText(" ", effective_size);
                    try words.append(self.allocator, .{
                        .kind = span.kind,
                        .text = " ",
                        .width = space_w,
                        .url = span.url,
                        .is_space = true,
                    });
                    i += 1;
                    continue;
                }
                const word_start = i;
                while (i < span.text.len and span.text[i] != ' ') i += 1;
                const word = span.text[word_start..i];
                const w = font_enum.measureText(word, effective_size);
                try words.append(self.allocator, .{
                    .kind = span.kind,
                    .text = word,
                    .width = w,
                    .url = span.url,
                    .is_space = false,
                });
            }
        }

        // Greedy line fill
        var line_words: std.ArrayListUnmanaged(WordDraw) = .empty;
        defer line_words.deinit(self.allocator);
        var line_width: f32 = 0;

        var idx: usize = 0;
        while (idx < words.items.len) {
            const w = words.items[idx];
            // Collapse leading space on a new line
            if (line_words.items.len == 0 and w.is_space) {
                idx += 1;
                continue;
            }
            if (line_width + w.width > max_width and line_words.items.len > 0) {
                // Emit line (strip trailing space)
                var emit = line_words.items;
                while (emit.len > 0 and emit[emit.len - 1].is_space) emit.len -= 1;
                try self.emitLine(content, emit, x_start, size_px, line_h, color);
                line_words.clearRetainingCapacity();
                line_width = 0;
                continue; // retry this word on fresh line
            }
            try line_words.append(self.allocator, w);
            line_width += w.width;
            idx += 1;
        }
        if (line_words.items.len > 0) {
            var emit = line_words.items;
            while (emit.len > 0 and emit[emit.len - 1].is_space) emit.len -= 1;
            try self.emitLine(content, emit, x_start, size_px, line_h, color);
        }
    }

    fn emitLine(
        self: *Renderer,
        content: *document.ContentStream,
        words: anytype,
        x_start: f32,
        size_px: f32,
        line_h: f32,
        color: document.Color,
    ) !void {
        try self.checkPageBreak(content, line_h);

        var x = x_start;
        for (words) |w| {
            const font_id = self.fontForSpan(w.kind);
            const effective_size = if (w.kind == .code) size_px - 1 else size_px;
            const effective_color = switch (w.kind) {
                .link => LINK_COLOR,
                .code => INK_BLACK,
                else => color,
            };
            try content.drawText(w.text, x, self.current_y, font_id, effective_size, effective_color);
            x += w.width;
        }
        self.current_y -= line_h;
    }

    fn drawHeading(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        const level = @min(@max(block.level, 1), 6);
        const size = HEADING_SIZES[level - 1];
        const gap_before = HEADING_GAPS_BEFORE[level - 1];
        const gap_after = HEADING_GAPS_AFTER[level - 1];

        self.current_y -= gap_before - BLOCK_GAP;

        // Reserve room for heading plus at least three body lines so a heading
        // never appears as the last thing on a page (widow prevention).
        try self.checkPageBreak(content, size + gap_after + LINE_HEIGHT * 3);

        // Promote plain text spans to bold so measurement and drawing both use
        // helvetica-bold glyph widths. Without this, "Activity log" measured
        // with helvetica-regular widths but drawn bold overlaps — spaces vanish.
        const promoted = try self.promoteTextToBold(block.spans);
        defer self.allocator.free(promoted);

        try self.drawSpans(content, promoted, self.margin_left, self.usable_width, size, size * 1.25, INK_BLACK);
        self.current_y -= gap_after;
    }

    /// Copy spans, flipping plain-text kind to bold. Used for headings so that
    /// the bold rendering matches bold measurement.
    fn promoteTextToBold(self: *Renderer, spans: []const Span) ![]Span {
        const out = try self.allocator.alloc(Span, spans.len);
        for (spans, 0..) |s, i| {
            out[i] = .{
                .kind = if (s.kind == .text) .bold else if (s.kind == .italic) .bold_italic else s.kind,
                .text = s.text,
                .url = s.url,
            };
        }
        return out;
    }

    fn drawParagraph(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        try self.drawSpans(content, block.spans, self.margin_left, self.usable_width, BODY_SIZE, LINE_HEIGHT, INK_BLACK);
        self.current_y -= PARAGRAPH_GAP;
    }

    fn drawBlockquote(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        // Grey left bar + indented prose
        try self.checkPageBreak(content, LINE_HEIGHT * 2);
        const bar_x = self.margin_left;
        const bar_top = self.current_y + 4;
        const text_x = self.margin_left + 14;
        const text_w = self.usable_width - 14;
        const y_before = self.current_y;
        try self.drawSpans(content, block.spans, text_x, text_w, BODY_SIZE, LINE_HEIGHT, MUTED_GREY);
        // Draw the bar spanning the prose block
        try content.drawLine(bar_x, bar_top, bar_x, self.current_y + 3, BORDER_GREY, 3);
        _ = y_before;
        self.current_y -= PARAGRAPH_GAP;
    }

    fn drawList(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        const is_ordered = block.kind == .ordered_list;
        for (block.items, 0..) |item, i| {
            try self.checkPageBreak(content, LINE_HEIGHT + 4);

            // Bullet marker
            if (is_ordered) {
                var num_buf: [16]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}.", .{i + 1});
                try content.drawText(num_str, self.margin_left + BULLET_INDENT - 4, self.current_y, self.font_regular, BODY_SIZE, MUTED_GREY);
            } else {
                // Red 3px dot
                const cx = self.margin_left + BULLET_INDENT;
                const cy = self.current_y + 4;
                try content.drawCircle(cx, cy, 1.7, ACCENT_RED, null);
            }

            // Text
            const text_x = self.margin_left + BULLET_TEXT_INDENT;
            const text_w = self.usable_width - BULLET_TEXT_INDENT;
            try self.drawSpans(content, item.spans, text_x, text_w, BODY_SIZE, LINE_HEIGHT, INK_BLACK);
            self.current_y -= 2; // small gap between items
        }
        self.current_y -= PARAGRAPH_GAP - 2;
    }

    fn drawCodeBlock(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        const pad: f32 = 10;
        const inner_w = self.usable_width - pad * 2;

        // Pre-wrap every source line so nothing runs off the page.
        var all_visual_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer all_visual_lines.deinit(self.allocator);

        var source_iter = std.mem.splitScalar(u8, block.code, '\n');
        while (source_iter.next()) |src_line| {
            if (src_line.len == 0) {
                try all_visual_lines.append(self.allocator, "");
                continue;
            }
            const wrapped = try document.wrapText(self.allocator, src_line, .courier, CODE_SIZE, inner_w);
            defer self.allocator.free(wrapped.lines);
            if (wrapped.lines.len == 0) {
                try all_visual_lines.append(self.allocator, src_line);
            } else {
                for (wrapped.lines) |wl| try all_visual_lines.append(self.allocator, wl);
            }
        }

        const line_count = all_visual_lines.items.len;
        const code_height = @as(f32, @floatFromInt(line_count)) * CODE_LINE_HEIGHT + pad * 2;
        try self.checkPageBreak(content, code_height + 6);

        const x = self.margin_left;
        const w = self.usable_width;
        const top_y = self.current_y + 2;
        const bottom_y = top_y - code_height;

        try content.drawRoundedRect(x, bottom_y, w, code_height, 4, CODE_BG);

        var text_y = top_y - pad - CODE_SIZE;
        for (all_visual_lines.items) |line| {
            try content.drawText(line, x + pad, text_y, self.font_code, CODE_SIZE, INK_BLACK);
            text_y -= CODE_LINE_HEIGHT;
        }

        self.current_y = bottom_y - PARAGRAPH_GAP;
    }

    /// Measure the height a table row will consume once all its cells are
    /// wrapped to column width. Used to ensure page breaks happen BETWEEN rows
    /// rather than mid-cell (which produced huge blank gaps).
    fn measureRowHeight(
        self: *Renderer,
        row: TableRow,
        col_w: f32,
        col_pad: f32,
        above_pad: f32,
        below_pad: f32,
        line_h: f32,
    ) !f32 {
        var max_lines: usize = 1;
        const inner_w = col_w - col_pad * 2;
        for (row.cells) |cell| {
            const lines = try self.countWrappedLines(cell.spans, inner_w, BODY_SIZE);
            if (lines > max_lines) max_lines = lines;
        }
        const text_height = @as(f32, @floatFromInt(max_lines)) * line_h;
        return above_pad + text_height + below_pad;
    }

    /// Count the number of visual lines a set of spans will produce when
    /// wrapped to max_width at the given size. Mirrors the greedy word-packing
    /// logic in drawSpans so the measurement stays in sync with rendering.
    fn countWrappedLines(
        self: *Renderer,
        spans: []const Span,
        max_width: f32,
        size: f32,
    ) !usize {
        // Flatten spans into words (same shape drawSpans builds internally)
        var words: std.ArrayListUnmanaged(struct {
            text: []const u8,
            width: f32,
            is_space: bool,
        }) = .empty;
        defer words.deinit(self.allocator);

        for (spans) |span| {
            const font_enum = fontEnumForSpan(span.kind);
            const eff_size = if (span.kind == .code) size - 1 else size;
            var i: usize = 0;
            while (i < span.text.len) {
                if (span.text[i] == ' ') {
                    try words.append(self.allocator, .{
                        .text = " ",
                        .width = font_enum.measureText(" ", eff_size),
                        .is_space = true,
                    });
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < span.text.len and span.text[i] != ' ') i += 1;
                const word = span.text[start..i];
                try words.append(self.allocator, .{
                    .text = word,
                    .width = font_enum.measureText(word, eff_size),
                    .is_space = false,
                });
            }
        }

        // Greedy line fill — count line emissions
        var line_count: usize = 0;
        var line_width: f32 = 0;
        var has_words_on_line: bool = false;

        for (words.items) |w| {
            if (!has_words_on_line and w.is_space) continue;
            if (line_width + w.width > max_width and has_words_on_line) {
                line_count += 1;
                line_width = if (w.is_space) 0 else w.width;
                has_words_on_line = !w.is_space;
                continue;
            }
            line_width += w.width;
            if (!w.is_space) has_words_on_line = true;
        }
        if (has_words_on_line) line_count += 1;
        return @max(1, line_count);
    }

    fn drawTable(self: *Renderer, content: *document.ContentStream, block: Block) !void {
        const tbl = block.table orelse return;
        const ncols = tbl.header.cells.len;
        if (ncols == 0) return;

        // Tight table layout: top/bottom padding sized to ascender/descender
        // extents so borders sit cleanly above and below the text without
        // cutting through glyphs.
        const col_pad: f32 = 8;
        const above_text_pad: f32 = 10; // clearance above ascender for top border
        const below_text_pad: f32 = 2; // clearance below descender for bottom border
        const table_line_h: f32 = 13;
        const col_w = self.usable_width / @as(f32, @floatFromInt(ncols));
        const row_height_min: f32 = above_text_pad + table_line_h + below_text_pad;

        const cell_border = document.Color{ .r = 0.70, .g = 0.70, .b = 0.72 }; // slightly stronger so cells read clearly

        // Measure the header row's actual height (it may wrap across multiple lines)
        const header_h = try self.measureRowHeight(tbl.header, col_w, col_pad, above_text_pad, below_text_pad, table_line_h);

        // Reserve room for the header + at least one data row (or measured first row)
        const first_row_h = if (tbl.rows.len > 0)
            try self.measureRowHeight(tbl.rows[0], col_w, col_pad, above_text_pad, below_text_pad, table_line_h)
        else
            row_height_min;
        try self.checkPageBreak(content, header_h + first_row_h + 8);

        // Draw the header row (borders + text)
        try self.drawTableRowWithBorders(content, tbl.header, col_w, col_pad, above_text_pad, below_text_pad, table_line_h, true, cell_border, true);

        // Data rows — pre-measure each row's height so multi-line cells don't get
        // split across pages mid-cell (which previously left a huge blank gap
        // between the row's top half and its continuation on the next page).
        // When a page break occurs mid-table the continuation row needs its
        // own top border (the previous row's bottom border is on the prior page).
        for (tbl.rows) |row| {
            const row_h = try self.measureRowHeight(row, col_w, col_pad, above_text_pad, below_text_pad, table_line_h);
            const y_before = self.current_y;
            try self.checkPageBreak(content, row_h);
            const page_broke = self.current_y > y_before; // y jumps upward on break
            try self.drawTableRowWithBorders(content, row, col_w, col_pad, above_text_pad, below_text_pad, table_line_h, false, cell_border, page_broke);
        }

        self.current_y -= PARAGRAPH_GAP;
    }

    /// Draw a table row with full cell borders (top edge, bottom edge, left,
    /// right, and internal column separators). Call with is_first_row=true for
    /// the very first row (header) to also draw the top border of the table.
    fn drawTableRowWithBorders(
        self: *Renderer,
        content: *document.ContentStream,
        row: TableRow,
        col_w: f32,
        col_pad: f32,
        above_pad: f32,
        below_pad: f32,
        line_h: f32,
        is_header: bool,
        cell_border: document.Color,
        is_first_row: bool,
    ) !void {
        const ncols = row.cells.len;
        const table_left = self.margin_left;
        const table_right = self.page_width - self.margin_right;

        // Row top is the current y position. Text baseline will be pushed
        // `above_pad` points below this — `above_pad` must exceed the font's
        // ascender height so the top border clears the glyph caps.
        const row_top = self.current_y;

        if (is_first_row) {
            try content.drawLine(table_left, row_top, table_right, row_top, cell_border, 0.6);
        }

        self.current_y -= above_pad;
        try self.drawTableRow(content, row, col_w, col_pad, line_h, is_header);

        // After drawTableRow, current_y = first_baseline - N*line_h.
        // The descender of the LAST line sits at current_y + line_h - 2
        // (where 2pt ≈ helvetica descender depth). Place the bottom border
        // `below_pad` points beneath that so it doesn't touch the descender.
        const descender_adj: f32 = 2;
        self.current_y = self.current_y + line_h - descender_adj - below_pad;

        const row_bottom = self.current_y;

        const bottom_weight: f32 = if (is_header) 0.9 else 0.5;
        try content.drawLine(table_left, row_bottom, table_right, row_bottom, cell_border, bottom_weight);

        // Vertical borders scoped to this row only (so a page-spanning table
        // doesn't draw phantom verticals across empty regions).
        try content.drawLine(table_left, row_top, table_left, row_bottom, cell_border, 0.6);
        try content.drawLine(table_right, row_top, table_right, row_bottom, cell_border, 0.6);
        var ci: usize = 1;
        while (ci < ncols) : (ci += 1) {
            const vx = table_left + @as(f32, @floatFromInt(ci)) * col_w;
            try content.drawLine(vx, row_top, vx, row_bottom, cell_border, 0.4);
        }
    }

    fn drawTableRow(
        self: *Renderer,
        content: *document.ContentStream,
        row: TableRow,
        col_w: f32,
        col_pad: f32,
        line_h: f32,
        is_header: bool,
    ) !void {
        const start_y = self.current_y;
        var max_consumed: f32 = 0;

        for (row.cells, 0..) |cell, i| {
            const col_x = self.margin_left + @as(f32, @floatFromInt(i)) * col_w + col_pad;
            const inner_w = col_w - col_pad * 2;

            self.current_y = start_y;

            const spans_to_draw = if (is_header) try self.promoteTextToBold(cell.spans) else cell.spans;
            defer if (is_header) self.allocator.free(spans_to_draw);

            try self.drawSpans(content, spans_to_draw, col_x, inner_w, BODY_SIZE, line_h, INK_BLACK);

            const consumed = start_y - self.current_y;
            if (consumed > max_consumed) max_consumed = consumed;
        }

        self.current_y = start_y - max_consumed;
    }

    fn drawHorizontalRule(self: *Renderer, content: *document.ContentStream) !void {
        try self.checkPageBreak(content, 20);
        self.current_y -= 6;
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, BORDER_GREY, 0.5);
        self.current_y -= 14;
    }

    fn drawFooter(self: *Renderer, content: *document.ContentStream) !void {
        const y = self.margin_bottom - 24;
        if (self.total_pages > 1) {
            var buf: [32]u8 = undefined;
            const pg = try std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.page_number, self.total_pages });
            const w = document.Font.helvetica.measureText(pg, 9);
            try content.drawText(pg, self.page_width - self.margin_right - w, y, self.font_regular, 9, SUBTLE_GREY);
        }
    }

    fn render(self: *Renderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        errdefer content.deinit();

        // Optional title block from frontmatter
        const fm = self.doc_parsed.frontmatter;
        if (fm.title.len > 0) {
            const t_spans = &[_]Span{.{ .kind = .bold, .text = fm.title }};
            try self.drawSpans(&content, t_spans, self.margin_left, self.usable_width, 26, 32, INK_BLACK);
            self.current_y -= 4;
            if (fm.date.len > 0 or fm.author.len > 0) {
                var meta: std.ArrayListUnmanaged(u8) = .empty;
                defer meta.deinit(self.allocator);
                if (fm.author.len > 0) try meta.appendSlice(self.allocator, fm.author);
                if (fm.author.len > 0 and fm.date.len > 0) try meta.appendSlice(self.allocator, "  \u{00B7}  ");
                if (fm.date.len > 0) try meta.appendSlice(self.allocator, fm.date);
                const m_spans = &[_]Span{.{ .kind = .text, .text = meta.items }};
                try self.drawSpans(&content, m_spans, self.margin_left, self.usable_width, 10, 14, SUBTLE_GREY);
            }
            self.current_y -= 18;
        }

        for (self.doc_parsed.blocks) |block| {
            switch (block.kind) {
                .heading => try self.drawHeading(&content, block),
                .paragraph => try self.drawParagraph(&content, block),
                .blockquote => try self.drawBlockquote(&content, block),
                .bullet_list, .ordered_list => try self.drawList(&content, block),
                .code_block => try self.drawCodeBlock(&content, block),
                .horizontal_rule => try self.drawHorizontalRule(&content),
                .table => try self.drawTable(&content, block),
            }
        }

        // Save final page
        try self.pages.append(self.allocator, content);
        content.buffer = .empty;

        self.total_pages = @intCast(self.pages.items.len);
        for (self.pages.items, 0..) |*page, idx| {
            self.page_number = @intCast(idx + 1);
            try self.drawFooter(page);
            try self.doc.addPage(page);
        }

        return try self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Render a markdown string to a PDF. Returned slice is owned by caller.
pub fn generateFromMarkdown(allocator: std.mem.Allocator, md: []const u8) ![]u8 {
    // Everything transient goes in an arena so we don't leak parsed nodes.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parse(arena_alloc, md);
    var renderer = Renderer.init(arena_alloc, parsed);
    defer renderer.deinit();

    const pdf_bytes = try renderer.render();
    return try allocator.dupe(u8, pdf_bytes);
}
