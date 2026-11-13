// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Markdown Parser — converts CommonMark-subset markdown into the
//! Document model (docx.zig types) for subsequent DOCX generation.
//!
//! Supported syntax:
//!   # Heading 1 through ###### Heading 6
//!   **bold**, *italic*, ***bold italic***
//!   `inline code`
//!   [link text](url)
//!   ~~struck through~~, ==highlighted==
//!   [text]{color=red bg=#fee2e2 strike underline}
//!   CriticMarkup: {--deleted--} {++inserted++} {~~old~>new~~} {==highlighted==}
//!   (inline marks nest; see parseInlineFormatting)
//!   - / * / + unordered lists (with nesting via indentation)
//!   1. ordered lists
//!   ```lang  fenced code blocks  ```
//!   > blockquotes
//!   --- horizontal rules
//!   | table | syntax |
//!   --- YAML frontmatter ---

const std = @import("std");
const docx = @import("docx.zig");
const StyleType = @import("styles.zig").StyleType;
const isSafeLinkUrl = @import("mdx.zig").isSafeLinkUrl;

pub const FrontMatter = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    description: ?[]const u8 = null,
    letterhead: ?[]const u8 = null, // <!-- letterhead: logo.png -->
};

pub const ParseResult = struct {
    document: docx.Document,
    frontmatter: FrontMatter,
    allocator: std.mem.Allocator,
    /// Base directory for resolving relative image paths. Null = cwd.
    base_dir: ?[]const u8 = null,

    pub fn deinit(self: *ParseResult) void {
        self.document.deinit();
        if (self.frontmatter.title) |t| self.allocator.free(t);
        if (self.frontmatter.author) |a| self.allocator.free(a);
        if (self.frontmatter.date) |d| self.allocator.free(d);
        if (self.frontmatter.description) |d| self.allocator.free(d);
        if (self.frontmatter.letterhead) |l| self.allocator.free(l);
        if (self.base_dir) |b| self.allocator.free(b);
    }
};

