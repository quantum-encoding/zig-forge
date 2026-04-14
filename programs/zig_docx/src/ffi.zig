// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! C FFI for zig-docx — embed document conversion in any language.
//!
//! All exported functions use C calling convention and C-compatible types.
//! Memory returned by zig_docx_* functions must be freed with zig_docx_free().
//!
//! Thread safety: each call is independent — no global state. Multiple
//! threads can call concurrently with separate inputs.
//!
//! Usage from Swift:
//!   let result = zig_docx_md_to_docx(mdPtr, mdLen, &opts)
//!   if result.data != nil { /* use result.data[0..<result.len] */ }
//!   zig_docx_free(result.data, result.len)

const std = @import("std");
const docx = @import("docx.zig");

// ─── Types ─────────────────────────────────────────────────────────

/// Result of a conversion: pointer + length to owned bytes, or null on error.
pub const ZigDocxResult = extern struct {
    data: ?[*]u8,
    len: usize,
    error_msg: ?[*:0]const u8,
};

/// Options for MD → DOCX conversion.
pub const ZigDocxOptions = extern struct {
    title: ?[*:0]const u8 = null,
    author: ?[*:0]const u8 = null,
    date: ?[*:0]const u8 = null,
    description: ?[*:0]const u8 = null,
    /// Letterhead image data (embedded, not a path). Null = no letterhead.
    letterhead_data: ?[*]const u8 = null,
    letterhead_len: usize = 0,
    /// Image extension for letterhead (e.g. "png", "jpg"). Null defaults to "png".
    letterhead_ext: ?[*:0]const u8 = null,
};

/// Document info extracted from a DOCX file.
pub const ZigDocxInfo = extern struct {
    title: ?[*:0]u8 = null,
    author: ?[*:0]u8 = null,
    word_count: u32 = 0,
    paragraph_count: u32 = 0,
    image_count: u16 = 0,
    has_tables: bool = false,
};

// ─── Allocator ─────────────────────────────────────────────────────

const allocator = std.heap.c_allocator;

// ─── Helpers ───────────────────────────────────────────────────────

fn sliceFromPtr(ptr: ?[*]const u8, len: usize) []const u8 {
    if (ptr) |p| return p[0..len];
    return "";
}

fn sliceFromSentinel(ptr: ?[*:0]const u8) []const u8 {
    if (ptr) |p| return std.mem.span(p);
    return "";
}

fn dupeToSentinel(src: []const u8) ?[*:0]u8 {
    const buf = allocator.allocSentinel(u8, src.len, 0) catch return null;
    @memcpy(buf[0..src.len], src);
    return buf.ptr;
}

fn makeError(msg: []const u8) ZigDocxResult {
    return .{
        .data = null,
        .len = 0,
        .error_msg = dupeToSentinel(msg),
    };
}

// ─── Symbol Exports ────────────────────────────────────────────────

comptime {
    @export(&zig_docx_md_to_docx, .{ .name = "zig_docx_md_to_docx" });
    @export(&zig_docx_to_markdown, .{ .name = "zig_docx_to_markdown" });
    @export(&zig_docx_fra_from_json, .{ .name = "zig_docx_fra_from_json" });
    @export(&zig_docx_info, .{ .name = "zig_docx_info" });
    @export(&zig_docx_free, .{ .name = "zig_docx_free" });
    @export(&zig_docx_free_string, .{ .name = "zig_docx_free_string" });
    @export(&zig_docx_free_info, .{ .name = "zig_docx_free_info" });
    @export(&zig_docx_version, .{ .name = "zig_docx_version" });
}

// ─── Core Functions ────────────────────────────────────────────────

fn zig_docx_md_to_docx(
    md_ptr: [*]const u8,
    md_len: usize,
    opts: ?*const ZigDocxOptions,
) callconv(.c) ZigDocxResult {
    const md_text = md_ptr[0..md_len];

    var result = docx.md_parser.parseMarkdown(allocator, md_text) catch {
        return makeError("Failed to parse markdown");
    };
    defer result.deinit();

    // Build writer options from FFI options
    var writer_opts = docx.docx_writer.DocxWriterOptions{};
    var letterhead: ?docx.docx_writer.LetterheadImage = null;

    if (opts) |o| {
        if (result.frontmatter.title) |t| {
            writer_opts.title = t;
        } else {
            writer_opts.title = sliceFromSentinel(o.title);
        }
        if (result.frontmatter.author) |a| {
            writer_opts.author = a;
        } else {
            writer_opts.author = sliceFromSentinel(o.author);
        }
        if (result.frontmatter.date) |d| {
            writer_opts.date = d;
        } else {
            writer_opts.date = sliceFromSentinel(o.date);
        }
        if (result.frontmatter.description) |d| {
            writer_opts.description = d;
        } else {
            writer_opts.description = sliceFromSentinel(o.description);
        }
        if (o.letterhead_data) |lh_data| {
            if (o.letterhead_len > 0) {
                letterhead = .{
                    .data = lh_data[0..o.letterhead_len],
                    .extension = sliceFromSentinel(o.letterhead_ext),
                };
                if (letterhead.?.extension.len == 0) letterhead.?.extension = "png";
            }
        }
    } else {
        // Use frontmatter values
        writer_opts.title = result.frontmatter.title orelse "";
        writer_opts.author = result.frontmatter.author orelse "";
        writer_opts.date = result.frontmatter.date orelse "";
        writer_opts.description = result.frontmatter.description orelse "";
    }
    writer_opts.letterhead = letterhead;

    const docx_bytes = docx.docx_writer.generateDocx(
        allocator,
        &result.document,
        writer_opts,
    ) catch {
        return makeError("Failed to generate DOCX");
    };

    return .{
        .data = docx_bytes.ptr,
        .len = docx_bytes.len,
        .error_msg = null,
    };
}

