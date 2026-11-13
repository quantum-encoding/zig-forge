//! MDX Output Generator
//!
//! Converts a parsed DOCX Document model into MDX (Markdown with JSX) format
//! suitable for Svelte/Astro blog posts with YAML frontmatter.

const std = @import("std");
const docx = @import("docx.zig");
const rels = @import("rels.zig");
const MarkColors = @import("md_parser.zig").MarkColors;

pub const MdxOptions = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    date: []const u8 = "",
    slug: []const u8 = "",
    image_mode: ImageMode = .file_reference,
    /// Also write text colour, shading and underline as `[text]{color=… bg=…
    /// underline}` spans, and runs in the redline look as CriticMarkup
    /// (`{--removed--}`, `{++added++}`), so Markdown → DOCX gives them back.
    /// Off by default: `{` opens a JSX expression in MDX, so the result is
    /// Markdown for zig_docx and zig_pdf_generator, not valid MDX.
    /// Strike-through (`~~`) and highlight (`==`) are written either way.
    marks: bool = false,

    pub const ImageMode = enum {
        file_reference, // ./images/1-image1.png (extract separately)
        placeholder, // ![Image 1]() placeholder only
    };
};

/// An image referenced in the document, resolved to its media file
pub const ImageRef = struct {
    index: u16, // 1-based sequential number
    filename: []const u8, // e.g. "1-image1.png"
    media_name: []const u8, // e.g. "media/image1.png" — key into doc.media
};

pub const MdxResult = struct {
    mdx: []u8,
    images: []ImageRef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MdxResult) void {
        self.allocator.free(self.mdx);
        for (self.images) |img| {
            self.allocator.free(img.filename);
        }
        self.allocator.free(self.images);
    }
};

