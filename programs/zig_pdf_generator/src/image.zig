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
const builtin = @import("builtin");
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
    ImageTooLarge,
    PngChunkTooLarge,
};

// =============================================================================
// Decode Limits
// =============================================================================
//
// A logo arrives as attacker-controlled bytes (JSON `company_logo_base64`,
// `qr_base64`, a `data:` URL). Every buffer below is sized from numbers inside
// those bytes, so each one needs a bound before it reaches the allocator.
// Sizes are computed in u64 and checked against these caps *before* narrowing
// to usize: on the wasm32 builds usize is u32, where the un-narrowed products
// would wrap and hand the allocator a value far smaller than the loops then
// write.

/// Decoded pixel budget (width x height). 50 MP is ~7000x7000 — orders of
/// magnitude past any logo or QR code, and still under the u32 product cap
/// for the largest channel count.
pub const MAX_PNG_PIXELS: u64 = 50_000_000;

/// Largest single PNG chunk accepted. IHDR is 13 bytes; a real IDAT run is
/// far under this.
pub const MAX_PNG_CHUNK: u64 = 16 * 1024 * 1024;

/// Total compressed IDAT accepted across all chunks — the zlib-bomb bound,
/// paired with the pixel cap that bounds what it can inflate to.
pub const MAX_PNG_IDAT_TOTAL: u64 = 32 * 1024 * 1024;

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
    // Canonical base64 only. A short non-canonical input ("=", "==") would
    // otherwise underflow output_len below to ~0 and hand that to the
    // allocator.
    if (input.len < 4 or input.len % 4 != 0) return error.InvalidBase64;

    // Calculate output size
    var padding: usize = 0;
    if (input[input.len - 1] == '=') padding += 1;
    if (input[input.len - 2] == '=') padding += 1;

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
    interlace: u8,
    has_alpha: bool,
};

