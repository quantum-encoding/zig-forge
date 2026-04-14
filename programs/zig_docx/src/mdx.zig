//! MDX Output Generator
//!
//! Converts a parsed DOCX Document model into MDX (Markdown with JSX) format
//! suitable for Svelte/Astro blog posts with YAML frontmatter.

const std = @import("std");
const docx = @import("docx.zig");
const rels = @import("rels.zig");

pub const MdxOptions = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    date: []const u8 = "",
    slug: []const u8 = "",
    image_mode: ImageMode = .file_reference,

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

                try writeParagraph(allocator, w, &p, doc, &image_counter, &image_refs, options.image_mode);
                // Blank line after every paragraph — required by Markdown for separate <p> tags
                try w.print("\n\n", .{});
            },
            .table => |t| {
                prev_was_empty = false;
                try w.print("\n", .{});
                try writeTable(w, &t);
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
    image_mode: MdxOptions.ImageMode,
) !void {
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

    // Write runs, merging adjacent runs with same formatting to avoid ****
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

        const has_link = run.hyperlink_url != null;

        // Merge consecutive runs with identical formatting (bold/italic)
        // This prevents **text1****text2** → **text1 text2**
        var merged_end = i + 1;
        while (merged_end < p.runs.len) {
            const next = p.runs[merged_end];
            if (next.text.len == 0) {
                merged_end += 1;
                continue;
            }
            if (next.bold != run.bold or next.italic != run.italic or
                next.hyperlink_url != null or next.image_rel_id != null) break;
            merged_end += 1;
        }

        if (has_link) try w.print("[", .{});

        // Open formatting
        if (run.bold and run.italic) {
            try w.print("***", .{});
        } else if (run.bold) {
            try w.print("**", .{});
        } else if (run.italic) {
            try w.print("*", .{});
        }

        // Write merged text, inserting spaces between runs where needed
        var j = i;
        while (j < merged_end) : (j += 1) {
            const r = p.runs[j];
            if (r.text.len == 0) continue;
            if (r.image_rel_id != null) continue;

            // Check if we need a space between this run and the previous
            if (j > i) {
                var prev_text: []const u8 = "";
                var k = j - 1;
                while (true) {
                    if (p.runs[k].text.len > 0 and p.runs[k].image_rel_id == null) {
                        prev_text = p.runs[k].text;
                        break;
                    }
                    if (k == i) break;
                    k -= 1;
                }
                if (needsSpaceBetween(prev_text, r.text)) {
                    try w.print(" ", .{});
                }
            }
            try w.print("{s}", .{r.text});
        }

        // Close formatting
        if (run.bold and run.italic) {
            try w.print("***", .{});
        } else if (run.bold) {
            try w.print("**", .{});
        } else if (run.italic) {
            try w.print("*", .{});
        }

        if (has_link) {
            try w.print("]({s})", .{run.hyperlink_url.?});
        }

        i = merged_end;
    }
}

