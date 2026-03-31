//! zig_doom/src/render/draw.zig
//!
//! Column and span drawing — the innermost rendering loops.
//! Translated from: linuxdoom-1.10/r_draw.c, r_draw.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const random = @import("../random.zig");

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;

// ============================================================================
// Column drawer context
// ============================================================================

pub const DrawColumnContext = struct {
    source: []const u8, // Texture column data
    colormap: []const u8, // 256-byte light/colormap
    x: i32, // Screen column
    yl: i32, // Top of column (screen y)
    yh: i32, // Bottom of column (screen y)
    iscale: Fixed, // Inverse scale (texel step per screen pixel)
    texturemid: Fixed, // Texture mid offset
    screen: [*]u8, // Destination screen buffer
};

/// Draw a textured, light-mapped vertical column
pub fn drawColumn(dc: *const DrawColumnContext) void {
    var count = dc.yh - dc.yl;
    if (count < 0) return;

    if (dc.x < 0 or dc.x >= SCREENWIDTH) return;
    if (dc.yl < 0 or dc.yh >= SCREENHEIGHT) return;

    const x: usize = @intCast(dc.x);
    var dest: usize = @as(usize, @intCast(dc.yl)) * SCREENWIDTH + x;

    // Starting texture coordinate
    var frac = dc.texturemid.raw() +% Fixed.mul(dc.iscale, Fixed.fromInt(dc.yl - (SCREENHEIGHT / 2))).raw();
    const fracstep = dc.iscale.raw();

    count += 1;
    while (count > 0) : (count -= 1) {
        // Mask to texture height (source.len acts as height)
        const src_idx: usize = @intCast(@as(u32, @bitCast(frac >> 16)) & 127);
        const pixel = if (src_idx < dc.source.len) dc.source[src_idx] else 0;
        const mapped = if (dc.colormap.len > pixel) dc.colormap[pixel] else pixel;

        if (dest < SCREENWIDTH * SCREENHEIGHT) {
            dc.screen[dest] = mapped;
        }
        dest += SCREENWIDTH;
        frac +%= fracstep;
    }
}

/// Draw a column with the fuzz (spectre/invisibility) effect
pub fn drawFuzzColumn(dc: *const DrawColumnContext) void {
    var count = dc.yh - dc.yl;
    if (count < 0) return;
    if (dc.x < 0 or dc.x >= SCREENWIDTH) return;

    const x: usize = @intCast(dc.x);
    var dest: usize = @as(usize, @intCast(std.math.clamp(dc.yl, 0, SCREENHEIGHT - 1))) * SCREENWIDTH + x;

    // Fuzz offset table (from original DOOM)
    const FUZZOFFSET = [_]i32{
        1, -1, 1, -1, 1,  1,  -1, 1, 1,  -1, 1,  1,  1,  -1, 1,  1,  1, -1, -1, -1,
        1, -1, -1, -1, 1,  1,  1,  1, -1, 1,  -1, 1,  1,  1,  -1, 1,  1, -1, 1,  1,
        -1, -1, 1, 1, -1, -1, -1, 1, 1,  -1,
    };

    var fuzz_idx: usize = 0;

    count += 1;
    while (count > 0) : (count -= 1) {
        if (dest < SCREENWIDTH * SCREENHEIGHT) {
            // Read pixel from offset position, map through dark colormap
            const fuzz_off = FUZZOFFSET[fuzz_idx % FUZZOFFSET.len];
            const src_pos = @as(i64, @intCast(dest)) + @as(i64, fuzz_off) * SCREENWIDTH;
            const clamped_src: usize = @intCast(std.math.clamp(src_pos, 0, SCREENWIDTH * SCREENHEIGHT - 1));
            const pixel = dc.screen[clamped_src];
            // Use colormap 6 (fairly dark) for fuzz effect
            const mapped = if (dc.colormap.len > pixel) dc.colormap[pixel] else pixel;
            dc.screen[dest] = mapped;
        }
        dest += SCREENWIDTH;
        fuzz_idx += 1;
    }
}

/// Draw a translucent column (DOOM didn't have this, but useful for testing)
pub fn drawColumnLow(dc: *const DrawColumnContext) void {
    // Low detail = draw each column 2 pixels wide
    var count = dc.yh - dc.yl;
    if (count < 0) return;
    if (dc.x < 0 or dc.x >= SCREENWIDTH - 1) return;

    const x: usize = @intCast(dc.x);
    var dest: usize = @as(usize, @intCast(dc.yl)) * SCREENWIDTH + x;

    var frac = dc.texturemid.raw() +% Fixed.mul(dc.iscale, Fixed.fromInt(dc.yl - (SCREENHEIGHT / 2))).raw();
    const fracstep = dc.iscale.raw();

    count += 1;
    while (count > 0) : (count -= 1) {
        const src_idx: usize = @intCast(@as(u32, @bitCast(frac >> 16)) & 127);
        const pixel = if (src_idx < dc.source.len) dc.source[src_idx] else 0;
        const mapped = if (dc.colormap.len > pixel) dc.colormap[pixel] else pixel;

        if (dest + 1 < SCREENWIDTH * SCREENHEIGHT) {
            dc.screen[dest] = mapped;
            dc.screen[dest + 1] = mapped; // double-width
        }
        dest += SCREENWIDTH;
        frac +%= fracstep;
    }
}

