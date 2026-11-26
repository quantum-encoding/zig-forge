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
//!   --- YAML frontmatter ---  (title, author, date, description, and the
//!       page settings in docx_writer.LayoutSettings: style, paper,
//!       orientation, margin, header, footer, page-numbers, lang)
//!   <!-- letterhead: logo.png -->, <!-- pagebreak -->
//!   :::card … :::  (the lines between in one bordered box)
//!
//! With ParseOptions.layout (the CLI's --to-docx turns it on), also:
//!   |:---|:---:|---:|  column alignment (left, centre, right); a column
//!                     with neither colon is flush left. Each column's width
//!                     is in proportion to its separator cell's width.
//!   {widths=30,70 borders=none}  on the line straight after a table: relative
//!                     column widths (one per column), and/or no lines at all.
//!   Text {align=center}  a trailing attribute on a paragraph, heading, list
//!                     item or quote: left, center (or centre), right, justify.
//! Table cells are flush left unless their column says otherwise. An
//! attribute list that holds anything else is left as typed.

const std = @import("std");
const docx = @import("docx.zig");
const LayoutSettings = @import("docx_writer.zig").LayoutSettings;
const StyleType = @import("styles.zig").StyleType;
const isSafeLinkUrl = @import("mdx.zig").isSafeLinkUrl;

pub const FrontMatter = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    description: ?[]const u8 = null,
    letterhead: ?[]const u8 = null, // <!-- letterhead: logo.png -->
    /// The page settings the frontmatter names (style, paper, orientation,
    /// margin, header, footer, page-numbers, lang), as written. Owned.
    layout: LayoutSettings = .{},

    fn deinit(self: *FrontMatter, allocator: std.mem.Allocator) void {
        const owned = [_]?[]const u8{
            self.title,         self.author,             self.date,
            self.description,   self.letterhead,         self.layout.style,
            self.layout.paper,  self.layout.orientation, self.layout.margin,
            self.layout.header, self.layout.footer,      self.layout.page_numbers,
            self.layout.lang,
        };
        for (owned) |field| if (field) |v| allocator.free(v);
        self.* = .{};
    }
};

/// What the parser reads beyond plain Markdown.
pub const ParseOptions = struct {
    /// The layout syntax: column alignment and widths from a table's
    /// separator row, a `{widths=… borders=none}` line straight after a
    /// table, and a trailing `{align=…}` on a paragraph, heading, list item
    /// or quote. Table cells are then flush left unless their column says
    /// otherwise, so a justified style does not stretch them. Off, the
    /// parser reads Markdown as it always has and every one of these is text.
    layout: bool = false,
};

pub const ParseResult = struct {
    document: docx.Document,
    frontmatter: FrontMatter,
    allocator: std.mem.Allocator,
    /// Base directory for resolving relative image paths. Null = cwd.
    base_dir: ?[]const u8 = null,

    pub fn deinit(self: *ParseResult) void {
        self.document.deinit();
        self.frontmatter.deinit(self.allocator);
        if (self.base_dir) |b| self.allocator.free(b);
    }
};

/// Parse markdown text into a Document model + optional YAML frontmatter.
pub fn parseMarkdown(allocator: std.mem.Allocator, markdown: []const u8) !ParseResult {
    return parseMarkdownWith(allocator, markdown, .{});
}