fn needsSpaceBetween(prev_text: []const u8, next_text: []const u8) bool {
    if (prev_text.len == 0 or next_text.len == 0) return false;
    const prev = prev_text[prev_text.len - 1];
    const next = next_text[0];
    // If either side is already whitespace, no space needed
    if (prev == ' ' or prev == '\t' or prev == '\n') return false;
    if (next == ' ' or next == '\t' or next == '\n') return false;
    // If both sides are word characters (letter/digit), insert a space.
    // Word splits text across runs at formatting boundaries, not mid-word.
    const prev_is_word = (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or (prev >= '0' and prev <= '9');
    const next_is_word = (next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or (next >= '0' and next <= '9');
    return prev_is_word and next_is_word;
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
    // First, collect all text from runs into a single buffer with formatting
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var ri: usize = 0;
    while (ri < p.runs.len) {
        const run = p.runs[ri];
        if (run.image_rel_id) |rel_id| {
            try writeImage(allocator, w, rel_id, doc, image_counter, image_refs, image_mode);
            ri += 1;
            continue;
        }
        if (run.text.len == 0) { ri += 1; continue; }

        // Merge consecutive runs with same formatting
        var merge_end = ri + 1;
        while (merge_end < p.runs.len) {
            const nr = p.runs[merge_end];
            if (nr.text.len == 0) { merge_end += 1; continue; }
            if (nr.bold != run.bold or nr.italic != run.italic or
                nr.hyperlink_url != null or nr.image_rel_id != null) break;
            merge_end += 1;
        }

        // Open formatting
        if (run.bold and run.italic) {
            try buf.appendSlice(allocator, "***");
        } else if (run.bold) {
            try buf.appendSlice(allocator, "**");
        } else if (run.italic) {
            try buf.appendSlice(allocator, "*");
        }

        // Write merged runs with space insertion
        var rj = ri;
        while (rj < merge_end) : (rj += 1) {
            const r = p.runs[rj];
            if (r.text.len == 0 or r.image_rel_id != null) continue;
            if (rj > ri) {
                // Find prev text
                var prev_text: []const u8 = "";
                var rk = rj - 1;
                while (true) {
                    if (p.runs[rk].text.len > 0 and p.runs[rk].image_rel_id == null) {
                        prev_text = p.runs[rk].text;
                        break;
                    }
                    if (rk == ri) break;
                    rk -= 1;
                }
                if (needsSpaceBetween(prev_text, r.text)) {
                    try buf.appendSlice(allocator, " ");
                }
            }
            try buf.appendSlice(allocator, r.text);
        }

        // Close formatting
        if (run.bold and run.italic) {
            try buf.appendSlice(allocator, "***");
        } else if (run.bold) {
            try buf.appendSlice(allocator, "**");
        } else if (run.italic) {
            try buf.appendSlice(allocator, "*");
        }

        ri = merge_end;
    }

    // Strip all markdown formatting markers from the collected text.
    // We'll re-apply bold to the entire list item text instead of inline.
    // This avoids broken ** markers when bold spans across bullet boundaries.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    {
        var i: usize = 0;
        while (i < buf.items.len) {
            if (i + 2 < buf.items.len and std.mem.eql(u8, buf.items[i .. i + 3], "***")) {
                i += 3; // Skip ***
            } else if (i + 1 < buf.items.len and std.mem.eql(u8, buf.items[i .. i + 2], "**")) {
                i += 2; // Skip **
            } else if (buf.items[i] == '*') {
                i += 1; // Skip *
            } else {
                try plain.append(allocator, buf.items[i]);
                i += 1;
            }
        }
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

fn writeTable(w: anytype, table: *const docx.Table) !void {
    if (table.rows.len == 0) return;

    // Write header row (first row)
    const header = &table.rows[0];
    try w.print("|", .{});
    for (header.cells) |cell| {
        try w.print(" ", .{});
        try writeCellText(w, &cell);
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
            try writeCellText(w, &cell);
            try w.print(" |", .{});
        }
        try w.print("\n", .{});
    }
}

fn writeCellText(w: anytype, cell: *const docx.TableCell) !void {
    var first_para = true;
    for (cell.paragraphs) |para| {
        if (!first_para) {
            try w.print(" ", .{}); // Join multiple paragraphs in a cell with space
        }
        first_para = false;

        // Merge adjacent runs with same formatting, insert spaces between word runs
        var ri: usize = 0;
        while (ri < para.runs.len) {
            const run = para.runs[ri];
            if (run.text.len == 0) { ri += 1; continue; }

            // Merge consecutive runs with same formatting
            var merge_end = ri + 1;
            while (merge_end < para.runs.len) {
                const nr = para.runs[merge_end];
                if (nr.text.len == 0) { merge_end += 1; continue; }
                if (nr.bold != run.bold or nr.italic != run.italic or
                    nr.hyperlink_url != null or nr.image_rel_id != null) break;
                merge_end += 1;
            }

            // Open formatting
            if (run.bold and run.italic) {
                try w.print("***", .{});
            } else if (run.bold) {
                try w.print("**", .{});
            } else if (run.italic) {
                try w.print("*", .{});
            }

            // Write merged runs
            var rj = ri;
            while (rj < merge_end) : (rj += 1) {
                const r = para.runs[rj];
                if (r.text.len == 0 or r.image_rel_id != null) continue;
                if (rj > ri) {
                    var prev_text: []const u8 = "";
                    var rk = rj - 1;
                    while (true) {
                        if (para.runs[rk].text.len > 0 and para.runs[rk].image_rel_id == null) {
                            prev_text = para.runs[rk].text;
                            break;
                        }
                        if (rk == ri) break;
                        rk -= 1;
                    }
                    if (needsSpaceBetween(prev_text, r.text)) {
                        try w.print(" ", .{});
                    }
                }
                try w.print("{s}", .{r.text});
            }

            // Close formatting
            if (run.bold and run.italic) {
                try w.print("***", .{});
            } else if (run.bold) {
                try w.print("**", .{});
            } else if (run.italic) {
                try w.print("*", .{});
            }

            ri = merge_end;
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