pub fn generateMdx(allocator: std.mem.Allocator, doc: *const docx.Document, options: MdxOptions) !MdxResult {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    var image_counter: u16 = 0;
    var image_refs: std.ArrayListUnmanaged(ImageRef) = .empty;

    // Auto-extract title from first heading if not provided
    var auto_title: []const u8 = options.title;
    if (auto_title.len == 0) {
        for (doc.elements) |elem| {
            switch (elem) {
                .paragraph => |p| {
                    if (p.style == .heading1 or p.style == .title) {
                        if (p.runs.len > 0) {
                            // Concatenate all runs' text for the title
                            var title_buf: std.ArrayList(u8) = .empty;
                            defer title_buf.deinit(allocator);
                            for (p.runs) |run| {
                                title_buf.appendSlice(allocator, run.text) catch break;
                            }
                            if (title_buf.items.len > 0) {
                                auto_title = title_buf.toOwnedSlice(allocator) catch break;
                            }
                        }
                        break;
                    }
                },
                else => {},
            }
        }
    }

    // Frontmatter
    try w.print("---\n", .{});
    if (auto_title.len > 0) {
        try w.print("title: \"{s}\"\n", .{auto_title});
    }
    if (options.description.len > 0) {
        try w.print("description: \"{s}\"\n", .{options.description});
    }
    if (options.author.len > 0) {
        try w.print("author: \"{s}\"\n", .{options.author});
    }
    if (options.date.len > 0) {
        try w.print("date: \"{s}\"\n", .{options.date});
    }
    if (options.slug.len > 0) {
        try w.print("slug: \"{s}\"\n", .{options.slug});
    }
    try w.print("---\n\n", .{});

    // Content
    var prev_was_empty = false;
    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| {
                // Skip truly empty paragraphs but add spacing
                if (p.runs.len == 0) {
                    prev_was_empty = true;
                    continue;
                }
                prev_was_empty = false;

                try writeParagraph(allocator, w, &p, doc, &image_counter, &image_refs, options);
                // Blank line after every paragraph — required by Markdown for separate <p> tags
                try w.print("\n\n", .{});
            },
            .table => |t| {
                prev_was_empty = false;
                try w.print("\n", .{});
                try writeTable(allocator, w, &t, options.marks);
                try w.print("\n", .{});
            },
        }
    }

    return .{
        .mdx = try aw.toOwnedSlice(),
        .images = try image_refs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn writeParagraph(
    allocator: std.mem.Allocator,
    w: anytype,
    p: *const docx.Paragraph,
    doc: *const docx.Document,
    image_counter: *u16,
    image_refs: *std.ArrayListUnmanaged(ImageRef),
    options: MdxOptions,
) !void {
    const image_mode = options.image_mode;
    // Heading prefix
    const prefix: []const u8 = switch (p.style) {
        .heading1, .title => "# ",
        .heading2, .subtitle => "## ",
        .heading3 => "### ",
        .heading4 => "#### ",
        .heading5 => "##### ",
        .heading6 => "###### ",
        else => "",
    };

    // List item prefix
    if (p.is_list_item or p.style == .list_paragraph) {
        // Indent based on level
        var indent: u8 = 0;
        while (indent < p.numbering_level) : (indent += 1) {
            try w.print("  ", .{});
        }
        try w.print("- ", .{});
    } else if (prefix.len > 0) {
        try w.print("{s}", .{prefix});
    }

    // Check if paragraph contains inline bullet characters (author typed • manually)
    var has_inline_bullets = false;
    for (p.runs) |run| {
        if (std.mem.indexOfScalar(u8, run.text, 0xE2) != null) {
            // UTF-8 bullet • is E2 80 A2 — check if the text contains it
            if (std.mem.indexOf(u8, run.text, "\xe2\x80\xa2") != null) {
                has_inline_bullets = true;
                break;
            }
        }
    }

    if (has_inline_bullets) {
        // Collect all text, then split on • and emit as list items
        try writeInlineBulletList(allocator, w, p, doc, image_counter, image_refs, image_mode);
        return;
    }

    // Write runs, adjacent runs that look the same as one marked group.
    var i: usize = 0;
    while (i < p.runs.len) {
        const run = p.runs[i];
        if (run.image_rel_id) |rel_id| {
            try writeImage(allocator, w, rel_id, doc, image_counter, image_refs, image_mode);
            i += 1;
            continue;
        }
        if (run.text.len == 0) {
            i += 1;
            continue;
        }
        const end = groupEnd(p.runs, i, options.marks);
        try writeGroup(allocator, w, p.runs[i..end], options.marks);
        i = end;
    }
}

/// The Markdown marks a run needs. Bold, italic, strike-through (`~~`) and
/// highlight (`==`) always; with `marks`, a run in the redline look as
/// CriticMarkup and any other colour, shading or underline as a
/// `[text]{…}` span. A hyperlink's own blue and underline are the link's,
/// not marks.
const Look = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    highlight: bool = false,
    underline: bool = false,
    fg: ?docx.Rgb = null,
    bg: ?docx.Rgb = null,
    critic: Critic = .none,

    const Critic = enum { none, removed, added };

    fn of(run: docx.Run, marks: bool) Look {
        var l = Look{
            .bold = run.bold,
            .italic = run.italic,
            .strike = run.strike,
            .highlight = run.highlight,
        };
        if (!marks or run.hyperlink_url != null) return l;
        l.underline = run.underline;
        l.fg = run.fg;
        l.bg = run.bg;
        const mc = MarkColors{};
        if (run.strike and rgbIs(run.fg, mc.removed) and rgbIs(run.bg, mc.removed_fill)) {
            l.critic = .removed;
            l.strike = false;
            l.fg = null;
            l.bg = null;
        } else if (run.bold and rgbIs(run.fg, mc.added) and rgbIs(run.bg, mc.added_fill)) {
            l.critic = .added;
            l.bold = false;
            l.fg = null;
            l.bg = null;
        }
        return l;
    }

    fn eql(a: Look, b: Look) bool {
        return a.bold == b.bold and a.italic == b.italic and a.strike == b.strike and
            a.highlight == b.highlight and a.underline == b.underline and a.critic == b.critic and
            optRgbEql(a.fg, b.fg) and optRgbEql(a.bg, b.bg);
    }

    fn span(self: Look) bool {
        return self.fg != null or self.bg != null or self.underline;
    }

    fn plain(self: Look) bool {
        return !self.bold and !self.italic and !self.strike and !self.highlight and
            !self.span() and self.critic == .none;
    }

    fn emphasis(self: Look) []const u8 {
        if (self.bold and self.italic) return "***";
        if (self.bold) return "**";
        if (self.italic) return "*";
        return "";
    }

    fn open(self: Look, w: anytype) !void {
        switch (self.critic) {
            .removed => try w.writeAll("{--"),
            .added => try w.writeAll("{++"),
            .none => {},
        }
        if (self.span()) try w.writeAll("[");
        if (self.highlight) try w.writeAll("==");
        if (self.strike) try w.writeAll("~~");
        try w.writeAll(self.emphasis());
    }

    fn close(self: Look, w: anytype) !void {
        try w.writeAll(self.emphasis());
        if (self.strike) try w.writeAll("~~");
        if (self.highlight) try w.writeAll("==");
        if (self.span()) {
            try w.writeAll("]{");
            var sep: []const u8 = "";
            if (self.fg) |c| {
                try w.print("color=#{s}", .{&c});
                sep = " ";
            }
            if (self.bg) |c| {
                try w.print("{s}bg=#{s}", .{ sep, &c });
                sep = " ";
            }
            if (self.underline) try w.print("{s}underline", .{sep});
            try w.writeAll("}");
        }
        switch (self.critic) {
            .removed => try w.writeAll("--}"),
            .added => try w.writeAll("++}"),
            .none => {},
        }
    }
};

