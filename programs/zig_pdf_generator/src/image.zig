//! Image Decoder and Processor
//!
//! Supports:
//! - JPEG: Pass-through embedding (DCTDecode)
//! - PNG: Decode to raw RGB/RGBA, embed as raw pixels
//! - Base64: Decode data URLs (data:image/png;base64,...)
//!
//! Note: PNG decoding is simplified - handles common cases (RGB, RGBA, 8-bit).
//! For full PNG compliance, a dedicated library would be needed.

const std = @import("std");
const document = @import("document.zig");

pub const ImageError = error{
    InvalidFormat,
    UnsupportedFormat,
    DecodeFailed,
    InvalidBase64,
    BufferTooSmall,
    OutOfMemory,
    InvalidPngHeader,
    UnsupportedColorType,
    DecompressFailed,
};

// =============================================================================
// Image Detection
// =============================================================================

pub fn detectFormat(data: []const u8) ?document.ImageFormat {
    if (data.len < 8) return null;

    // JPEG: FF D8 FF
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G' and
        data[4] == 0x0D and data[5] == 0x0A and data[6] == 0x1A and data[7] == 0x0A)
    {
        return .png_rgb; // Will determine RGBA during decode
    }

    return null;
}

// =============================================================================
// Base64 Decoding
// =============================================================================

const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64CharIndex(c: u8) ?u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return null;
}

pub fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    // Skip data URL prefix if present
    var data = encoded;
    if (std.mem.indexOf(u8, encoded, ";base64,")) |idx| {
        data = encoded[idx + 8 ..];
    }

    // Remove whitespace and calculate output size
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(allocator);

    for (data) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            try clean.append(allocator, c);
        }
    }

    const input = clean.items;
    if (input.len == 0) return error.InvalidBase64;

    // Calculate output size
    var padding: usize = 0;
    if (input.len > 0 and input[input.len - 1] == '=') padding += 1;
    if (input.len > 1 and input[input.len - 2] == '=') padding += 1;

    const output_len = (input.len / 4) * 3 - padding;
    var output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var i: usize = 0;
    var o: usize = 0;

    while (i + 4 <= input.len) : (i += 4) {
        const c0 = base64CharIndex(input[i]) orelse 0;
        const c1 = base64CharIndex(input[i + 1]) orelse 0;
        const c2 = if (input[i + 2] == '=') @as(u8, 0) else (base64CharIndex(input[i + 2]) orelse 0);
        const c3 = if (input[i + 3] == '=') @as(u8, 0) else (base64CharIndex(input[i + 3]) orelse 0);

        const combined: u32 = (@as(u32, c0) << 18) | (@as(u32, c1) << 12) | (@as(u32, c2) << 6) | @as(u32, c3);

        if (o < output_len) {
            output[o] = @truncate(combined >> 16);
            o += 1;
        }
        if (o < output_len and input[i + 2] != '=') {
            output[o] = @truncate(combined >> 8);
            o += 1;
        }
        if (o < output_len and input[i + 3] != '=') {
            output[o] = @truncate(combined);
            o += 1;
        }
    }

    return output;
}

// =============================================================================
// PNG Decoder (Simplified)
// =============================================================================

const PngChunk = struct {
    length: u32,
    chunk_type: [4]u8,
    data: []const u8,
    crc: u32,
};

pub const PngInfo = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    has_alpha: bool,
};

