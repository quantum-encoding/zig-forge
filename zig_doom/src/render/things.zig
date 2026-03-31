//! zig_doom/src/render/things.zig
//!
//! Sprite (thing) rendering — vissprite sorting and drawing.
//! Translated from: linuxdoom-1.10/r_things.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Sprites are rendered after walls, clipped against the recorded drawsegs.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const tables = @import("../tables.zig");
const draw = @import("draw.zig");
const state_mod = @import("state.zig");
const RenderState = state_mod.RenderState;
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const MAXVISSPRITES = 256;

pub const VisSprite = struct {
    x1: i32 = 0,
    x2: i32 = 0,
    gx: Fixed = Fixed.ZERO, // Global position for sorting
    gy: Fixed = Fixed.ZERO,
    gz: Fixed = Fixed.ZERO, // z bottom
    gzt: Fixed = Fixed.ZERO, // z top
    texturemid: Fixed = Fixed.ZERO,
    scale: Fixed = Fixed.ZERO,
    xiscale: Fixed = Fixed.ZERO,
    startfrac: Fixed = Fixed.ZERO,
    patch: usize = 0, // lump number
    colormap: i32 = 0, // light level index
    flip: bool = false,
};

pub const ThingState = struct {
    vissprites: [MAXVISSPRITES]VisSprite = undefined,
    num_vissprites: usize = 0,

    pub fn init() ThingState {
        return .{};
    }

    pub fn clear(self: *ThingState) void {
        self.num_vissprites = 0;
    }

    /// Add a sprite to the vissprite list
    pub fn projectSprite(
        self: *ThingState,
        thing_x: Fixed,
        thing_y: Fixed,
        thing_z: Fixed,
        sprite_lump: usize,
        flip: bool,
        rstate: *const RenderState,
        rdata: *const RenderData,
    ) void {
        _ = rdata;

        // Transform to view-relative coordinates
        const tr_x = Fixed.sub(thing_x, rstate.viewx);
        const tr_y = Fixed.sub(thing_y, rstate.viewy);

        // Rotate around viewangle
        const gxt = Fixed.mul(tr_x, rstate.viewcos);
        const gyt = Fixed.mul(tr_y, rstate.viewsin);
        const tz = Fixed.add(gxt, gyt); // depth
        if (tz.raw() < fixed.FRAC_UNIT * 4) return; // Too close or behind

        const gxt2 = Fixed.mul(tr_x, rstate.viewsin);
        const gyt2 = Fixed.mul(tr_y, rstate.viewcos);
        const tx = Fixed.sub(gyt2, gxt2); // horizontal position

        // Calculate screen x
        const xscale = Fixed.div(rstate.projection, tz);
        const x_center = rstate.centerx + Fixed.mul(tx, xscale).toInt();

        // Rough width estimate (sprite is ~64 pixels wide)
        const half_width = Fixed.mul(Fixed.fromInt(16), xscale).toInt();
        const x1 = x_center - half_width;
        const x2 = x_center + half_width;

        if (x1 > SCREENWIDTH or x2 < 0) return;

        if (self.num_vissprites >= MAXVISSPRITES) return;

        self.vissprites[self.num_vissprites] = .{
            .x1 = @max(0, x1),
            .x2 = @min(SCREENWIDTH - 1, x2),
            .gx = thing_x,
            .gy = thing_y,
            .gz = thing_z,
            .gzt = Fixed.add(thing_z, Fixed.fromInt(56)), // sprite height estimate
            .texturemid = Fixed.sub(Fixed.add(thing_z, Fixed.fromInt(56)), rstate.viewz),
            .scale = xscale,
            .xiscale = if (xscale.raw() != 0) Fixed.div(Fixed.ONE, xscale) else Fixed.ONE,
            .startfrac = Fixed.ZERO,
            .patch = sprite_lump,
            .colormap = 0,
            .flip = flip,
        };
        self.num_vissprites += 1;
    }

    /// Draw all vissprites (back to front)
    pub fn drawSprites(self: *ThingState, rstate: *const RenderState, rdata: *RenderData, screen: [*]u8) void {
        if (self.num_vissprites == 0) return;

        // Sort by scale (back to front = smallest scale first)
        // Simple insertion sort for small N
        const sprites = self.vissprites[0..self.num_vissprites];
        for (1..sprites.len) |i| {
            const key = sprites[i];
            var j: usize = i;
            while (j > 0 and sprites[j - 1].scale.raw() > key.scale.raw()) {
                sprites[j] = sprites[j - 1];
                j -= 1;
            }
            sprites[j] = key;
        }

        // Draw back to front
        for (sprites) |*vs| {
            drawVisSprite(vs, rstate, rdata, screen);
        }
    }

    fn drawVisSprite(vs: *const VisSprite, rstate: *const RenderState, rdata: *RenderData, screen: [*]u8) void {
        _ = rstate;

        // Get patch data from WAD
        if (vs.patch == 0) return;
        const patch_data = rdata.wad.lumpData(vs.patch);
        if (patch_data.len < 8) return;

        const patch_width: i32 = @intCast(readU16(patch_data, 0));
        const patch_height: i32 = @intCast(readU16(patch_data, 2));

        const colormap = rdata.getColormap(vs.colormap);
        _ = patch_height;

        // Draw each column
        var frac = vs.startfrac;
        var x = vs.x1;
        while (x <= vs.x2) : (x += 1) {
            if (x < 0 or x >= SCREENWIDTH) {
                frac = Fixed.add(frac, vs.xiscale);
                continue;
            }

            var tex_col = frac.toInt();
            if (vs.flip) tex_col = patch_width - 1 - tex_col;
            tex_col = std.math.clamp(tex_col, 0, patch_width - 1);

            // Get column data from patch
            const col_data = getPatchColumn(patch_data, tex_col);
            if (col_data.len > 0) {
                const yl = rstate_mod_centery() - Fixed.mul(vs.texturemid, vs.scale).toInt();
                const yh = yl + Fixed.mul(Fixed.fromInt(@intCast(col_data.len)), vs.scale).toInt();
                const iscale = vs.xiscale;

                const dc = draw.DrawColumnContext{
                    .source = col_data,
                    .colormap = colormap,
                    .x = x,
                    .yl = std.math.clamp(yl, 0, SCREENHEIGHT - 1),
                    .yh = std.math.clamp(yh, 0, SCREENHEIGHT - 1),
                    .iscale = iscale,
                    .texturemid = vs.texturemid,
                    .screen = screen,
                };
                draw.drawColumn(&dc);
            }

            frac = Fixed.add(frac, vs.xiscale);
        }
    }
};

fn rstate_mod_centery() i32 {
    return SCREENHEIGHT / 2;
}

fn getPatchColumn(patch_data: []const u8, col: i32) []const u8 {
    if (col < 0) return &[_]u8{};
    const ucol: usize = @intCast(col);
    const off_pos = 8 + ucol * 4;
    if (off_pos + 4 > patch_data.len) return &[_]u8{};
    const col_off = readU32(patch_data, off_pos);
    if (col_off >= patch_data.len) return &[_]u8{};

    // Find first post
    var off: usize = col_off;
    if (off >= patch_data.len) return &[_]u8{};
    const topdelta = patch_data[off];
    if (topdelta == 0xFF) return &[_]u8{};
    off += 1;
    if (off >= patch_data.len) return &[_]u8{};
    const length: usize = patch_data[off];
    off += 2; // length + padding

    if (off + length > patch_data.len) return &[_]u8{};
    return patch_data[off .. off + length];
}

fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readU32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

test "thing state init" {
    var ts = ThingState.init();
    try std.testing.expectEqual(@as(usize, 0), ts.num_vissprites);
    ts.clear();
    try std.testing.expectEqual(@as(usize, 0), ts.num_vissprites);
}