/// parseMarkdown, reading the extra syntax `options` turns on.
pub fn parseMarkdownWith(allocator: std.mem.Allocator, markdown: []const u8, options: ParseOptions) !ParseResult {
    var elements: std.ArrayListUnmanaged(docx.Element) = .empty;
    errdefer {
        for (elements.items) |*e| freeElement(allocator, e);
        elements.deinit(allocator);
    }

    var frontmatter = FrontMatter{};
    errdefer frontmatter.deinit(allocator);
    var lines = std.mem.splitScalar(u8, markdown, '\n');

    // Check for YAML frontmatter (--- delimited)
    const first_line = lines.peek() orelse "";
    if (std.mem.eql(u8, std.mem.trim(u8, first_line, " \t\r"), "---")) {
        _ = lines.next(); // consume opening ---
        try parseFrontMatter(allocator, &lines, &frontmatter);
    }

    // Block-level parsing
    var in_code_block = false;
    var code_lines: std.ArrayListUnmanaged(u8) = .empty;
    defer code_lines.deinit(allocator);

    var in_table = false;
    var table: PendingTable = .{};
    defer table.deinit(allocator);

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        // ── Code block toggle ──
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            if (in_code_block) {
                // End code block — emit as a single paragraph
                try appendCodeBlock(allocator, &elements, code_lines.items);
                code_lines.clearRetainingCapacity();
                in_code_block = false;
            } else {
                // Flush any pending table
                if (in_table) {
                    try flushTable(allocator, &elements, &table, options);
                    in_table = false;
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
            in_table = true;
            // Separator rows (| --- | --- |) are not rows; the first one
            // gives the columns their widths and alignment.
            if (isSeparatorRow(line)) {
                if (options.layout and !table.separator_seen) try table.readSeparator(allocator, line);
                table.separator_seen = true;
                continue;
            }
            const row = try parseTableRow(allocator, line);
            table.rows.append(allocator, row) catch |err| {
                freeRow(allocator, row);
                return err;
            };
            continue;
        } else if (in_table) {
            // A `{widths=… borders=none}` line straight after the table is
            // part of it; any other line ends the table and is read as usual.
            const attrs_line = options.layout and try table.readAttrs(allocator, std.mem.trim(u8, line, " \t"));
            try flushTable(allocator, &elements, &table, options);
            in_table = false;
            if (attrs_line) continue;
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
                    const owned = try allocator.dupe(u8, path);
                    if (frontmatter.letterhead) |old| allocator.free(old);
                    frontmatter.letterhead = owned;
                }
            } else if (std.mem.eql(u8, comment, "pagebreak")) {
                // <!-- pagebreak --> on its own line → a hard Word page break.
                try appendParagraph(allocator, &elements, .{
                    .style = .page_break,
                    .runs = &[_]docx.Run{},
                });
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
                for (cell_paras.items) |cp| freeRunList(allocator, cp.runs);
                cell_paras.deinit(allocator);
            }
            while (lines.next()) |inner_raw| {
                const inner_line = std.mem.trimEnd(u8, inner_raw, "\r");
                const inner_trimmed = std.mem.trim(u8, inner_line, " \t");
                if (std.mem.eql(u8, inner_trimmed, ":::")) break; // end of card
                const runs = try parseInlineFormatting(allocator, inner_trimmed);
                // In layout mode the box is a table cell like any other:
                // flush left, whatever the body's alignment.
                cell_paras.append(allocator, .{
                    .style = .normal,
                    .runs = runs,
                    .alignment = if (options.layout) .left else null,
                }) catch |err| {
                    freeRunList(allocator, runs);
                    return err;
                };
            }
            // In layout mode the box spans the page's text width, whatever
            // the paper and margins.
            const weights: []u16 = if (options.layout) try allocator.dupe(u16, &.{1}) else &.{};
            errdefer if (weights.len > 0) allocator.free(weights);
            const paras = try cell_paras.toOwnedSlice(allocator);
            errdefer {
                for (paras) |cp| freeRunList(allocator, cp.runs);
                allocator.free(paras);
            }
            const cells = try allocator.alloc(docx.TableCell, 1);
            errdefer allocator.free(cells);
            cells[0] = .{ .paragraphs = paras };
            const rows = try allocator.alloc(docx.TableRow, 1);
            errdefer allocator.free(rows);
            rows[0] = .{ .cells = cells };
            try elements.append(allocator, .{ .table = .{ .rows = rows, .col_weights = weights } });
            continue;
        }

        // ── Horizontal rule ──
        if (isHorizontalRule(trimmed)) {
            try appendParagraph(allocator, &elements, .{
                .style = .horizontal_rule,
                .runs = &[_]docx.Run{},
            });
            continue;
        }

        // ── Heading ──
        if (line.len > 0 and line[0] == '#') {
            if (parseHeading(line)) |h| {
                const block = blockText(h.text, options);
                const runs = try parseInlineFormatting(allocator, block.text);
                try appendParagraph(allocator, &elements, .{
                    .style = h.style,
                    .runs = runs,
                    .alignment = block.alignment,
                });
                continue;
            }
        }

        // ── Blockquote ──
        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const block = blockText(trimmed[2..], options);
            const runs = try parseInlineFormatting(allocator, block.text);
            try appendParagraph(allocator, &elements, .{
                .style = .blockquote,
                .runs = runs,
                .alignment = block.alignment,
            });
            continue;
        }
        if (std.mem.eql(u8, trimmed, ">")) {
            continue; // empty blockquote line
        }

        // ── Unordered list ──
        if (parseUnorderedListItem(line)) |item| {
            const block = blockText(item.text, options);
            const runs = try parseInlineFormatting(allocator, block.text);
            try appendParagraph(allocator, &elements, .{
                .style = .list_paragraph,
                .runs = runs,
                .is_list_item = true,
                .is_ordered = false,
                .numbering_level = item.level,
                .alignment = block.alignment,
            });
            continue;
        }

        // ── Ordered list ──
        if (parseOrderedListItem(line)) |item| {
            const block = blockText(item.text, options);
            const runs = try parseInlineFormatting(allocator, block.text);
            try appendParagraph(allocator, &elements, .{
                .style = .list_paragraph,
                .runs = runs,
                .is_list_item = true,
                .is_ordered = true,
                .numbering_level = item.level,
                .alignment = block.alignment,
            });
            continue;
        }

        // ── Normal paragraph ──
        const block = blockText(trimmed, options);
        const runs = try parseInlineFormatting(allocator, block.text);
        try appendParagraph(allocator, &elements, .{
            .style = .normal,
            .runs = runs,
            .alignment = block.alignment,
        });
    }

    // Flush any trailing code block or table
    if (in_code_block and code_lines.items.len > 0) try appendCodeBlock(allocator, &elements, code_lines.items);
    if (in_table) try flushTable(allocator, &elements, &table, options);

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
    errdefer {
        for (cells.items) |cell| {
            for (cell.paragraphs) |cp| freeRunList(allocator, cp.runs);
            allocator.free(cell.paragraphs);
        }
        cells.deinit(allocator);
    }

    // Split by | and trim, skipping leading/trailing empty segments
    var iter = std.mem.splitScalar(u8, line, '|');
    while (iter.next()) |segment| {
        const cell_text = std.mem.trim(u8, segment, " \t");
        if (cell_text.len == 0 and (cells.items.len == 0 or iter.peek() == null)) continue;

        const runs = try parseInlineFormatting(allocator, cell_text);
        const paras = allocator.alloc(docx.Paragraph, 1) catch |err| {
            freeRunList(allocator, runs);
            return err;
        };
        paras[0] = .{ .style = .normal, .runs = runs };
        cells.append(allocator, .{ .paragraphs = paras }) catch |err| {
            freeRunList(allocator, runs);
            allocator.free(paras);
            return err;
        };
    }

    return .{ .cells = try cells.toOwnedSlice(allocator) };
}

