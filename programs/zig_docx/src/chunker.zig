//! Section-Aware Document Chunker
//!
//! Splits markdown documents into AI-optimized chunks that respect
//! document structure (headers, code blocks, tables).
//! Each chunk gets a content hash for stable cross-references.

const std = @import("std");

pub const ChunkConfig = struct {
    target_words: u32 = 6000,
    min_words: u32 = 500,
    max_words: u32 = 8000,
};

pub const Chunk = struct {
    index: u32,
    title: []const u8,
    content: []const u8,
    word_count: u32,
    hash: [16]u8, // MD5 of content for stable chunk IDs
    has_code: bool,
    has_tables: bool,
    allocator: std.mem.Allocator,

    pub fn hashHex(self: *const Chunk) [32]u8 {
        var hex: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>32}", .{std.mem.readInt(u128, &self.hash, .big)}) catch {};
        return hex;
    }

    pub fn deinit(self: *Chunk) void {
        self.allocator.free(self.title);
        self.allocator.free(self.content);
    }
};

pub const ChunkResult = struct {
    chunks: []Chunk,
    total_words: u32,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChunkResult) void {
        for (self.chunks) |*chunk| {
            var c = chunk.*;
            c.deinit();
        }
        self.allocator.free(self.chunks);
        self.allocator.free(self.source);
    }

    /// Generate the index.md navigation file
    pub fn generateIndex(self: *const ChunkResult, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# Chunk Index\n\n");
        const src_line = try std.fmt.allocPrint(allocator, "Source: `{s}`\n", .{self.source});
        defer allocator.free(src_line);
        try buf.appendSlice(allocator, src_line);

        const stats = try std.fmt.allocPrint(allocator, "Total chunks: {d} | Total words: {d}\n\n## Chunks\n\n", .{ self.chunks.len, self.total_words });
        defer allocator.free(stats);
        try buf.appendSlice(allocator, stats);

        for (self.chunks) |chunk| {
            const fname = chunkFilename(allocator, chunk.index, chunk.title) catch continue;
            defer allocator.free(fname);
            const hex = chunk.hashHex();

            const line = try std.fmt.allocPrint(allocator, "- [{s}](./{s}) — {d} words `#{s}`{s}{s}\n", .{
                chunk.title,
                fname,
                chunk.word_count,
                hex[0..8],
                if (chunk.has_code) " [code]" else "",
                if (chunk.has_tables) " [table]" else "",
            });
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Generate a single chunk's markdown with navigation headers
    pub fn generateChunkMd(self: *const ChunkResult, allocator: std.mem.Allocator, idx: usize) ![]u8 {
        if (idx >= self.chunks.len) return error.IndexOutOfBounds;
        const chunk = &self.chunks[idx];
        const hex = chunk.hashHex();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        // Header comment
        const header = try std.fmt.allocPrint(allocator,
            "<!-- chunk:{d}/{d} hash:{s} words:{d} -->\n\n",
            .{ chunk.index + 1, self.chunks.len, hex[0..16], chunk.word_count },
        );
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);

        // Navigation
        try buf.appendSlice(allocator, try self.navLine(allocator, idx));

        try buf.appendSlice(allocator, "\n---\n\n");

        // Content
        try buf.appendSlice(allocator, chunk.content);

        try buf.appendSlice(allocator, "\n\n---\n\n");

        // Bottom navigation
        try buf.appendSlice(allocator, try self.navLine(allocator, idx));
        try buf.appendSlice(allocator, "\n");

        return buf.toOwnedSlice(allocator);
    }

    fn navLine(self: *const ChunkResult, allocator: std.mem.Allocator, idx: usize) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        if (idx > 0) {
            const prev = chunkFilename(allocator, self.chunks[idx - 1].index, self.chunks[idx - 1].title) catch "prev.md";
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "[<< Previous](./{s})", .{prev}));
        }

        try buf.appendSlice(allocator, " | [Index](./index.md) | ");

        if (idx + 1 < self.chunks.len) {
            const next_fn = chunkFilename(allocator, self.chunks[idx + 1].index, self.chunks[idx + 1].title) catch "next.md";
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "[Next >>](./{s})", .{next_fn}));
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// Chunk a markdown document into sections
pub fn chunkDocument(allocator: std.mem.Allocator, markdown: []const u8, source_name: []const u8, config: ChunkConfig) !ChunkResult {
    var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    var total_words: u32 = 0;

    // Split into sections based on headers
    var sections: std.ArrayListUnmanaged(Section) = .empty;
    defer sections.deinit(allocator);
    try findSections(allocator, markdown, &sections);

    // Merge small sections, split large ones
    var merged: std.ArrayListUnmanaged(Section) = .empty;
    defer merged.deinit(allocator);
    try optimizeSections(allocator, &sections, &merged, config);

    // Create chunks from sections
    for (merged.items, 0..) |section, i| {
        const content = try allocator.dupe(u8, section.content);
        const wc = countWords(content);
        total_words += wc;

        // MD5 hash of content for stable IDs
        var hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(content, &hash, .{});

        try chunks.append(allocator, .{
            .index = @intCast(i),
            .title = try allocator.dupe(u8, section.title),
            .content = content,
            .word_count = wc,
            .hash = hash,
            .has_code = std.mem.indexOf(u8, content, "```") != null,
            .has_tables = std.mem.indexOf(u8, content, "| ") != null and std.mem.indexOf(u8, content, " |") != null,
            .allocator = allocator,
        });
    }

    return ChunkResult{
        .chunks = try chunks.toOwnedSlice(allocator),
        .total_words = total_words,
        .source = try allocator.dupe(u8, source_name),
        .allocator = allocator,
    };
}

