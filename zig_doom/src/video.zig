//! zig_doom/src/video.zig
//!
//! Framebuffer and video output operations.
//! Translated from: linuxdoom-1.10/v_video.c, v_video.h, i_video.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const defs = @import("defs.zig");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const SCREENSIZE = SCREENWIDTH * SCREENHEIGHT;
pub const NUM_SCREENS = 5; // 0=main, 1=status bar back, 2-4=wipe buffers

/// A 320x200 palette-indexed framebuffer
pub const Screen = [SCREENSIZE]u8;

/// All video screens
pub const VideoState = struct {
    screens: [NUM_SCREENS]Screen,
    palette: [768]u8, // Current RGB palette (256 * 3)
    gamma: u8, // Gamma correction level (0-4)

    pub fn init() VideoState {
        var state: VideoState = undefined;
        for (&state.screens) |*s| {
            @memset(s, 0);
        }
        @memset(&state.palette, 0);
        state.gamma = 0;
        return state;
    }

    /// Load palette from PLAYPAL lump (palette 0)
    pub fn loadPalette(self: *VideoState, playpal_data: []const u8) void {
        if (playpal_data.len >= 768) {
            @memcpy(&self.palette, playpal_data[0..768]);
        }
    }

    /// Clear screen to a palette index
    pub fn clearScreen(self: *VideoState, screen_num: usize, color: u8) void {
        @memset(&self.screens[screen_num], color);
    }

    /// Write screen as PPM file
    pub fn writePPM(self: *const VideoState, screen_num: usize, path: []const u8, alloc: std.mem.Allocator) bool {
        const path_z = alloc.dupeZ(u8, path) catch return false;
        defer alloc.free(path_z);

        const file = c.fopen(path_z.ptr, "wb") orelse return false;
        defer _ = c.fclose(file);

        // PPM header
        const header = "P6\n320 200\n255\n";
        _ = c.fwrite(header.ptr, 1, header.len, file);

        // Convert palette indices to RGB
        const screen = &self.screens[screen_num];
        var rgb_buf: [SCREENWIDTH * 3]u8 = undefined;

        for (0..SCREENHEIGHT) |_y| {
            const row_start = _y * SCREENWIDTH;
            for (0..SCREENWIDTH) |_x| {
                const idx: usize = screen[row_start + _x];
                rgb_buf[_x * 3 + 0] = self.palette[idx * 3 + 0];
                rgb_buf[_x * 3 + 1] = self.palette[idx * 3 + 1];
                rgb_buf[_x * 3 + 2] = self.palette[idx * 3 + 2];
            }
            _ = c.fwrite(&rgb_buf, 1, SCREENWIDTH * 3, file);
        }

        return true;
    }

    /// Draw a vertical column of pixels to a screen
    pub fn drawColumnRaw(self: *VideoState, screen_num: usize, x: i32, y1: i32, y2: i32, source: []const u8, colormap: []const u8, frac: i32, step: i32) void {
        if (x < 0 or x >= SCREENWIDTH) return;
        const ux: usize = @intCast(x);

        var cy = y1;
        var tex_frac = frac;
        const screen = &self.screens[screen_num];

        while (cy <= y2) : (cy += 1) {
            if (cy >= 0 and cy < SCREENHEIGHT) {
                const src_idx: usize = @intCast((tex_frac >> 16) & 127);
                const pixel = if (src_idx < source.len) source[src_idx] else 0;
                const mapped = if (colormap.len > pixel) colormap[pixel] else pixel;
                screen[@as(usize, @intCast(cy)) * SCREENWIDTH + ux] = mapped;
            }
            tex_frac +%= step;
        }
    }

    /// Draw a horizontal span of pixels
    pub fn drawSpanRaw(self: *VideoState, screen_num: usize, y: i32, x1: i32, x2: i32, source: []const u8, colormap: []const u8, xfrac: i32, yfrac: i32, xstep: i32, ystep: i32) void {
        if (y < 0 or y >= SCREENHEIGHT) return;
        const row: usize = @intCast(y);
        const screen = &self.screens[screen_num];
        const row_start = row * SCREENWIDTH;

        var cx = x1;
        var xf = xfrac;
        var yf = yfrac;

        while (cx <= x2) : (cx += 1) {
            if (cx >= 0 and cx < SCREENWIDTH) {
                // Flat textures are 64x64
                const spot: usize = ((@as(usize, @intCast((yf >> 16) & 63)) << 6) +
                    @as(usize, @intCast((xf >> 16) & 63)));
                const pixel = if (spot < source.len) source[spot] else 0;
                const mapped = if (colormap.len > pixel) colormap[pixel] else pixel;
                screen[row_start + @as(usize, @intCast(cx))] = mapped;
            }
            xf +%= xstep;
            yf +%= ystep;
        }
    }

    /// Fill a rectangle with a solid color
    pub fn fillRect(self: *VideoState, screen_num: usize, x: i32, y: i32, w: i32, h: i32, color: u8) void {
        var cy = y;
        while (cy < y + h) : (cy += 1) {
            if (cy < 0 or cy >= SCREENHEIGHT) continue;
            var cx = x;
            while (cx < x + w) : (cx += 1) {
                if (cx < 0 or cx >= SCREENWIDTH) continue;
                self.screens[screen_num][@as(usize, @intCast(cy)) * SCREENWIDTH + @as(usize, @intCast(cx))] = color;
            }
        }
    }

    /// Copy a rectangular region between screens
    pub fn copyRect(self: *VideoState, src_screen: usize, dst_screen: usize, x: i32, y: i32, w: i32, h: i32) void {
        var cy = y;
        while (cy < y + h) : (cy += 1) {
            if (cy < 0 or cy >= SCREENHEIGHT) continue;
            const row: usize = @intCast(cy);
            const row_start = row * SCREENWIDTH;
            var cx = x;
            while (cx < x + w) : (cx += 1) {
                if (cx < 0 or cx >= SCREENWIDTH) continue;
                const col: usize = @intCast(cx);
                self.screens[dst_screen][row_start + col] = self.screens[src_screen][row_start + col];
            }
        }
    }
};