fn readU32BE(data: []const u8) u32 {
    return (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | @as(u32, data[3]);
}

fn readPngChunk(data: []const u8, offset: usize) ?PngChunk {
    if (offset > data.len or data.len - offset < 12) return null;

    const length = readU32BE(data[offset..]);
    if (length > MAX_PNG_CHUNK) return null;
    // Subtraction, never `offset + 12 + length`: that sum wraps on wasm32
    // (usize == u32) for a chunk claiming a length near 0xFFFFFFFF, and the
    // slice below would then run off the end of `data`.
    if (data.len - offset - 12 < length) return null;

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
        .interlace = ihdr_data[12], // 0 = none, 1 = Adam7
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
            if (compressed_data.items.len + chunk.data.len > MAX_PNG_IDAT_TOTAL) {
                return error.PngChunkTooLarge;
            }
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
    // Adam7 interlacing lays the scanlines out as seven sub-images, which the
    // single-pass filter loop below cannot read. Say so rather than decoding
    // the bytes as if they were sequential.
    if (png_info.interlace != 0) return error.UnsupportedColorType;

    // Every size below is derived from IHDR, i.e. from attacker bytes. Bound the
    // pixel count first, then do the arithmetic in u64 so the products cannot
    // wrap before they are checked — on wasm32 `usize` is u32, and the wrapped
    // value would under-size the allocations that the filter loop then writes
    // across in full.
    if (png_info.width == 0 or png_info.height == 0) return error.InvalidPngHeader;
    const pixel_count: u64 = @as(u64, png_info.width) * @as(u64, png_info.height);
    if (pixel_count > MAX_PNG_PIXELS) return error.ImageTooLarge;

    // Decompress using zlib (DEFLATE)
    const channels: u32 = if (png_info.color_type == 6) 4 else 3;
    const scanline_bytes_64: u64 = @as(u64, png_info.width) * channels + 1; // +1 for filter byte
    const raw_size_64: u64 = scanline_bytes_64 * png_info.height;
    if (raw_size_64 > std.math.maxInt(usize)) return error.ImageTooLarge;
    const scanline_bytes: usize = @intCast(scanline_bytes_64);
    const raw_size: usize = @intCast(raw_size_64);

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
    // A stream that inflates to less than the scanlines IHDR promises leaves
    // the tail of `decompressed` uninitialised, and the filter loop below reads
    // every byte of it — so a truncated PNG would otherwise render whatever the
    // allocator last left on that heap page into the output document. Refuse
    // instead.
    if (total_read < raw_size) return error.DecompressFailed;

    // Apply PNG filters and extract pixels
    const pixel_bytes: usize = @intCast(pixel_count * channels);
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

/// Flatten RGBA to RGB by alpha-compositing each pixel onto a WHITE background.
/// PDF pages here are white, so a transparent PNG (e.g. a logo with a cut-out
/// background) blends seamlessly into the page instead of showing the stray RGB
/// left under fully-transparent pixels (the old "white/black box" artefact).
/// out = fg·α + 255·(1−α), per channel.
pub fn rgbaToRgb(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const rgb_size = width * height * 3;
    var rgb = try allocator.alloc(u8, rgb_size);
    errdefer allocator.free(rgb);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        const inv: u32 = 255 - a;
        rgb[o] = @intCast((@as(u32, rgba[i]) * a + 255 * inv) / 255); // R
        rgb[o + 1] = @intCast((@as(u32, rgba[i + 1]) * a + 255 * inv) / 255); // G
        rgb[o + 2] = @intCast((@as(u32, rgba[i + 2]) * a + 255 * inv) / 255); // B
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
/// A decoded image plus the heap buffer backing its pixel/JPEG data. The
/// caller must keep `decoded_bytes` alive until the document is built, then
/// free it. Named (not anonymous) so multiple loaders share one return type.
pub const LoadedImage = struct {
    image: document.Image,
    decoded_bytes: []u8,
};

pub fn loadImageFromBase64(allocator: std.mem.Allocator, base64_data: []const u8) !LoadedImage {
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

/// Resolve an image reference that may be raw base64, a `data:` URL, OR a
/// filesystem path, into a decoded `document.Image` plus the byte buffer that
/// must be kept alive (free it when the document is built). Drop-in replacement
/// for `loadImageFromBase64` — same return shape — so a slot can accept either
/// an inline image or a file path with no schema change.
///
/// Disambiguation is content-free: a `data:` URL is decoded as base64;
/// otherwise the string is *tried as a file path*, and only if that open fails
/// (NotFound, or NameTooLong for a long base64 blob) does it fall back to raw
/// base64. A real path opens; a base64 string never names a real file.
pub fn loadImageFlexible(
    allocator: std.mem.Allocator,
    src: []const u8,
) !LoadedImage {
    // data: URLs are base64 payloads, never file paths.
    if (std.mem.startsWith(u8, src, "data:")) {
        return loadImageFromBase64(allocator, src);
    }

    // Try the string as a filesystem path (relative to cwd). Uses the shared
    // single-threaded IO handle so it behaves identically from CLI and FFI.
    //
    // Skipped on freestanding (the browser WASM build): there is no filesystem,
    // and referencing std.Io.Threaded there fails to compile (posix getrandom /
    // IOV_MAX are absent). Browser callers must pass base64 / data: URLs, which
    // is handled by the fall-through below.
    if (builtin.target.os.tag != .freestanding) {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(32 * 1024 * 1024))) |raw| {
            const img = loadImage(allocator, raw) catch |err| {
                allocator.free(raw);
                return err;
            };
            if (img.format == .jpeg) {
                // JPEG image references the raw file bytes — keep them.
                return .{ .image = img, .decoded_bytes = raw };
            }
            // PNG decoded to a fresh pixel buffer; the raw file bytes are done.
            allocator.free(raw);
            return .{ .image = img, .decoded_bytes = @constCast(img.data) };
        } else |_| {}
    }

    // Not a file (or freestanding) — treat as raw base64.
    return loadImageFromBase64(allocator, src);
}

// =============================================================================
// Tests
// =============================================================================

// -----------------------------------------------------------------------------
// Decode-limit tests
//
// Each builds a PNG whose IHDR/chunk headers lie about the payload, i.e. the
// exact shape a hostile logo takes: a few hundred bytes of JSON that steer a
// multi-gigabyte allocation. `buildPng` emits a well-formed container so the
// only thing under test is the bound.
// -----------------------------------------------------------------------------

/// Wrap `data` in a zlib stream of one stored (uncompressed) DEFLATE block.
/// Hand-built rather than run through a compressor so the test fixture is a
/// fixed, inspectable byte sequence.
fn zlibStored(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &[_]u8{ 0x78, 0x01 }); // CMF/FLG
    try out.append(allocator, 0x01); // BFINAL=1, BTYPE=00 (stored)
    var le: [2]u8 = undefined;
    std.mem.writeInt(u16, &le, @intCast(data.len), .little);
    try out.appendSlice(allocator, &le);
    std.mem.writeInt(u16, &le, ~@as(u16, @intCast(data.len)), .little);
    try out.appendSlice(allocator, &le);
    try out.appendSlice(allocator, data);

    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(allocator, &be);

    return out.toOwnedSlice(allocator);
}

/// Assemble a PNG from an IHDR field set and a raw IDAT payload. `idat_len_override`
/// writes a length field that disagrees with the bytes that follow, for the
/// chunk-bound test.
fn buildPng(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    color_type: u8,
    interlace: u8,
    idat: []const u8,
    idat_len_override: ?u32,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var be: [4]u8 = undefined;
    // IHDR
    std.mem.writeInt(u32, &be, 13, .big);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, "IHDR");
    std.mem.writeInt(u32, &be, width, .big);
    try out.appendSlice(allocator, &be);
    std.mem.writeInt(u32, &be, height, .big);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, &[_]u8{ 8, color_type, 0, 0, interlace });
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // CRC (unchecked here)

    // IDAT
    std.mem.writeInt(u32, &be, idat_len_override orelse @intCast(idat.len), .big);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, "IDAT");
    try out.appendSlice(allocator, idat);
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

    // IEND
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
    try out.appendSlice(allocator, "IEND");
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

    return out.toOwnedSlice(allocator);
}

