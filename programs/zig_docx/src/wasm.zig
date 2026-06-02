// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Freestanding WebAssembly entry point for browser / edge embedding.
//!
//! Unlike the wasm32-wasi reactor library (build step `wasm`, root
//! src/ffi.zig), this module targets wasm32-freestanding and imports
//! NOTHING from the host — no WASI, no libc. It can be instantiated with
//! an empty import object straight from `WebAssembly.instantiate`, which
//! is what the website's Next.js loader does. The ABI mirrors
//! zig_pdf_generator's wasm.zig: a `wasm_alloc` bump for input, a single
//! pointer return plus an out-length, and an error string accessor.
//!
//! Scope: the Fire Risk Assessment generator (JSON in → DOCX bytes out).
//! Photo-evidence images that reference files on disk are skipped here —
//! there is no filesystem (see can_read_image_files in fra.zig).
//!
//! JavaScript usage:
//! ```javascript
//! const { instance } = await WebAssembly.instantiate(wasmBytes, {});
//! const { wasm_alloc, wasm_free, zigdocx_generate_fra, memory } = instance.exports;
//!
//! const json = new TextEncoder().encode(JSON.stringify(fraData));
//! const inPtr = wasm_alloc(json.length);
//! new Uint8Array(memory.buffer, inPtr, json.length).set(json);
//!
//! const lenPtr = wasm_alloc(4);
//! const docxPtr = zigdocx_generate_fra(inPtr, json.length, lenPtr);
//! wasm_free(inPtr, json.length);
//!
//! if (docxPtr) {
//!   const len = new DataView(memory.buffer).getUint32(lenPtr, true);
//!   const docx = new Uint8Array(memory.buffer, docxPtr, len).slice();
//!   wasm_free(docxPtr, len);
//!   wasm_free(lenPtr, 4);
//!   // docx is a complete .docx (zip) ready to download
//! }
//! ```

const std = @import("std");
const fra = @import("fra.zig");
const docx = @import("docx.zig");

const wasm_allocator = std.heap.wasm_allocator;

// ─── Memory management ─────────────────────────────────────────────

/// Allocate `size` bytes in WASM linear memory. Returns 0 on failure.
export fn wasm_alloc(size: usize) usize {
    if (size == 0) return 0;
    const slice = wasm_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// Free memory returned by wasm_alloc or a generate function. `size` must
/// be the SAME length used at allocation / returned via the out-length.
export fn wasm_free(ptr: usize, size: usize) void {
    if (ptr == 0 or size == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    wasm_allocator.free(p[0..size]);
}

/// Backwards-compatible alias matching the zig_pdf_generator surface.
export fn zigdocx_free(ptr: usize, size: usize) void {
    wasm_free(ptr, size);
}

// ─── Error reporting ───────────────────────────────────────────────

var last_error: [256]u8 = undefined;
var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const n = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..n], msg[0..n]);
    last_error[n] = 0;
    last_error_len = n;
}

/// Null-terminated message describing the most recent failure.
export fn zigdocx_get_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

/// Module version string.
export fn zigdocx_version() [*:0]const u8 {
    return "1.0.0-wasm";
}

// ─── Fire Risk Assessment ──────────────────────────────────────────

/// Generate a Fire Risk Assessment DOCX from JSON.
///
/// Returns a pointer to the DOCX bytes (owned by the module; free with
/// wasm_free(ptr, *output_len)) and writes the byte length into
/// `output_len`. Returns null on error — call zigdocx_get_error() for why.
export fn zigdocx_generate_fra(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    output_len.* = 0;
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    // One arena per call: every allocation made while parsing the JSON and
    // building the document is reclaimed on deinit. Only the final DOCX is
    // copied into the module allocator so it outlives the arena.
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fra_data = fra.parseFraJson(a, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FRA JSON parse error: {s}", .{@errorName(err)}) catch "FRA JSON parse error";
        setLastError(msg);
        return null;
    };

    const docx_bytes = fra.generateFra(a, &fra_data) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FRA generation error: {s}", .{@errorName(err)}) catch "FRA generation error";
        setLastError(msg);
        return null;
    };

    const out = wasm_allocator.alloc(u8, docx_bytes.len) catch {
        setLastError("Out of memory copying DOCX output");
        return null;
    };
    @memcpy(out, docx_bytes);

    output_len.* = out.len;
    return out.ptr;
}

// ─── Markdown → DOCX ───────────────────────────────────────────────

/// Render a structured DOCX from Markdown (with optional YAML frontmatter for
/// title/author/date). Same ownership contract as zigdocx_generate_fra.
/// Disk-backed images / letterhead in the frontmatter are skipped (no fs).
export fn zigdocx_md_to_docx(md_ptr: [*]const u8, md_len: usize, output_len: *usize) ?[*]u8 {
    output_len.* = 0;
    const md_slice = md_ptr[0..md_len];

    if (!std.unicode.utf8ValidateSlice(md_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = docx.md_parser.parseMarkdown(a, md_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Markdown parse error: {s}", .{@errorName(err)}) catch "Markdown parse error");
        return null;
    };

    const options = docx.docx_writer.DocxWriterOptions{
        .title = result.frontmatter.title orelse "",
        .author = result.frontmatter.author orelse "",
        .description = result.frontmatter.description orelse "",
        .date = result.frontmatter.date orelse "",
    };

    const docx_bytes = docx.docx_writer.generateDocx(a, &result.document, options) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "DOCX generation error: {s}", .{@errorName(err)}) catch "DOCX generation error");
        return null;
    };

    const out = wasm_allocator.alloc(u8, docx_bytes.len) catch {
        setLastError("Out of memory copying DOCX output");
        return null;
    };
    @memcpy(out, docx_bytes);
    output_len.* = out.len;
    return out.ptr;
}

// ─── DOCX → Markdown ───────────────────────────────────────────────

/// Convert a .docx (zip bytes) to Markdown. Returns Markdown text bytes
/// (same ownership contract). Images are referenced by name but not extracted
/// (no filesystem in the browser build).
export fn zigdocx_docx_to_md(docx_ptr: [*]const u8, docx_len: usize, output_len: *usize) ?[*]u8 {
    output_len.* = 0;
    const data = docx_ptr[0..docx_len];

    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var archive = docx.zip.ZipArchive.openFromMemory(a, data) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Not a valid .docx file: {s}", .{@errorName(err)}) catch "Invalid .docx");
        return null;
    };

    const doc = docx.parseDocument(a, &archive) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "DOCX parse error: {s}", .{@errorName(err)}) catch "DOCX parse error");
        return null;
    };

    const result = docx.mdx.generateMdx(a, &doc, .{}) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Markdown conversion error: {s}", .{@errorName(err)}) catch "conversion error");
        return null;
    };

    const out = wasm_allocator.alloc(u8, result.mdx.len) catch {
        setLastError("Out of memory copying Markdown output");
        return null;
    };
    @memcpy(out, result.mdx);
    output_len.* = out.len;
    return out.ptr;
}

// ─── Memory info ───────────────────────────────────────────────────

export fn wasm_memory_size() usize {
    return @wasmMemorySize(0);
}

export fn wasm_memory_grow(pages: usize) isize {
    return @wasmMemoryGrow(0, pages);
}