/// A pipe table being read, row by row, and what its separator row and
/// attribute line say about its columns.
const PendingTable = struct {
    rows: std.ArrayListUnmanaged(docx.TableRow) = .empty,
    separator_seen: bool = false,
    /// Each separator cell's width in characters, colons included.
    sep_widths: std.ArrayListUnmanaged(u16) = .empty,
    /// Each separator cell's alignment: `:--` left, `--:` right, `:-:` centre.
    sep_aligns: std.ArrayListUnmanaged(?docx.Alignment) = .empty,
    /// From `{widths=…}`: one relative width per column.
    attr_widths: std.ArrayListUnmanaged(u16) = .empty,
    /// From `{borders=none}`.
    borderless: bool = false,

    /// Frees the rows still held (only on an error path; a flushed table
    /// owns its rows) and the lists.
    fn deinit(self: *PendingTable, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| freeRow(allocator, row);
        self.rows.deinit(allocator);
        self.sep_widths.deinit(allocator);
        self.sep_aligns.deinit(allocator);
        self.attr_widths.deinit(allocator);
    }

    /// Ready for the next table, keeping the lists' memory.
    fn reset(self: *PendingTable) void {
        self.rows.clearRetainingCapacity();
        self.sep_widths.clearRetainingCapacity();
        self.sep_aligns.clearRetainingCapacity();
        self.attr_widths.clearRetainingCapacity();
        self.separator_seen = false;
        self.borderless = false;
    }

    /// The most cells any row has.
    fn columns(self: *const PendingTable) usize {
        var n: usize = 0;
        for (self.rows.items) |row| n = @max(n, row.cells.len);
        return n;
    }

    /// Each cell of a separator row (`|:---|:---:|---:|`): its width as
    /// drawn and its alignment.
    fn readSeparator(self: *PendingTable, allocator: std.mem.Allocator, line: []const u8) !void {
        var iter = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (iter.next()) |segment| {
            const cell = std.mem.trim(u8, segment, " \t");
            // The empty pieces outside the leading and trailing pipes.
            const outside = cell.len == 0 and (first or iter.peek() == null);
            first = false;
            if (outside) continue;
            const left = cell.len > 0 and cell[0] == ':';
            const right = cell.len > 0 and cell[cell.len - 1] == ':';
            try self.sep_widths.append(allocator, @intCast(@max(1, @min(cell.len, std.math.maxInt(u16)))));
            try self.sep_aligns.append(allocator, if (left and right and cell.len > 1)
                .center
            else if (left)
                .left
            else if (right)
                .right
            else
                null);
        }
    }

    /// When `trimmed` is a table attribute list, `{widths=30,70 borders=none}`
    /// (either attribute or both), records it and returns true. Anything else
    /// — another attribute, a width that is not a whole number above zero, or
    /// a count of widths that is not the table's column count — leaves the
    /// table as it was and returns false, so the line is read as text.
    fn readAttrs(self: *PendingTable, allocator: std.mem.Allocator, trimmed: []const u8) !bool {
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return false;
        var widths: std.ArrayListUnmanaged(u16) = .empty;
        defer widths.deinit(allocator);
        var borderless = false;
        var any = false;
        var it = std.mem.tokenizeAny(u8, trimmed[1 .. trimmed.len - 1], " \t");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "borders=none")) {
                borderless = true;
            } else if (std.mem.startsWith(u8, tok, "widths=")) {
                widths.clearRetainingCapacity();
                var values = std.mem.splitScalar(u8, tok["widths=".len..], ',');
                while (values.next()) |raw| {
                    const v = if (std.mem.endsWith(u8, raw, "%")) raw[0 .. raw.len - 1] else raw;
                    const w = std.fmt.parseInt(u16, v, 10) catch return false;
                    if (w == 0) return false;
                    try widths.append(allocator, w);
                }
                if (widths.items.len != self.columns()) return false;
            } else return false;
            any = true;
        }
        if (!any) return false;
        self.borderless = borderless;
        self.attr_widths.clearRetainingCapacity();
        try self.attr_widths.appendSlice(allocator, widths.items);
        return true;
    }
};

