//! WebAssembly (WASM) Entry Point for Edge Deployment
//!
//! This module provides WASM-specific exports for running the PDF generator
//! in edge environments like Cloudflare Workers, Deno, Node.js, or browsers.
//!
//! Memory Model:
//! - WASM linear memory is used for all allocations
//! - JavaScript allocates input buffers using wasm_alloc()
//! - JavaScript must free output buffers using wasm_free()
//!
//! Usage from JavaScript:
//! ```javascript
//! const wasm = await WebAssembly.instantiate(wasmBytes);
//! const { wasm_alloc, wasm_free, zigpdf_generate_invoice, memory } = wasm.instance.exports;
//!
//! // Allocate and write JSON input
//! const json = JSON.stringify(invoiceData);
//! const encoder = new TextEncoder();
//! const jsonBytes = encoder.encode(json);
//! const inputPtr = wasm_alloc(jsonBytes.length + 1);
//! new Uint8Array(memory.buffer, inputPtr, jsonBytes.length).set(jsonBytes);
//! new Uint8Array(memory.buffer)[inputPtr + jsonBytes.length] = 0; // null terminate
//!
//! // Allocate space for output length
//! const lenPtr = wasm_alloc(4);
//!
//! // Generate PDF
//! const pdfPtr = zigpdf_generate_invoice(inputPtr, lenPtr);
//! wasm_free(inputPtr, jsonBytes.length + 1);
//!
//! if (pdfPtr) {
//!     const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
//!     const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();
//!     wasm_free(pdfPtr, pdfLen);
//!     wasm_free(lenPtr, 4);
//!     return pdfBytes;
//! }
//! wasm_free(lenPtr, 4);
//! return null;
//! ```

const std = @import("std");

// Import PDF generation modules directly (bypassing ffi.zig file I/O)
const invoice = @import("invoice.zig");
const json_parser = @import("json.zig");
// Note: crypto_receipt doesn't have generateFromJson, needs manual JSON parsing
// const crypto_receipt = @import("crypto_receipt.zig");
const contract = @import("contract.zig");
const share_certificate = @import("share_certificate.zig");
const dividend_voucher = @import("dividend_voucher.zig");
const stock_transfer = @import("stock_transfer.zig");
const board_resolution = @import("board_resolution.zig");
const director_consent = @import("director_consent.zig");
const director_appointment = @import("director_appointment.zig");
const director_resignation = @import("director_resignation.zig");
const written_resolution = @import("written_resolution.zig");
const presentation = @import("presentation.zig");
const qrcode = @import("qrcode.zig");
const proposal = @import("proposal.zig");
const clean_quote = @import("clean_quote.zig");
const letter_quote = @import("letter_quote.zig");
const template_card = @import("template_card.zig");

// =============================================================================
// WASM Allocator
// =============================================================================

const wasm_allocator = std.heap.wasm_allocator;

// =============================================================================
// Memory Management Exports
// =============================================================================

/// Allocate memory in WASM linear memory
/// Returns pointer to allocated memory, or 0 on failure
export fn wasm_alloc(size: usize) usize {
    const slice = wasm_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// Free memory allocated by wasm_alloc or PDF generation functions
export fn wasm_free(ptr: usize, size: usize) void {
    if (ptr == 0) return;
    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    wasm_allocator.free(slice_ptr[0..size]);
}

// =============================================================================
// Error Handling
// =============================================================================

var last_error: [256]u8 = undefined;
var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..copy_len], msg[0..copy_len]);
    last_error[copy_len] = 0;
    last_error_len = copy_len;
}

/// Get the last error message (null-terminated)
export fn zigpdf_get_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

/// Get version string
export fn zigpdf_version() [*:0]const u8 {
    return "1.0.0-wasm";
}

// =============================================================================
// PDF Generation Functions
// =============================================================================

/// Generate an invoice PDF from JSON input
export fn zigpdf_generate_invoice(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const data = json_parser.parseInvoiceJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "JSON parse error: {s}", .{@errorName(err)}) catch "JSON parse error";
        setLastError(msg);
        return null;
    };
    defer json_parser.freeInvoiceData(wasm_allocator, &data);

    const pdf_bytes = invoice.generateInvoice(wasm_allocator, data) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "PDF generation error: {s}", .{@errorName(err)}) catch "PDF generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