test "PNG pixel budget is capped" {
    const allocator = std.testing.allocator;

    // 65536 x 65536 RGBA. The old u32 arithmetic wrapped
    // (w*4+1)*h to a small value and sized the buffers from the wrapped
    // product, while the filter loop still walked the real geometry.
    const huge = try buildPng(allocator, 65536, 65536, 6, 0, "x", null);
    defer allocator.free(huge);
    try std.testing.expectError(error.ImageTooLarge, decodePng(allocator, huge));

    // Just over the cap on one axis alone.
    const wide = try buildPng(allocator, 1_000_000, 51, 2, 0, "x", null);
    defer allocator.free(wide);
    try std.testing.expectError(error.ImageTooLarge, decodePng(allocator, wide));

    // A zero dimension is a malformed header, not a 0-byte image.
    const zero = try buildPng(allocator, 0, 10, 2, 0, "x", null);
    defer allocator.free(zero);
    try std.testing.expectError(error.InvalidPngHeader, decodePng(allocator, zero));
}

test "PNG chunk length beyond the buffer or past the cap is refused" {
    const allocator = std.testing.allocator;

    // Exercise readPngChunk directly: the per-chunk cap is only *observable*
    // when the buffer is big enough that the overrun check would otherwise let
    // the chunk through, which needs a buffer larger than MAX_PNG_CHUNK.
    const big = try allocator.alloc(u8, MAX_PNG_CHUNK + 64);
    defer allocator.free(big);
    @memset(big, 0);
    std.mem.writeInt(u32, big[0..4], @intCast(MAX_PNG_CHUNK + 1), .big);
    @memcpy(big[4..8], "IDAT");
    try std.testing.expect(readPngChunk(big, 0) == null);

    // One byte under the cap, and within the buffer, is accepted — so the
    // refusal above is the cap talking and not the overrun check.
    std.mem.writeInt(u32, big[0..4], @intCast(MAX_PNG_CHUNK - 1), .big);
    try std.testing.expect(readPngChunk(big, 0) != null);

    // A length that runs past the end of a small buffer is refused. The check
    // is written as a subtraction because `offset + 12 + length` wraps on
    // wasm32 (usize == u32) for a length near 0xFFFFFFFF; that wrap is not
    // reachable on a 64-bit host, so this case only pins the in-range half.
    var small: [32]u8 = @splat(0);
    std.mem.writeInt(u32, small[0..4], 0xFFFF_FFF0, .big);
    @memcpy(small[4..8], "IDAT");
    try std.testing.expect(readPngChunk(&small, 0) == null);

    // And the whole-file path refuses such a PNG rather than slicing OOB.
    const overrun = try buildPng(allocator, 8, 8, 2, 0, "abcd", 0xFFFF_FFF0);
    defer allocator.free(overrun);
    try std.testing.expectError(error.DecompressFailed, decodePng(allocator, overrun));
}

