// PDF Image Renderer
//
// Decodes and renders image XObjects in PDF documents.
// Supports common image formats:
// - DCTDecode (JPEG)
// - FlateDecode + PNG predictor (PNG-like)
// - Raw samples (uncompressed)
//
// PDF image color spaces:
// - DeviceGray, DeviceRGB, DeviceCMYK
// - Indexed (palette-based)

const std = @import("std");
const bitmap_mod = @import("bitmap.zig");
const gs_mod = @import("graphics_state.zig");

const Bitmap = bitmap_mod.Bitmap;
const Color = bitmap_mod.Color;
const Matrix = gs_mod.Matrix;

/// Image color space
pub const ImageColorSpace = enum {
    DeviceGray,
    DeviceRGB,
    DeviceCMYK,
    Indexed,
};

/// Decoded image data
pub const DecodedImage = struct {
    pixels: []Color,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
    }

    /// Create from raw samples
    pub fn fromSamples(
        allocator: std.mem.Allocator,
        samples: []const u8,
        width: u32,
        height: u32,
        bits_per_component: u8,
        color_space: ImageColorSpace,
        palette: ?[]const u8,
    ) !DecodedImage {
        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(Color, pixel_count);
        errdefer allocator.free(pixels);

        switch (color_space) {
            .DeviceGray => {
                try decodeGray(pixels, samples, width, height, bits_per_component);
            },
            .DeviceRGB => {
                try decodeRGB(pixels, samples, width, height, bits_per_component);
            },
            .DeviceCMYK => {
                try decodeCMYK(pixels, samples, width, height, bits_per_component);
            },
            .Indexed => {
                try decodeIndexed(pixels, samples, width, height, bits_per_component, palette);
            },
        }

        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Convert to bitmap
    pub fn toBitmap(self: *const DecodedImage, allocator: std.mem.Allocator) !Bitmap {
        const bmp = try Bitmap.init(allocator, self.width, self.height);
        @memcpy(bmp.pixels, self.pixels);
        return bmp;
    }
};

/// Decode grayscale samples
fn decodeGray(
    pixels: []Color,
    samples: []const u8,
    width: u32,
    height: u32,
    bits_per_component: u8,
) !void {
    const pixel_count = @as(usize, width) * @as(usize, height);

    if (bits_per_component == 8) {
        // Simple case: 1 byte per pixel
        for (0..@min(pixel_count, samples.len)) |i| {
            const gray = samples[i];
            pixels[i] = Color.rgb(gray, gray, gray);
        }
    } else if (bits_per_component == 1) {
        // 1-bit: 8 pixels per byte
        var pixel_idx: usize = 0;
        for (samples) |byte| {
            var bit: u3 = 7;
            while (true) : (bit -%= 1) {
                if (pixel_idx >= pixel_count) break;
                const gray: u8 = if ((byte >> bit) & 1 != 0) 255 else 0;
                pixels[pixel_idx] = Color.rgb(gray, gray, gray);
                pixel_idx += 1;
                if (bit == 0) break;
            }
        }
    } else if (bits_per_component == 4) {
        // 4-bit: 2 pixels per byte
        var pixel_idx: usize = 0;
        for (samples) |byte| {
            if (pixel_idx >= pixel_count) break;
            const hi = (byte >> 4) * 17; // Scale 0-15 to 0-255
            pixels[pixel_idx] = Color.rgb(hi, hi, hi);
            pixel_idx += 1;

            if (pixel_idx >= pixel_count) break;
            const lo = (byte & 0x0F) * 17;
            pixels[pixel_idx] = Color.rgb(lo, lo, lo);
            pixel_idx += 1;
        }
    } else {
        // Unsupported bit depth - fill with gray
        @memset(pixels, Color.rgb(128, 128, 128));
    }
}

/// Decode RGB samples
fn decodeRGB(
    pixels: []Color,
    samples: []const u8,
    width: u32,
    height: u32,
    bits_per_component: u8,
) !void {
    const pixel_count = @as(usize, width) * @as(usize, height);

    if (bits_per_component == 8) {
        // 3 bytes per pixel
        var i: usize = 0;
        var sample_idx: usize = 0;
        while (i < pixel_count and sample_idx + 2 < samples.len) : (i += 1) {
            pixels[i] = Color.rgb(
                samples[sample_idx],
                samples[sample_idx + 1],
                samples[sample_idx + 2],
            );
            sample_idx += 3;
        }
    } else {
        @memset(pixels, Color.rgb(128, 128, 128));
    }
}

