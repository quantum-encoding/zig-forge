//! WebAssembly (WASM) Entry Point for Edge Deployment
//!
//! This module provides WASM-specific exports for running the PDF generator
//! in edge environments like Cloudflare Workers, Deno, Node.js, or browsers.
//!
//! Memory Model:
//! - WASM linear memory is used for all allocations
//! - JavaScript allocates input buffers using wasm_alloc()
//! - JavaScript must free output buffers using wasm_free() or zigpdf_free()
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
//! const inputPtr = wasm_alloc(jsonBytes.length);
//! new Uint8Array(memory.buffer, inputPtr, jsonBytes.length).set(jsonBytes);
//!
//! // Allocate space for output length
//! const lenPtr = wasm_alloc(4);
//!
//! // Generate PDF
//! const pdfPtr = zigpdf_generate_invoice(inputPtr, jsonBytes.length, lenPtr);
//! wasm_free(inputPtr, jsonBytes.length);
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
const order_email = @import("order_email.zig");
const letter = @import("letter.zig");

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

/// Free memory wrapper (backwards-compatible alias)
export fn zigpdf_free(ptr: usize, size: usize) void {
    wasm_free(ptr, size);
}

// =============================================================================
// Error Handling
// =============================================================================

var last_error: [256]u8 = [_]u8{0} ** 256;
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
// PDF → MDX Extraction (the inverse of generation)
// =============================================================================

const pdf_extract = @import("pdf_extract.zig");
var last_meta: pdf_extract.ExtractionMeta = .{};

/// Image blobs from the last extract call made with `extract_images`. Owned
/// here; borrowed by zigpdf_extract_image_name/_data; freed on the next extract
/// call or by zigpdf_extract_free_images.
var last_images: []pdf_extract.ExtractedImage = &.{};

fn freeLastImages() void {
    for (last_images) |img| {
        wasm_allocator.free(img.name);
        wasm_allocator.free(img.bytes);
    }
    if (last_images.len > 0) wasm_allocator.free(last_images);
    last_images = &.{};
}

fn runExtract(pdf: []const u8, opts: pdf_extract.ExtractOptions, output_len: *usize) ?[*]u8 {
    freeLastImages();
    const result = pdf_extract.extractToMdx(wasm_allocator, pdf, opts) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "PDF extraction error: {s}", .{@errorName(err)}) catch "PDF extraction error";
        setLastError(msg);
        return null;
    };
    last_meta = result.meta;
    last_images = result.images;
    output_len.* = result.mdx.len;
    return @ptrCast(@constCast(result.mdx.ptr));
}

/// Extract MDX from PDF bytes with default options. Mirrors zigdocx_docx_to_md
/// so one Wazero helper drives both modules. Returns MDX bytes (free with
/// wasm_free) or 0 on error.
export fn zigpdf_extract_mdx(pdf_ptr: [*]const u8, pdf_len: usize, output_len: *usize) ?[*]u8 {
    return runExtract(pdf_ptr[0..pdf_len], .{}, output_len);
}

/// Extract MDX with explicit options. The bool flags are passed as u32 (0/1);
/// source_name is a (ptr,len) slice into linear memory (len 0 → none). When
/// extract_images is nonzero, image blobs are reachable via
/// zigpdf_extract_image_count/_name/_data after this returns.
export fn zigpdf_extract_mdx_opts(
    pdf_ptr: [*]const u8,
    pdf_len: usize,
    extract_images: u32,
    detect_tables: u32,
    detect_headings: u32,
    source_name_ptr: [*]const u8,
    source_name_len: usize,
    output_len: *usize,
) ?[*]u8 {
    const opts = pdf_extract.ExtractOptions{
        .extract_images = extract_images != 0,
        .detect_tables = detect_tables != 0,
        .detect_headings = detect_headings != 0,
        .source_name = if (source_name_len > 0) source_name_ptr[0..source_name_len] else "",
    };
    return runExtract(pdf_ptr[0..pdf_len], opts, output_len);
}

/// Serialize the last extraction's metadata as JSON. Free with wasm_free.
export fn zigpdf_extract_meta_json(output_len: *usize) ?[*]u8 {
    const json = std.json.Stringify.valueAlloc(wasm_allocator, .{
        .pages = last_meta.pages,
        .has_text_layer = last_meta.has_text_layer,
        .needs_ocr = last_meta.needs_ocr,
        .images_found = last_meta.images_found,
        .tables_found = last_meta.tables_found,
        .extraction_method = last_meta.extraction_method,
        .encrypted = last_meta.encrypted,
        .form_fields = last_meta.form_fields,
    }, .{}) catch {
        setLastError("meta serialization failed");
        return null;
    };
    output_len.* = json.len;
    return @ptrCast(@constCast(json.ptr));
}

/// Number of image blobs captured by the last extract call made with
/// `extract_images` set (0 otherwise).
export fn zigpdf_extract_image_count() usize {
    return last_images.len;
}

/// Borrowed pointer (into linear memory) to image `idx`'s file name, length in
/// out_len. Owned by the module; valid until the next extract call or
/// zigpdf_extract_free_images — do not wasm_free it. 0 if idx is out of range.
export fn zigpdf_extract_image_name(idx: usize, out_len: *usize) ?[*]u8 {
    if (idx >= last_images.len) {
        out_len.* = 0;
        return null;
    }
    const name = last_images[idx].name;
    out_len.* = name.len;
    return @ptrCast(@constCast(name.ptr));
}