/// Parse markdown text into a Document model + optional YAML frontmatter.
pub fn parseMarkdown(allocator: std.mem.Allocator, markdown: []const u8) !ParseResult {
    var elements: std.ArrayListUnmanaged(docx.Element) = .empty;
    errdefer {
        for (elements.items) |*e| freeElement(allocator, e);
        elements.deinit(allocator);
    }

    var frontmatter = FrontMatter{};
    var lines = std.mem.splitScalar(u8, markdown, '\n');

    // Check for YAML frontmatter (--- delimited)
    const first_line = lines.peek() orelse "";
    if (std.mem.eql(u8, std.mem.trim(u8, first_line, " \t\r"), "---")) {
        _ = lines.next(); // consume opening ---
        frontmatter = try parseFrontMatter(allocator, &lines);
    }

    // Block-level parsing
    var in_code_block = false;
    var code_lines: std.ArrayListUnmanaged(u8) = .empty;
    defer code_lines.deinit(allocator);

    var in_table = false;
    var table_rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer table_rows.deinit(allocator);
    var table_header_seen = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        // ── Code block toggle ──
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            if (in_code_block) {
                // End code block — emit as a single paragraph
                const code_text = try allocator.dupe(u8, code_lines.items);
                const runs = try allocator.alloc(docx.Run, 1);
                runs[0] = .{ .text = code_text };
                try elements.append(allocator, .{ .paragraph = .{
                    .style = .code_block,
                    .runs = runs,
                } });
                code_lines.clearRetainingCapacity();
                in_code_block = false;
            } else {
                // Flush any pending table
                if (in_table) {
                    try flushTable(allocator, &elements, &table_rows);
                    in_table = false;
                    table_header_seen = false;
                }
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            if (code_lines.items.len > 0) try code_lines.append(allocator, '\n');
            try code_lines.appendSlice(allocator, line);
            continue;
        }

        // ── Table rows ──
        if (line.len > 0 and line[0] == '|') {
            if (!in_table) {
                in_table = true;
                table_header_seen = false;
            }
            // Skip separator rows (| --- | --- |)
            if (isSeparatorRow(line)) {
                table_header_seen = true;
                continue;
            }
            const row = try parseTableRow(allocator, line);
            try table_rows.append(allocator, row);
            continue;
        } else if (in_table) {
            try flushTable(allocator, &elements, &table_rows);
            in_table = false;
            table_header_seen = false;
        }

        // ── Blank line ──
        if (line.len == 0 or std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "")) {
            continue; // paragraph breaks are implicit between elements
        }

        // ── HTML comment directives ──
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "<!--") and std.mem.endsWith(u8, trimmed, "-->")) {
            const comment = std.mem.trim(u8, trimmed[4 .. trimmed.len - 3], " \t");
            if (std.mem.startsWith(u8, comment, "letterhead:")) {
                const path = std.mem.trim(u8, comment["letterhead:".len..], " \t");
                if (path.len > 0) {
                    if (frontmatter.letterhead) |old| allocator.free(old);
                    frontmatter.letterhead = try allocator.dupe(u8, path);
                }
            } else if (std.mem.eql(u8, comment, "pagebreak")) {
                // <!-- pagebreak --> on its own line → a hard Word page break.
                try elements.append(allocator, .{ .paragraph = .{
                    .style = .page_break,
                    .runs = &[_]docx.Run{},
                } });
            }
            continue; // consume comment, don't emit as paragraph
        }

        // ── Card block ( :::card … ::: ) ──
        // Renders inner lines as a single-cell bordered table (an address
        // "card" box). Inner lines keep inline formatting and each become a
        // separate paragraph inside the one cell.
        if (std.mem.eql(u8, trimmed, ":::card")) {
            var cell_paras: std.ArrayListUnmanaged(docx.Paragraph) = .empty;
            errdefer {
                for (cell_paras.items) |cp| {
                    for (cp.runs) |r| {
                        if (r.text.len > 0) allocator.free(r.text);
                        if (r.hyperlink_url) |u| allocator.free(u);
                    }
                    if (cp.runs.len > 0) allocator.free(cp.runs);
                }
                cell_paras.deinit(allocator);
            }
            while (lines.next()) |inner_raw| {
                const inner_line = std.mem.trimEnd(u8, inner_raw, "\r");
                const inner_trimmed = std.mem.trim(u8, inner_line, " \t");
                if (std.mem.eql(u8, inner_trimmed, ":::")) break; // end of card
                const runs = try parseInlineFormatting(allocator, inner_trimmed);
                try cell_paras.append(allocator, .{ .style = .normal, .runs = runs });
            }
            const paras = try cell_paras.toOwnedSlice(allocator);
            const cells = try allocator.alloc(docx.TableCell, 1);
            cells[0] = .{ .paragraphs = paras };
            const rows = try allocator.alloc(docx.TableRow, 1);
            rows[0] = .{ .cells = cells };
            try elements.append(allocator, .{ .table = .{ .rows = rows } });
            continue;
        }

        // ── Horizontal rule ──
        if (isHorizontalRule(trimmed)) {
            try elements.append(allocator, .{ .paragraph = .{
                .style = .horizontal_rule,
                .runs = &[_]docx.Run{},
            } });
            continue;
        }

        // ── Heading ──
        if (line.len > 0 and line[0] == '#') {
            if (parseHeading(line)) |h| {
                const runs = try parseInlineFormatting(allocator, h.text);
                try elements.append(allocator, .{ .paragraph = .{
                    .style = h.style,
                    .runs = runs,
                } });
                continue;
            }
        }

        // ── Blockquote ──
        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const quote_text = trimmed[2..];
            const runs = try parseInlineFormatting(allocator, quote_text);
            try elements.append(allocator, .{ .paragraph = .{
                .style = .blockquote,
                .runs = runs,
            } });
            continue;
        }
        if (std.mem.eql(u8, trimmed, ">")) {
            continue; // empty blockquote line
        }

        // ── Unordered list ──
        if (parseUnorderedListItem(line)) |item| {
            const runs = try parseInlineFormatting(allocator, item.text);
            try elements.append(allocator, .{ .paragraph = .{
                .style = .list_paragraph,
                .runs = runs,
                .is_list_item = true,
                .is_ordered = false,
                .numbering_level = item.level,
            } });
            continue;
        }

        // ── Ordered list ──
        if (parseOrderedListItem(line)) |item| {
            const runs = try parseInlineFormatting(allocator, item.text);
            try elements.append(allocator, .{ .paragraph = .{
                .style = .list_paragraph,
                .runs = runs,
                .is_list_item = true,
                .is_ordered = true,
                .numbering_level = item.level,
            } });
            continue;
        }

        // ── Normal paragraph ──
        const runs = try parseInlineFormatting(allocator, trimmed);
        try elements.append(allocator, .{ .paragraph = .{
            .style = .normal,
            .runs = runs,
        } });
    }

    // Flush any trailing code block or table
    if (in_code_block and code_lines.items.len > 0) {
        const code_text = try allocator.dupe(u8, code_lines.items);
        const runs = try allocator.alloc(docx.Run, 1);
        runs[0] = .{ .text = code_text };
        try elements.append(allocator, .{ .paragraph = .{
            .style = .code_block,
            .runs = runs,
        } });
    }
    if (in_table and table_rows.items.len > 0) {
        try flushTable(allocator, &elements, &table_rows);
    }

    return ParseResult{
        .document = .{
            .elements = try elements.toOwnedSlice(allocator),
            .media = &[_]docx.MediaFile{},
            .allocator = allocator,
        },
        .frontmatter = frontmatter,
        .allocator = allocator,
    };
}