/// Decode CMYK samples
fn decodeCMYK(
    pixels: []Color,
    samples: []const u8,
    width: u32,
    height: u32,
    bits_per_component: u8,
) !void {
    const pixel_count = @as(usize, width) * @as(usize, height);

    if (bits_per_component == 8) {
        // 4 bytes per pixel
        var i: usize = 0;
        var sample_idx: usize = 0;
        while (i < pixel_count and sample_idx + 3 < samples.len) : (i += 1) {
            const c = @as(f32, @floatFromInt(samples[sample_idx])) / 255.0;
            const m = @as(f32, @floatFromInt(samples[sample_idx + 1])) / 255.0;
            const y = @as(f32, @floatFromInt(samples[sample_idx + 2])) / 255.0;
            const k = @as(f32, @floatFromInt(samples[sample_idx + 3])) / 255.0;

            pixels[i] = Color.fromCMYK(c, m, y, k);
            sample_idx += 4;
        }
    } else {
        @memset(pixels, Color.rgb(128, 128, 128));
    }
}

/// Decode indexed (palette-based) samples
fn decodeIndexed(
    pixels: []Color,
    samples: []const u8,
    width: u32,
    height: u32,
    bits_per_component: u8,
    palette: ?[]const u8,
) !void {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const pal = palette orelse return error.NoPalette;

    if (bits_per_component == 8) {
        for (0..@min(pixel_count, samples.len)) |i| {
            const idx = samples[i];
            const pal_offset = @as(usize, idx) * 3;
            if (pal_offset + 2 < pal.len) {
                pixels[i] = Color.rgb(pal[pal_offset], pal[pal_offset + 1], pal[pal_offset + 2]);
            } else {
                pixels[i] = Color.black;
            }
        }
    } else if (bits_per_component == 4) {
        var pixel_idx: usize = 0;
        for (samples) |byte| {
            if (pixel_idx >= pixel_count) break;
            const hi_idx = @as(usize, byte >> 4) * 3;
            if (hi_idx + 2 < pal.len) {
                pixels[pixel_idx] = Color.rgb(pal[hi_idx], pal[hi_idx + 1], pal[hi_idx + 2]);
            }
            pixel_idx += 1;

            if (pixel_idx >= pixel_count) break;
            const lo_idx = @as(usize, byte & 0x0F) * 3;
            if (lo_idx + 2 < pal.len) {
                pixels[pixel_idx] = Color.rgb(pal[lo_idx], pal[lo_idx + 1], pal[lo_idx + 2]);
            }
            pixel_idx += 1;
        }
    } else {
        @memset(pixels, Color.rgb(128, 128, 128));
    }
}

