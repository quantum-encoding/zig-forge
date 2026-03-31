//! Framebuffer for 240x240 RGB565 display
//!
//! Provides software rendering with double buffering support.

const std = @import("std");
const types = @import("types.zig");
const fonts = @import("fonts.zig");

const Color = types.Color;
const Colors = types.Colors;
const Point = types.Point;
const Rect = types.Rect;
const Align = types.Align;
const FontSize = types.FontSize;
const WIDTH = types.WIDTH;
const HEIGHT = types.HEIGHT;

/// Framebuffer for 240x240 RGB565 display
/// Size: 240 * 240 * 2 = 115,200 bytes (~112.5 KB)
pub const Framebuffer = struct {
    pixels: [WIDTH * HEIGHT]Color,
    dirty: bool,

    const Self = @This();

    /// Initialize with a solid color
    pub fn init(color: Color) Self {
        var fb: Self = .{
            .pixels = undefined,
            .dirty = true,
        };
        @memset(&fb.pixels, color);
        return fb;
    }

    /// Clear to a solid color
    pub fn clear(self: *Self, color: Color) void {
        @memset(&self.pixels, color);
        self.dirty = true;
    }

    /// Set a single pixel
    pub fn setPixel(self: *Self, x: i16, y: i16, color: Color) void {
        if (x < 0 or y < 0 or x >= WIDTH or y >= HEIGHT) return;
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);
        self.pixels[@as(usize, uy) * WIDTH + @as(usize, ux)] = color;
        self.dirty = true;
    }

    /// Get a pixel color
    pub fn getPixel(self: *const Self, x: i16, y: i16) ?Color {
        if (x < 0 or y < 0 or x >= WIDTH or y >= HEIGHT) return null;
        const ux: u16 = @intCast(x);
        const uy: u16 = @intCast(y);
        return self.pixels[@as(usize, uy) * WIDTH + @as(usize, ux)];
    }

    /// Draw a horizontal line
    pub fn hLine(self: *Self, x: i16, y: i16, length: u16, color: Color) void {
        if (y < 0 or y >= HEIGHT) return;
        const start_x: i16 = @max(0, x);
        const end_x: i16 = @min(@as(i16, WIDTH), x + @as(i16, @intCast(length)));
        if (start_x >= end_x) return;

        const row_start = @as(usize, @intCast(y)) * WIDTH;
        const start: usize = row_start + @as(usize, @intCast(start_x));
        const end: usize = row_start + @as(usize, @intCast(end_x));
        @memset(self.pixels[start..end], color);
        self.dirty = true;
    }

    /// Draw a vertical line
    pub fn vLine(self: *Self, x: i16, y: i16, length: u16, color: Color) void {
        if (x < 0 or x >= WIDTH) return;
        const start_y: i16 = @max(0, y);
        const end_y: i16 = @min(@as(i16, HEIGHT), y + @as(i16, @intCast(length)));

        var cy = start_y;
        while (cy < end_y) : (cy += 1) {
            const idx = @as(usize, @intCast(cy)) * WIDTH + @as(usize, @intCast(x));
            self.pixels[idx] = color;
        }
        self.dirty = true;
    }

    /// Draw a line using Bresenham's algorithm
    pub fn line(self: *Self, x0: i16, y0: i16, x1: i16, y1: i16, color: Color) void {
        var cx = x0;
        var cy = y0;
        const dx: i16 = @intCast(@abs(x1 - x0));
        const dy: i16 = @intCast(@abs(y1 - y0));
        const sx: i16 = if (x0 < x1) 1 else -1;
        const sy: i16 = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        while (true) {
            self.setPixel(cx, cy, color);
            if (cx == x1 and cy == y1) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                cx += sx;
            }
            if (e2 < dx) {
                err += dx;
                cy += sy;
            }
        }
    }

    /// Draw a rectangle outline
    pub fn rect(self: *Self, x: i16, y: i16, width: u16, height: u16, color: Color) void {
        self.hLine(x, y, width, color);
        self.hLine(x, y + @as(i16, @intCast(height)) - 1, width, color);
        self.vLine(x, y, height, color);
        self.vLine(x + @as(i16, @intCast(width)) - 1, y, height, color);
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *Self, x: i16, y: i16, width: u16, height: u16, color: Color) void {
        const start_y: i16 = @max(0, y);
        const end_y: i16 = @min(@as(i16, HEIGHT), y + @as(i16, @intCast(height)));

        var cy = start_y;
        while (cy < end_y) : (cy += 1) {
            self.hLine(x, cy, width, color);
        }
    }

    /// Draw a rounded rectangle outline
    pub fn roundRect(self: *Self, x: i16, y: i16, width: u16, height: u16, radius: u8, color: Color) void {
        const r: i16 = @intCast(radius);
        const w: i16 = @intCast(width);
        const h: i16 = @intCast(height);

        // Horizontal lines
        self.hLine(x + r, y, width - @as(u16, radius) * 2, color);
        self.hLine(x + r, y + h - 1, width - @as(u16, radius) * 2, color);

        // Vertical lines
        self.vLine(x, y + r, height - @as(u16, radius) * 2, color);
        self.vLine(x + w - 1, y + r, height - @as(u16, radius) * 2, color);

        // Corners (simple quarter circles)
        self.drawCorner(x + r, y + r, radius, 0, color);
        self.drawCorner(x + w - r - 1, y + r, radius, 1, color);
        self.drawCorner(x + r, y + h - r - 1, radius, 2, color);
        self.drawCorner(x + w - r - 1, y + h - r - 1, radius, 3, color);
    }

    fn drawCorner(self: *Self, cx: i16, cy: i16, radius: u8, quadrant: u2, color: Color) void {
        var x: i16 = @intCast(radius);
        var y: i16 = 0;
        var err: i16 = 0;

        while (x >= y) {
            switch (quadrant) {
                0 => { // Top-left
                    self.setPixel(cx - x, cy - y, color);
                    self.setPixel(cx - y, cy - x, color);
                },
                1 => { // Top-right
                    self.setPixel(cx + x, cy - y, color);
                    self.setPixel(cx + y, cy - x, color);
                },
                2 => { // Bottom-left
                    self.setPixel(cx - x, cy + y, color);
                    self.setPixel(cx - y, cy + x, color);
                },
                3 => { // Bottom-right
                    self.setPixel(cx + x, cy + y, color);
                    self.setPixel(cx + y, cy + x, color);
                },
            }

            y += 1;
            err += 1 + 2 * y;
            if (2 * (err - x) + 1 > 0) {
                x -= 1;
                err += 1 - 2 * x;
            }
        }
    }

    /// Draw a circle outline
    pub fn circle(self: *Self, cx: i16, cy: i16, radius: u16, color: Color) void {
        var x: i16 = @intCast(radius);
        var y: i16 = 0;
        var err: i16 = 0;

        while (x >= y) {
            self.setPixel(cx + x, cy + y, color);
            self.setPixel(cx + y, cy + x, color);
            self.setPixel(cx - y, cy + x, color);
            self.setPixel(cx - x, cy + y, color);
            self.setPixel(cx - x, cy - y, color);
            self.setPixel(cx - y, cy - x, color);
            self.setPixel(cx + y, cy - x, color);
            self.setPixel(cx + x, cy - y, color);

            y += 1;
            err += 1 + 2 * y;
            if (2 * (err - x) + 1 > 0) {
                x -= 1;
                err += 1 - 2 * x;
            }
        }
    }

    /// Draw a filled circle
    pub fn fillCircle(self: *Self, cx: i16, cy: i16, radius: u16, color: Color) void {
        var x: i16 = @intCast(radius);
        var y: i16 = 0;
        var err: i16 = 0;

        while (x >= y) {
            self.hLine(cx - x, cy + y, @intCast(x * 2 + 1), color);
            self.hLine(cx - x, cy - y, @intCast(x * 2 + 1), color);
            self.hLine(cx - y, cy + x, @intCast(y * 2 + 1), color);
            self.hLine(cx - y, cy - x, @intCast(y * 2 + 1), color);

            y += 1;
            err += 1 + 2 * y;
            if (2 * (err - x) + 1 > 0) {
                x -= 1;
                err += 1 - 2 * x;
            }
        }
    }

    /// Draw a character at position
    pub fn drawChar(self: *Self, x: i16, y: i16, char: u8, size: FontSize, fg: Color, bg: ?Color) void {
        const bitmap = fonts.getCharBitmap(char, size);
        const char_width = size.charWidth();
        const char_height = size.charHeight();

        for (0..char_height) |row| {
            for (0..char_width) |col| {
                const bit_idx = row * char_width + col;
                const byte_idx = bit_idx / 8;
                const bit_pos: u3 = @intCast(7 - (bit_idx % 8));

                if (byte_idx < bitmap.len) {
                    const is_set = (bitmap[byte_idx] >> bit_pos) & 1 == 1;
                    const px = x + @as(i16, @intCast(col));
                    const py = y + @as(i16, @intCast(row));

                    if (is_set) {
                        self.setPixel(px, py, fg);
                    } else if (bg) |bg_color| {
                        self.setPixel(px, py, bg_color);
                    }
                }
            }
        }
    }

    /// Draw text string
    pub fn drawText(self: *Self, x: i16, y: i16, text: []const u8, size: FontSize, fg: Color, bg: ?Color) void {
        var cx = x;
        const char_width: i16 = size.charWidth();

        for (text) |char| {
            if (char == '\n') {
                continue; // Skip newlines for simple single-line rendering
            }
            self.drawChar(cx, y, char, size, fg, bg);
            cx += char_width;
        }
    }

    /// Draw text with alignment
    pub fn drawTextAligned(
        self: *Self,
        x: i16,
        y: i16,
        width: u16,
        text: []const u8,
        size: FontSize,
        alignment: Align,
        fg: Color,
        bg: ?Color,
    ) void {
        const text_width = @as(u16, @intCast(text.len)) * size.charWidth();
        const offset: i16 = switch (alignment) {
            .left => 0,
            .center => @intCast(@divTrunc(@as(i32, width) - @as(i32, text_width), 2)),
            .right => @intCast(@as(i32, width) - @as(i32, text_width)),
        };
        self.drawText(x + offset, y, text, size, fg, bg);
    }

    /// Get raw pixel buffer for DMA transfer
    pub fn getBuffer(self: *const Self) []const Color {
        return &self.pixels;
    }

    /// Get raw pixel buffer as bytes (for SPI transfer)
    pub fn getBufferBytes(self: *const Self) []const u8 {
        const ptr: [*]const u8 = @ptrCast(&self.pixels);
        return ptr[0 .. WIDTH * HEIGHT * 2];
    }

    /// Mark buffer as clean (after display update)
    pub fn markClean(self: *Self) void {
        self.dirty = false;
    }

    /// Check if buffer needs updating
    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }
};