fn rgbIs(c: ?docx.Rgb, want: docx.Rgb) bool {
    return if (c) |v| std.mem.eql(u8, &v, &want) else false;
}

fn optRgbEql(a: ?docx.Rgb, b: ?docx.Rgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, &a.?, &b.?);
}

fn sameLink(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// One past the last run that joins the group starting at `start`: runs that
/// look the same and belong to the same hyperlink (or to none). Word splits
/// text into runs mid-word (spelling marks, revision ids), so a group is
/// written as one marked stretch rather than `**a****b**`.
fn groupEnd(runs: []const docx.Run, start: usize, marks: bool) usize {
    const first = runs[start];
    const look = Look.of(first, marks);
    var j = start + 1;
    while (j < runs.len) : (j += 1) {
        const next = runs[j];
        if (next.image_rel_id != null) break;
        if (next.text.len == 0) continue;
        if (!sameLink(first.hyperlink_url, next.hyperlink_url)) break;
        if (!Look.eql(look, Look.of(next, marks))) break;
    }
    return j;
}

/// Write a group of runs that look the same as one marked stretch. Spaces at
/// either end go outside the marks: `~~ word~~` does not read as
/// strike-through, `~~word~~ ` does.
fn writeGroup(allocator: std.mem.Allocator, w: anytype, group: []const docx.Run, marks: bool) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (group) |r| {
        if (r.image_rel_id == null) try text.appendSlice(allocator, r.text);
    }
    const all = text.items;

    // H3: only emit a markdown link when the target passes the scheme
    // allowlist (blocks javascript:/data:/vbscript:/file: and control-char
    // obfuscation). An unsafe target degrades to plain text — never a live
    // link. The URL is percent-escaped on emission so a `)` can't break out
    // of the `](…)` destination and inject MDX/JSX downstream.
    const link_url: ?[]const u8 = if (group[0].hyperlink_url) |u|
        (if (isSafeLinkUrl(u)) u else null)
    else
        null;
    const look = Look.of(group[0], marks);

    const ws = " \t\r\n";
    const core_start = std.mem.indexOfNone(u8, all, ws) orelse all.len;
    const core_end = if (std.mem.lastIndexOfNone(u8, all, ws)) |e| e + 1 else core_start;
    if (core_start >= core_end or (look.plain() and link_url == null)) {
        try w.writeAll(all);
        return;
    }

    try w.writeAll(all[0..core_start]);
    if (link_url != null) try w.writeAll("[");
    try look.open(w);
    try w.writeAll(all[core_start..core_end]);
    try look.close(w);
    if (link_url) |u| {
        try w.writeAll("](");
        try writeEscapedLinkUrl(w, u);
        try w.writeAll(")");
    }
    try w.writeAll(all[core_end..]);
}

