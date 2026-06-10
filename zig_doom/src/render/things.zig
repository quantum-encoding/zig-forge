//! zig_doom/src/render/things.zig
//!
//! Sprite (thing) rendering — vissprite projection, sorting, drawseg
//! clipping, masked mid textures, and player weapon sprites.
//! Translated from: linuxdoom-1.10/r_things.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Order per frame (R_DrawMasked): sort vissprites by scale and draw back to
//! front (each clipped against the drawsegs in front of it, drawing any
//! masked mid textures that lie behind it first), then the remaining masked
//! mid textures, then the player's weapon sprites on top.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const info = @import("../info.zig");
const tables = @import("../tables.zig");
const setup = @import("../play/setup.zig");
const user = @import("../play/user.zig");
const draw = @import("draw.zig");
const segs = @import("segs.zig");
const state_mod = @import("state.zig");
const RenderState = state_mod.RenderState;
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const MAXVISSPRITES = 256;

/// Things closer than this projected distance are not drawn (player's own body)
const MINZ: i32 = 4 * (1 << fixed.FRAC_BITS);
const BASEYCENTER: i32 = 100; // vanilla psprite coordinate origin

/// Weapon sprites are positioned for vanilla's 168-line view window (the
/// status bar overdraws the bottom 32 lines), so their vertical center is
/// (SCREENHEIGHT - 32) / 2 — not the full-screen centery.
const PSPRITE_CENTERY: i32 = (SCREENHEIGHT - 32) / 2;