// ─────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────

const Section = struct {
    title: []const u8,
    content: []const u8,
    word_count: u32,
};

fn findSections(allocator: std.mem.Allocator, markdown: []const u8, sections: *std.ArrayListUnmanaged(Section)) !void {
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var current_title: []const u8 = "Untitled";
    var current_start: usize = 0;
    var in_code_block = false;
    var pos: usize = 0;
    var lines_since_break: u32 = 0;

    while (lines.next()) |line| {
        const line_end = pos + line.len + 1; // +1 for \n

        // Track code blocks — never split inside them
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            in_code_block = !in_code_block;
        }

        if (!in_code_block) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            // Detect headers
            if (std.mem.startsWith(u8, trimmed, "# ") or std.mem.startsWith(u8, trimmed, "## ")) {
                // H1/H2 always break
                if (pos > current_start) {
                    try sections.append(allocator, .{
                        .title = current_title,
                        .content = markdown[current_start..pos],
                        .word_count = countWords(markdown[current_start..pos]),
                    });
                }
                // Extract title
                var t = trimmed;
                while (t.len > 0 and t[0] == '#') t = t[1..];
                current_title = std.mem.trim(u8, t, " \t*");
                current_start = pos;
                lines_since_break = 0;
            } else if (std.mem.startsWith(u8, trimmed, "### ") and lines_since_break >= 50) {
                // H3 only breaks after 50+ lines
                if (pos > current_start) {
                    try sections.append(allocator, .{
                        .title = current_title,
                        .content = markdown[current_start..pos],
                        .word_count = countWords(markdown[current_start..pos]),
                    });
                }
                var t = trimmed;
                while (t.len > 0 and t[0] == '#') t = t[1..];
                current_title = std.mem.trim(u8, t, " \t*");
                current_start = pos;
                lines_since_break = 0;
            }
        }

        lines_since_break += 1;
        pos = line_end;
    }

    // Final section
    if (current_start < markdown.len) {
        try sections.append(allocator, .{
            .title = current_title,
            .content = markdown[current_start..],
            .word_count = countWords(markdown[current_start..]),
        });
    }
}

fn optimizeSections(
    allocator: std.mem.Allocator,
    sections: *std.ArrayListUnmanaged(Section),
    merged: *std.ArrayListUnmanaged(Section),
    config: ChunkConfig,
) !void {
    var i: usize = 0;
    while (i < sections.items.len) {
        var section = sections.items[i];

        // Merge small sections with next
        while (section.word_count < config.min_words and i + 1 < sections.items.len) {
            i += 1;
            const next = sections.items[i];
            // Merge: keep first title, concatenate content
            const merged_content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ section.content, next.content });
            section = .{
                .title = section.title,
                .content = merged_content,
                .word_count = section.word_count + next.word_count,
            };
        }

        // Split large sections at paragraph boundaries
        if (section.word_count > config.max_words) {
            try splitLargeSection(allocator, section, merged, config);
        } else {
            try merged.append(allocator, section);
        }

        i += 1;
    }
}

fn splitLargeSection(
    allocator: std.mem.Allocator,
    section: Section,
    merged: *std.ArrayListUnmanaged(Section),
    config: ChunkConfig,
) !void {
    const content = section.content;
    var start: usize = 0;
    var part: u32 = 1;

    while (start < content.len) {
        // Find split point at ~80% of target at a paragraph boundary
        const target_chars = @as(usize, config.target_words) * 5; // ~5 chars per word
        const search_end = @min(start + target_chars, content.len);

        // Look for a blank line (paragraph boundary) near the target
        var best_split = search_end;
        if (search_end < content.len) {
            // Search backwards from target for a blank line
            var j = search_end;
            while (j > start + target_chars / 2) : (j -= 1) {
                if (j + 1 < content.len and content[j] == '\n' and content[j + 1] == '\n') {
                    best_split = j + 2;
                    break;
                }
            }
        }

        const chunk_content = content[start..best_split];
        const title = if (part == 1)
            section.title
        else
            (std.fmt.allocPrint(allocator, "{s} (part {d})", .{ section.title, part }) catch section.title);

        try merged.append(allocator, .{
            .title = title,
            .content = chunk_content,
            .word_count = countWords(chunk_content),
        });

        start = best_split;
        part += 1;
    }
}

fn countWords(text: []const u8) u32 {
    var count: u32 = 0;
    var in_word = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (in_word) count += 1;
            in_word = false;
        } else {
            in_word = true;
        }
    }
    if (in_word) count += 1;
    return count;
}

pub fn chunkFilename(allocator: std.mem.Allocator, index: u32, title: []const u8) ![]u8 {
    // Sanitize title: alphanumeric + underscore only, max 50 chars
    var name_buf: [50]u8 = undefined;
    var name_len: usize = 0;
    for (title) |c| {
        if (name_len >= 50) break;
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_') {
            name_buf[name_len] = c;
            name_len += 1;
        } else if ((c >= 'A' and c <= 'Z')) {
            name_buf[name_len] = c + 32; // lowercase
            name_len += 1;
        } else if (c == ' ' or c == '-') {
            name_buf[name_len] = '_';
            name_len += 1;
        }
    }
    if (name_len == 0) {
        name_buf[0] = 'c';
        name_buf[1] = 'h';
        name_buf[2] = 'u';
        name_buf[3] = 'n';
        name_buf[4] = 'k';
        name_len = 5;
    }

    return std.fmt.allocPrint(allocator, "{d:0>4}_{s}.md", .{ index + 1, name_buf[0..name_len] });
}