// ── Heading parser ──────────────────────────────────────────────

const HeadingResult = struct { style: StyleType, text: []const u8 };

fn parseHeading(line: []const u8) ?HeadingResult {
    var level: u8 = 0;
    while (level < line.len and level < 6 and line[level] == '#') level += 1;
    if (level == 0 or level >= line.len) return null;
    if (line[level] != ' ') return null; // "##text" is not a heading
    const text = std.mem.trim(u8, line[level + 1 ..], " \t");
    const style: StyleType = switch (level) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        6 => .heading6,
        else => .normal,
    };
    return .{ .style = style, .text = text };
}

// ── List parsers ────────────────────────────────────────────────

const ListItem = struct { text: []const u8, level: u8 };

fn parseUnorderedListItem(line: []const u8) ?ListItem {
    var indent: u8 = 0;
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {
        indent += if (line[i] == '\t') 4 else 1;
    }
    if (i >= line.len) return null;
    if ((line[i] == '-' or line[i] == '*' or line[i] == '+') and
        i + 1 < line.len and line[i + 1] == ' ')
    {
        return .{
            .text = std.mem.trim(u8, line[i + 2 ..], " \t"),
            .level = indent / 2, // 2 spaces per nesting level
        };
    }
    return null;
}

fn parseOrderedListItem(line: []const u8) ?ListItem {
    var indent: u8 = 0;
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {
        indent += if (line[i] == '\t') 4 else 1;
    }
    // Look for digits followed by ". "
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start or i >= line.len) return null;
    if (line[i] == '.' and i + 1 < line.len and line[i + 1] == ' ') {
        return .{
            .text = std.mem.trim(u8, line[i + 2 ..], " \t"),
            .level = indent / 2,
        };
    }
    return null;
}

// ── Horizontal rule ─────────────────────────────────────────────

fn isHorizontalRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const c = trimmed[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (trimmed) |ch| {
        if (ch != c and ch != ' ') return false;
    }
    return true;
}

// ── Table helpers ───────────────────────────────────────────────

fn isSeparatorRow(line: []const u8) bool {
    for (line) |c| {
        if (c != '|' and c != '-' and c != ':' and c != ' ' and c != '\t') return false;
    }
    return true;
}

fn parseTableRow(allocator: std.mem.Allocator, line: []const u8) !docx.TableRow {
    var cells: std.ArrayListUnmanaged(docx.TableCell) = .empty;
    errdefer cells.deinit(allocator);

    // Split by | and trim, skipping leading/trailing empty segments
    var iter = std.mem.splitScalar(u8, line, '|');
    while (iter.next()) |segment| {
        const cell_text = std.mem.trim(u8, segment, " \t");
        if (cell_text.len == 0 and (cells.items.len == 0 or iter.peek() == null)) continue;

        const runs = try parseInlineFormatting(allocator, cell_text);
        const paras = try allocator.alloc(docx.Paragraph, 1);
        paras[0] = .{ .style = .normal, .runs = runs };
        try cells.append(allocator, .{ .paragraphs = paras });
    }

    return .{ .cells = try cells.toOwnedSlice(allocator) };
}

fn flushTable(
    allocator: std.mem.Allocator,
    elements: *std.ArrayListUnmanaged(docx.Element),
    table_rows: *std.ArrayListUnmanaged(docx.TableRow),
) !void {
    if (table_rows.items.len == 0) return;
    try elements.append(allocator, .{ .table = .{
        .rows = try table_rows.toOwnedSlice(allocator),
    } });
}

// ── Inline formatting parser ────────────────────────────────────
//
// The inline syntax is the one zig_pdf_generator's Markdown reads, so the
// same text marks up the same way in a PDF and in a .docx.

/// Marks nest at most this deep; anything deeper is kept as typed, so
/// hostile input cannot recurse without bound.
const MAX_INLINE_DEPTH: u8 = 8;

