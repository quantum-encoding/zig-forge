//! C Foreign Function Interface (FFI)
//!
//! Exposes the PDF generator to C/C++, Kotlin (JNI), Swift, and Rust.
//! This interface allows Android and iOS apps to generate PDFs by:
//! 1. Passing quote data as JSON string
//! 2. Receiving PDF bytes back
//!
//! Memory Management:
//! - Input strings are borrowed (caller owns)
//! - Output bytes are allocated by Zig, caller must free with zigpdf_free()
//!
//! Usage from C:
//! ```c
//! const char* json = "{...}";
//! size_t pdf_len = 0;
//! uint8_t* pdf = zigpdf_generate_invoice(json, &pdf_len);
//! if (pdf) {
//!     // Use PDF bytes...
//!     zigpdf_free(pdf, pdf_len);
//! }
//! ```
//!
//! Usage from Kotlin (JNI):
//! ```kotlin
//! external fun generateInvoice(json: String): ByteArray?
//! ```

const std = @import("std");
const json_parser = @import("json.zig");
const invoice = @import("invoice.zig");
const document = @import("document.zig");
const crypto_receipt = @import("crypto_receipt.zig");
const qrcode = @import("qrcode.zig");
const identicon = @import("identicon.zig");
const contract = @import("contract.zig");
const share_certificate = @import("share_certificate.zig");
const dividend_voucher = @import("dividend_voucher.zig");
const stock_transfer = @import("stock_transfer.zig");
const board_resolution = @import("board_resolution.zig");
const director_consent = @import("director_consent.zig");
const director_appointment = @import("director_appointment.zig");
const director_resignation = @import("director_resignation.zig");
const written_resolution = @import("written_resolution.zig");
const proposal = @import("proposal.zig");
const clean_quote = @import("clean_quote.zig");
const markdown = @import("markdown.zig");
const template_card = @import("template_card.zig");

// =============================================================================
// Global Allocator for FFI
// =============================================================================

const builtin = @import("builtin");

/// Select allocator based on target:
/// - WASM: wasm_allocator (uses WASM linear memory)
/// - Android: page_allocator (no libc dependency)
/// - Others: c_allocator (standard libc malloc/free)
const ffi_allocator = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => std.heap.wasm_allocator,
    else => if (builtin.abi == .android)
        std.heap.page_allocator
    else
        std.heap.c_allocator,
};

// =============================================================================
// Error Codes
// =============================================================================

pub const ZigPdfError = enum(c_int) {
    success = 0,
    invalid_json = -1,
    render_failed = -2,
    out_of_memory = -3,
    invalid_argument = -4,
};

// =============================================================================
// Result Buffer
// =============================================================================

/// Thread-local storage for error message
var last_error: [256]u8 = undefined;
var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..copy_len], msg[0..copy_len]);
    last_error[copy_len] = 0;
    last_error_len = copy_len;
}

// =============================================================================
// Core FFI Functions
// =============================================================================

/// Generate an invoice PDF from JSON input
///
/// Parameters:
/// - json_input: Null-terminated JSON string containing invoice data
/// - output_len: Pointer to receive the length of the output PDF
///
/// Returns:
/// - Pointer to PDF bytes on success (caller must free with zigpdf_free)
/// - NULL on error (call zigpdf_get_error for details)
export fn zigpdf_generate_invoice(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    // Parse JSON to InvoiceData
    const data = json_parser.parseInvoiceJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "JSON parse error: {s}", .{@errorName(err)}) catch "JSON parse error";
        setLastError(msg);
        return null;
    };
    defer json_parser.freeInvoiceData(ffi_allocator, &data);

    // Generate PDF
    const pdf_bytes = invoice.generateInvoice(ffi_allocator, data) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "PDF generation error: {s}", .{@errorName(err)}) catch "PDF generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(pdf_bytes.ptr);
}