pub const VisSprite = struct {
    x1: i32 = 0,
    x2: i32 = 0,
    gx: Fixed = Fixed.ZERO, // Global position (for drawseg side tests)
    gy: Fixed = Fixed.ZERO,
    gz: Fixed = Fixed.ZERO, // World z bottom
    gzt: Fixed = Fixed.ZERO, // World z top
    texturemid: Fixed = Fixed.ZERO,
    scale: Fixed = Fixed.ZERO,
    xiscale: Fixed = Fixed.ZERO, // Negative when flipped
    startfrac: Fixed = Fixed.ZERO,
    patch: usize = 0, // Sprite lump number
    lightlevel: i16 = 255,
    fullbright: bool = false,
    shadow: bool = false, // MF_SHADOW → fuzz effect
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

    /// Project one map object into a vissprite (R_ProjectSprite).
    pub fn projectSprite(
        self: *ThingState,
        thing_x: Fixed,
        thing_y: Fixed,
        thing_z: Fixed,
        thing_angle: Angle,
        sprite: info.SpriteNum,
        frame_bits: i32,
        flags: u32,
        sector_light: i16,
        rstate: *const RenderState,
        rdata: *const RenderData,
    ) void {
        // Transform the origin point to view space
        const tr_x = Fixed.sub(thing_x, rstate.viewx);
        const tr_y = Fixed.sub(thing_y, rstate.viewy);

        // Depth along the view direction
        const tz = Fixed.add(Fixed.mul(tr_x, rstate.viewcos), Fixed.mul(tr_y, rstate.viewsin));
        if (tz.raw() < MINZ) return; // Behind or too close

        const xscale = Fixed.div(rstate.projection, tz);

        // Horizontal offset across the view (positive = right of center)
        var tx = Fixed.sub(Fixed.mul(tr_x, rstate.viewsin), Fixed.mul(tr_y, rstate.viewcos));

        // Too far off the side?
        if (Fixed.abs(tx).raw() > (tz.raw() << 2)) return;

        // Sprite definition lookup: frame + rotation
        const snum = @intFromEnum(sprite);
        if (snum >= rdata.spritedefs.len) return;
        const sd = &rdata.spritedefs[snum];
        const fr: usize = @intCast(frame_bits & info.FF_FRAMEMASK);
        if (fr >= sd.frames.len) return;
        const sf = &sd.frames[fr];

        var lump: usize = 0;
        var flip = false;
        if (sf.rotate) {
            // Choose rotation based on the angle from the viewpoint to the thing
            const ang = rstate.pointToAngle(thing_x, thing_y);
            const rot: usize = @intCast((ang -% thing_angle +% @as(u32, 0x90000000)) >> 29);
            lump = sf.lump[rot & 7];
            flip = sf.flip[rot & 7];
        } else {
            lump = sf.lump[0];
            flip = sf.flip[0];
        }
        if (lump == 0) return;

        const pi = rdata.getPatchInfo(lump);
        if (pi.width <= 0) return;

        // Horizontal screen extent
        tx = Fixed.sub(tx, Fixed.fromInt(pi.leftoffset));
        const x1_fr = @as(i64, rstate.centerxfrac.raw()) + (@as(i64, tx.raw()) * @as(i64, xscale.raw()) >> 16);
        const x1: i32 = @intCast(std.math.clamp(x1_fr >> 16, -32768, 32767));
        if (x1 > SCREENWIDTH - 1) return;

        tx = Fixed.add(tx, Fixed.fromInt(pi.width));
        const x2_fr = @as(i64, rstate.centerxfrac.raw()) + (@as(i64, tx.raw()) * @as(i64, xscale.raw()) >> 16);
        const x2: i32 = @intCast(std.math.clamp((x2_fr >> 16) - 1, -32768, 32767));
        if (x2 < 0) return;

        if (self.num_vissprites >= MAXVISSPRITES) return;
        const vis = &self.vissprites[self.num_vissprites];
        self.num_vissprites += 1;

        const gzt = Fixed.add(thing_z, Fixed.fromInt(pi.topoffset));
        const iscale = if (xscale.raw() != 0) Fixed.div(Fixed.ONE, xscale) else Fixed.ONE;

        vis.* = .{
            .gx = thing_x,
            .gy = thing_y,
            .gz = thing_z,
            .gzt = gzt,
            .texturemid = Fixed.sub(gzt, rstate.viewz),
            .x1 = if (x1 < 0) 0 else x1,
            .x2 = if (x2 >= SCREENWIDTH) SCREENWIDTH - 1 else x2,
            .scale = xscale,
            .patch = lump,
            .lightlevel = sector_light,
            .fullbright = (frame_bits & info.FF_FULLBRIGHT) != 0,
            .shadow = (flags & info.MF_SHADOW) != 0,
            .xiscale = if (flip) Fixed.fromRaw(-iscale.raw()) else iscale,
            .startfrac = if (flip)
                Fixed.fromRaw((@as(i32, @intCast(pi.width)) << 16) - 1)
            else
                Fixed.ZERO,
        };
        if (x1 < 0) {
            // Left-clipped: advance the texture start
            vis.startfrac = Fixed.fromRaw(vis.startfrac.raw() +% vis.xiscale.raw() *% (-x1));
        }
    }

    /// Sort vissprites far-to-near (smallest scale first) and draw them all,
    /// then the leftover masked mid textures (R_DrawMasked, minus psprites —
    /// the caller draws those via drawPlayerSprites so it can supply the
    /// player).
    pub fn drawMasked(
        self: *ThingState,
        level: *const setup.Level,
        rstate: *RenderState,
        rdata: *RenderData,
        screen: [*]u8,
    ) void {
        // Insertion sort by scale, ascending (back to front)
        const sprites = self.vissprites[0..self.num_vissprites];
        var i: usize = 1;
        while (i < sprites.len) : (i += 1) {
            const key = sprites[i];
            var j: usize = i;
            while (j > 0 and sprites[j - 1].scale.raw() > key.scale.raw()) {
                sprites[j] = sprites[j - 1];
                j -= 1;
            }
            sprites[j] = key;
        }

        for (sprites) |*vs| {
            drawSprite(vs, level, rstate, rdata, screen);
        }

        // Render any remaining masked mid textures, near to far
        var d = rstate.num_drawsegs;
        while (d > 0) {
            d -= 1;
            const ds = &rstate.drawsegs[d];
            if (ds.maskedtexturecol != null) {
                segs.renderMaskedSegRange(ds, ds.x1, ds.x2, level, rstate, rdata, screen);
            }
        }
    }
};