/// Longest bracketed text `[…]` a link or marked span may hold. Bounds the
/// work per `[`, so a long run of unclosed brackets costs linear time.
const MAX_BRACKET_TEXT: usize = 4096;

/// How CriticMarkup deletions and insertions look: `{--…--}`, `{++…++}` and
/// the two halves of `{~~old~>new~~}`. The defaults are the redline sheet's:
/// removed words red, struck through, on light red; added words green and
/// bold on light green.
pub const MarkColors = struct {
    removed: docx.Rgb = "A00000".*,
    removed_fill: docx.Rgb = "FDDADA".*,
    added: docx.Rgb = "006400".*,
    added_fill: docx.Rgb = "D7F5D7".*,

    pub fn removedLook(self: MarkColors, base: docx.Run) docx.Run {
        var r = base;
        r.strike = true;
        r.fg = self.removed;
        r.bg = self.removed_fill;
        return r;
    }

    pub fn addedLook(self: MarkColors, base: docx.Run) docx.Run {
        var r = base;
        r.bold = true;
        r.fg = self.added;
        r.bg = self.added_fill;
        return r;
    }
};

/// Colour names a `[text]{color=… bg=…}` span accepts, with the hex each
/// stands for (the same table as zig_pdf_generator's).
const NAMED_COLORS = [_]struct { name: []const u8, hex: *const [6]u8 }{
    .{ .name = "black", .hex = "0F0F0F" },      .{ .name = "white", .hex = "FFFFFF" },
    .{ .name = "grey", .hex = "71717A" },       .{ .name = "gray", .hex = "71717A" },
    .{ .name = "red", .hex = "B91C1C" },        .{ .name = "green", .hex = "166534" },
    .{ .name = "blue", .hex = "1D4ED8" },       .{ .name = "orange", .hex = "C2410C" },
    .{ .name = "purple", .hex = "7E22CE" },     .{ .name = "yellow", .hex = "FEF08A" },
    .{ .name = "pink", .hex = "FBCFE8" },       .{ .name = "lightred", .hex = "FEE2E2" },
    .{ .name = "lightgreen", .hex = "DCFCE7" }, .{ .name = "lightblue", .hex = "DBEAFE" },
    .{ .name = "lightgrey", .hex = "E4E4E7" },  .{ .name = "lightgray", .hex = "E4E4E7" },
};

/// `#rgb`, `#rrggbb` or one of NAMED_COLORS (any case); null for anything else.
pub fn parseColor(s: []const u8) ?docx.Rgb {
    if (s.len > 0 and s[0] == '#') {
        const hex = s[1..];
        if (hex.len == 6) return docx.parseRgb(hex);
        if (hex.len != 3) return null;
        var out: docx.Rgb = undefined;
        for (hex, 0..) |c, i| {
            if (!std.ascii.isHex(c)) return null;
            out[i * 2] = std.ascii.toUpper(c);
            out[i * 2 + 1] = std.ascii.toUpper(c);
        }
        return out;
    }
    for (NAMED_COLORS) |n| {
        if (std.ascii.eqlIgnoreCase(n.name, s)) return n.hex.*;
    }
    return null;
}

/// The attribute list of `[text]{…}` applied over `base`: space-separated
/// `color=<colour>`, `bg=<colour>`, `strike`, `underline`. Null when the list
/// is empty or holds anything else, so `[x]{y}` in ordinary prose is left alone.
fn parseSpanAttrs(attrs: []const u8, base: docx.Run) ?docx.Run {
    var style = base;
    var any = false;
    var it = std.mem.tokenizeAny(u8, attrs, " \t");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "strike")) {
            style.strike = true;
        } else if (std.mem.eql(u8, tok, "underline")) {
            style.underline = true;
        } else if (std.mem.startsWith(u8, tok, "color=")) {
            style.fg = parseColor(tok["color=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, tok, "bg=")) {
            style.bg = parseColor(tok["bg=".len..]) orelse return null;
        } else return null;
        any = true;
    }
    return if (any) style else null;
}

