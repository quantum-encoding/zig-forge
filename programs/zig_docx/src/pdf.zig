//! PDF Text Extraction
//!
//! Extracts text from PDF files using system tools (pdftotext from poppler).
//! Falls back to basic binary extraction if no tools available.

const std = @import("std");

pub const PdfResult = struct {
    text: []u8,
    page_count: u32,
    method: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PdfResult) void {
        self.allocator.free(self.text);
    }
};

/// Extract text from a PDF file. Tries pdftotext first, then mutool.
pub fn extractPdf(allocator: std.mem.Allocator, path: []const u8) !PdfResult {
    // Try pdftotext (poppler) — best quality, preserves layout
    if (tryPdfToText(allocator, path)) |text| {
        const pages = countFormFeeds(text);
        return PdfResult{
            .text = text,
            .page_count = pages,
            .method = "pdftotext",
            .allocator = allocator,
        };
    }

    // Try mutool (mupdf)
    if (tryMutool(allocator, path)) |text| {
        return PdfResult{
            .text = text,
            .page_count = countFormFeeds(text),
            .method = "mutool",
            .allocator = allocator,
        };
    }

    return error.NoPdfToolAvailable;
}

fn tryPdfToText(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    // pdftotext -layout file.pdf -
    var io_threaded: std.Io.Threaded = .init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pdftotext", "-layout", path, "-" },
    }) catch return null;
    defer allocator.free(result.stderr);

    if (result.term != .exited) {
        allocator.free(result.stdout);
        return null;
    }

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

fn tryMutool(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var io_threaded: std.Io.Threaded = .init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "mutool", "draw", "-F", "text", path },
    }) catch return null;
    defer allocator.free(result.stderr);

    if (result.term != .exited) {
        allocator.free(result.stdout);
        return null;
    }

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

fn countFormFeeds(text: []const u8) u32 {
    var count: u32 = 1; // At least 1 page
    for (text) |c| {
        if (c == '\x0C') count += 1; // Form feed = page break
    }
    return count;
}

/// Convert extracted PDF text to markdown format
/// Detects headers (ALL CAPS lines), bullet points, and preserves structure
pub fn textToMarkdown(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var prev_blank = true;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip form feeds
        if (trimmed.len == 1 and trimmed[0] == '\x0C') {
            try buf.appendSlice(allocator, "\n---\n\n"); // Page break
            prev_blank = true;
            continue;
        }

        // Empty line
        if (trimmed.len == 0) {
            if (!prev_blank) {
                try buf.append(allocator, '\n');
                prev_blank = true;
            }
            continue;
        }

        // Detect ALL CAPS headers (common in PDFs)
        if (trimmed.len >= 3 and trimmed.len <= 100 and isAllCaps(trimmed)) {
            if (!prev_blank) try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, "## ");
            try buf.appendSlice(allocator, trimmed);
            try buf.appendSlice(allocator, "\n\n");
            prev_blank = true;
            continue;
        }

        // Regular text
        try buf.appendSlice(allocator, trimmed);
        try buf.append(allocator, '\n');
        prev_blank = false;
    }

    return buf.toOwnedSlice(allocator);
}

fn isAllCaps(text: []const u8) bool {
    var has_letter = false;
    for (text) |c| {
        if (c >= 'a' and c <= 'z') return false;
        if (c >= 'A' and c <= 'Z') has_letter = true;
    }
    return has_letter;
}