fn readU32BE(data: []const u8) u32 {
    return (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | @as(u32, data[3]);
}

fn readPngChunk(data: []const u8, offset: usize) ?PngChunk {
    if (offset + 12 > data.len) return null;

    const length = readU32BE(data[offset..]);
    if (offset + 12 + length > data.len) return null;

    return PngChunk{
        .length = length,
        .chunk_type = data[offset + 4 ..][0..4].*,
        .data = data[offset + 8 .. offset + 8 + length],
        .crc = readU32BE(data[offset + 8 + length ..]),
    };
}

fn parsePngHeader(ihdr_data: []const u8) !PngInfo {
    if (ihdr_data.len < 13) return error.InvalidPngHeader;

    return PngInfo{
        .width = readU32BE(ihdr_data[0..]),
        .height = readU32BE(ihdr_data[4..]),
        .bit_depth = ihdr_data[8],
        .color_type = ihdr_data[9],
        .has_alpha = (ihdr_data[9] == 4 or ihdr_data[9] == 6), // Grayscale+A or RGBA
    };
}

/// Decode PNG to raw RGB or RGBA pixels
pub fn decodePng(allocator: std.mem.Allocator, png_data: []const u8) !struct { pixels: []u8, info: PngInfo } {
    // Verify PNG signature
    if (png_data.len < 8) return error.InvalidPngHeader;
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, png_data[0..8], &signature)) {
        return error.InvalidPngHeader;
    }

    var offset: usize = 8;
    var info: ?PngInfo = null;
    var compressed_data: std.ArrayListUnmanaged(u8) = .empty;
    defer compressed_data.deinit(allocator);

    // Read chunks
    while (offset < png_data.len) {
        const chunk = readPngChunk(png_data, offset) orelse break;
        offset += 12 + chunk.length;

        if (std.mem.eql(u8, &chunk.chunk_type, "IHDR")) {
            info = try parsePngHeader(chunk.data);
        } else if (std.mem.eql(u8, &chunk.chunk_type, "IDAT")) {
            try compressed_data.appendSlice(allocator, chunk.data);
        } else if (std.mem.eql(u8, &chunk.chunk_type, "IEND")) {
            break;
        }
    }

    const png_info = info orelse return error.InvalidPngHeader;

    // Only support 8-bit truecolor (RGB/RGBA) for now
    if (png_info.bit_depth != 8) return error.UnsupportedColorType;
    if (png_info.color_type != 2 and png_info.color_type != 6) {
        // 2 = RGB, 6 = RGBA
        return error.UnsupportedColorType;
    }

    // Decompress using zlib (DEFLATE)
    const channels: u32 = if (png_info.color_type == 6) 4 else 3;
    const scanline_bytes = png_info.width * channels + 1; // +1 for filter byte
    const raw_size = scanline_bytes * png_info.height;

    var decompressed = try allocator.alloc(u8, raw_size);
    defer allocator.free(decompressed);

    // Use std.compress.flate to decompress (Zig 0.16 API)
    // Create a Reader from the compressed data
    var input_reader = std.Io.Reader.fixed(compressed_data.items);

    // Allocate decompression window buffer (must be >= flate.max_window_len)
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;

    // Initialize zlib decompressor
    var decompress = std.compress.flate.Decompress.init(&input_reader, .zlib, &window_buf);

    // Read decompressed data using readSliceShort
    var total_read: usize = 0;
    while (total_read < raw_size) {
        const n = decompress.reader.readSliceShort(decompressed[total_read..]) catch |err| {
            if (err == error.EndOfStream) break;
            return error.DecompressFailed;
        };
        if (n == 0) break;
        total_read += n;
    }

    // Apply PNG filters and extract pixels
    const pixel_bytes = png_info.width * png_info.height * channels;
    var pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);

    var y: u32 = 0;
    while (y < png_info.height) : (y += 1) {
        const scanline_start = y * scanline_bytes;
        const filter_type = decompressed[scanline_start];
        const scanline = decompressed[scanline_start + 1 .. scanline_start + scanline_bytes];
        const pixel_row_start = y * png_info.width * channels;

        // Apply filter (simplified - only None and Sub)
        var x: u32 = 0;
        while (x < png_info.width * channels) : (x += 1) {
            var value = scanline[x];

            switch (filter_type) {
                0 => {}, // None
                1 => { // Sub
                    if (x >= channels) {
                        value +%= pixels[pixel_row_start + x - channels];
                    }
                },
                2 => { // Up
                    if (y > 0) {
                        const prev_row = (y - 1) * png_info.width * channels;
                        value +%= pixels[prev_row + x];
                    }
                },
                3 => { // Average
                    var left: u16 = 0;
                    var up: u16 = 0;
                    if (x >= channels) {
                        left = pixels[pixel_row_start + x - channels];
                    }
                    if (y > 0) {
                        const prev_row = (y - 1) * png_info.width * channels;
                        up = pixels[prev_row + x];
                    }
                    value +%= @truncate((left + up) / 2);
                },
                4 => { // Paeth
                    var a: i16 = 0; // Left
                    var b: i16 = 0; // Up
                    var c: i16 = 0; // Upper-left
                    if (x >= channels) {
                        a = pixels[pixel_row_start + x - channels];
                    }
                    if (y > 0) {
                        const prev_row = (y - 1) * png_info.width * channels;
                        b = pixels[prev_row + x];
                        if (x >= channels) {
                            c = pixels[prev_row + x - channels];
                        }
                    }
                    const p = a + b - c;
                    const pa = @abs(p - a);
                    const pb = @abs(p - b);
                    const pc = @abs(p - c);
                    const predictor: u8 = if (pa <= pb and pa <= pc)
                        @truncate(@as(u16, @intCast(a)))
                    else if (pb <= pc)
                        @truncate(@as(u16, @intCast(b)))
                    else
                        @truncate(@as(u16, @intCast(c)));
                    value +%= predictor;
                },
                else => {}, // Unknown filter, skip
            }

            pixels[pixel_row_start + x] = value;
        }
    }

    return .{ .pixels = pixels, .info = png_info };
}