test "PNG IDAT total is capped across chunks" {
    const allocator = std.testing.allocator;

    // Enough IDAT chunks to cross MAX_PNG_IDAT_TOTAL. Each is well-formed; it
    // is only the accumulated total that is hostile.
    const chunk_payload = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(chunk_payload);
    @memset(chunk_payload, 0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, 13, .big);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, "IHDR");
    std.mem.writeInt(u32, &be, 16, .big);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, &be);
    try out.appendSlice(allocator, &[_]u8{ 8, 2, 0, 0, 0 });
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

    var n: usize = 0;
    while (n < 9) : (n += 1) { // 9 x 4 MiB = 36 MiB > 32 MiB cap
        std.mem.writeInt(u32, &be, @intCast(chunk_payload.len), .big);
        try out.appendSlice(allocator, &be);
        try out.appendSlice(allocator, "IDAT");
        try out.appendSlice(allocator, chunk_payload);
        try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
    }

    try std.testing.expectError(error.PngChunkTooLarge, decodePng(allocator, out.items));
}

test "PNG that inflates short of its declared scanlines is refused" {
    const allocator = std.testing.allocator;

    // A valid zlib stream carrying one filter byte + one RGB pixel, but IHDR
    // claims 64x64 — the filter loop would otherwise read the uninitialised
    // tail of the scanline buffer into the rendered image.
    const payload = [_]u8{ 0, 0, 0, 0 }; // filter byte + 1 RGB pixel
    const stream = try zlibStored(allocator, &payload);
    defer allocator.free(stream);

    const short = try buildPng(allocator, 64, 64, 2, 0, stream, null);
    defer allocator.free(short);
    try std.testing.expectError(error.DecompressFailed, decodePng(allocator, short));
}

test "interlaced PNG is refused rather than mis-decoded" {
    const allocator = std.testing.allocator;

    const adam7 = try buildPng(allocator, 8, 8, 2, 1, "abcd", null);
    defer allocator.free(adam7);
    try std.testing.expectError(error.UnsupportedColorType, decodePng(allocator, adam7));
}

test "non-canonical base64 length is refused, not underflowed" {
    const allocator = std.testing.allocator;

    // "=" / "==" made (len/4)*3 - padding wrap to ~0, which then went straight
    // to the allocator.
    try std.testing.expectError(error.InvalidBase64, decodeBase64(allocator, "="));
    try std.testing.expectError(error.InvalidBase64, decodeBase64(allocator, "=="));
    try std.testing.expectError(error.InvalidBase64, decodeBase64(allocator, "abc=="));
    try std.testing.expectError(error.InvalidBase64, decodeBase64(allocator, "abcde"));

    // Canonical input still decodes.
    const ok = try decodeBase64(allocator, "SGVsbG8=");
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("Hello", ok);
}

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