/// Index of the `]` matching the `[` at `start`, counting nested pairs.
fn findBracketClose(text: []const u8, start: usize) ?usize {
    var depth: u32 = 1;
    var i = start + 1;
    const limit = @min(text.len, start + 1 + MAX_BRACKET_TEXT);
    while (i < limit) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// The closing `delim` of a `~~…~~` / `==…==` mark opened just before `from`:
/// the first one after at least one character and not preceded by a space.
fn findCloser(text: []const u8, from: usize, delim: []const u8) ?usize {
    var p = from;
    while (std.mem.indexOfPos(u8, text, p, delim)) |at| {
        if (at > from and text[at - 1] != ' ') return at;
        p = at + 1;
    }
    return null;
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '~', '=', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// Parse inline markdown into Runs, with CriticMarkup in the default colours.
///
///   **bold**  *italic*  ***bold italic***  `code`  [link](url)  ![alt](path)
///   ~~struck through~~   ==highlighted==
///   [text]{color=red bg=#fee2e2 strike underline}   (any subset of the four)
///   {--deleted--}  {++inserted++}  {~~old~>new~~}  {==highlighted==}
///
/// Marks nest with each other and with bold and italic. A backslash before
/// one of ``\ ` * ~ = [ ] { }`` keeps that character as typed.
pub fn parseInlineFormatting(allocator: std.mem.Allocator, text: []const u8) ![]docx.Run {
    return parseInlineMarked(allocator, text, .{});
}

/// parseInlineFormatting with CriticMarkup drawn in `marks`.
pub fn parseInlineMarked(allocator: std.mem.Allocator, text: []const u8, marks: MarkColors) ![]docx.Run {
    var p = InlineParser{ .allocator = allocator, .marks = marks };
    errdefer p.deinit();
    try p.parseInto(text, .{ .text = "" }, 0);

    // A paragraph with no runs at all is invisible; keep one empty run.
    if (p.runs.items.len == 0) try p.runs.append(allocator, .{ .text = "" });
    return p.runs.toOwnedSlice(allocator);
}

const InlineParser = struct {
    allocator: std.mem.Allocator,
    marks: MarkColors,
    runs: std.ArrayListUnmanaged(docx.Run) = .empty,

    fn deinit(self: *InlineParser) void {
        for (self.runs.items) |r| {
            if (r.text.len > 0) self.allocator.free(r.text);
            if (r.hyperlink_url) |u| self.allocator.free(u);
            if (r.image_rel_id) |u| self.allocator.free(u);
        }
        self.runs.deinit(self.allocator);
    }

    /// Append `text` in `style`, joined onto the previous run when the two
    /// look the same (an escape splits text that reads as one run).
    fn plain(self: *InlineParser, style: docx.Run, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.text.len > 0 and sameLook(last.*, style) and joinable(last.*) and joinable(style)) {
                const joined = try std.mem.concat(self.allocator, u8, &.{ last.text, text });
                self.allocator.free(last.text);
                last.text = joined;
                return;
            }
        }
        var run = style;
        run.text = try self.allocator.dupe(u8, text);
        try self.runs.append(self.allocator, run);
    }

    fn parseInto(self: *InlineParser, text: []const u8, style: docx.Run, depth: u8) error{OutOfMemory}!void {
        if (depth >= MAX_INLINE_DEPTH) return self.plain(style, text);

        var i: usize = 0;
        var plain_start: usize = 0;
        // Once a closing delimiter is known to be absent from the rest of the
        // text, later openers of that kind are not searched for again.
        var no_strike_close = false;
        var no_mark_close = false;
        var no_critic_close = false;

        while (i < text.len) {
            const c = text[i];

            // Backslash escape: the next character is kept, not interpreted.
            if (c == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) {
                try self.plain(style, text[plain_start..i]);
                plain_start = i + 1;
                i += 2;
                continue;
            }

            // Inline code
            if (c == '`') {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                    try self.plain(style, text[plain_start..i]);
                    var code = style;
                    code.is_code = true;
                    code.text = try self.allocator.dupe(u8, text[i + 1 .. end]);
                    try self.runs.append(self.allocator, code);
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }

            // CriticMarkup: {--deleted--} {++inserted++} {==highlighted==} {~~old~>new~~}
            if (c == '{' and !no_critic_close and i + 2 < text.len and text[i + 1] == text[i + 2]) {
                const m = text[i + 1];
                if (m == '-' or m == '+' or m == '=' or m == '~') {
                    const closer = [3]u8{ m, m, '}' };
                    if (std.mem.indexOfPos(u8, text, i + 3, &closer)) |close| {
                        const inner = text[i + 3 .. close];
                        const arrow = if (m == '~') std.mem.indexOf(u8, inner, "~>") else null;
                        if (m != '~' or arrow != null) {
                            try self.plain(style, text[plain_start..i]);
                            switch (m) {
                                '-' => try self.parseInto(inner, self.marks.removedLook(style), depth + 1),
                                '+' => try self.parseInto(inner, self.marks.addedLook(style), depth + 1),
                                '=' => {
                                    var h = style;
                                    h.highlight = true;
                                    try self.parseInto(inner, h, depth + 1);
                                },
                                else => {
                                    try self.parseInto(inner[0..arrow.?], self.marks.removedLook(style), depth + 1);
                                    try self.parseInto(inner[arrow.? + 2 ..], self.marks.addedLook(style), depth + 1);
                                },
                            }
                            i = close + 3;
                            plain_start = i;
                            continue;
                        }
                    } else if (std.mem.indexOfScalarPos(u8, text, i + 3, '}') == null) {
                        no_critic_close = true;
                    }
                }
            }

            // ~~struck through~~ and ==highlighted==
            if ((c == '~' or c == '=') and i + 2 < text.len and text[i + 1] == c and text[i + 2] != ' ') {
                const gave_up = if (c == '~') &no_strike_close else &no_mark_close;
                if (!gave_up.*) {
                    const delim = [2]u8{ c, c };
                    if (findCloser(text, i + 2, &delim)) |close| {
                        try self.plain(style, text[plain_start..i]);
                        var inner = style;
                        if (c == '~') inner.strike = true else inner.highlight = true;
                        try self.parseInto(text[i + 2 .. close], inner, depth + 1);
                        i = close + 2;
                        plain_start = i;
                        continue;
                    }
                    gave_up.* = true;
                }
            }

            // Image ![alt](path): the run carries the path until the image is resolved.
            if (c == '!' and i + 1 < text.len and text[i + 1] == '[') {
                if (findBracketClose(text, i + 1)) |close_bracket| {
                    if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                        if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                            try self.plain(style, text[plain_start..i]);
                            const alt_text = try self.allocator.dupe(u8, text[i + 2 .. close_bracket]);
                            errdefer self.allocator.free(alt_text);
                            const img_path = try self.allocator.dupe(u8, text[close_bracket + 2 .. close_paren]);
                            errdefer self.allocator.free(img_path);
                            try self.runs.append(self.allocator, .{ .text = alt_text, .image_rel_id = img_path });
                            i = close_paren + 1;
                            plain_start = i;
                            continue;
                        }
                    }
                }
            }

            // Link [text](url), or a marked span [text]{color=… bg=… strike underline}
            if (c == '[') {
                if (findBracketClose(text, i)) |close_bracket| {
                    const next: u8 = if (close_bracket + 1 < text.len) text[close_bracket + 1] else 0;
                    if (next == '(') {
                        if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                            try self.plain(style, text[plain_start..i]);
                            // H3 (writer side) — scheme allowlist. An unsafe
                            // destination (javascript:, data:, file:, …) must
                            // not become a live TargetMode="External"
                            // relationship in the DOCX; keep the visible text,
                            // drop the hyperlink.
                            const url_src = text[close_bracket + 2 .. close_paren];
                            const link_text = try self.allocator.dupe(u8, text[i + 1 .. close_bracket]);
                            errdefer self.allocator.free(link_text);
                            const url = if (isSafeLinkUrl(url_src)) try self.allocator.dupe(u8, url_src) else null;
                            errdefer if (url) |u| self.allocator.free(u);
                            var link = style;
                            link.text = link_text;
                            link.hyperlink_url = url;
                            try self.runs.append(self.allocator, link);
                            i = close_paren + 1;
                            plain_start = i;
                            continue;
                        }
                    } else if (next == '{') {
                        if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, '}')) |close_brace| {
                            if (parseSpanAttrs(text[close_bracket + 2 .. close_brace], style)) |span_style| {
                                try self.plain(style, text[plain_start..i]);
                                try self.parseInto(text[i + 1 .. close_bracket], span_style, depth + 1);
                                i = close_brace + 1;
                                plain_start = i;
                                continue;
                            }
                        }
                    }
                }
            }

            // Bold / italic / bold-italic — asterisks
            if (c == '*') {
                var star_count: usize = 0;
                while (i + star_count < text.len and text[i + star_count] == '*' and star_count < 3) star_count += 1;
                // Find a closing run of at least as many asterisks. A longer run
                // closes with its last ones; the rest belong to marks opened inside.
                var search_from = i + star_count;
                var matched = false;
                while (search_from < text.len) {
                    const maybe_close = std.mem.indexOfScalarPos(u8, text, search_from, '*') orelse break;
                    var close_count: usize = 0;
                    while (maybe_close + close_count < text.len and text[maybe_close + close_count] == '*' and close_count < 3) close_count += 1;
                    if (close_count >= star_count and maybe_close > i + star_count) {
                        try self.plain(style, text[plain_start..i]);
                        var inner = style;
                        if (star_count != 1) inner.bold = true;
                        if (star_count != 2) inner.italic = true;
                        const close_at = maybe_close + close_count - star_count;
                        try self.parseInto(text[i + star_count .. close_at], inner, depth + 1);
                        i = close_at + star_count;
                        plain_start = i;
                        matched = true;
                        break;
                    }
                    search_from = maybe_close + close_count;
                }
                if (matched) continue;
            }

            i += 1;
        }

        try self.plain(style, text[plain_start..]);
    }
};

