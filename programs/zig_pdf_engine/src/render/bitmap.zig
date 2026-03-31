// PDF Renderer - Bitmap/Pixel Buffer
//
// High-performance RGBA pixel buffer for PDF page rendering.
// Designed for direct use with Android SurfaceView via JNI.
//
// Memory layout: Row-major, RGBA8888 (compatible with Android Bitmap)

const std = @import("std");

/// RGBA color with 8 bits per channel
pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    /// Create from RGB values (fully opaque)
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Create from RGBA values
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Create from floating point RGB [0.0, 1.0]
    pub fn fromFloat(r: f32, g: f32, b: f32) Color {
        return .{
            .r = @intFromFloat(@max(0, @min(255, r * 255.0))),
            .g = @intFromFloat(@max(0, @min(255, g * 255.0))),
            .b = @intFromFloat(@max(0, @min(255, b * 255.0))),
            .a = 255,
        };
    }

    /// Create from floating point RGBA [0.0, 1.0]
    pub fn fromFloatAlpha(r: f32, g: f32, b: f32, a: f32) Color {
        return .{
            .r = @intFromFloat(@max(0, @min(255, r * 255.0))),
            .g = @intFromFloat(@max(0, @min(255, g * 255.0))),
            .b = @intFromFloat(@max(0, @min(255, b * 255.0))),
            .a = @intFromFloat(@max(0, @min(255, a * 255.0))),
        };
    }

    /// Create from grayscale value [0.0, 1.0]
    pub fn fromGray(gray: f32) Color {
        const v: u8 = @intFromFloat(@max(0, @min(255, gray * 255.0)));
        return .{ .r = v, .g = v, .b = v, .a = 255 };
    }

    /// Create from CMYK values [0.0, 1.0]
    pub fn fromCMYK(c: f32, m: f32, y: f32, k: f32) Color {
        // Standard CMYK to RGB conversion
        const r = (1.0 - c) * (1.0 - k);
        const g = (1.0 - m) * (1.0 - k);
        const b = (1.0 - y) * (1.0 - k);
        return fromFloat(r, g, b);
    }

    /// Blend this color over another using alpha compositing (Porter-Duff "over")
    pub fn blendOver(self: Color, dst: Color) Color {
        if (self.a == 255) return self;
        if (self.a == 0) return dst;

        const src_a = @as(f32, @floatFromInt(self.a)) / 255.0;
        const dst_a = @as(f32, @floatFromInt(dst.a)) / 255.0;
        const out_a = src_a + dst_a * (1.0 - src_a);

        if (out_a < 0.001) return Color.transparent;

        const inv_out_a = 1.0 / out_a;
        const src_contrib = src_a * inv_out_a;
        const dst_contrib = dst_a * (1.0 - src_a) * inv_out_a;

        return .{
            .r = @intFromFloat(@min(255, @as(f32, @floatFromInt(self.r)) * src_contrib + @as(f32, @floatFromInt(dst.r)) * dst_contrib)),
            .g = @intFromFloat(@min(255, @as(f32, @floatFromInt(self.g)) * src_contrib + @as(f32, @floatFromInt(dst.g)) * dst_contrib)),
            .b = @intFromFloat(@min(255, @as(f32, @floatFromInt(self.b)) * src_contrib + @as(f32, @floatFromInt(dst.b)) * dst_contrib)),
            .a = @intFromFloat(@min(255, out_a * 255.0)),
        };
    }

    /// Multiply color by alpha (for anti-aliasing coverage)
    pub fn withAlpha(self: Color, alpha: f32) Color {
        const new_a = @as(f32, @floatFromInt(self.a)) / 255.0 * alpha;
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = @intFromFloat(@max(0, @min(255, new_a * 255.0))),
        };
    }

    /// Convert to packed u32 (for direct memory operations)
    pub fn toU32(self: Color) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }

    /// Create from packed u32
    pub fn fromU32(val: u32) Color {
        return .{
            .r = @truncate(val),
            .g = @truncate(val >> 8),
            .b = @truncate(val >> 16),
            .a = @truncate(val >> 24),
        };
    }
};

