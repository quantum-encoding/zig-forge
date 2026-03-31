//! ZigQR C Foreign Function Interface
//!
//! Clean C API for QR code encoding and rendering.
//! All output buffers are allocated by the library; caller must free with zigqr_free().

const std = @import("std");
const qrcode = @import("qrcode.zig");
const png = @import("png.zig");

const is_wasm = @import("builtin").target.cpu.arch == .wasm32;
const ffi_allocator: std.mem.Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

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

fn setErrorFromErr(prefix: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ prefix, @errorName(err) }) catch prefix;
    setLastError(msg);
}

fn ecLevelFromInt(level: i32) qrcode.ErrorCorrectionLevel {
    return switch (level) {
        0 => .L,
        1 => .M,
        2 => .Q,
        3 => .H,
        else => .M,
    };
}

// =============================================================================
// Core API
// =============================================================================

/// Encode data into a QR code matrix.
/// Returns a flat array of `size * size` bytes (0=white, 1=black).
/// Caller must free with `zigqr_free(ptr, size * size)`.
export fn zigqr_encode(data: [*]const u8, data_len: usize, ec_level: i32, size: *u32) ?[*]u8 {
    const input = data[0..data_len];
    const ec = ecLevelFromInt(ec_level);

    var qr = qrcode.encode(ffi_allocator, input, .{ .ec_level = ec }) catch |err| {
        setErrorFromErr("Encode failed", err);
        return null;
    };

    const qr_size = qr.size;
    size.* = qr_size;
    const total = @as(usize, qr_size) * qr_size;
    const out = ffi_allocator.alloc(u8, total) catch {
        setLastError("Out of memory");
        qr.deinit(ffi_allocator);
        return null;
    };

    // Flatten module grid: 1 = black, 0 = white
    for (0..qr_size) |y| {
        for (0..qr_size) |x| {
            out[y * qr_size + x] = if (qr.getModule(@intCast(x), @intCast(y))) 1 else 0;
        }
    }

    qr.deinit(ffi_allocator);
    return out.ptr;
}

/// Render a QR module matrix to RGB pixel data.
/// Input: flat module array from zigqr_encode. Output: RGB pixels with 8-byte header (width_u32_le, height_u32_le, pixels...).
/// Caller must free with zigqr_free(ptr, *output_len).
export fn zigqr_render_rgb(modules: [*]const u8, size: u32, module_px: u32, quiet_zone: u32, output_len: *usize) ?[*]u8 {
    const s = @as(usize, size);
    const mp: u8 = @intCast(@min(module_px, 255));
    const qz: u8 = @intCast(@min(quiet_zone, 255));
    const img_dim = (s + 2 * @as(usize, qz)) * mp;
    const rgb_len = img_dim * img_dim * 3;
    const total_len = 8 + rgb_len;

    const out = ffi_allocator.alloc(u8, total_len) catch {
        setLastError("Out of memory");
        return null;
    };

    // Width and height as little-endian u32
    const dim32: u32 = @intCast(img_dim);
    out[0] = @intCast(dim32 & 0xFF);
    out[1] = @intCast((dim32 >> 8) & 0xFF);
    out[2] = @intCast((dim32 >> 16) & 0xFF);
    out[3] = @intCast((dim32 >> 24) & 0xFF);
    @memcpy(out[4..8], out[0..4]); // square

    // Render pixels
    const pixels = out[8..];
    for (0..img_dim) |py| {
        for (0..img_dim) |px| {
            const mx = px / mp;
            const my = py / mp;
            const in_qr = mx >= qz and mx < s + qz and my >= qz and my < s + qz;
            const is_black = if (in_qr) modules[(my - qz) * s + (mx - qz)] != 0 else false;
            const offset = (py * img_dim + px) * 3;
            const color: u8 = if (is_black) 0 else 255;
            pixels[offset] = color;
            pixels[offset + 1] = color;
            pixels[offset + 2] = color;
        }
    }

    output_len.* = total_len;
    return out.ptr;
}