/// Draw one vissprite, clipped against all drawsegs in front of it
/// (R_DrawSprite). Masked mid textures behind the sprite are rendered first.
fn drawSprite(
    spr: *const VisSprite,
    level: *const setup.Level,
    rstate: *RenderState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    var clipbot: [SCREENWIDTH]i16 = undefined;
    var cliptop: [SCREENWIDTH]i16 = undefined;
    var x = spr.x1;
    while (x <= spr.x2) : (x += 1) {
        clipbot[@intCast(x)] = -2;
        cliptop[@intCast(x)] = -2;
    }

    // Scan drawsegs from nearest to farthest; the ones in front of the
    // sprite clip it, the masked ones behind it get drawn now.
    var d = rstate.num_drawsegs;
    while (d > 0) {
        d -= 1;
        const ds = &rstate.drawsegs[d];

        if (ds.x1 > spr.x2 or ds.x2 < spr.x1) continue;
        if (ds.silhouette == state_mod.SIL_NONE and ds.maskedtexturecol == null) continue;

        const r1 = if (ds.x1 < spr.x1) spr.x1 else ds.x1;
        const r2 = if (ds.x2 > spr.x2) spr.x2 else ds.x2;

        var lowscale: Fixed = undefined;
        var scale: Fixed = undefined;
        if (ds.scale1.raw() > ds.scale2.raw()) {
            lowscale = ds.scale2;
            scale = ds.scale1;
        } else {
            lowscale = ds.scale1;
            scale = ds.scale2;
        }

        if (scale.raw() < spr.scale.raw() or
            (lowscale.raw() < spr.scale.raw() and !pointOnSegSide(spr.gx, spr.gy, level, ds.curline)))
        {
            // Seg is behind the sprite: draw its masked mid texture now
            if (ds.maskedtexturecol != null) {
                segs.renderMaskedSegRange(ds, r1, r2, level, rstate, rdata, screen);
            }
            continue;
        }

        // Seg is in front: clip the sprite by the seg's silhouette
        var sil = ds.silhouette;
        if (spr.gz.ge(ds.bsilheight)) sil &= ~@as(u32, state_mod.SIL_BOTTOM);
        if (spr.gzt.le(ds.tsilheight)) sil &= ~@as(u32, state_mod.SIL_TOP);

        if (sil != 0) {
            var cx = r1;
            while (cx <= r2) : (cx += 1) {
                const ux: usize = @intCast(cx);
                if (sil & state_mod.SIL_BOTTOM != 0 and clipbot[ux] == -2) {
                    clipbot[ux] = @intCast(std.math.clamp(segs.drawSegClipValue(rstate, ds, ds.sprbottomclip, cx, SCREENHEIGHT), -1, SCREENHEIGHT));
                }
                if (sil & state_mod.SIL_TOP != 0 and cliptop[ux] == -2) {
                    cliptop[ux] = @intCast(std.math.clamp(segs.drawSegClipValue(rstate, ds, ds.sprtopclip, cx, -1), -1, SCREENHEIGHT));
                }
            }
        }
    }

    // Columns with no clipping get the full screen
    x = spr.x1;
    while (x <= spr.x2) : (x += 1) {
        const ux: usize = @intCast(x);
        if (clipbot[ux] == -2) clipbot[ux] = @intCast(SCREENHEIGHT);
        if (cliptop[ux] == -2) cliptop[ux] = -1;
    }

    drawVisSprite(spr, &cliptop, &clipbot, rstate.centery, rdata, screen);
}

/// Draw the columns of a vissprite (R_DrawVisSprite).
fn drawVisSprite(
    vs: *const VisSprite,
    cliptop: *const [SCREENWIDTH]i16,
    clipbot: *const [SCREENWIDTH]i16,
    centery: i32,
    rdata: *const RenderData,
    screen: [*]u8,
) void {
    if (vs.patch == 0) return;
    const pi = rdata.getPatchInfo(vs.patch);
    if (pi.width <= 0) return;

    // Fullbright frames ignore light diminishing; shadow draws as fuzz
    // through the dark colormap (vanilla uses colormap 6 for fuzz).
    const colormap = if (vs.shadow)
        rdata.getColormap(6)
    else if (vs.fullbright)
        rdata.getColormap(0)
    else
        rdata.getColormap(RenderData.lightIndex(vs.lightlevel, vs.scale));

    const iscale = Fixed.abs(vs.xiscale);
    const sprtopscreen = Fixed.sub(Fixed.fromInt(centery), Fixed.mul(vs.texturemid, vs.scale));

    var frac = vs.startfrac;
    var x = vs.x1;
    while (x <= vs.x2) : (x += 1) {
        const ux: usize = @intCast(x);
        const tex_col = frac.raw() >> 16;
        if (tex_col >= 0 and tex_col < pi.width) {
            const posts = rdata.getPatchColumnPosts(vs.patch, tex_col);
            if (posts.len > 0) {
                draw.drawMaskedColumnStyle(
                    screen,
                    x,
                    posts,
                    colormap,
                    vs.scale,
                    sprtopscreen,
                    vs.texturemid,
                    iscale,
                    @intCast(cliptop[ux]),
                    @intCast(clipbot[ux]),
                    centery,
                    if (vs.shadow) .fuzz else .normal,
                );
            }
        }
        frac = Fixed.fromRaw(frac.raw() +% vs.xiscale.raw());
    }
}