/// Draw a DOOM patch (column-based graphic) to a screen.
/// Patch format: header (8 bytes) + column offsets + column data
pub fn drawPatch(video: *VideoState, screen_num: usize, x_off: i32, y_off: i32, patch_data: []const u8) void {
    if (patch_data.len < 8) return;

    // Parse patch header
    const width: i32 = @as(i32, readU16(patch_data, 0));
    const height: i32 = @as(i32, readU16(patch_data, 2));
    const left: i32 = @as(i32, readI16(patch_data, 4));
    const top: i32 = @as(i32, readI16(patch_data, 6));

    const draw_x = x_off - left;
    const draw_y = y_off - top;
    _ = height; // used implicitly by column data

    // Column offsets start at byte 8
    const col_offset_start: usize = 8;

    var col: i32 = 0;
    while (col < width) : (col += 1) {
        const screen_x = draw_x + col;
        if (screen_x < 0 or screen_x >= SCREENWIDTH) continue;

        // Read column offset
        const off_pos = col_offset_start + @as(usize, @intCast(col)) * 4;
        if (off_pos + 4 > patch_data.len) break;
        const col_off: usize = readU32(patch_data, off_pos);
        if (col_off >= patch_data.len) continue;

        // Parse column posts
        var post_off = col_off;
        while (post_off < patch_data.len) {
            const topdelta = patch_data[post_off];
            if (topdelta == 0xFF) break; // End of column
            post_off += 1;
            if (post_off >= patch_data.len) break;

            const length: usize = patch_data[post_off];
            post_off += 1; // length
            post_off += 1; // padding byte

            if (post_off + length + 1 > patch_data.len) break;

            // Draw pixels
            const screen = &video.screens[screen_num];
            for (0..length) |p| {
                const screen_y = draw_y + @as(i32, topdelta) + @as(i32, @intCast(p));
                if (screen_y >= 0 and screen_y < SCREENHEIGHT) {
                    const pixel = patch_data[post_off + p];
                    screen[@as(usize, @intCast(screen_y)) * SCREENWIDTH + @as(usize, @intCast(screen_x))] = pixel;
                }
            }

            post_off += length; // pixel data
            post_off += 1; // trailing padding byte
        }
    }
}

// ============================================================================
// Little-endian read helpers (WAD is always little-endian)
// ============================================================================

fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readI16(data: []const u8, off: usize) i16 {
    return @bitCast(readU16(data, off));
}

fn readU32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

test "video state init" {
    var video = VideoState.init();
    try std.testing.expectEqual(@as(u8, 0), video.screens[0][0]);
    try std.testing.expectEqual(@as(u8, 0), video.gamma);
}

test "fill rect" {
    var video = VideoState.init();
    video.fillRect(0, 10, 10, 5, 5, 42);
    try std.testing.expectEqual(@as(u8, 42), video.screens[0][10 * SCREENWIDTH + 10]);
    try std.testing.expectEqual(@as(u8, 42), video.screens[0][14 * SCREENWIDTH + 14]);
    try std.testing.expectEqual(@as(u8, 0), video.screens[0][9 * SCREENWIDTH + 10]);
}

test "read helpers" {
    const data = [_]u8{ 0x40, 0x01, 0xC8, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u16, 320), readU16(&data, 0));
    try std.testing.expectEqual(@as(u16, 200), readU16(&data, 2));
}
