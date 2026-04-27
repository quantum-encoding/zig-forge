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

/// One embedded image extracted from a DOCX. `filename` matches the
/// reference written into the markdown (e.g. "1-image1.png" appears in
/// the MDX as `./images/1-image1.png` — host writes the file under that
/// name). `data` may be null if the markdown referenced an image whose
/// bytes weren't present in the archive — in that case the embedder
/// should skip writing the file but keep the markdown reference.
pub const ZigDocxImage = extern struct {
    filename: ?[*:0]u8,
    data: ?[*]u8,
    len: usize,
};

/// Result of zig_docx_to_markdown_with_images: MDX text plus the embedded
/// images keyed by the filenames the markdown references. Free with
/// zig_docx_free_markdown_result.
pub const ZigDocxMarkdownResult = extern struct {
    mdx_data: ?[*]u8,
    mdx_len: usize,
    images: ?[*]ZigDocxImage,
    images_count: usize,
    error_msg: ?[*:0]const u8,
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
    @export(&zig_docx_to_markdown_with_images, .{ .name = "zig_docx_to_markdown_with_images" });
    @export(&zig_docx_fra_from_json, .{ .name = "zig_docx_fra_from_json" });
    @export(&zig_docx_info, .{ .name = "zig_docx_info" });
    @export(&zig_docx_alloc, .{ .name = "zig_docx_alloc" });
    @export(&zig_docx_free, .{ .name = "zig_docx_free" });
    @export(&zig_docx_free_string, .{ .name = "zig_docx_free_string" });
    @export(&zig_docx_free_info, .{ .name = "zig_docx_free_info" });
    @export(&zig_docx_free_markdown_result, .{ .name = "zig_docx_free_markdown_result" });
    @export(&zig_docx_version, .{ .name = "zig_docx_version" });
}

// ─── Memory ────────────────────────────────────────────────────────

/// Allocate `len` bytes inside the library's allocator. Returns the
/// pointer or null on OOM / zero length.
///
/// Intended primarily for WASM hosts: the JS embedder calls this to
/// reserve space inside the module's linear memory, copies input bytes
/// into that region, then passes (ptr, len) to one of the conversion
/// functions. After the call returns, free with zig_docx_free(ptr, len)
/// passing the SAME length used at allocation.
///
/// Native callers can use this too, but typically don't need to —
/// the conversion functions take any caller-owned buffer.
fn zig_docx_alloc(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
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

/// Convert a DOCX to markdown AND surface the embedded images. Each
/// image's `filename` matches a `./images/<filename>` reference in the
/// emitted MDX, so the embedder can write the bytes to that path and
/// the markdown links resolve. Free with zig_docx_free_markdown_result.
///
/// Use this instead of zig_docx_to_markdown when you need the images
/// (e.g. uploading a Word doc with embedded photos to a static-site
/// pipeline). zig_docx_to_markdown drops the images on the floor.
fn zig_docx_to_markdown_with_images(
    docx_ptr: [*]const u8,
    docx_len: usize,
) callconv(.c) ZigDocxMarkdownResult {
    const make_err = struct {
        fn f(msg: []const u8) ZigDocxMarkdownResult {
            return .{
                .mdx_data = null,
                .mdx_len = 0,
                .images = null,
                .images_count = 0,
                .error_msg = dupeToSentinel(msg),
            };
        }
    }.f;

    const docx_data = allocator.dupe(u8, docx_ptr[0..docx_len]) catch return make_err("Out of memory");

    var archive = docx.zip.ZipArchive.openFromMemory(allocator, docx_data) catch {
        allocator.free(docx_data);
        return make_err("Failed to open DOCX archive");
    };
    defer archive.close();

    var document = docx.parseDocument(allocator, &archive) catch return make_err("Failed to parse DOCX content");
    defer document.deinit();

    const mdx_result = docx.mdx.generateMdx(allocator, &document, .{}) catch return make_err("Failed to generate markdown");
    // mdx_result holds the mdx bytes + a slice of ImageRef. We transfer
    // the mdx bytes to the caller and rebuild the image array as owned
    // {filename: cstring, data: bytes} pairs before document.deinit()
    // frees document.media bytes.
    var transferred = false;
    defer if (!transferred) {
        allocator.free(mdx_result.mdx);
        for (mdx_result.images) |img| allocator.free(img.filename);
        allocator.free(mdx_result.images);
    };

    const out_images = allocator.alloc(ZigDocxImage, mdx_result.images.len) catch return make_err("Out of memory");
    var built: usize = 0;
    errdefer {
        for (out_images[0..built]) |img| {
            if (img.filename) |fp| {
                const s = std.mem.span(fp);
                allocator.free(s[0 .. s.len + 1]);
            }
            if (img.data) |dp| if (img.len > 0) allocator.free(dp[0..img.len]);
        }
        allocator.free(out_images);
    }

    for (mdx_result.images) |img_ref| {
        // Look up the image bytes in document.media via media_name. The
        // markdown reference uses img_ref.filename ("1-image1.png"), but
        // the bytes are keyed by the original DOCX path ("media/image1.png").
        var bytes: ?[]const u8 = null;
        for (document.media) |m| {
            if (std.mem.eql(u8, m.name, img_ref.media_name)) {
                bytes = m.data;
                break;
            }
        }

        const filename_z = dupeToSentinel(img_ref.filename) orelse return make_err("Out of memory");
        var data_owned: ?[]u8 = null;
        if (bytes) |b| {
            data_owned = allocator.dupe(u8, b) catch {
                const s = std.mem.span(filename_z);
                allocator.free(s[0 .. s.len + 1]);
                return make_err("Out of memory");
            };
        }

        out_images[built] = .{
            .filename = filename_z,
            .data = if (data_owned) |d| d.ptr else null,
            .len = if (data_owned) |d| d.len else 0,
        };
        built += 1;
    }

    transferred = true;
    // Reclaim the mdx_result image refs now that we've extracted what we need.
    for (mdx_result.images) |img| allocator.free(img.filename);
    allocator.free(mdx_result.images);

    return .{
        .mdx_data = mdx_result.mdx.ptr,
        .mdx_len = mdx_result.mdx.len,
        .images = out_images.ptr,
        .images_count = built,
        .error_msg = null,
    };
}

/// Free a ZigDocxMarkdownResult: the MDX bytes, every image's filename
/// and data, the images array itself, and any error_msg. Resets all
/// fields to null so a double-call is a no-op.
fn zig_docx_free_markdown_result(result: *ZigDocxMarkdownResult) callconv(.c) void {
    if (result.mdx_data) |p| {
        if (result.mdx_len > 0) allocator.free(p[0..result.mdx_len]);
    }
    if (result.images) |imgs_ptr| {
        const imgs = imgs_ptr[0..result.images_count];
        for (imgs) |img| {
            if (img.filename) |fp| {
                const s = std.mem.span(fp);
                allocator.free(s[0 .. s.len + 1]);
            }
            if (img.data) |dp| {
                if (img.len > 0) allocator.free(dp[0..img.len]);
            }
        }
        allocator.free(imgs);
    }
    if (result.error_msg) |e| zig_docx_free_string(@constCast(e));
    result.* = .{
        .mdx_data = null,
        .mdx_len = 0,
        .images = null,
        .images_count = 0,
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