// ============================================================================
// Span drawer context
// ============================================================================

pub const DrawSpanContext = struct {
    source: []const u8, // Flat texture (64x64 = 4096 bytes)
    colormap: []const u8, // 256-byte colormap
    y: i32, // Screen row
    x1: i32, // Left x
    x2: i32, // Right x
    xfrac: Fixed, // Starting x texture coord
    yfrac: Fixed, // Starting y texture coord
    xstep: Fixed, // X texture step per pixel
    ystep: Fixed, // Y texture step per pixel
    screen: [*]u8, // Destination screen buffer
};

/// Draw a horizontal span of floor/ceiling texture
pub fn drawSpan(ds: *const DrawSpanContext) void {
    var count = ds.x2 - ds.x1;
    if (count < 0) return;

    if (ds.y < 0 or ds.y >= SCREENHEIGHT) return;
    const row: usize = @intCast(ds.y);
    const row_start = row * SCREENWIDTH;

    var dest = row_start + @as(usize, @intCast(std.math.clamp(ds.x1, 0, SCREENWIDTH - 1)));
    var xfrac = ds.xfrac.raw();
    var yfrac = ds.yfrac.raw();
    const xstep = ds.xstep.raw();
    const ystep = ds.ystep.raw();

    count += 1;
    while (count > 0) : (count -= 1) {
        // 64x64 flat: (y&63)*64 + (x&63)
        const spot: usize = ((@as(usize, @intCast(@as(u32, @bitCast(yfrac >> 16)) & 63)) << 6) +
            @as(usize, @intCast(@as(u32, @bitCast(xfrac >> 16)) & 63)));
        const pixel = if (spot < ds.source.len) ds.source[spot] else 0;
        const mapped = if (ds.colormap.len > pixel) ds.colormap[pixel] else pixel;

        if (dest < SCREENWIDTH * SCREENHEIGHT) {
            ds.screen[dest] = mapped;
        }
        dest += 1;
        xfrac +%= xstep;
        yfrac +%= ystep;
    }
}

/// Draw a solid-color column (used for sky when no texture available)
pub fn drawSolidColumn(screen: [*]u8, x: i32, yl: i32, yh: i32, color: u8) void {
    if (x < 0 or x >= SCREENWIDTH) return;
    const ux: usize = @intCast(x);
    var y = std.math.clamp(yl, 0, SCREENHEIGHT - 1);
    const y_end = std.math.clamp(yh, 0, SCREENHEIGHT - 1);
    while (y <= y_end) : (y += 1) {
        screen[@as(usize, @intCast(y)) * SCREENWIDTH + ux] = color;
    }
}

test "drawColumn basic" {
    var screen_buf: [SCREENWIDTH * SCREENHEIGHT]u8 = undefined;
    @memset(&screen_buf, 0);

    // Identity colormap
    var cmap: [256]u8 = undefined;
    for (&cmap, 0..) |*v, i| v.* = @intCast(i);

    const source = [_]u8{ 42, 43, 44, 45, 42, 43, 44, 45 } ** 16;

    const dc = DrawColumnContext{
        .source = &source,
        .colormap = &cmap,
        .x = 160,
        .yl = 50,
        .yh = 55,
        .iscale = Fixed.ONE,
        .texturemid = Fixed.ZERO,
        .screen = &screen_buf,
    };

    drawColumn(&dc);

    // Verify pixels were drawn
    try std.testing.expect(screen_buf[50 * SCREENWIDTH + 160] != 0);
    try std.testing.expect(screen_buf[55 * SCREENWIDTH + 160] != 0);
    // Verify outside wasn't touched
    try std.testing.expectEqual(@as(u8, 0), screen_buf[49 * SCREENWIDTH + 160]);
}

test "drawSpan basic" {
    var screen_buf: [SCREENWIDTH * SCREENHEIGHT]u8 = undefined;
    @memset(&screen_buf, 0);

    var cmap: [256]u8 = undefined;
    for (&cmap, 0..) |*v, i| v.* = @intCast(i);

    const flat = [_]u8{100} ** 4096;

    const ds = DrawSpanContext{
        .source = &flat,
        .colormap = &cmap,
        .y = 100,
        .x1 = 10,
        .x2 = 20,
        .xfrac = Fixed.ZERO,
        .yfrac = Fixed.ZERO,
        .xstep = Fixed.ONE,
        .ystep = Fixed.ZERO,
        .screen = &screen_buf,
    };

    drawSpan(&ds);

    try std.testing.expectEqual(@as(u8, 100), screen_buf[100 * SCREENWIDTH + 10]);
    try std.testing.expectEqual(@as(u8, 100), screen_buf[100 * SCREENWIDTH + 20]);
    try std.testing.expectEqual(@as(u8, 0), screen_buf[100 * SCREENWIDTH + 9]);
}