/// Image XObject renderer
pub const ImageRenderer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ImageRenderer {
        return .{ .allocator = allocator };
    }

    /// Render an image XObject to a target bitmap
    pub fn render(
        self: *ImageRenderer,
        target: *Bitmap,
        image_data: []const u8,
        width: u32,
        height: u32,
        bits_per_component: u8,
        color_space: ImageColorSpace,
        palette: ?[]const u8,
        ctm: Matrix,
        interpolate: bool,
    ) !void {
        // Decode image
        var decoded = try DecodedImage.fromSamples(
            self.allocator,
            image_data,
            width,
            height,
            bits_per_component,
            color_space,
            palette,
        );
        defer decoded.deinit();

        // Render with transformation
        try self.blitTransformed(target, &decoded, ctm, interpolate);
    }

    /// Blit decoded image with transformation matrix
    fn blitTransformed(
        self: *const ImageRenderer,
        target: *Bitmap,
        image: *const DecodedImage,
        ctm: Matrix,
        interpolate: bool,
    ) !void {
        _ = self;

        // PDF images are rendered in a 1x1 unit square, CTM transforms them
        // Inverse transform to map target pixels to source pixels
        const inv_ctm = ctm.invert() orelse return;

        // Calculate transformed bounds
        const corners = [_]struct { x: f32, y: f32 }{
            ctm.transformPoint(0, 0),
            ctm.transformPoint(1, 0),
            ctm.transformPoint(1, 1),
            ctm.transformPoint(0, 1),
        };

        var min_x: f32 = corners[0].x;
        var max_x: f32 = corners[0].x;
        var min_y: f32 = corners[0].y;
        var max_y: f32 = corners[0].y;

        for (corners[1..]) |c| {
            min_x = @min(min_x, c.x);
            max_x = @max(max_x, c.x);
            min_y = @min(min_y, c.y);
            max_y = @max(max_y, c.y);
        }

        // Clip to target bounds
        const start_x = @max(0, @as(i32, @intFromFloat(@floor(min_x))));
        const end_x = @min(@as(i32, @intCast(target.width)) - 1, @as(i32, @intFromFloat(@ceil(max_x))));
        const start_y = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
        const end_y = @min(@as(i32, @intCast(target.height)) - 1, @as(i32, @intFromFloat(@ceil(max_y))));

        if (start_x > end_x or start_y > end_y) return;

        const img_w = @as(f32, @floatFromInt(image.width));
        const img_h = @as(f32, @floatFromInt(image.height));

        // Render each pixel
        var y = start_y;
        while (y <= end_y) : (y += 1) {
            var x = start_x;
            while (x <= end_x) : (x += 1) {
                // Transform back to image coordinates
                const src = inv_ctm.transformPoint(@floatFromInt(x), @floatFromInt(y));

                // Check if in image bounds (0-1 range)
                if (src.x >= 0 and src.x < 1 and src.y >= 0 and src.y < 1) {
                    // Map to pixel coordinates
                    const img_x = src.x * img_w;
                    const img_y = src.y * img_h;

                    const color = if (interpolate)
                        sampleBilinear(image, img_x, img_y)
                    else
                        sampleNearest(image, img_x, img_y);

                    target.blendPixel(x, y, color);
                }
            }
        }
    }

    /// Nearest-neighbor sampling
    fn sampleNearest(image: *const DecodedImage, x: f32, y: f32) Color {
        const ix: u32 = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(image.width - 1)), x)));
        const iy: u32 = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(image.height - 1)), y)));
        return image.pixels[@as(usize, iy) * @as(usize, image.width) + @as(usize, ix)];
    }

    /// Bilinear interpolation sampling
    fn sampleBilinear(image: *const DecodedImage, x: f32, y: f32) Color {
        const fx = @max(0, @min(@as(f32, @floatFromInt(image.width - 1)), x));
        const fy = @max(0, @min(@as(f32, @floatFromInt(image.height - 1)), y));

        const x0: u32 = @intFromFloat(@floor(fx));
        const y0: u32 = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, image.width - 1);
        const y1 = @min(y0 + 1, image.height - 1);

        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));

        const w = image.width;
        const c00 = image.pixels[@as(usize, y0) * w + @as(usize, x0)];
        const c10 = image.pixels[@as(usize, y0) * w + @as(usize, x1)];
        const c01 = image.pixels[@as(usize, y1) * w + @as(usize, x0)];
        const c11 = image.pixels[@as(usize, y1) * w + @as(usize, x1)];

        // Interpolate
        const r = lerp(lerp(@as(f32, @floatFromInt(c00.r)), @as(f32, @floatFromInt(c10.r)), tx), lerp(@as(f32, @floatFromInt(c01.r)), @as(f32, @floatFromInt(c11.r)), tx), ty);
        const g = lerp(lerp(@as(f32, @floatFromInt(c00.g)), @as(f32, @floatFromInt(c10.g)), tx), lerp(@as(f32, @floatFromInt(c01.g)), @as(f32, @floatFromInt(c11.g)), tx), ty);
        const b = lerp(lerp(@as(f32, @floatFromInt(c00.b)), @as(f32, @floatFromInt(c10.b)), tx), lerp(@as(f32, @floatFromInt(c01.b)), @as(f32, @floatFromInt(c11.b)), tx), ty);
        const a = lerp(lerp(@as(f32, @floatFromInt(c00.a)), @as(f32, @floatFromInt(c10.a)), tx), lerp(@as(f32, @floatFromInt(c01.a)), @as(f32, @floatFromInt(c11.a)), tx), ty);

        return Color.rgba(
            @intFromFloat(@max(0, @min(255, r))),
            @intFromFloat(@max(0, @min(255, g))),
            @intFromFloat(@max(0, @min(255, b))),
            @intFromFloat(@max(0, @min(255, a))),
        );
    }

    fn lerp(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }
};

