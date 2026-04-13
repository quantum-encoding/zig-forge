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
            }
            continue; // consume comment, don't emit as paragraph
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

/// Parse inline markdown formatting into a sequence of Runs.
/// Handles: **bold**, *italic*, ***bold italic***, `code`, [link](url)
pub fn parseInlineFormatting(allocator: std.mem.Allocator, text: []const u8) ![]docx.Run {
    var runs: std.ArrayListUnmanaged(docx.Run) = .empty;
    errdefer {
        for (runs.items) |r| if (r.text.len > 0) allocator.free(r.text);
        runs.deinit(allocator);
    }

    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < text.len) {
        // ── Inline code ──
        if (text[i] == '`' and !isDoubleBacktick(text, i)) {
            if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                plain_start = i;
                i += 1;
                continue;
            };
            const code_text = try allocator.dupe(u8, text[i + 1 .. end]);
            try runs.append(allocator, .{
                .text = code_text,
                .bold = false,
                .italic = false,
                .is_code = true,
            });
            i = end + 1;
            plain_start = i;
            continue;
        }

        // ── Bold + italic (***) ──
        if (i + 2 < text.len and text[i] == '*' and text[i + 1] == '*' and text[i + 2] == '*') {
            if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
            const close = findClosing(text, i + 3, "***") orelse {
                plain_start = i;
                i += 3;
                continue;
            };
            const inner = try allocator.dupe(u8, text[i + 3 .. close]);
            try runs.append(allocator, .{ .text = inner, .bold = true, .italic = true });
            i = close + 3;
            plain_start = i;
            continue;
        }

        // ── Bold (**) ──
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
            const close = findClosing(text, i + 2, "**") orelse {
                plain_start = i;
                i += 2;
                continue;
            };
            const inner = try allocator.dupe(u8, text[i + 2 .. close]);
            try runs.append(allocator, .{ .text = inner, .bold = true });
            i = close + 2;
            plain_start = i;
            continue;
        }

        // ── Italic (*) ──
        if (text[i] == '*' and (i + 1 < text.len and text[i + 1] != '*')) {
            if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '*') orelse {
                plain_start = i;
                i += 1;
                continue;
            };
            const inner = try allocator.dupe(u8, text[i + 1 .. close]);
            try runs.append(allocator, .{ .text = inner, .italic = true });
            i = close + 1;
            plain_start = i;
            continue;
        }

        // ── Image ![alt](path) ──
        if (text[i] == '!' and i + 1 < text.len and text[i + 1] == '[') {
            const close_bracket = std.mem.indexOfScalarPos(u8, text, i + 2, ']') orelse {
                i += 1;
                continue;
            };
            if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse {
                    i += 1;
                    continue;
                };
                if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
                const alt_text = try allocator.dupe(u8, text[i + 2 .. close_bracket]);
                const img_path = try allocator.dupe(u8, text[close_bracket + 2 .. close_paren]);
                try runs.append(allocator, .{
                    .text = alt_text,
                    .image_rel_id = img_path, // temporarily stores path; main.zig resolves to rel ID
                });
                i = close_paren + 1;
                plain_start = i;
                continue;
            }
        }

        // ── Link [text](url) ──
        if (text[i] == '[') {
            const close_bracket = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse {
                i += 1;
                continue;
            };
            if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse {
                    i += 1;
                    continue;
                };
                if (i > plain_start) try appendRun(allocator, &runs, text[plain_start..i], false, false, false);
                const link_text = try allocator.dupe(u8, text[i + 1 .. close_bracket]);
                try runs.append(allocator, .{
                    .text = link_text,
                    .hyperlink_url = try allocator.dupe(u8, text[close_bracket + 2 .. close_paren]),
                });
                i = close_paren + 1;
                plain_start = i;
                continue;
            }
        }

        i += 1;
    }

    // Remaining plain text
    if (plain_start < text.len) {
        try appendRun(allocator, &runs, text[plain_start..], false, false, false);
    }

    // If no runs at all, add an empty one so the paragraph isn't invisible
    if (runs.items.len == 0) {
        try appendRun(allocator, &runs, "", false, false, false);
    }

    return runs.toOwnedSlice(allocator);
}

fn appendRun(allocator: std.mem.Allocator, runs: *std.ArrayListUnmanaged(docx.Run), text: []const u8, bold: bool, italic: bool, is_code: bool) !void {
    try runs.append(allocator, .{
        .text = try allocator.dupe(u8, text),
        .bold = bold,
        .italic = italic,
        .is_code = is_code,
    });
}

fn findClosing(text: []const u8, start: usize, needle: []const u8) ?usize {
    const offset = std.mem.indexOf(u8, text[start..], needle) orelse return null;
    return start + offset; // absolute index into text
}

fn isDoubleBacktick(text: []const u8, pos: usize) bool {
    // Check for `` (code fence in inline) — we only handle single backtick
    return pos + 1 < text.len and text[pos + 1] == '`';
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