/// Generate a simple PDF document (for testing)
///
/// Parameters:
/// - title: Document title (null-terminated)
/// - body: Document body text (null-terminated)
/// - output_len: Pointer to receive output length
///
/// Returns:
/// - Pointer to PDF bytes on success
/// - NULL on error
export fn zigpdf_generate_simple(
    title: [*:0]const u8,
    body: [*:0]const u8,
    output_len: *usize,
) ?[*]u8 {
    const title_slice = std.mem.span(title);
    const body_slice = std.mem.span(body);

    var doc = document.PdfDocument.init(ffi_allocator);
    defer doc.deinit();

    _ = doc.addFont(.helvetica);
    _ = doc.addFont(.helvetica_bold);

    var content = document.ContentStream.init(ffi_allocator);
    defer content.deinit();

    // Title
    content.drawText(title_slice, 72, 750, "F1", 24, document.Color.black) catch {
        setLastError("Failed to draw title");
        return null;
    };

    // Body
    content.drawText(body_slice, 72, 700, "F0", 12, document.Color.black) catch {
        setLastError("Failed to draw body");
        return null;
    };

    doc.addPage(&content) catch {
        setLastError("Failed to add page");
        return null;
    };

    const pdf_bytes = doc.build() catch {
        setLastError("Failed to build PDF");
        return null;
    };

    // Copy to C-allocated buffer
    const result = ffi_allocator.alloc(u8, pdf_bytes.len) catch {
        setLastError("Out of memory");
        return null;
    };
    @memcpy(result, pdf_bytes);

    output_len.* = result.len;
    return result.ptr;
}

/// Free memory allocated by zigpdf functions
///
/// Must be called for every non-NULL return from zigpdf_generate_*
export fn zigpdf_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        ffi_allocator.free(p[0..len]);
    }
}

/// Get the last error message
///
/// Returns: Null-terminated error string (valid until next zigpdf call)
export fn zigpdf_get_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

/// Get library version
export fn zigpdf_version() [*:0]const u8 {
    return "1.0.0";
}

// =============================================================================
// Convenience Functions
// =============================================================================

/// Generate invoice and write directly to file
///
/// Parameters:
/// - json_input: Null-terminated JSON string
/// - output_path: Null-terminated file path
///
/// Returns: Error code
export fn zigpdf_generate_invoice_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_invoice(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    // Use global single-threaded Io for FFI calls
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    // Write using buffered writer
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// JNI Helper (Android)
// =============================================================================

/// JNI-friendly wrapper that returns a newly allocated buffer
/// The buffer includes a 4-byte length prefix for easy Java/Kotlin parsing
///
/// Buffer format: [4 bytes length (big endian)][PDF data]
export fn zigpdf_generate_invoice_jni(json_input: [*:0]const u8, total_len: *usize) ?[*]u8 {
    var pdf_len: usize = 0;
    const pdf_ptr = zigpdf_generate_invoice(json_input, &pdf_len);

    if (pdf_ptr == null) {
        return null;
    }

    // Allocate buffer with length prefix
    const result = ffi_allocator.alloc(u8, pdf_len + 4) catch {
        zigpdf_free(pdf_ptr, pdf_len);
        setLastError("Out of memory for JNI buffer");
        return null;
    };

    // Write length as big-endian 32-bit
    result[0] = @truncate(pdf_len >> 24);
    result[1] = @truncate(pdf_len >> 16);
    result[2] = @truncate(pdf_len >> 8);
    result[3] = @truncate(pdf_len);

    // Copy PDF data
    @memcpy(result[4..], pdf_ptr.?[0..pdf_len]);

    zigpdf_free(pdf_ptr, pdf_len);

    total_len.* = pdf_len + 4;
    return result.ptr;
}

// =============================================================================
// Crypto Receipt FFI
// =============================================================================

/// Generate a crypto transaction receipt PDF from JSON input
///
/// Parameters:
/// - json_input: Null-terminated JSON string containing receipt data
/// - output_len: Pointer to receive the length of the output PDF
///
/// Returns:
/// - Pointer to PDF bytes on success (caller must free with zigpdf_free)
/// - NULL on error (call zigpdf_get_error for details)
///
/// JSON format:
/// ```json
/// {
///   "tx_hash": "abc123...",
///   "from_address": "bc1q...",
///   "to_address": "bc1q...",
///   "amount": "1.23456789",
///   "symbol": "BTC",
///   "network": "bitcoin",
///   "timestamp": "2025-01-04T12:34:56Z",
///   "confirmations": 6,
///   "network_fee": "0.00012345",
///   "fiat_value": 45678.90,
///   "memo": "Payment for services"
/// }
/// ```
export fn zigpdf_generate_crypto_receipt(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    // Parse JSON to CryptoReceiptData
    const data = json_parser.parseCryptoReceiptJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "JSON parse error: {s}", .{@errorName(err)}) catch "JSON parse error";
        setLastError(msg);
        return null;
    };
    defer json_parser.freeCryptoReceiptData(ffi_allocator, &data);

    // Generate PDF
    const pdf_bytes = crypto_receipt.generateReceipt(ffi_allocator, data) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "PDF generation error: {s}", .{@errorName(err)}) catch "PDF generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(pdf_bytes.ptr);
}