/// True when two runs are drawn the same way.
pub fn sameLook(a: docx.Run, b: docx.Run) bool {
    return a.bold == b.bold and a.italic == b.italic and a.underline == b.underline and
        a.strike == b.strike and a.highlight == b.highlight and a.is_code == b.is_code and
        optRgbEql(a.fg, b.fg) and optRgbEql(a.bg, b.bg);
}

fn optRgbEql(a: ?docx.Rgb, b: ?docx.Rgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, &a.?, &b.?);
}

/// A run plain text may be joined onto: not code, a link or an image.
fn joinable(r: docx.Run) bool {
    return !r.is_code and r.hyperlink_url == null and r.image_rel_id == null;
}

// ── YAML frontmatter parser ─────────────────────────────────────

fn parseFrontMatter(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar)) !FrontMatter {
    var fm = FrontMatter{};
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, "---")) break; // end of frontmatter
        // Parse "key: value" lines
        if (std.mem.indexOf(u8, line, ": ")) |colon| {
            const key = std.mem.trim(u8, line[0..colon], " \t");
            var value = std.mem.trim(u8, line[colon + 2 ..], " \t");
            // Strip surrounding quotes
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
                if (value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
            }
            if (std.mem.eql(u8, key, "title")) {
                fm.title = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "author")) {
                fm.author = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "date")) {
                fm.date = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "description")) {
                fm.description = try allocator.dupe(u8, value);
            }
        }
    }
    return fm;
}