/// H3 — hyperlink scheme allowlist. Returns true only for URLs safe to emit as
/// a live markdown/MDX link: `http:`, `https:`, `mailto:`, or a relative
/// reference (no scheme, e.g. `./a.png`, `#anchor`, `/path`, `//host/x`).
/// Rejects script-bearing schemes (`javascript:`, `data:`, `vbscript:`,
/// `file:`, …) and any control characters. Case-insensitive on the scheme.
pub fn isSafeLinkUrl(url_in: []const u8) bool {
    if (url_in.len == 0) return false;
    // Reject control chars anywhere (NUL, tab, newline, DEL) — these enable
    // scheme obfuscation like "java\tscript:" that browsers may still execute.
    for (url_in) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    // Browsers strip leading whitespace before resolving the scheme, so must we.
    const url = std.mem.trimStart(u8, url_in, " ");
    if (url.len == 0) return false;

    // A scheme starts with an alpha char; if the first char isn't alpha, this
    // is a relative reference (path/fragment) with no scheme — allow.
    if (!std.ascii.isAlphabetic(url[0])) return true;

    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        if (c == ':') {
            const scheme = url[0..i];
            return std.ascii.eqlIgnoreCase(scheme, "http") or
                std.ascii.eqlIgnoreCase(scheme, "https") or
                std.ascii.eqlIgnoreCase(scheme, "mailto");
        }
        // A '/', '?' or '#' before any ':' means there is no scheme → relative.
        if (c == '/' or c == '?' or c == '#') return true;
        // Not a valid scheme char and no ':' yet → not a scheme → relative.
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return true;
    }
    // No ':' at all → relative reference.
    return true;
}

/// Emit a link destination with the characters that would break out of a
/// markdown `](…)` destination percent-encoded: `(`, `)`, spaces, and any
/// stray control byte. Prevents a `)` in the URL from terminating the link and
/// injecting following text as MDX/JSX.
fn writeEscapedLinkUrl(w: anytype, url: []const u8) !void {
    for (url) |c| {
        switch (c) {
            '(' => try w.print("%28", .{}),
            ')' => try w.print("%29", .{}),
            ' ' => try w.print("%20", .{}),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("%{X:0>2}", .{c});
                } else {
                    try w.print("{c}", .{c});
                }
            },
        }
    }
}

/// Handle paragraphs where the author typed • bullet characters manually
/// instead of using Word's list formatting. Splits on • and emits proper markdown list.
fn writeInlineBulletList(
    allocator: std.mem.Allocator,
    w: anytype,
    p: *const docx.Paragraph,
    doc: *const docx.Document,
    image_counter: *u16,
    image_refs: *std.ArrayListUnmanaged(ImageRef),
    image_mode: MdxOptions.ImageMode,
) !void {
    // The items are written as plain text: a mark opened in one item could
    // otherwise close in the next. Images are written where they stand.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    for (p.runs) |run| {
        if (run.image_rel_id) |rel_id| {
            try writeImage(allocator, w, rel_id, doc, image_counter, image_refs, image_mode);
            continue;
        }
        try plain.appendSlice(allocator, run.text);
    }

    // Split on • (UTF-8: E2 80 A2) and emit each segment as a list item
    const bullet_char = "\xe2\x80\xa2";
    var iter = std.mem.splitSequence(u8, plain.items, bullet_char);
    var first = true;
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) {
            first = false;
            continue;
        }

        if (first) {
            // Text before the first bullet — emit as a normal paragraph
            try w.print("{s}\n\n", .{trimmed});
            first = false;
        } else {
            try w.print("- {s}\n", .{trimmed});
        }
    }
}

fn writeTable(allocator: std.mem.Allocator, w: anytype, table: *const docx.Table, marks: bool) !void {
    if (table.rows.len == 0) return;

    // Write header row (first row)
    const header = &table.rows[0];
    try w.print("|", .{});
    for (header.cells) |cell| {
        try w.print(" ", .{});
        try writeCellText(allocator, w, &cell, marks);
        try w.print(" |", .{});
    }
    try w.print("\n", .{});

    // Separator row
    try w.print("|", .{});
    for (header.cells) |_| {
        try w.print("---|", .{});
    }
    try w.print("\n", .{});

    // Data rows
    for (table.rows[1..]) |row| {
        try w.print("|", .{});
        for (row.cells) |cell| {
            try w.print(" ", .{});
            try writeCellText(allocator, w, &cell, marks);
            try w.print(" |", .{});
        }
        try w.print("\n", .{});
    }
}

fn writeCellText(allocator: std.mem.Allocator, w: anytype, cell: *const docx.TableCell, marks: bool) !void {
    var first_para = true;
    for (cell.paragraphs) |para| {
        if (!first_para) {
            try w.print(" ", .{}); // Join multiple paragraphs in a cell with space
        }
        first_para = false;

        var ri: usize = 0;
        while (ri < para.runs.len) {
            const run = para.runs[ri];
            if (run.text.len == 0 or run.image_rel_id != null) {
                ri += 1;
                continue;
            }
            const end = groupEnd(para.runs, ri, marks);
            try writeGroup(allocator, w, para.runs[ri..end], marks);
            ri = end;
        }
    }
}