/// Generate a Fire Risk Assessment DOCX from JSON input.
fn zig_docx_fra_from_json(
    json_ptr: [*]const u8,
    json_len: usize,
) callconv(.c) ZigDocxResult {
    const json_str = json_ptr[0..json_len];

    var fra_data = docx.fra.parseFraJson(allocator, json_str) catch {
        return makeError("Failed to parse FRA JSON");
    };
    _ = &fra_data;

    const docx_bytes = docx.fra.generateFra(allocator, &fra_data) catch {
        return makeError("Failed to generate FRA document");
    };

    return .{
        .data = docx_bytes.ptr,
        .len = docx_bytes.len,
        .error_msg = null,
    };
}

/// Convert a DOCX file (in memory) to markdown text.
///
/// Returns a ZigDocxResult with UTF-8 markdown bytes.
fn zig_docx_to_markdown(
    docx_ptr: [*]const u8,
    docx_len: usize,
) callconv(.c) ZigDocxResult {
    // Dupe input — ZipArchive.close() frees the data buffer
    const docx_data = allocator.dupe(u8, docx_ptr[0..docx_len]) catch {
        return makeError("Out of memory");
    };

    var archive = docx.zip.ZipArchive.openFromMemory(allocator, docx_data) catch {
        allocator.free(docx_data);
        return makeError("Failed to open DOCX archive");
    };
    defer archive.close();

    var document = docx.parseDocument(allocator, &archive) catch {
        return makeError("Failed to parse DOCX content");
    };
    defer document.deinit();

    const mdx_result = docx.mdx.generateMdx(allocator, &document, .{}) catch {
        return makeError("Failed to generate markdown");
    };
    defer {
        // Free images but keep mdx bytes (we're transferring ownership)
        for (mdx_result.images) |img| {
            allocator.free(img.filename);
        }
        allocator.free(mdx_result.images);
    }

    return .{
        .data = mdx_result.mdx.ptr,
        .len = mdx_result.mdx.len,
        .error_msg = null,
    };
}

/// Get document info from a DOCX file without full conversion.
fn zig_docx_info(
    docx_ptr: [*]const u8,
    docx_len: usize,
) callconv(.c) ZigDocxInfo {
    // Dupe input — ZipArchive.close() frees the data buffer
    const docx_data = allocator.dupe(u8, docx_ptr[0..docx_len]) catch {
        return .{};
    };

    var archive = docx.zip.ZipArchive.openFromMemory(allocator, docx_data) catch {
        allocator.free(docx_data);
        return .{};
    };
    defer archive.close();

    var document = docx.parseDocument(allocator, &archive) catch {
        return .{};
    };
    defer document.deinit();

    var info = ZigDocxInfo{};
    var word_count: u32 = 0;
    var para_count: u32 = 0;

    for (document.elements) |elem| {
        switch (elem) {
            .paragraph => |p| {
                para_count += 1;
                for (p.runs) |run| {
                    // Count words in run text
                    var in_word = false;
                    for (run.text) |c| {
                        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                            if (in_word) word_count += 1;
                            in_word = false;
                        } else {
                            in_word = true;
                        }
                    }
                    if (in_word) word_count += 1;
                }
                // Check for title in first heading
                if (info.title == null and (p.style == .heading1 or p.style == .title)) {
                    if (p.runs.len > 0) {
                        info.title = dupeToSentinel(p.runs[0].text);
                    }
                }
            },
            .table => {
                info.has_tables = true;
            },
        }
    }

    info.word_count = word_count;
    info.paragraph_count = para_count;
    info.image_count = @intCast(document.media.len);

    return info;
}

/// Free memory returned by zig_docx_* functions.
fn zig_docx_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| {
        if (len > 0) {
            allocator.free(p[0..len]);
        }
    }
}

/// Free a sentinel-terminated string returned by zig_docx_* functions.
fn zig_docx_free_string(ptr: ?[*:0]u8) callconv(.c) void {
    if (ptr) |p| {
        const s = std.mem.span(p);
        allocator.free(s[0 .. s.len + 1]); // include sentinel
    }
}

/// Free a ZigDocxInfo struct's owned strings.
fn zig_docx_free_info(info: *ZigDocxInfo) callconv(.c) void {
    if (info.title) |t| zig_docx_free_string(t);
    if (info.author) |a| zig_docx_free_string(a);
    info.* = .{};
}

/// Returns the library version as a null-terminated string.
fn zig_docx_version() callconv(.c) [*:0]const u8 {
    return "1.1.0";
}