/// Appends `p`, whose runs `elements` then owns; frees them if it cannot.
fn appendParagraph(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), p: docx.Paragraph) !void {
    elements.append(allocator, .{ .paragraph = p }) catch |err| {
        freeRunList(allocator, p.runs);
        return err;
    };
}

/// Appends a code block: its lines as the one run of a CodeBlock paragraph.
fn appendCodeBlock(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), code: []const u8) !void {
    const text = try allocator.dupe(u8, code);
    const runs = allocator.alloc(docx.Run, 1) catch |err| {
        allocator.free(text);
        return err;
    };
    runs[0] = .{ .text = text };
    try appendParagraph(allocator, elements, .{ .style = .code_block, .runs = runs });
}

fn freeRow(allocator: std.mem.Allocator, row: docx.TableRow) void {
    for (row.cells) |cell| {
        for (cell.paragraphs) |cp| freeRunList(allocator, cp.runs);
        allocator.free(cell.paragraphs);
    }
    allocator.free(row.cells);
}

fn freeRunList(allocator: std.mem.Allocator, runs: []docx.Run) void {
    for (runs) |r| {
        if (r.text.len > 0) allocator.free(r.text);
        if (r.hyperlink_url) |u| allocator.free(u);
        if (r.image_rel_id) |u| allocator.free(u);
    }
    if (runs.len > 0) allocator.free(runs);
}

/// Moves the pending table into `elements` and readies `pending` for the
/// next one. In layout mode the table takes its column widths from the
/// attribute line or else the separator row, and each cell takes its
/// column's alignment, flush left when the column has none. On an error the
/// rows not yet moved stay in `pending`, whose deinit frees them.
fn flushTable(
    allocator: std.mem.Allocator,
    elements: *std.ArrayListUnmanaged(docx.Element),
    pending: *PendingTable,
    options: ParseOptions,
) !void {
    if (pending.rows.items.len == 0) return pending.reset();

    var weights: []u16 = &.{};
    errdefer if (weights.len > 0) allocator.free(weights);
    if (options.layout) {
        for (pending.rows.items) |row| {
            for (row.cells, 0..) |cell, col| {
                const a: ?docx.Alignment = if (col < pending.sep_aligns.items.len) pending.sep_aligns.items[col] else null;
                for (cell.paragraphs) |*p| p.alignment = a orelse .left;
            }
        }
        const cols = pending.columns();
        if (cols > 0) {
            weights = try allocator.alloc(u16, cols);
            if (pending.attr_widths.items.len == cols) {
                @memcpy(weights, pending.attr_widths.items);
            } else {
                // Columns the separator row does not reach get its average.
                const drawn = pending.sep_widths.items[0..@min(cols, pending.sep_widths.items.len)];
                var sum: usize = 0;
                for (drawn) |w| sum += w;
                const fill: u16 = if (drawn.len == 0) 1 else @intCast(@max(1, sum / drawn.len));
                @memset(weights, fill);
                @memcpy(weights[0..drawn.len], drawn);
            }
        }
    }

    const rows = try pending.rows.toOwnedSlice(allocator);
    errdefer {
        for (rows) |row| freeRow(allocator, row);
        allocator.free(rows);
    }
    try elements.append(allocator, .{ .table = .{
        .rows = rows,
        .col_weights = weights,
        .fixed_layout = weights.len > 0,
        .borderless = options.layout and pending.borderless,
    } });
    pending.reset();
}