/// Render a QR module matrix to SVG string.
/// Caller must free with zigqr_free(ptr, *output_len).
export fn zigqr_render_svg(modules: [*]const u8, size: u32, module_px: u32, quiet_zone: u32, output_len: *usize) ?[*]u8 {
    // Wrap the external module array in a QrCode for renderSvg
    const qr_size: u8 = @intCast(@min(size, 177));
    const s = @as(usize, qr_size);
    // Copy modules into an owned slice (renderSvg needs a QrCode with modules slice)
    const mod_copy = ffi_allocator.alloc(u8, s * s) catch {
        setLastError("Out of memory");
        return null;
    };
    @memcpy(mod_copy, modules[0 .. s * s]);
    var qr = qrcode.QrCode{
        .modules = mod_copy,
        .size = qr_size,
        .version = 0,
        .ec_level = .M,
    };
    defer qr.deinit(ffi_allocator);

    var svg = qrcode.renderSvg(ffi_allocator, &qr, .{
        .module_size = @intCast(@min(module_px, 255)),
        .quiet_zone = @intCast(@min(quiet_zone, 255)),
    }) catch |err| {
        setErrorFromErr("SVG render failed", err);
        return null;
    };

    output_len.* = svg.data.len;
    const ptr = svg.data.ptr;
    svg.data = &.{};
    return ptr;
}

/// Render a QR module matrix to PNG bytes.
/// Caller must free with zigqr_free(ptr, *output_len).
export fn zigqr_render_png(modules: [*]const u8, size: u32, module_px: u32, quiet_zone: u32, output_len: *usize) ?[*]u8 {
    // First render to RGB
    var rgb_len: usize = 0;
    const rgb_ptr = zigqr_render_rgb(modules, size, module_px, quiet_zone, &rgb_len) orelse return null;
    defer ffi_allocator.free(rgb_ptr[0..rgb_len]);

    // Extract dimensions from header
    const width = @as(u32, rgb_ptr[0]) | (@as(u32, rgb_ptr[1]) << 8) | (@as(u32, rgb_ptr[2]) << 16) | (@as(u32, rgb_ptr[3]) << 24);
    const height = width; // square
    const pixels = rgb_ptr[8..rgb_len];

    const png_bytes = png.encodePng(ffi_allocator, pixels, width, height) catch |err| {
        setErrorFromErr("PNG encode failed", err);
        return null;
    };

    output_len.* = png_bytes.len;
    return @ptrCast(@constCast(png_bytes.ptr));
}

// =============================================================================
// Convenience One-Shot Functions
// =============================================================================

/// Encode data and render directly to SVG.
/// Caller must free with zigqr_free(ptr, *output_len).
export fn zigqr_to_svg(data: [*]const u8, data_len: usize, ec_level: i32, output_len: *usize) ?[*]u8 {
    const input = data[0..data_len];
    const ec = ecLevelFromInt(ec_level);

    var svg = qrcode.encodeAndRenderSvg(ffi_allocator, input, .{ .ec_level = ec }, .{}) catch |err| {
        setErrorFromErr("SVG generation failed", err);
        return null;
    };

    output_len.* = svg.data.len;
    const ptr = svg.data.ptr;
    svg.data = &.{};
    return ptr;
}

/// Encode data and render directly to PNG.
/// Caller must free with zigqr_free(ptr, *output_len).
export fn zigqr_to_png(data: [*]const u8, data_len: usize, ec_level: i32, output_len: *usize) ?[*]u8 {
    const input = data[0..data_len];
    const ec = ecLevelFromInt(ec_level);

    // Encode QR
    var img = qrcode.encodeAndRender(ffi_allocator, input, 4, .{ .ec_level = ec }) catch |err| {
        setErrorFromErr("QR encode failed", err);
        return null;
    };
    defer img.deinit(ffi_allocator);

    // Convert to PNG
    const png_bytes = png.encodePng(ffi_allocator, img.pixels, img.width, img.height) catch |err| {
        setErrorFromErr("PNG encode failed", err);
        return null;
    };

    output_len.* = png_bytes.len;
    return @ptrCast(@constCast(png_bytes.ptr));
}

// =============================================================================
// Memory Management
// =============================================================================

/// Free a buffer allocated by zigqr functions.
export fn zigqr_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    ffi_allocator.free(ptr[0..len]);
}

/// Get the library version string.
export fn zigqr_version() [*:0]const u8 {
    return "1.0.0";
}

/// Get the last error message (null-terminated).
export fn zigqr_get_error() [*:0]const u8 {
    return @ptrCast(&last_error);
}