fn writeImage(
    allocator: std.mem.Allocator,
    w: anytype,
    rel_id: []const u8,
    doc: *const docx.Document,
    image_counter: *u16,
    image_refs: *std.ArrayListUnmanaged(ImageRef),
    image_mode: MdxOptions.ImageMode,
) !void {
    image_counter.* += 1;
    const idx = image_counter.*;

    // Look up relationship to get target path (e.g. "media/image1.png")
    var target: []const u8 = "";
    for (doc.relationships) |rel| {
        if (std.mem.eql(u8, rel.id, rel_id)) {
            target = rel.target;
            break;
        }
    }

    // Extract just the filename from target (e.g. "media/image1.png" -> "image1.png")
    const base_name = if (std.mem.lastIndexOfScalar(u8, target, '/')) |slash|
        target[slash + 1 ..]
    else if (target.len > 0)
        target
    else
        "image.png";

    // Build numbered filename: "1-image1.png"
    var name_buf: [256]u8 = undefined;
    const numbered_name = std.fmt.bufPrint(&name_buf, "{d}-{s}", .{ idx, base_name }) catch base_name;

    // Record the image reference for extraction
    try image_refs.append(allocator, .{
        .index = idx,
        .filename = try allocator.dupe(u8, numbered_name),
        .media_name = target, // points into doc.relationships (owned by Document)
    });

    // Write markdown image reference
    switch (image_mode) {
        .file_reference => try w.print("![Image {d}](./images/{s})", .{ idx, numbered_name }),
        .placeholder => try w.print("![Image {d}]()", .{idx}),
    }
}

// =============================================================================
// Tests
// =============================================================================

test "generate MDX from simple document" {
    const allocator = std.testing.allocator;

    const runs1 = [_]docx.Run{
        .{ .text = "Hello World" },
    };
    const runs2 = [_]docx.Run{
        .{ .text = "Bold text", .bold = true },
        .{ .text = " and normal" },
    };
    const runs3 = [_]docx.Run{
        .{ .text = "List item" },
    };

    const elements = [_]docx.Element{
        .{ .paragraph = .{ .style = .heading1, .runs = @constCast(&runs1) } },
        .{ .paragraph = .{ .style = .normal, .runs = @constCast(&runs2) } },
        .{ .paragraph = .{ .style = .list_paragraph, .runs = @constCast(&runs3), .is_list_item = true } },
    };

    const doc = docx.Document{
        .elements = @constCast(&elements),
        .media = @constCast(&[_]docx.MediaFile{}),
        .allocator = allocator,
    };

    var result = try generateMdx(allocator, &doc, .{
        .title = "Test Document",
        .author = "Test Author",
    });
    defer result.deinit();

    // Check frontmatter
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "title: \"Test Document\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "author: \"Test Author\"") != null);

    // Check content
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "# Hello World") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "**Bold text**") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "- List item") != null);
}

test "H3: isSafeLinkUrl allows http/https/mailto and relative, blocks scripts" {
    // Safe schemes and relative references.
    try std.testing.expect(isSafeLinkUrl("http://example.com/a"));
    try std.testing.expect(isSafeLinkUrl("https://example.com/a?b=c#d"));
    try std.testing.expect(isSafeLinkUrl("HTTPS://EXAMPLE.COM")); // case-insensitive
    try std.testing.expect(isSafeLinkUrl("mailto:a@b.com"));
    try std.testing.expect(isSafeLinkUrl("./images/x.png"));
    try std.testing.expect(isSafeLinkUrl("../docs/x.png"));
    try std.testing.expect(isSafeLinkUrl("#anchor"));
    try std.testing.expect(isSafeLinkUrl("/absolute/path"));
    try std.testing.expect(isSafeLinkUrl("//host/proto-relative"));

    // Dangerous schemes are rejected.
    try std.testing.expect(!isSafeLinkUrl("javascript:alert(1)"));
    try std.testing.expect(!isSafeLinkUrl("JavaScript:alert(1)"));
    try std.testing.expect(!isSafeLinkUrl("  javascript:alert(1)")); // leading-space bypass
    try std.testing.expect(!isSafeLinkUrl("data:text/html;base64,PHN2Zz4="));
    try std.testing.expect(!isSafeLinkUrl("vbscript:msgbox(1)"));
    try std.testing.expect(!isSafeLinkUrl("file:///etc/passwd"));
    try std.testing.expect(!isSafeLinkUrl("tel:12345")); // not on allowlist
    // Control-char obfuscation (e.g. "java\tscript:") is rejected outright.
    try std.testing.expect(!isSafeLinkUrl("java\tscript:alert(1)"));
    try std.testing.expect(!isSafeLinkUrl(""));
}