// ── Element cleanup ─────────────────────────────────────────────

fn freeElement(allocator: std.mem.Allocator, elem: *docx.Element) void {
    switch (elem.*) {
        .paragraph => |p| {
            for (p.runs) |r| {
                if (r.text.len > 0) allocator.free(r.text);
                if (r.hyperlink_url) |u| allocator.free(u);
            }
            if (p.runs.len > 0) allocator.free(p.runs);
        },
        .table => |t| {
            for (t.rows) |row| {
                for (row.cells) |cell| {
                    for (cell.paragraphs) |cp| {
                        for (cp.runs) |r| {
                            if (r.text.len > 0) allocator.free(r.text);
                            if (r.hyperlink_url) |u| allocator.free(u);
                        }
                        if (cp.runs.len > 0) allocator.free(cp.runs);
                    }
                    allocator.free(cell.paragraphs);
                }
                allocator.free(row.cells);
            }
            allocator.free(t.rows);
        },
    }
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn freeRuns(runs: []docx.Run) void {
    for (runs) |r| {
        if (r.text.len > 0) testing.allocator.free(r.text);
        if (r.hyperlink_url) |u| testing.allocator.free(u);
        if (r.image_rel_id) |u| testing.allocator.free(u);
    }
    testing.allocator.free(runs);
}

fn rgb(s: []const u8) docx.Rgb {
    return docx.parseRgb(s).?;
}

test "strike-through and highlight marks" {
    const runs = try parseInlineFormatting(testing.allocator, "a ~~gone~~ and ==look== b");
    defer freeRuns(runs);
    try testing.expectEqual(@as(usize, 5), runs.len);
    try testing.expectEqualStrings("gone", runs[1].text);
    try testing.expect(runs[1].strike and !runs[1].highlight);
    try testing.expectEqualStrings(" and ", runs[2].text);
    try testing.expect(!runs[2].strike);
    try testing.expectEqualStrings("look", runs[3].text);
    try testing.expect(runs[3].highlight and !runs[3].strike);
}

test "marks nest with each other and with bold" {
    const runs = try parseInlineFormatting(testing.allocator, "==x **bold ~~both~~** y==");
    defer freeRuns(runs);
    try testing.expectEqual(@as(usize, 4), runs.len);
    for (runs) |r| try testing.expect(r.highlight);
    try testing.expectEqualStrings("bold ", runs[1].text);
    try testing.expect(runs[1].bold and !runs[1].strike);
    try testing.expectEqualStrings("both", runs[2].text);
    try testing.expect(runs[2].bold and runs[2].strike);
}

test "a span sets colour, shading, strike and underline" {
    const runs = try parseInlineFormatting(testing.allocator, "[warn **now**]{color=red bg=#fee strike underline}!");
    defer freeRuns(runs);
    try testing.expectEqual(@as(usize, 3), runs.len);
    for (runs[0..2]) |r| {
        try testing.expectEqualStrings("B91C1C", &r.fg.?);
        try testing.expectEqualStrings("FFEEEE", &r.bg.?);
        try testing.expect(r.strike and r.underline);
    }
    try testing.expect(runs[1].bold);
    try testing.expectEqualStrings("!", runs[2].text);
    try testing.expect(runs[2].fg == null);
}

test "text that only looks like a mark is left as typed" {
    const cases = [_][]const u8{
        "if a == b and c == d",
        "[note]{see below}",
        "[x]{color=#12345}",
        "~~ spaced~~",
        "{--never closed",
        "2 * 3",
    };
    for (cases) |case| {
        const runs = try parseInlineFormatting(testing.allocator, case);
        defer freeRuns(runs);
        try testing.expectEqual(@as(usize, 1), runs.len);
        try testing.expectEqualStrings(case, runs[0].text);
        try testing.expect(!runs[0].strike and !runs[0].highlight and runs[0].fg == null and !runs[0].italic);
    }
}

test "CriticMarkup draws removed and added words in the redline look" {
    const runs = try parseInlineFormatting(testing.allocator, "{--old--}{++new++} {~~was~>is~~} {==see==}");
    defer freeRuns(runs);
    try testing.expectEqual(@as(usize, 7), runs.len);
    const removed = [_]usize{ 0, 3 };
    const added = [_]usize{ 1, 4 };
    for (removed) |i| {
        try testing.expect(runs[i].strike and !runs[i].bold);
        try testing.expectEqualStrings("A00000", &runs[i].fg.?);
        try testing.expectEqualStrings("FDDADA", &runs[i].bg.?);
    }
    for (added) |i| {
        try testing.expect(runs[i].bold and !runs[i].strike);
        try testing.expectEqualStrings("006400", &runs[i].fg.?);
        try testing.expectEqualStrings("D7F5D7", &runs[i].bg.?);
    }
    try testing.expectEqualStrings("was", runs[3].text);
    try testing.expectEqualStrings("is", runs[4].text);
    try testing.expect(runs[6].highlight);

    // The colours come from the caller when it has its own.
    const own = try parseInlineMarked(testing.allocator, "{--x--}", .{ .removed = rgb("123456") });
    defer freeRuns(own);
    try testing.expectEqualStrings("123456", &own[0].fg.?);
}

test "a backslash keeps a mark character as typed" {
    const runs = try parseInlineFormatting(testing.allocator, "\\~~not struck\\~~ and \\*plain\\* \\\\");
    defer freeRuns(runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("~~not struck~~ and *plain* \\", runs[0].text);
}

test "links, images and code keep working beside the marks" {
    const runs = try parseInlineFormatting(testing.allocator, "~~see [site](https://example.com) and `x`~~ ![pic](a.png) [bad](javascript:void)");
    defer freeRuns(runs);
    try testing.expectEqualStrings("site", runs[1].text);
    try testing.expectEqualStrings("https://example.com", runs[1].hyperlink_url.?);
    try testing.expect(runs[1].strike);
    try testing.expectEqualStrings("x", runs[3].text);
    try testing.expect(runs[3].is_code and runs[3].strike);
    try testing.expectEqualStrings("a.png", runs[5].image_rel_id.?);
    try testing.expectEqualStrings("bad", runs[7].text);
    try testing.expect(runs[7].hyperlink_url == null);
}

test "deep nesting stops at the depth limit instead of recursing" {
    var buf: [400]u8 = undefined;
    var n: usize = 0;
    for (0..40) |_| {
        @memcpy(buf[n .. n + 3], "==a");
        n += 3;
    }
    for (0..40) |_| {
        @memcpy(buf[n .. n + 2], "==");
        n += 2;
    }
    const runs = try parseInlineFormatting(testing.allocator, buf[0..n]);
    defer freeRuns(runs);
    try testing.expect(runs.len > 0);
}