// =============================================================================
// WASM Memory Management (only compiled for wasm32)
// =============================================================================

export fn wasm_alloc(size: usize) usize {
    if (!is_wasm) return 0;
    const slice = ffi_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

export fn wasm_free(ptr: usize, size: usize) void {
    if (!is_wasm) return;
    if (ptr == 0) return;
    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    ffi_allocator.free(slice_ptr[0..size]);
}

// =============================================================================
// Embedded C Header
// =============================================================================

pub const C_HEADER =
    \\/**
    \\ * @file zigqr.h
    \\ * @brief ZigQR - High-performance QR code generator
    \\ * @version 1.0.0
    \\ *
    \\ * Pure Zig implementation of ISO/IEC 18004 QR codes (versions 1-40).
    \\ * Supports numeric, alphanumeric, and byte encoding modes with
    \\ * error correction levels L/M/Q/H.
    \\ *
    \\ * Output formats: raw matrix, RGB pixels, SVG, PNG.
    \\ *
    \\ * Memory Management:
    \\ * - All output buffers are allocated by the library
    \\ * - Caller MUST free outputs with zigqr_free()
    \\ *
    \\ * Example:
    \\ * @code
    \\ * size_t len;
    \\ * uint8_t* png = zigqr_to_png("https://example.com", 19, 1, &len);
    \\ * if (png) {
    \\ *     fwrite(png, 1, len, fopen("qr.png", "wb"));
    \\ *     zigqr_free(png, len);
    \\ * }
    \\ * @endcode
    \\ */
    \\
    \\#ifndef ZIGQR_H
    \\#define ZIGQR_H
    \\
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* ============================================================================
    \\ * Error Correction Levels
    \\ * ============================================================================
    \\ *
    \\ * ZIGQR_EC_L = 0   ~7% recovery
    \\ * ZIGQR_EC_M = 1   ~15% recovery (default)
    \\ * ZIGQR_EC_Q = 2   ~25% recovery
    \\ * ZIGQR_EC_H = 3   ~30% recovery
    \\ */
    \\#define ZIGQR_EC_L 0
    \\#define ZIGQR_EC_M 1
    \\#define ZIGQR_EC_Q 2
    \\#define ZIGQR_EC_H 3
    \\
    \\/* ============================================================================
    \\ * Encoding Functions
    \\ * ============================================================================ */
    \\
    \\/**
    \\ * @brief Encode data into a QR code module matrix.
    \\ *
    \\ * Returns a flat array of size*size bytes where 0=white, 1=black.
    \\ * The matrix can be rendered with zigqr_render_rgb/svg/png.
    \\ *
    \\ * @param data       Input data bytes
    \\ * @param data_len   Length of input data
    \\ * @param ec_level   Error correction level (ZIGQR_EC_L/M/Q/H)
    \\ * @param size       Pointer to receive matrix dimension (size x size)
    \\ * @return Pointer to module matrix, or NULL on error
    \\ *
    \\ * @note Caller must free with zigqr_free(ptr, size * size)
    \\ */
    \\uint8_t* zigqr_encode(const uint8_t* data, size_t data_len, int ec_level, uint32_t* size);
    \\
    \\/* ============================================================================
    \\ * Rendering Functions
    \\ * ============================================================================ */
    \\
    \\/**
    \\ * @brief Render QR modules to RGB pixel data.
    \\ *
    \\ * Output format: [width_u32_le][height_u32_le][RGB pixels...]
    \\ *
    \\ * @param modules     Module matrix from zigqr_encode
    \\ * @param size        Matrix dimension
    \\ * @param module_px   Pixels per QR module (1-16, recommended 4)
    \\ * @param quiet_zone  Border modules (recommended 4)
    \\ * @param output_len  Pointer to receive output length
    \\ * @return Pointer to RGB data, or NULL on error
    \\ */
    \\uint8_t* zigqr_render_rgb(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);
    \\
    \\/**
    \\ * @brief Render QR modules to SVG string.
    \\ *
    \\ * @param modules     Module matrix from zigqr_encode
    \\ * @param size        Matrix dimension
    \\ * @param module_px   Module size in SVG units
    \\ * @param quiet_zone  Border modules
    \\ * @param output_len  Pointer to receive SVG string length
    \\ * @return Pointer to SVG string, or NULL on error
    \\ */
    \\uint8_t* zigqr_render_svg(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);
    \\
    \\/**
    \\ * @brief Render QR modules to PNG image.
    \\ *
    \\ * @param modules     Module matrix from zigqr_encode
    \\ * @param size        Matrix dimension
    \\ * @param module_px   Pixels per QR module
    \\ * @param quiet_zone  Border modules
    \\ * @param output_len  Pointer to receive PNG length
    \\ * @return Pointer to PNG bytes, or NULL on error
    \\ */
    \\uint8_t* zigqr_render_png(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);
    \\
    \\/* ============================================================================
    \\ * One-Shot Functions
    \\ * ============================================================================ */
    \\
    \\/**
    \\ * @brief Encode data and render directly to SVG.
    \\ *
    \\ * @param data       Input data bytes
    \\ * @param data_len   Length of input data
    \\ * @param ec_level   Error correction level
    \\ * @param output_len Pointer to receive SVG string length
    \\ * @return Pointer to SVG string, or NULL on error
    \\ */
    \\uint8_t* zigqr_to_svg(const uint8_t* data, size_t data_len, int ec_level, size_t* output_len);
    \\
    \\/**
    \\ * @brief Encode data and render directly to PNG.
    \\ *
    \\ * @param data       Input data bytes
    \\ * @param data_len   Length of input data
    \\ * @param ec_level   Error correction level
    \\ * @param output_len Pointer to receive PNG length
    \\ * @return Pointer to PNG bytes, or NULL on error
    \\ */
    \\uint8_t* zigqr_to_png(const uint8_t* data, size_t data_len, int ec_level, size_t* output_len);
    \\
    \\/* ============================================================================
    \\ * Memory & Utility
    \\ * ============================================================================ */
    \\
    \\/**
    \\ * @brief Free a buffer allocated by zigqr functions.
    \\ *
    \\ * @param ptr  Pointer to free (may be NULL)
    \\ * @param len  Length of the buffer
    \\ */
    \\void zigqr_free(uint8_t* ptr, size_t len);
    \\
    \\/**
    \\ * @brief Get library version string.
    \\ * @return Null-terminated version string
    \\ */
    \\const char* zigqr_version(void);
    \\
    \\/**
    \\ * @brief Get last error message.
    \\ * @return Null-terminated error string
    \\ */
    \\const char* zigqr_get_error(void);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#endif /* ZIGQR_H */
    \\
;

// =============================================================================
// Tests
// =============================================================================

test "zigqr_encode basic" {
    var size: u32 = 0;
    const modules = zigqr_encode("HELLO", 5, 1, &size);
    if (modules) |m| {
        defer zigqr_free(m, @as(usize, size) * size);
        try std.testing.expect(size >= 21); // minimum v1 = 21x21
        try std.testing.expect(size <= 177); // maximum v40 = 177x177
    } else {
        return error.EncodeFailed;
    }
}

test "zigqr_to_svg basic" {
    var len: usize = 0;
    const svg = zigqr_to_svg("test", 4, 1, &len);
    if (svg) |s| {
        defer zigqr_free(s, len);
        try std.testing.expect(len > 100);
        // Check SVG header
        const slice = s[0..5];
        try std.testing.expectEqualSlices(u8, "<svg ", slice);
    } else {
        return error.SvgFailed;
    }
}

test "zigqr_to_png basic" {
    var len: usize = 0;
    const png_ptr = zigqr_to_png("test", 4, 1, &len);
    if (png_ptr) |p| {
        defer zigqr_free(p, len);
        try std.testing.expect(len > 50);
        // Check PNG signature
        try std.testing.expectEqual(@as(u8, 0x89), p[0]);
        try std.testing.expectEqual(@as(u8, 0x50), p[1]); // 'P'
        try std.testing.expectEqual(@as(u8, 0x4E), p[2]); // 'N'
        try std.testing.expectEqual(@as(u8, 0x47), p[3]); // 'G'
    } else {
        return error.PngFailed;
    }
}

test "zigqr_version" {
    const v = zigqr_version();
    try std.testing.expectEqualSlices(u8, "1.0.0", std.mem.span(v));
}