/// Borrowed pointer to image `idx`'s encoded bytes (complete JPEG/JP2/PNG file),
/// length in out_len. Same borrow contract as zigpdf_extract_image_name.
export fn zigpdf_extract_image_data(idx: usize, out_len: *usize) ?[*]u8 {
    if (idx >= last_images.len) {
        out_len.* = 0;
        return null;
    }
    const bytes = last_images[idx].bytes;
    out_len.* = bytes.len;
    return @ptrCast(@constCast(bytes.ptr));
}

/// Release the retained image set early (the next extract call frees it anyway).
export fn zigpdf_extract_free_images() void {
    freeLastImages();
}

// =============================================================================
// PDF Generation Functions
// =============================================================================

/// Generate an invoice PDF from JSON input
export fn zigpdf_generate_invoice(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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

/// Generate an AES-256 password-encrypted invoice PDF, using a host-supplied
/// 32-byte CSPRNG seed (WASM has no in-module entropy source). `seed_ptr` must
/// point to 32 bytes of `crypto.getRandomValues` output; the file key, salts
/// and IVs derive from it. The open/owner passwords come from the JSON
/// (`password`, `owner_password`). An all-zero seed is rejected (returns null
/// with an error). Free the result with wasm_free.
export fn zigpdf_generate_invoice_encrypted(json_ptr: [*]const u8, json_len: usize, seed_ptr: [*]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    var data = json_parser.parseInvoiceJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "JSON parse error: {s}", .{@errorName(err)}) catch "JSON parse error";
        setLastError(msg);
        return null;
    };
    defer json_parser.freeInvoiceData(wasm_allocator, &data);

    var seed: [32]u8 = undefined;
    @memcpy(&seed, seed_ptr[0..32]);
    data.seed = seed;

    const pdf_bytes = invoice.generateInvoice(wasm_allocator, data) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "PDF generation error: {s}", .{@errorName(err)}) catch "PDF generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate an AES-256 password-encrypted letter PDF, using a host-supplied
/// 32-byte CSPRNG seed (see zigpdf_generate_invoice_encrypted). Passwords come
/// from the JSON (`password`, `owner_password`). Free with wasm_free.
export fn zigpdf_generate_letter_encrypted(json_ptr: [*]const u8, json_len: usize, seed_ptr: [*]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    var seed: [32]u8 = undefined;
    @memcpy(&seed, seed_ptr[0..32]);

    const pdf_bytes = letter.generateLetterFromJsonSeeded(wasm_allocator, json_slice, seed) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Letter generation error: {s}", .{@errorName(err)}) catch "Letter generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate an app-aware order-confirmation email from a normalized Stripe
/// event (JSON). Returns a JSON envelope (also bytes) the webhook acts on:
///   {"action":"send", from_name, from_email, to, subject, order_ref,
///    legal_entity, is_physical, event_id, html}
///   {"action":"skip", reason, event_id}   // unknown/untagged app — NO email
/// Returns null only on a hard error (bad UTF-8 / malformed JSON / OOM); an
/// unknown app is a successful `skip` envelope, not null. Free with wasm_free.
export fn zigpdf_generate_order_email(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    const envelope = order_email.generateFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Order email error: {s}", .{@errorName(err)}) catch "Order email error";
        setLastError(msg);
        return null;
    };

    output_len.* = envelope.len;
    return @ptrCast(envelope.ptr);
}

/// Generate a "letter" PDF (markdown body flowed across pages + letterhead +
/// optional full-page background image) from JSON. See src/letter.zig for the
/// input shape. Returns the PDF bytes; free with wasm_free. Null on error.
export fn zigpdf_generate_letter(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

    const pdf_bytes = letter.generateLetterFromJson(wasm_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Letter generation error: {s}", .{@errorName(err)}) catch "Letter generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

// Note: zigpdf_generate_crypto_receipt requires manual JSON parsing
// Not available in WASM build - use native FFI for crypto receipts

/// Generate a contract PDF from JSON input
export fn zigpdf_generate_contract(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_share_certificate(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_dividend_voucher(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_stock_transfer(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_board_resolution(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_director_consent(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_director_appointment(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_director_resignation(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_written_resolution(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_presentation(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_proposal(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_clean_quote(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_letter_quote(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_template_card(json_ptr: [*]const u8, json_len: usize, output_len: *usize) ?[*]u8 {
    const json_slice = json_ptr[0..json_len];

    if (!std.unicode.utf8ValidateSlice(json_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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
export fn zigpdf_generate_qrcode_svg(data_ptr: [*]const u8, data_len: usize, output_len: *usize) ?[*]u8 {
    const data_slice = data_ptr[0..data_len];

    if (!std.unicode.utf8ValidateSlice(data_slice)) {
        setLastError("Invalid UTF-8 input");
        return null;
    }

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

// =============================================================================
// Unit Tests
// =============================================================================

test "WASM FFI UTF-8 boundary validation" {
    // 1. Test invalid UTF-8 rejected
    const invalid_utf8 = "\xff\xff";
    var out_len: usize = 0;
    const result = zigpdf_generate_invoice(invalid_utf8.ptr, invalid_utf8.len, &out_len);
    
    try std.testing.expect(result == null);
    
    const err_ptr = zigpdf_get_error();
    const err_slice = std.mem.span(err_ptr);
    try std.testing.expect(std.mem.indexOf(u8, err_slice, "Invalid UTF-8") != null);
    
    // 2. Test valid empty string (will fail JSON parse, NOT UTF-8 validation)
    const valid_empty = "";
    const result2 = zigpdf_generate_invoice(valid_empty.ptr, valid_empty.len, &out_len);
    try std.testing.expect(result2 == null);
    
    const err_ptr2 = zigpdf_get_error();
    const err_slice2 = std.mem.span(err_ptr2);
    try std.testing.expect(std.mem.indexOf(u8, err_slice2, "JSON parse error") != null);
}