/// Convert RGBA to RGB by removing alpha channel
pub fn rgbaToRgb(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const rgb_size = width * height * 3;
    var rgb = try allocator.alloc(u8, rgb_size);
    errdefer allocator.free(rgb);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        rgb[o] = rgba[i]; // R
        rgb[o + 1] = rgba[i + 1]; // G
        rgb[o + 2] = rgba[i + 2]; // B
        // Skip alpha (rgba[i + 3])
        o += 3;
    }

    return rgb;
}

// =============================================================================
// JPEG Handling
// =============================================================================

/// Extract JPEG dimensions from header
pub fn getJpegDimensions(jpeg_data: []const u8) !struct { width: u32, height: u32 } {
    if (jpeg_data.len < 4) return error.InvalidFormat;

    // Find SOF0 marker (0xFF 0xC0) for baseline JPEG
    var i: usize = 0;
    while (i + 1 < jpeg_data.len) : (i += 1) {
        if (jpeg_data[i] == 0xFF) {
            const marker = jpeg_data[i + 1];
            // SOF0, SOF1, SOF2 markers contain dimensions
            if (marker == 0xC0 or marker == 0xC1 or marker == 0xC2) {
                if (i + 9 >= jpeg_data.len) return error.InvalidFormat;
                // Skip marker (2 bytes) and length (2 bytes) and precision (1 byte)
                const height = (@as(u32, jpeg_data[i + 5]) << 8) | @as(u32, jpeg_data[i + 6]);
                const width = (@as(u32, jpeg_data[i + 7]) << 8) | @as(u32, jpeg_data[i + 8]);
                return .{ .width = width, .height = height };
            }
            // Skip APP and other markers
            if (marker >= 0xE0 and marker <= 0xEF) {
                if (i + 4 >= jpeg_data.len) return error.InvalidFormat;
                const seg_len = (@as(usize, jpeg_data[i + 2]) << 8) | @as(usize, jpeg_data[i + 3]);
                i += seg_len + 1;
            }
        }
    }

    return error.InvalidFormat;
}

// =============================================================================
// High-Level Image Loading
// =============================================================================

/// Load image from raw bytes (auto-detects format)
pub fn loadImage(allocator: std.mem.Allocator, data: []const u8) !document.Image {
    const format = detectFormat(data) orelse return error.UnsupportedFormat;

    switch (format) {
        .jpeg => {
            const dims = try getJpegDimensions(data);
            return document.Image{
                .width = dims.width,
                .height = dims.height,
                .format = .jpeg,
                .data = data, // JPEG is embedded as-is
            };
        },
        .png_rgb, .png_rgba => {
            const decoded = try decodePng(allocator, data);
            if (decoded.info.has_alpha) {
                // Convert to RGB (PDF doesn't handle RGBA well)
                const rgb = try rgbaToRgb(allocator, decoded.pixels, decoded.info.width, decoded.info.height);
                allocator.free(decoded.pixels);
                return document.Image{
                    .width = decoded.info.width,
                    .height = decoded.info.height,
                    .format = .raw_rgb,
                    .data = rgb,
                };
            } else {
                return document.Image{
                    .width = decoded.info.width,
                    .height = decoded.info.height,
                    .format = .raw_rgb,
                    .data = decoded.pixels,
                };
            }
        },
        else => return error.UnsupportedFormat,
    }
}

/// Load image from base64 data URL
pub fn loadImageFromBase64(allocator: std.mem.Allocator, base64_data: []const u8) !struct { image: document.Image, decoded_bytes: []u8 } {
    const decoded = try decodeBase64(allocator, base64_data);
    errdefer allocator.free(decoded);

    const img = try loadImage(allocator, decoded);

    // If it's a JPEG, the image data points to decoded, so we need to keep it
    // If it's a PNG, new pixel data was allocated, so we can free decoded
    if (img.format == .jpeg) {
        return .{ .image = img, .decoded_bytes = decoded };
    } else {
        // PNG was decoded to new buffer
        allocator.free(decoded);
        // Note: caller must free img.data when done
        return .{ .image = img, .decoded_bytes = @constCast(img.data) };
    }
}

// =============================================================================
// Tests
// =============================================================================

test "base64 decode" {
    const allocator = std.testing.allocator;

    // "Hello" in base64
    const encoded = "SGVsbG8=";
    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello", decoded);
}

test "detect JPEG format" {
    // detectFormat requires at least 8 bytes
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46 };
    try std.testing.expectEqual(document.ImageFormat.jpeg, detectFormat(&jpeg_header).?);
}

test "detect PNG format" {
    const png_header = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqual(document.ImageFormat.png_rgb, detectFormat(&png_header).?);
}