test "H3: writeEscapedLinkUrl percent-encodes parens/spaces so links can't break out" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeEscapedLinkUrl(&aw.writer, "https://x.com/a(b)c d");
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    try std.testing.expectEqualStrings("https://x.com/a%28b%29c%20d", out);
}

// ─── Round trips through .docx ────────────────────────────────────

/// Markdown → .docx → parsed document → MDX body (frontmatter dropped).
fn roundTrip(arena: std.mem.Allocator, md: []const u8, marks: bool) ![]const u8 {
    var parsed = try docx.md_parser.parseMarkdown(arena, md);
    _ = &parsed;
    const bytes = try docx.docx_writer.generateDocx(arena, &parsed.document, .{});
    var archive = try docx.zip.ZipArchive.openFromMemory(arena, bytes);
    const doc = try docx.parseDocument(arena, &archive);
    const result = try generateMdx(arena, &doc, .{ .marks = marks });
    const body = result.mdx[std.mem.indexOf(u8, result.mdx, "---\n\n").? + 5 ..];
    return std.mem.trim(u8, body, "\n");
}

test "struck and highlighted text comes back as ~~ and ==" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Word stores formatting per run, so nested marks come back run by run:
    // the same look, written flat.
    try std.testing.expectEqualStrings(
        "Keep ~~this~~ and ==that== **bold** ~~**both**~~.",
        try roundTrip(arena, "Keep ~~this~~ and ==that== **bold ~~both~~**.", false),
    );
    // Without marks, a redline run keeps its strike, an added run its bold.
    try std.testing.expectEqualStrings(
        "~~old~~**new** [plain]",
        try roundTrip(arena, "{--old--}{++new++} [[plain]]{color=red}", false),
    );
}

test "with marks, colours and CriticMarkup come back as typed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const md = "{--old--} {++new++} [warn]{color=#B91C1C bg=#FEE2E2 underline} ==mark==";
    try std.testing.expectEqualStrings(md, try roundTrip(arena, md, true));
    // A table cell takes the same marks.
    const table = "| a | b |\n|---|---|\n| ~~x~~ | {++y++} |";
    const out = try roundTrip(arena, table, true);
    try std.testing.expect(std.mem.indexOf(u8, out, "| ~~x~~ | {++y++} |") != null);
}

test "spaces at the edge of a run go outside its marks" {
    const runs = [_]docx.Run{
        .{ .text = "kept " },
        .{ .text = "free ", .strike = true },
        .{ .text = "from " },
        .{ .text = " bold ", .bold = true },
        .{ .text = "end" },
    };
    const elements = [_]docx.Element{.{ .paragraph = .{ .runs = @constCast(&runs) } }};
    const doc = docx.Document{
        .elements = @constCast(&elements),
        .media = @constCast(&[_]docx.MediaFile{}),
        .allocator = std.testing.allocator,
    };
    var result = try generateMdx(std.testing.allocator, &doc, .{ .title = "t" });
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "kept ~~free~~ from  **bold** end") != null);
}

test "text after a link is not pulled into the link" {
    const runs = [_]docx.Run{
        .{ .text = "see ", .hyperlink_url = null },
        .{ .text = "the site", .hyperlink_url = "https://example.com" },
        .{ .text = " for more" },
    };
    const elements = [_]docx.Element{.{ .paragraph = .{ .runs = @constCast(&runs) } }};
    const doc = docx.Document{
        .elements = @constCast(&elements),
        .media = @constCast(&[_]docx.MediaFile{}),
        .allocator = std.testing.allocator,
    };
    var result = try generateMdx(std.testing.allocator, &doc, .{ .title = "t" });
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.mdx, "see [the site](https://example.com) for more") != null);
}