/// High-performance pixel buffer
/// Row-major RGBA8888 layout for Android compatibility
pub const Bitmap = struct {
    pixels: []Color,
    width: u32,
    height: u32,
    stride: u32, // Bytes per row (may include padding)
    allocator: std.mem.Allocator,

    /// Create a new bitmap with given dimensions
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(Color, pixel_count);

        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = width * 4,
            .allocator = allocator,
        };
    }

    /// Free bitmap memory
    pub fn deinit(self: *Bitmap) void {
        self.allocator.free(self.pixels);
    }

    /// Clear entire bitmap to a color
    pub fn clear(self: *Bitmap, color: Color) void {
        @memset(self.pixels, color);
    }

    /// Get raw byte slice for FFI (RGBA8888 format)
    pub fn getRawBytes(self: *const Bitmap) []const u8 {
        const byte_ptr: [*]const u8 = @ptrCast(self.pixels.ptr);
        return byte_ptr[0 .. self.pixels.len * 4];
    }

    /// Get mutable raw byte slice for FFI
    pub fn getRawBytesMut(self: *Bitmap) []u8 {
        const byte_ptr: [*]u8 = @ptrCast(self.pixels.ptr);
        return byte_ptr[0 .. self.pixels.len * 4];
    }

    /// Get pixel at (x, y) - no bounds checking
    pub inline fn getPixelUnchecked(self: *const Bitmap, x: u32, y: u32) Color {
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    /// Set pixel at (x, y) - no bounds checking
    pub inline fn setPixelUnchecked(self: *Bitmap, x: u32, y: u32, color: Color) void {
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = color;
    }

    /// Get pixel with bounds checking
    pub fn getPixel(self: *const Bitmap, x: i32, y: i32) ?Color {
        if (x < 0 or y < 0) return null;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return null;
        return self.getPixelUnchecked(ux, uy);
    }

    /// Set pixel with bounds checking
    pub fn setPixel(self: *Bitmap, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        self.setPixelUnchecked(ux, uy, color);
    }

    /// Blend pixel with alpha compositing
    pub fn blendPixel(self: *Bitmap, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;

        const idx = @as(usize, uy) * @as(usize, self.width) + @as(usize, ux);
        self.pixels[idx] = color.blendOver(self.pixels[idx]);
    }

    /// Fill horizontal span (for scanline rasterization)
    /// x1 and x2 are inclusive, no bounds checking
    pub fn fillSpanUnchecked(self: *Bitmap, y: u32, x1: u32, x2: u32, color: Color) void {
        const row_start = @as(usize, y) * @as(usize, self.width);
        const start = row_start + @as(usize, x1);
        const end = row_start + @as(usize, x2) + 1;
        @memset(self.pixels[start..end], color);
    }

    /// Fill horizontal span with bounds checking and clipping
    pub fn fillSpan(self: *Bitmap, y: i32, x1: i32, x2: i32, color: Color) void {
        if (y < 0 or y >= @as(i32, @intCast(self.height))) return;

        const clipped_x1 = @max(0, x1);
        const clipped_x2 = @min(@as(i32, @intCast(self.width)) - 1, x2);
        if (clipped_x1 > clipped_x2) return;

        self.fillSpanUnchecked(
            @intCast(y),
            @intCast(clipped_x1),
            @intCast(clipped_x2),
            color,
        );
    }

    /// Fill horizontal span with alpha blending
    pub fn blendSpan(self: *Bitmap, y: i32, x1: i32, x2: i32, color: Color) void {
        if (y < 0 or y >= @as(i32, @intCast(self.height))) return;
        if (color.a == 0) return;

        const clipped_x1: u32 = @intCast(@max(0, x1));
        const clipped_x2: u32 = @intCast(@min(@as(i32, @intCast(self.width)) - 1, x2));
        if (clipped_x1 > clipped_x2) return;

        const row_start = @as(usize, @intCast(y)) * @as(usize, self.width);

        if (color.a == 255) {
            // Fully opaque - direct write
            @memset(self.pixels[row_start + clipped_x1 .. row_start + clipped_x2 + 1], color);
        } else {
            // Alpha blend each pixel
            for (clipped_x1..clipped_x2 + 1) |x| {
                const idx = row_start + x;
                self.pixels[idx] = color.blendOver(self.pixels[idx]);
            }
        }
    }

    /// Fill a rectangle
    pub fn fillRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        const x2 = x + @as(i32, @intCast(w)) - 1;
        const y2 = y + @as(i32, @intCast(h)) - 1;

        var cy = y;
        while (cy <= y2) : (cy += 1) {
            self.fillSpan(cy, x, x2, color);
        }
    }

    /// Copy a rectangular region from another bitmap
    pub fn blit(self: *Bitmap, src: *const Bitmap, dst_x: i32, dst_y: i32) void {
        self.blitRegion(src, 0, 0, src.width, src.height, dst_x, dst_y);
    }

    /// Copy a rectangular region from another bitmap with source offset
    pub fn blitRegion(
        self: *Bitmap,
        src: *const Bitmap,
        src_x: u32,
        src_y: u32,
        src_w: u32,
        src_h: u32,
        dst_x: i32,
        dst_y: i32,
    ) void {
        // Calculate clipped bounds
        var sx: i32 = @intCast(src_x);
        var sy: i32 = @intCast(src_y);
        var dx = dst_x;
        var dy = dst_y;
        var w: i32 = @intCast(src_w);
        var h: i32 = @intCast(src_h);

        // Clip to destination bounds
        if (dx < 0) {
            sx -= dx;
            w += dx;
            dx = 0;
        }
        if (dy < 0) {
            sy -= dy;
            h += dy;
            dy = 0;
        }
        if (dx + w > @as(i32, @intCast(self.width))) {
            w = @as(i32, @intCast(self.width)) - dx;
        }
        if (dy + h > @as(i32, @intCast(self.height))) {
            h = @as(i32, @intCast(self.height)) - dy;
        }

        if (w <= 0 or h <= 0) return;

        // Copy row by row
        const src_stride = src.width;
        const dst_stride = self.width;

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const src_row_start = @as(usize, @intCast(sy + row)) * src_stride + @as(usize, @intCast(sx));
            const dst_row_start = @as(usize, @intCast(dy + row)) * dst_stride + @as(usize, @intCast(dx));
            const copy_len: usize = @intCast(w);

            @memcpy(
                self.pixels[dst_row_start..][0..copy_len],
                src.pixels[src_row_start..][0..copy_len],
            );
        }
    }

    /// Blit with alpha blending
    pub fn blitBlend(self: *Bitmap, src: *const Bitmap, dst_x: i32, dst_y: i32) void {
        var row: u32 = 0;
        while (row < src.height) : (row += 1) {
            const dy = dst_y + @as(i32, @intCast(row));
            if (dy < 0 or dy >= @as(i32, @intCast(self.height))) continue;

            var col: u32 = 0;
            while (col < src.width) : (col += 1) {
                const dx = dst_x + @as(i32, @intCast(col));
                if (dx < 0 or dx >= @as(i32, @intCast(self.width))) continue;

                const src_color = src.getPixelUnchecked(col, row);
                if (src_color.a > 0) {
                    self.blendPixel(dx, dy, src_color);
                }
            }
        }
    }

    /// Export as PPM format (for debugging)
    pub fn writePPM(self: *const Bitmap, path: []const u8) !void {
        const libc = std.c;

        // Convert path to null-terminated
        var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= std.fs.max_path_bytes) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fd = libc.open(&path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(libc.mode_t, 0o644));
        if (fd < 0) return error.AccessDenied;
        defer _ = libc.close(fd);

        // Write header
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ self.width, self.height }) catch return error.Unexpected;
        const hdr_result = libc.write(fd, header.ptr, header.len);
        if (hdr_result < 0) return error.WriteFailure;

        // Write pixels
        for (self.pixels) |pixel| {
            const rgb = [_]u8{ pixel.r, pixel.g, pixel.b };
            const px_result = libc.write(fd, &rgb, 3);
            if (px_result < 0) return error.WriteFailure;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "color creation" {
    const c = Color.rgb(128, 64, 32);
    try std.testing.expectEqual(@as(u8, 128), c.r);
    try std.testing.expectEqual(@as(u8, 64), c.g);
    try std.testing.expectEqual(@as(u8, 32), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "color from float" {
    const c = Color.fromFloat(1.0, 0.5, 0.0);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 127), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "color CMYK conversion" {
    // Black (K=1)
    const black = Color.fromCMYK(0, 0, 0, 1);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    // White (all zeros)
    const white = Color.fromCMYK(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
}

test "bitmap creation and clear" {
    var bmp = try Bitmap.init(std.testing.allocator, 100, 100);
    defer bmp.deinit();

    bmp.clear(Color.white);
    try std.testing.expectEqual(Color.white, bmp.getPixelUnchecked(50, 50));

    bmp.setPixel(10, 10, Color.black);
    try std.testing.expectEqual(Color.black, bmp.getPixel(10, 10).?);
}

test "bitmap fill span" {
    var bmp = try Bitmap.init(std.testing.allocator, 100, 100);
    defer bmp.deinit();

    bmp.clear(Color.white);
    bmp.fillSpan(50, 20, 80, Color.black);

    try std.testing.expectEqual(Color.white, bmp.getPixel(19, 50).?);
    try std.testing.expectEqual(Color.black, bmp.getPixel(20, 50).?);
    try std.testing.expectEqual(Color.black, bmp.getPixel(80, 50).?);
    try std.testing.expectEqual(Color.white, bmp.getPixel(81, 50).?);
}

test "alpha blending" {
    const dst = Color.rgb(100, 100, 100);
    const src = Color.rgba(200, 0, 0, 128); // 50% red

    const result = src.blendOver(dst);

    // Result should be blend of red and gray
    try std.testing.expect(result.r > 100); // More red
    try std.testing.expect(result.g < 100); // Less green
    try std.testing.expect(result.b < 100); // Less blue
}