/// Draw the player's weapon sprites (R_DrawPlayerSprites). Drawn last, on
/// top of everything, unclipped by the world.
pub fn drawPlayerSprites(
    player: *const user.Player,
    sector_light: i16,
    rstate: *const RenderState,
    rdata: *const RenderData,
    screen: [*]u8,
) void {
    for (&player.psprites) |*psp| {
        const st = psp.state orelse continue;

        const snum = @intFromEnum(st.sprite);
        if (snum >= rdata.spritedefs.len) continue;
        const sd = &rdata.spritedefs[snum];
        const fr: usize = @intCast(st.frame & info.FF_FRAMEMASK);
        if (fr >= sd.frames.len) continue;
        const sf = &sd.frames[fr];
        const lump = sf.lump[0];
        if (lump == 0) continue;
        const flip = sf.flip[0];

        const pi = rdata.getPatchInfo(lump);
        if (pi.width <= 0) continue;

        // Horizontal: psp->sx is centered around 160 (screen center)
        var tx = Fixed.sub(psp.sx, Fixed.fromInt(SCREENWIDTH / 2));
        tx = Fixed.sub(tx, Fixed.fromInt(pi.leftoffset));
        const x1: i32 = rstate.centerx + (tx.raw() >> 16);
        if (x1 > SCREENWIDTH - 1) continue;
        const x2: i32 = x1 + pi.width - 1;
        if (x2 < 0) continue;

        // Vertical: psp->sy from the weapon bob/raise state machine
        const texturemid = Fixed.sub(
            Fixed.add(Fixed.fromInt(BASEYCENTER), Fixed.fromRaw(1 << 15)),
            Fixed.sub(psp.sy, Fixed.fromInt(pi.topoffset)),
        );

        var vis = VisSprite{
            .x1 = if (x1 < 0) 0 else x1,
            .x2 = if (x2 >= SCREENWIDTH) SCREENWIDTH - 1 else x2,
            .texturemid = texturemid,
            .scale = Fixed.ONE, // pspritescale at 320-wide
            .patch = lump,
            .lightlevel = sector_light,
            .fullbright = (st.frame & info.FF_FULLBRIGHT) != 0,
            .xiscale = if (flip) Fixed.fromRaw(-(1 << 16)) else Fixed.fromRaw(1 << 16),
            .startfrac = if (flip) Fixed.fromRaw((pi.width << 16) - 1) else Fixed.ZERO,
        };
        if (x1 < 0) {
            vis.startfrac = Fixed.fromRaw(vis.startfrac.raw() +% vis.xiscale.raw() *% (-x1));
        }

        var cliptop: [SCREENWIDTH]i16 = undefined;
        var clipbot: [SCREENWIDTH]i16 = undefined;
        @memset(&cliptop, -1);
        @memset(&clipbot, @intCast(SCREENHEIGHT));

        drawVisSprite(&vis, &cliptop, &clipbot, PSPRITE_CENTERY, rdata, screen);
    }
}

/// Which side of a seg's line a point is on (R_PointOnSegSide).
/// Returns false for the front (right) side, true for the back side —
/// callers use it as "is the point on the back side".
fn pointOnSegSide(x: Fixed, y: Fixed, level: *const setup.Level, seg_idx: u32) bool {
    if (seg_idx >= level.segs.len) return false;
    const seg = &level.segs[seg_idx];
    const v1 = &level.vertices[seg.v1];
    const v2 = &level.vertices[seg.v2];

    const ldx: i64 = v2.x.raw() - v1.x.raw();
    const ldy: i64 = v2.y.raw() - v1.y.raw();
    const dx: i64 = x.raw() - v1.x.raw();
    const dy: i64 = y.raw() - v1.y.raw();

    const left: i64 = ldy * dx;
    const right: i64 = dy * ldx;
    return right >= left; // back side
}

test "thing state init" {
    var ts = ThingState.init();
    try std.testing.expectEqual(@as(usize, 0), ts.num_vissprites);
    ts.clear();
    try std.testing.expectEqual(@as(usize, 0), ts.num_vissprites);
}