// ── Block attributes ────────────────────────────────────────────

/// A block's text and the alignment a trailing `{align=…}` gave it.
const BlockText = struct { text: []const u8, alignment: ?docx.Alignment = null };

/// `text` without a trailing ` {align=…}` and the alignment it names, in
/// layout mode. The attribute list must come after a space and hold only
/// `align=left|center|centre|right|justify`; anything else (`[x]{color=red}`,
/// `\{align=center}`, `{==see==}`) is left in the text for the inline parser.
fn blockText(text: []const u8, options: ParseOptions) BlockText {
    const none: BlockText = .{ .text = text };
    if (!options.layout) return none;
    if (text.len == 0 or text[text.len - 1] != '}') return none;
    const open = std.mem.lastIndexOfScalar(u8, text, '{') orelse return none;
    if (open == 0 or (text[open - 1] != ' ' and text[open - 1] != '\t')) return none;
    var alignment: ?docx.Alignment = null;
    var it = std.mem.tokenizeAny(u8, text[open + 1 .. text.len - 1], " \t");
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, "align=")) return none;
        alignment = parseAlignment(tok["align=".len..]) orelse return none;
    }
    if (alignment == null) return none;
    return .{ .text = std.mem.trimEnd(u8, text[0..open], " \t"), .alignment = alignment };
}

fn parseAlignment(s: []const u8) ?docx.Alignment {
    if (std.mem.eql(u8, s, "centre")) return .center;
    return std.meta.stringToEnum(docx.Alignment, s);
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
        errdefer self.allocator.free(run.text);
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
                    errdefer self.allocator.free(code.text);
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

/// The frontmatter keys parseFrontMatter keeps, and where each goes.
const FrontMatterKey = enum {
    title,
    author,
    date,
    description,
    style,
    paper,
    orientation,
    margin,
    header,
    footer,
    @"page-numbers",
    lang,

    fn field(self: FrontMatterKey, fm: *FrontMatter) *?[]const u8 {
        return switch (self) {
            .title => &fm.title,
            .author => &fm.author,
            .date => &fm.date,
            .description => &fm.description,
            .style => &fm.layout.style,
            .paper => &fm.layout.paper,
            .orientation => &fm.layout.orientation,
            .margin => &fm.layout.margin,
            .header => &fm.layout.header,
            .footer => &fm.layout.footer,
            .@"page-numbers" => &fm.layout.page_numbers,
            .lang => &fm.layout.lang,
        };
    }
};

/// Reads `key: value` lines up to the closing `---` into `fm`. A key given
/// twice keeps its last value; keys it does not know are skipped.
fn parseFrontMatter(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar), fm: *FrontMatter) !void {
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
            const known = std.meta.stringToEnum(FrontMatterKey, key) orelse continue;
            const slot = known.field(fm);
            const owned = try allocator.dupe(u8, value);
            if (slot.*) |old| allocator.free(old);
            slot.* = owned;
        }
    }
}

// ── Element cleanup ─────────────────────────────────────────────

