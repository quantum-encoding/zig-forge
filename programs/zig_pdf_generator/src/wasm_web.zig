//! Freestanding browser WASM entry point (no WASI, no libc).
//!
//! `src/wasm.zig` is the full edge/WASI build — it pulls in the PDF *extractor*
//! and `share_certificate`'s path-based image loading, both of which reference
//! `std.Io.Threaded` (posix `getrandom`/`IOV_MAX`) and therefore do NOT compile
//! for `wasm32-freestanding`. This root exports only the **pure, browser-safe
//! generators** — the ones that take JSON in and bytes out, decoding any images
//! from inline base64 (never the filesystem). The module imports nothing from
//! the host, so the page instantiates it with an empty import object (no WASI
//! shim needed).
//!
//! Built by `zig build wasm-web` → `zig-out/lib/zigpdf_web.wasm`.
//!
//! ABI (same as wasm.zig):
//!   ptr = wasm_alloc(json_len)                       // write UTF-8 JSON here
//!   lenPtr = wasm_alloc(4)
//!   pdfPtr = zigpdf_generate_presentation(ptr, json_len, lenPtr)
//!   pdfLen = DataView(memory.buffer).getUint32(lenPtr, true)
//!   bytes  = Uint8Array(memory.buffer, pdfPtr, pdfLen).slice()
//!   zigpdf_free(ptr, json_len); zigpdf_free(pdfPtr, pdfLen); zigpdf_free(lenPtr, 4)
//! On failure the generate fns return 0; read zigpdf_get_error() for the reason.

const std = @import("std");

const invoice = @import("invoice.zig");
const json_parser = @import("json.zig");
const presentation = @import("presentation.zig");
const proposal = @import("proposal.zig");
const clean_quote = @import("clean_quote.zig");
const letter = @import("letter.zig");
const order_email = @import("order_email.zig");
const crg_solar_report = @import("crg_solar_report.zig");
const website_health_report = @import("website_health_report.zig");

const wasm_allocator = std.heap.wasm_allocator;

// ---- memory management -----------------------------------------------------

export fn wasm_alloc(size: usize) usize {
    const slice = wasm_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

export fn wasm_free(ptr: usize, size: usize) void {
    if (ptr == 0) return;
    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    wasm_allocator.free(slice_ptr[0..size]);
}

export fn zigpdf_free(ptr: usize, size: usize) void {
    wasm_free(ptr, size);
}

// ---- error / version -------------------------------------------------------

var last_error: [256]u8 = [_]u8{0} ** 256;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..copy_len], msg[0..copy_len]);
    last_error[copy_len] = 0;
}

export fn zigpdf_get_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

export fn zigpdf_version() [*:0]const u8 {
    return "1.0.0-wasm-web";
}

// ---- generators ------------------------------------------------------------

fn validateUtf8(json_slice: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return false;
    }
    return true;
}

/// Canvas / presentation renderer — the CRG solar proposal target.
export fn zigpdf_generate_presentation(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = presentation.generatePresentationFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Presentation error: {s}", .{@errorName(err)}) catch "Presentation error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// CRG Solar Proposal — 20-page report from a small CrgQuote JSON (the ~28
/// per-lead fields; missing fields fall back to the sample defaults). Brand
/// assets are embedded, so no images need to be supplied.
export fn zigpdf_generate_crg_solar_report(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = crg_solar_report.generateCrgSolarReportFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "CRG report error: {s}", .{@errorName(err)}) catch "CRG report error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Website Health & Compliance Audit — baton-audit SiteHealthReport JSON in,
/// paginating branded PDF out (QE assets embedded).
export fn zigpdf_generate_health_report(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = website_health_report.generateWebsiteHealthReportFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Health report error: {s}", .{@errorName(err)}) catch "Health report error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Standard invoice / quote.
export fn zigpdf_generate_invoice(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const data = json_parser.parseInvoiceJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const detail = json_parser.describeInvoiceError(err) orelse @errorName(err);
        setLastError(std.fmt.bufPrint(&buf, "JSON parse error: {s}", .{detail}) catch "JSON parse error");
        return null;
    };
    defer json_parser.freeInvoiceData(wasm_allocator, &data);
    const pdf_bytes = invoice.generateInvoice(wasm_allocator, data) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "PDF generation error: {s}", .{@errorName(err)}) catch "PDF generation error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Branded pitch-deck proposal (legacy) — shares the clean_quote schema.
export fn zigpdf_generate_proposal(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = proposal.generateProposalFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Proposal error: {s}", .{@errorName(err)}) catch "Proposal error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Minimalist clean-quote (QUOTE/INVOICE/HANDOVER/INSPECTION by ref prefix).
export fn zigpdf_generate_clean_quote(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = clean_quote.generateCleanQuoteFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Clean quote error: {s}", .{@errorName(err)}) catch "Clean quote error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Flowing markdown letter (no encryption; open-text only in the browser build).
export fn zigpdf_generate_letter(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const pdf_bytes = letter.generateLetterFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Letter error: {s}", .{@errorName(err)}) catch "Letter error");
        return null;
    };
    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Stripe order-confirmation email (returns the HTML/text envelope bytes).
export fn zigpdf_generate_order_email(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];
    if (!validateUtf8(json_slice)) return null;
    const envelope = order_email.generateFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        setLastError(std.fmt.bufPrint(&buf, "Order email error: {s}", .{@errorName(err)}) catch "Order email error");
        return null;
    };
    output_len.* = envelope.len;
    return @ptrCast(@constCast(envelope.ptr));
}
