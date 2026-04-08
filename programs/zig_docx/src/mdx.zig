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

    // Frontmatter
    try w.print("---\n", .{});
    if (options.title.len > 0) {
        try w.print("title: \"{s}\"\n", .{options.title});
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

    // Write runs
    for (p.runs) |run| {
        if (run.image_rel_id) |rel_id| {
            try writeImage(allocator, w, rel_id, doc, image_counter, image_refs, image_mode);
            continue;
        }

        if (run.text.len == 0) continue;

        const has_link = run.hyperlink_url != null;
        if (has_link) {
            try w.print("[", .{});
        }

        if (run.bold and run.italic) {
            try w.print("***{s}***", .{run.text});
        } else if (run.bold) {
            try w.print("**{s}**", .{run.text});
        } else if (run.italic) {
            try w.print("*{s}*", .{run.text});
        } else {
            try w.print("{s}", .{run.text});
        }

        if (has_link) {
            try w.print("]({s})", .{run.hyperlink_url.?});
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
    var first = true;
    for (cell.paragraphs) |para| {
        if (!first) {
            try w.print(" ", .{}); // Join multiple paragraphs in a cell with space
        }
        first = false;
        for (para.runs) |run| {
            if (run.text.len == 0) continue;
            if (run.bold) {
                try w.print("**{s}**", .{run.text});
            } else if (run.italic) {
                try w.print("*{s}*", .{run.text});
            } else {
                try w.print("{s}", .{run.text});
            }
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