// Note: zigpdf_generate_crypto_receipt requires manual JSON parsing
// Not available in WASM build - use native FFI for crypto receipts

/// Generate a contract PDF from JSON input
export fn zigpdf_generate_contract(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = contract.generateContractFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Contract error: {s}", .{@errorName(err)}) catch "Contract error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a share certificate PDF from JSON input
export fn zigpdf_generate_share_certificate(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = share_certificate.generateShareCertificateFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Share certificate error: {s}", .{@errorName(err)}) catch "Share certificate error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a dividend voucher PDF from JSON input
export fn zigpdf_generate_dividend_voucher(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = dividend_voucher.generateDividendVoucherFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Dividend voucher error: {s}", .{@errorName(err)}) catch "Dividend voucher error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a stock transfer form PDF from JSON input
export fn zigpdf_generate_stock_transfer(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = stock_transfer.generateStockTransferFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Stock transfer error: {s}", .{@errorName(err)}) catch "Stock transfer error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a board resolution PDF from JSON input
export fn zigpdf_generate_board_resolution(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = board_resolution.generateBoardResolutionFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Board resolution error: {s}", .{@errorName(err)}) catch "Board resolution error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a director consent PDF from JSON input
export fn zigpdf_generate_director_consent(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_consent.generateDirectorConsentFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director consent error: {s}", .{@errorName(err)}) catch "Director consent error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a director appointment PDF from JSON input
export fn zigpdf_generate_director_appointment(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_appointment.generateDirectorAppointmentFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director appointment error: {s}", .{@errorName(err)}) catch "Director appointment error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a director resignation PDF from JSON input
export fn zigpdf_generate_director_resignation(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_resignation.generateDirectorResignationFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director resignation error: {s}", .{@errorName(err)}) catch "Director resignation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a written resolution PDF from JSON input
export fn zigpdf_generate_written_resolution(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = written_resolution.generateWrittenResolutionFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Written resolution error: {s}", .{@errorName(err)}) catch "Written resolution error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a presentation/canvas PDF from JSON input
export fn zigpdf_generate_presentation(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = presentation.generatePresentationFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Presentation error: {s}", .{@errorName(err)}) catch "Presentation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a branded proposal PDF from JSON input
export fn zigpdf_generate_proposal(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = proposal.generateProposalFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Proposal error: {s}", .{@errorName(err)}) catch "Proposal error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a minimalist clean-quote PDF from JSON input. Shared schema
/// with zigpdf_generate_proposal — document type (QUOTE / INVOICE /
/// HANDOVER / INSPECTION) is derived from the reference prefix
/// (QTE / INV / HND / INS). QR code auto-renders on the last page when
/// footer.dashboard_url is set.
export fn zigpdf_generate_clean_quote(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = clean_quote.generateCleanQuoteFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Clean quote error: {s}", .{@errorName(err)}) catch "Clean quote error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a premium letter-style quote PDF from JSON input.
/// Centred hero title, gold hairline separators, letter-spaced labels, and a
/// multi-page flow (description letter + itemised estimate). See
/// src/letter_quote.zig for the JSON contract.
export fn zigpdf_generate_letter_quote(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = letter_quote.generateLetterQuoteFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Letter quote error: {s}", .{@errorName(err)}) catch "Letter quote error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a template card PDF from JSON input
export fn zigpdf_generate_template_card(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = template_card.generateTemplateCardFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Template card error: {s}", .{@errorName(err)}) catch "Template card error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate a QR code as SVG string from data
export fn zigpdf_generate_qrcode_svg(data_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const data_slice = std.mem.span(data_input);

    var svg = qrcode.encodeAndRenderSvg(wasm_allocator, data_slice, .{ .ec_level = .M }, .{}) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "QR SVG error: {s}", .{@errorName(err)}) catch "QR SVG error";
        setLastError(msg);
        return null;
    };

    output_len.* = svg.data.len;
    const ptr = svg.data.ptr;
    svg.data = &.{};
    return ptr;
}

// =============================================================================
// WASM Memory Info
// =============================================================================

/// Get current WASM memory size in pages (64KB each)
export fn wasm_memory_size() usize {
    return @wasmMemorySize(0);
}

/// Grow WASM memory by specified number of pages
/// Returns previous size in pages, or -1 on failure
export fn wasm_memory_grow(pages: usize) isize {
    return @wasmMemoryGrow(0, pages);
}