/// Generate a QR code image from data
///
/// Parameters:
/// - data: Null-terminated string to encode
/// - module_size: Size of each module in pixels (1-16, recommended 4)
/// - output_len: Pointer to receive output length
///
/// Returns: Pointer to raw RGB pixel data (width*height*3 bytes)
/// First 8 bytes contain width and height as u32 little-endian
/// Format: [4 bytes width][4 bytes height][RGB pixel data]
export fn zigpdf_generate_qrcode(data: [*:0]const u8, module_size: c_int, output_len: *usize) ?[*]u8 {
    const data_slice = std.mem.span(data);
    const mod_size: u8 = if (module_size > 0 and module_size <= 16) @intCast(module_size) else 4;

    const qr_img = qrcode.encodeAndRender(ffi_allocator, data_slice, mod_size, .{ .ec_level = .M, .quiet_zone = 2 }) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "QR generation error: {s}", .{@errorName(err)}) catch "QR generation error";
        setLastError(msg);
        return null;
    };

    // Allocate buffer with header: [width:u32][height:u32][pixels]
    const header_size: usize = 8;
    const total_size = header_size + qr_img.pixels.len;
    const result = ffi_allocator.alloc(u8, total_size) catch {
        ffi_allocator.free(qr_img.pixels);
        setLastError("Out of memory");
        return null;
    };

    // Write dimensions as little-endian
    result[0] = @truncate(qr_img.width);
    result[1] = @truncate(qr_img.width >> 8);
    result[2] = @truncate(qr_img.width >> 16);
    result[3] = @truncate(qr_img.width >> 24);
    result[4] = @truncate(qr_img.height);
    result[5] = @truncate(qr_img.height >> 8);
    result[6] = @truncate(qr_img.height >> 16);
    result[7] = @truncate(qr_img.height >> 24);

    // Copy pixel data
    @memcpy(result[header_size..], qr_img.pixels);

    ffi_allocator.free(qr_img.pixels);

    output_len.* = total_size;
    return result.ptr;
}

/// Generate a QR code as SVG string
///
/// Parameters:
/// - data: Null-terminated data string
/// - output_len: Pointer to receive SVG string length
///
/// Returns: Pointer to null-terminated SVG string, or null on error
export fn zigpdf_generate_qrcode_svg(data: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const data_slice = std.mem.span(data);

    var svg = qrcode.encodeAndRenderSvg(ffi_allocator, data_slice, .{ .ec_level = .M }, .{}) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "QR SVG error: {s}", .{@errorName(err)}) catch "QR SVG error";
        setLastError(msg);
        return null;
    };

    output_len.* = svg.data.len;
    const ptr = svg.data.ptr;
    // Transfer ownership — caller must free with zigpdf_free()
    svg.data = &.{};
    return ptr;
}

/// Generate an identicon image from an address
///
/// Parameters:
/// - address: Null-terminated address string (e.g., "0x1234...")
/// - scale: Scale factor (1-16, recommended 8)
/// - output_len: Pointer to receive output length
///
/// Returns: Pointer to raw RGB pixel data
/// First 8 bytes contain width and height as u32 little-endian
/// Format: [4 bytes width][4 bytes height][RGB pixel data]
export fn zigpdf_generate_identicon(address: [*:0]const u8, scale: c_int, output_len: *usize) ?[*]u8 {
    const address_slice = std.mem.span(address);
    const scale_val: u8 = if (scale > 0 and scale <= 16) @intCast(scale) else 8;

    var icon = identicon.generate(ffi_allocator, address_slice, .{ .scale = scale_val }) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Identicon generation error: {s}", .{@errorName(err)}) catch "Identicon generation error";
        setLastError(msg);
        return null;
    };

    // Allocate buffer with header: [width:u32][height:u32][pixels]
    const header_size: usize = 8;
    const total_size = header_size + icon.pixels.len;
    const result = ffi_allocator.alloc(u8, total_size) catch {
        icon.deinit(ffi_allocator);
        setLastError("Out of memory");
        return null;
    };

    // Write dimensions as little-endian
    result[0] = @truncate(icon.width);
    result[1] = @truncate(icon.width >> 8);
    result[2] = @truncate(icon.width >> 16);
    result[3] = @truncate(icon.width >> 24);
    result[4] = @truncate(icon.height);
    result[5] = @truncate(icon.height >> 8);
    result[6] = @truncate(icon.height >> 16);
    result[7] = @truncate(icon.height >> 24);

    // Copy pixel data
    @memcpy(result[header_size..], icon.pixels);

    icon.deinit(ffi_allocator);

    output_len.* = total_size;
    return result.ptr;
}