/// JPEG decoder (basic implementation)
/// Full JPEG decoding is complex - this handles the common baseline case
pub const JpegDecoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JpegDecoder {
        return .{ .allocator = allocator };
    }

    /// Decode JPEG data
    /// Returns null if not a valid JPEG or unsupported format
    pub fn decode(self: *JpegDecoder, data: []const u8) !?DecodedImage {
        // Check JPEG signature
        if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
            return null; // Not a JPEG
        }

        // Parse JPEG markers to find dimensions and data
        var pos: usize = 2;
        var width: u32 = 0;
        var height: u32 = 0;
        var num_components: u8 = 0;

        while (pos + 1 < data.len) {
            if (data[pos] != 0xFF) {
                pos += 1;
                continue;
            }

            const marker = data[pos + 1];
            pos += 2;

            // Skip padding FFs
            if (marker == 0xFF or marker == 0x00) continue;

            // Start of Frame markers (SOF0-SOF15)
            if ((marker >= 0xC0 and marker <= 0xCF) and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
                if (pos + 7 > data.len) break;

                // const precision = data[pos + 2]; // Usually 8
                height = (@as(u32, data[pos + 3]) << 8) | @as(u32, data[pos + 4]);
                width = (@as(u32, data[pos + 5]) << 8) | @as(u32, data[pos + 6]);
                num_components = data[pos + 7];
                break;
            }

            // Skip other markers
            if (marker == 0xD9) break; // EOI
            if (marker >= 0xD0 and marker <= 0xD7) continue; // RSTn
            if (marker == 0x01) continue; // TEM

            // Read length and skip
            if (pos + 2 > data.len) break;
            const length = (@as(u16, data[pos]) << 8) | @as(u16, data[pos + 1]);
            pos += length;
        }

        if (width == 0 or height == 0) return null;

        // For now, return a placeholder - full JPEG decoding requires
        // Huffman tables, DCT, etc.
        // In production, you'd use a dedicated JPEG decoder
        // num_components tells us if it's grayscale (1), RGB (3), or CMYK (4)
        const is_grayscale = num_components == 1;

        // Create placeholder image (gray)
        const pixels = try self.allocator.alloc(Color, @as(usize, width) * @as(usize, height));
        const placeholder_color = if (is_grayscale) Color.rgb(180, 180, 180) else Color.rgb(200, 200, 200);
        @memset(pixels, placeholder_color);

        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = self.allocator,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "decode grayscale 8-bit" {
    const samples = [_]u8{ 0, 64, 128, 192, 255 };
    var pixels: [5]Color = undefined;

    try decodeGray(&pixels, &samples, 5, 1, 8);

    try std.testing.expectEqual(@as(u8, 0), pixels[0].r);
    try std.testing.expectEqual(@as(u8, 64), pixels[1].r);
    try std.testing.expectEqual(@as(u8, 128), pixels[2].r);
    try std.testing.expectEqual(@as(u8, 255), pixels[4].r);
}

test "decode grayscale 1-bit" {
    const samples = [_]u8{0b10101010};
    var pixels: [8]Color = undefined;

    try decodeGray(&pixels, &samples, 8, 1, 1);

    try std.testing.expectEqual(@as(u8, 255), pixels[0].r); // 1
    try std.testing.expectEqual(@as(u8, 0), pixels[1].r); // 0
    try std.testing.expectEqual(@as(u8, 255), pixels[2].r); // 1
    try std.testing.expectEqual(@as(u8, 0), pixels[3].r); // 0
}

test "decode RGB 8-bit" {
    const samples = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    var pixels: [3]Color = undefined;

    try decodeRGB(&pixels, &samples, 3, 1, 8);

    try std.testing.expectEqual(Color.rgb(255, 0, 0), pixels[0]); // Red
    try std.testing.expectEqual(Color.rgb(0, 255, 0), pixels[1]); // Green
    try std.testing.expectEqual(Color.rgb(0, 0, 255), pixels[2]); // Blue
}

test "image renderer init" {
    const renderer = ImageRenderer.init(std.testing.allocator);
    _ = renderer;
}