fn freeElement(allocator: std.mem.Allocator, elem: *docx.Element) void {
    switch (elem.*) {
        .paragraph => |p| freeRunList(allocator, p.runs),
        .table => |t| {
            for (t.rows) |row| freeRow(allocator, row);
            allocator.free(t.rows);
            if (t.col_weights.len > 0) allocator.free(t.col_weights);
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

// ── Layout syntax ──────────────────────────────────────────────────

fn parseLayout(md: []const u8) !ParseResult {
    return parseMarkdownWith(testing.allocator, md, .{ .layout = true });
}

fn cellAlignment(t: docx.Table, row: usize, col: usize) ?docx.Alignment {
    return t.rows[row].cells[col].paragraphs[0].alignment;
}

fn paragraphText(p: docx.Paragraph) []const u8 {
    return if (p.runs.len == 1) p.runs[0].text else "(several runs)";
}

test "layout: the separator row gives each column its alignment and its width" {
    var r = try parseLayout(
        \\| Left | Centre | Right | Plain |
        \\|:-----|:------:|------:| --- |
        \\| a | b | c | d |
    );
    defer r.deinit();
    const t = r.document.elements[0].table;
    // Each separator cell's width as drawn, colons included.
    try testing.expectEqualSlices(u16, &.{ 6, 8, 7, 3 }, t.col_weights);
    try testing.expect(t.fixed_layout and !t.borderless);
    for (0..2) |row| {
        try testing.expectEqual(docx.Alignment.left, cellAlignment(t, row, 0));
        try testing.expectEqual(docx.Alignment.center, cellAlignment(t, row, 1));
        try testing.expectEqual(docx.Alignment.right, cellAlignment(t, row, 2));
        // No colon: flush left, never the body's justification.
        try testing.expectEqual(docx.Alignment.left, cellAlignment(t, row, 3));
    }
}

test "layout: columns the separator row does not reach take its average width" {
    var r = try parseLayout(
        \\| a | b | c |
        \\|----|--------|
        \\| 1 | 2 | 3 |
    );
    defer r.deinit();
    try testing.expectEqualSlices(u16, &.{ 4, 8, 6 }, r.document.elements[0].table.col_weights);
}

test "layout: an attribute line after a table sets its widths and takes its lines away" {
    var r = try parseLayout(
        \\| Expediente | SAN-1 |
        \\|---|---|
        \\| DNI | 00000000T |
        \\{widths=30,70 borders=none}
        \\After.
    );
    defer r.deinit();
    const els = r.document.elements;
    try testing.expectEqual(@as(usize, 2), els.len);
    try testing.expectEqualSlices(u16, &.{ 30, 70 }, els[0].table.col_weights);
    try testing.expect(els[0].table.borderless);
    try testing.expectEqualStrings("After.", paragraphText(els[1].paragraph));

    // Either attribute alone, and widths written as percentages.
    var widths_only = try parseLayout("| a | b |\n|---|---|\n{widths=25%,75%}");
    defer widths_only.deinit();
    try testing.expectEqualSlices(u16, &.{ 25, 75 }, widths_only.document.elements[0].table.col_weights);
    try testing.expect(!widths_only.document.elements[0].table.borderless);
    var lines_only = try parseLayout("| a | b |\n|--|------|\n{borders=none}");
    defer lines_only.deinit();
    try testing.expectEqualSlices(u16, &.{ 2, 6 }, lines_only.document.elements[0].table.col_weights);
    try testing.expect(lines_only.document.elements[0].table.borderless);
}

test "layout: an attribute line that does not fit the table is kept as text" {
    const lines = [_][]const u8{
        "{widths=30,60,10}", // three widths for two columns
        "{widths=0,100}",
        "{widths=a,b}",
        "{borders=dotted}",
        "{widths=30,70 colour=red}",
        "{}",
    };
    for (lines) |line| {
        var buf: [128]u8 = undefined;
        const md = try std.fmt.bufPrint(&buf, "| a | b |\n|---|---|\n{s}", .{line});
        var r = try parseLayout(md);
        defer r.deinit();
        const els = r.document.elements;
        try testing.expectEqual(@as(usize, 2), els.len);
        try testing.expectEqualSlices(u16, &.{ 3, 3 }, els[0].table.col_weights);
        try testing.expect(!els[0].table.borderless);
        try testing.expectEqualStrings(line, paragraphText(els[1].paragraph));
    }
}

test "layout: a trailing {align=...} aligns a paragraph, heading, list item or quote" {
    var r = try parseLayout(
        \\# EXPONE {align=center}
        \\Body text. {align=justify}
        \\Fdo.: Nombre {align=right}
        \\1. First request {align=centre}
        \\- A point {align=right}
        \\> Quoted {align=left}
        \\No attribute here.
    );
    defer r.deinit();
    const els = r.document.elements;
    const want = [_]struct { text: []const u8, alignment: ?docx.Alignment, style: StyleType }{
        .{ .text = "EXPONE", .alignment = .center, .style = .heading1 },
        .{ .text = "Body text.", .alignment = .justify, .style = .normal },
        .{ .text = "Fdo.: Nombre", .alignment = .right, .style = .normal },
        .{ .text = "First request", .alignment = .center, .style = .list_paragraph },
        .{ .text = "A point", .alignment = .right, .style = .list_paragraph },
        .{ .text = "Quoted", .alignment = .left, .style = .blockquote },
        .{ .text = "No attribute here.", .alignment = null, .style = .normal },
    };
    try testing.expectEqual(want.len, els.len);
    for (want, els) |w, e| {
        try testing.expectEqualStrings(w.text, paragraphText(e.paragraph));
        try testing.expectEqual(w.alignment, e.paragraph.alignment);
        try testing.expectEqual(w.style, e.paragraph.style);
    }
}

test "layout: inline spans and marks still parse beside a block attribute" {
    // A span at the end of a line is a span, not a block attribute.
    var span = try parseLayout("Read [this]{color=red}");
    defer span.deinit();
    const sp = span.document.elements[0].paragraph;
    try testing.expect(sp.alignment == null);
    try testing.expectEqual(@as(usize, 2), sp.runs.len);
    try testing.expectEqualStrings("this", sp.runs[1].text);
    try testing.expectEqualStrings("B91C1C", &sp.runs[1].fg.?);

    // Both together: the block attribute comes off, the span stays.
    var both = try parseLayout("[Aviso]{color=red bg=lightred} importante {align=center}");
    defer both.deinit();
    const bp = both.document.elements[0].paragraph;
    try testing.expectEqual(docx.Alignment.center, bp.alignment.?);
    try testing.expectEqualStrings("Aviso", bp.runs[0].text);
    try testing.expectEqualStrings("FEE2E2", &bp.runs[0].bg.?);
    try testing.expectEqualStrings(" importante", bp.runs[1].text);

    // CriticMarkup at the end of a line is still CriticMarkup.
    var critic = try parseLayout("Mark {==see==}");
    defer critic.deinit();
    const cp = critic.document.elements[0].paragraph;
    try testing.expect(cp.alignment == null and cp.runs[1].highlight);

    // Anything that is not a block attribute after a space is kept as typed.
    const as_typed = [_]struct { md: []const u8, text: []const u8 }{
        .{ .md = "Note {color=red}", .text = "Note {color=red}" },
        .{ .md = "Keep \\{align=center}", .text = "Keep {align=center}" },
        .{ .md = "{align=center}", .text = "{align=center}" },
        .{ .md = "Mid {align=center} line", .text = "Mid {align=center} line" },
        .{ .md = "Odd {align=middle}", .text = "Odd {align=middle}" },
        .{ .md = "Glued{align=center}", .text = "Glued{align=center}" },
    };
    for (as_typed) |c| {
        var r = try parseLayout(c.md);
        defer r.deinit();
        const p = r.document.elements[0].paragraph;
        try testing.expect(p.alignment == null);
        try testing.expectEqualStrings(c.text, paragraphText(p));
    }
}

test "without layout the layout syntax is text, and tables are as they always were" {
    const md =
        \\# EXPONE {align=center}
        \\| a | b |
        \\|:--|--:|
        \\| 1 | 2 |
        \\{widths=30,70 borders=none}
        \\:::card
        \\Boxed
        \\:::
    ;
    var r = try parseMarkdown(testing.allocator, md);
    defer r.deinit();
    const els = r.document.elements;
    try testing.expectEqual(@as(usize, 4), els.len);
    try testing.expectEqualStrings("EXPONE {align=center}", paragraphText(els[0].paragraph));
    try testing.expect(els[0].paragraph.alignment == null);
    const t = els[1].table;
    try testing.expectEqual(@as(usize, 0), t.col_weights.len);
    try testing.expect(!t.fixed_layout and !t.borderless);
    try testing.expect(cellAlignment(t, 0, 0) == null and cellAlignment(t, 1, 1) == null);
    try testing.expectEqualStrings("{widths=30,70 borders=none}", paragraphText(els[2].paragraph));
    try testing.expectEqual(@as(usize, 0), els[3].table.col_weights.len);
    try testing.expect(cellAlignment(els[3].table, 0, 0) == null);
}

test "layout: a card spans the text width and its lines are flush left" {
    var r = try parseLayout(":::card\n**Name**\nAddress\n:::");
    defer r.deinit();
    const t = r.document.elements[0].table;
    try testing.expectEqualSlices(u16, &.{1}, t.col_weights);
    for (t.rows[0].cells[0].paragraphs) |p| try testing.expectEqual(docx.Alignment.left, p.alignment.?);
}

test "frontmatter page settings are kept as written; a repeated key keeps its last value" {
    var r = try parseMarkdown(testing.allocator,
        \\---
        \\title: First
        \\title: "Second"
        \\style: letter
        \\paper: a4
        \\orientation: landscape
        \\margin: 25mm
        \\header: Expediente: 1
        \\footer: Pie
        \\page-numbers: true
        \\lang: es
        \\unknown: skipped
        \\---
        \\Body
    );
    defer r.deinit();
    const fm = r.frontmatter;
    try testing.expectEqualStrings("Second", fm.title.?);
    try testing.expectEqualStrings("letter", fm.layout.style.?);
    try testing.expectEqualStrings("a4", fm.layout.paper.?);
    try testing.expectEqualStrings("landscape", fm.layout.orientation.?);
    try testing.expectEqualStrings("25mm", fm.layout.margin.?);
    try testing.expectEqualStrings("Expediente: 1", fm.layout.header.?);
    try testing.expectEqualStrings("Pie", fm.layout.footer.?);
    try testing.expectEqualStrings("true", fm.layout.page_numbers.?);
    try testing.expectEqualStrings("es", fm.layout.lang.?);
}

test "the sample filing parses into the shape the CLI renders" {
    var r = try parseLayout(@embedFile("testdata/escrito_sample.md"));
    defer r.deinit();
    try testing.expectEqualStrings("letter", r.frontmatter.layout.style.?);
    try testing.expectEqualStrings("es", r.frontmatter.layout.lang.?);

    var tables: [2]docx.Table = undefined;
    var n_tables: usize = 0;
    var expone: ?docx.Paragraph = null;
    var last: ?docx.Paragraph = null;
    for (r.document.elements) |e| switch (e) {
        .table => |t| {
            tables[n_tables] = t;
            n_tables += 1;
        },
        .paragraph => |p| {
            if (p.style == .heading1 and std.mem.eql(u8, paragraphText(p), "EXPONE")) expone = p;
            last = p;
        },
    };
    try testing.expectEqual(@as(usize, 2), n_tables);
    // The case details: no lines, a narrow label column.
    try testing.expect(tables[0].borderless);
    try testing.expectEqualSlices(u16, &.{ 30, 70 }, tables[0].col_weights);
    // The amounts: a wide left column and a narrow right-aligned one.
    try testing.expect(!tables[1].borderless);
    try testing.expect(tables[1].col_weights[0] > 3 * tables[1].col_weights[1]);
    try testing.expectEqual(docx.Alignment.left, cellAlignment(tables[1], 1, 0));
    try testing.expectEqual(docx.Alignment.right, cellAlignment(tables[1], 1, 1));
    // The headings carry no attribute: the letter style centres them.
    try testing.expect(expone.?.alignment == null);
    try testing.expectEqual(docx.Alignment.right, last.?.alignment.?);
    try testing.expectEqualStrings("Fdo.: Persona Ficticia Ejemplo", paragraphText(last.?));
}

test "every allocation failure while parsing is an error, never a leak" {
    const parse = struct {
        fn run(allocator: std.mem.Allocator, md: []const u8, options: ParseOptions) !void {
            var r = try parseMarkdownWith(allocator, md, options);
            r.deinit();
        }
    }.run;
    const everything =
        \\---
        \\title: T
        \\---
        \\<!-- letterhead: a.png -->
        \\<!-- letterhead: b.png -->
        \\# Head `code` [link](https://example.com) ![pic](p.png) {align=center}
        \\> quote **bold** {align=right}
        \\- item
        \\1. item
        \\---
        \\<!-- pagebreak -->
        \\```
        \\fenced
        \\```
        \\:::card
        \\**Name** [x]{color=red}
        \\Line
        \\:::
        \\| a | `b` |
        \\|:--|--:|
        \\| [l](https://example.com) | ![i](i.png) |
        \\{widths=1,2 borders=none}
        \\```
        \\never closed
    ;
    const docs = [_][]const u8{ @embedFile("testdata/escrito_sample.md"), everything };
    for (docs) |md| {
        for ([_]bool{ true, false }) |layout| {
            try testing.checkAllAllocationFailures(testing.allocator, parse, .{ md, ParseOptions{ .layout = layout } });
        }
    }
}