/// Generate crypto receipt and write directly to file
export fn zigpdf_generate_crypto_receipt_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_crypto_receipt(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    // Use global single-threaded Io for FFI calls
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    // Write using buffered writer
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Contract/Document FFI
// =============================================================================

/// Generate a contract/document PDF from JSON input
///
/// Parameters:
/// - json_input: Null-terminated JSON string containing contract data
/// - output_len: Pointer to receive the length of the output PDF
///
/// Returns:
/// - Pointer to PDF bytes on success (caller must free with zigpdf_free)
/// - NULL on error (call zigpdf_get_error for details)
///
/// JSON format:
/// ```json
/// {
///   "document_type": "document",
///   "title": "Contract Title",
///   "subtitle": "Optional subtitle",
///   "parties": [...],
///   "sections": [...],
///   "signatures": [...],
///   "variables": {...},
///   "styling": {...}
/// }
/// ```
export fn zigpdf_generate_contract(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    // Generate PDF from JSON
    const pdf_bytes = contract.generateContractFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Contract generation error: {s}", .{@errorName(err)}) catch "Contract generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate contract and write directly to file
export fn zigpdf_generate_contract_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_contract(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    // Use global single-threaded Io for FFI calls
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    // Write using buffered writer
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Share Certificate FFI
// =============================================================================

/// Generate a share certificate PDF from JSON input
///
/// Parameters:
/// - json_input: Null-terminated JSON string containing certificate data
/// - output_len: Pointer to receive the length of the output PDF
///
/// Returns:
/// - Pointer to PDF bytes on success (caller must free with zigpdf_free)
/// - NULL on error (call zigpdf_get_error for details)
export fn zigpdf_generate_share_certificate(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = share_certificate.generateShareCertificateFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Share certificate error: {s}", .{@errorName(err)}) catch "Share certificate error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate share certificate and write directly to file
export fn zigpdf_generate_share_certificate_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_share_certificate(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    // Use global single-threaded Io for FFI calls
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    // Write using buffered writer
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Dividend Voucher FFI
// =============================================================================

/// Generate a dividend voucher PDF from JSON input
///
/// Parameters:
/// - json_input: Null-terminated JSON string containing voucher data
/// - output_len: Pointer to receive the length of the output PDF
///
/// Returns:
/// - Pointer to PDF bytes on success (caller must free with zigpdf_free)
/// - NULL on error (call zigpdf_get_error for details)
export fn zigpdf_generate_dividend_voucher(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = dividend_voucher.generateDividendVoucherFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Dividend voucher error: {s}", .{@errorName(err)}) catch "Dividend voucher error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate dividend voucher and write directly to file
export fn zigpdf_generate_dividend_voucher_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_dividend_voucher(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    // Use global single-threaded Io for FFI calls
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    // Write using buffered writer
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Stock Transfer FFI
// =============================================================================

/// Generate a stock transfer form PDF from JSON input
export fn zigpdf_generate_stock_transfer(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = stock_transfer.generateStockTransferFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Stock transfer error: {s}", .{@errorName(err)}) catch "Stock transfer error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate stock transfer form and write directly to file
export fn zigpdf_generate_stock_transfer_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_stock_transfer(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Board Resolution FFI
// =============================================================================

/// Generate a board resolution PDF from JSON input
export fn zigpdf_generate_board_resolution(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = board_resolution.generateBoardResolutionFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Board resolution error: {s}", .{@errorName(err)}) catch "Board resolution error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate board resolution and write directly to file
export fn zigpdf_generate_board_resolution_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_board_resolution(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Director Consent FFI
// =============================================================================

/// Generate director consent from JSON
export fn zigpdf_generate_director_consent(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_consent.generateDirectorConsentFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director consent error: {s}", .{@errorName(err)}) catch "Director consent error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate director consent and write directly to file
export fn zigpdf_generate_director_consent_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_director_consent(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Director Appointment FFI
// =============================================================================

/// Generate director appointment letter from JSON
export fn zigpdf_generate_director_appointment(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_appointment.generateDirectorAppointmentFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director appointment error: {s}", .{@errorName(err)}) catch "Director appointment error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate director appointment and write directly to file
export fn zigpdf_generate_director_appointment_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_director_appointment(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Director Resignation FFI
// =============================================================================

/// Generate director resignation letter from JSON
export fn zigpdf_generate_director_resignation(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = director_resignation.generateDirectorResignationFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Director resignation error: {s}", .{@errorName(err)}) catch "Director resignation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate director resignation and write directly to file
export fn zigpdf_generate_director_resignation_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_director_resignation(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Written Resolution FFI
// =============================================================================

/// Generate written resolution from JSON
export fn zigpdf_generate_written_resolution(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = written_resolution.generateWrittenResolutionFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Written resolution error: {s}", .{@errorName(err)}) catch "Written resolution error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate written resolution and write directly to file
export fn zigpdf_generate_written_resolution_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_written_resolution(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Proposal FFI
// =============================================================================

/// Generate a branded proposal PDF from JSON input
export fn zigpdf_generate_proposal(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = proposal.generateProposalFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Proposal generation error: {s}", .{@errorName(err)}) catch "Proposal generation error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate proposal and write directly to file
export fn zigpdf_generate_proposal_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_proposal(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Clean Quote — minimalist consultant-style template
// =============================================================================

/// Generate a clean-style PDF (quote / invoice / handover / inspection).
/// Document type word is derived from the reference prefix:
///   QTE → QUOTE, INV → INVOICE, HND → HANDOVER, INS → INSPECTION
/// Uses the same JSON contract as zigpdf_generate_proposal.
export fn zigpdf_generate_clean_quote(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = clean_quote.generateCleanQuoteFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Clean quote error: {s}", .{@errorName(err)}) catch "Clean quote error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate clean quote and write directly to file.
export fn zigpdf_generate_clean_quote_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_clean_quote(json_input, &len);
    if (pdf_ptr == null) return .invalid_json;
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Markdown → PDF
// =============================================================================

/// Render a markdown string to a PDF. Caller must free with zigpdf_free.
export fn zigpdf_generate_markdown(md_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const md_slice = std.mem.span(md_input);

    const pdf_bytes = markdown.generateFromMarkdown(ffi_allocator, md_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Markdown render error: {s}", .{@errorName(err)}) catch "Markdown render error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Render markdown to a PDF file at the given path.
export fn zigpdf_generate_markdown_to_file(
    md_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_markdown(md_input, &len);
    if (pdf_ptr == null) return .invalid_json;
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Template Card
// =============================================================================

/// Generate a template card PDF from JSON input
export fn zigpdf_generate_template_card(json_input: [*:0]const u8, output_len: *usize) ?[*]u8 {
    const json_slice = std.mem.span(json_input);

    const pdf_bytes = template_card.generateTemplateCardFromJson(ffi_allocator, json_slice) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Template card error: {s}", .{@errorName(err)}) catch "Template card error";
        setLastError(msg);
        return null;
    };

    output_len.* = pdf_bytes.len;
    return @ptrCast(@constCast(pdf_bytes.ptr));
}

/// Generate template card and write directly to file
export fn zigpdf_generate_template_card_to_file(
    json_input: [*:0]const u8,
    output_path: [*:0]const u8,
) ZigPdfError {
    var len: usize = 0;
    const pdf_ptr = zigpdf_generate_template_card(json_input, &len);

    if (pdf_ptr == null) {
        return .invalid_json;
    }
    defer zigpdf_free(pdf_ptr, len);

    const path_slice = std.mem.span(output_path);
    const pdf_data = pdf_ptr.?[0..len];

    const io = std.Io.Threaded.global_single_threaded.io();

    const file = std.Io.Dir.createFileAbsolute(io, path_slice, .{}) catch {
        setLastError("Failed to create output file");
        return .render_failed;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(pdf_data) catch {
        setLastError("Failed to write PDF data");
        return .render_failed;
    };
    std.Io.Writer.flush(&writer.interface) catch {
        setLastError("Failed to flush PDF data");
        return .render_failed;
    };

    return .success;
}

// =============================================================================
// Tests
// =============================================================================

test "FFI simple document generation" {
    var len: usize = 0;
    const result = zigpdf_generate_simple("Test Title", "Test body text", &len);

    if (result) |ptr| {
        defer zigpdf_free(ptr, len);
        try std.testing.expect(len > 100);
        try std.testing.expect(ptr[0] == '%');
        try std.testing.expect(ptr[1] == 'P');
        try std.testing.expect(ptr[2] == 'D');
        try std.testing.expect(ptr[3] == 'F');
    } else {
        // If this fails, print the error
        const err = zigpdf_get_error();
        std.debug.print("Error: {s}\n", .{std.mem.span(err)});
        try std.testing.expect(false);
    }
}
