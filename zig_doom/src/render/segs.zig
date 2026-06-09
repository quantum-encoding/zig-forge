//! zig_doom/src/render/segs.zig
//!
//! Wall segment rendering — the core of DOOM's wall drawing.
//! Translated from: linuxdoom-1.10/r_segs.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Each seg (wall segment) is projected to screen columns and drawn with
//! appropriate textures (upper, lower, mid), while marking floor/ceiling
//! visplane columns.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const tables = @import("../tables.zig");
const defs = @import("../defs.zig");
const setup = @import("../play/setup.zig");
const state_mod = @import("state.zig");
const RenderState = state_mod.RenderState;
const draw = @import("draw.zig");
const planes = @import("planes.zig");
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;

const centerx_i: i32 = SCREENWIDTH / 2;

/// atan(num/den) as a binary angle, for 0 <= num <= den (result in 0..ANG45).
fn atanSlope(num: u32, den: u32) Angle {
    if (den == 0) return fixed.ANG90;
    if (num >= den) return fixed.ANG45;
    const idx = @min((num << 11) / den, 2048);
    return tables.tantoangle[idx];
}

/// View angle of screen column x relative to view center (DOOM xtoviewangle[x]).
/// Columns left of center yield a positive angle, right of center negative.
fn xToViewAngle(x: i32) Angle {
    const dx = centerx_i - x;
    if (dx == 0) return 0;
    const adx: u32 = @intCast(if (dx < 0) -dx else dx);
    const a = atanSlope(adx, @intCast(centerx_i));
    return if (dx > 0) a else 0 -% a;
}

/// tan(angle) using this codebase's finetangent convention:
/// finetangent[i] = tan((2048.5 - i)*pi/4096), so i = 2048 - (signed_angle >> 19).
fn fineTan(angle: Angle) Fixed {
    const s: i32 = @bitCast(angle);
    var i: i32 = 2048 - (s >> tables.ANGLETOFINESHIFT);
    if (i < 0) i = 0;
    if (i > 4095) i = 4095;
    return tables.finetangent[@intCast(i)];
}

/// Render a wall segment from screen column x1 to x2
pub fn renderSeg(
    seg_idx: u16,
    x1: i32,
    x2: i32,
    rw_angle1: Angle,
    level: *const setup.Level,
    rstate: *RenderState,
    pstate: *planes.PlaneState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    if (x1 > x2) return;
    if (seg_idx >= level.segs.len) return;

    const seg = &level.segs[seg_idx];
    const line = &level.lines[seg.linedef];
    const side = &level.sides[seg.sidedef];

    const front_idx = seg.frontsector orelse return;
    if (front_idx >= level.sectors.len) return;
    const frontsector = &level.sectors[front_idx];

    var backsector: ?*const setup.Sector = null;
    if (seg.backsector) |back_idx| {
        if (back_idx < level.sectors.len) {
            backsector = &level.sectors[back_idx];
        }
    }

    // Perpendicular distance from the viewpoint to the seg's line.
    // (linuxdoom-1.10 r_segs.c R_StoreWallRange)
    //
    //   offsetangle = abs(rw_normalangle - rw_angle1), clamped to ANG90
    //   distangle   = ANG90 - offsetangle
    //   rw_distance = hyp * sin(distangle)   ==  hyp * cos(offsetangle)
    //
    // The previous code used sin(offsetangle) directly (sin where it needed
    // cos), which over-estimates the distance for any wall not at exactly 45°
    // off-normal — collapsing walls into a thin band at the horizon.
    const rw_normalangle = seg.angle +% fixed.ANG90;
    const dnorm = rw_normalangle -% rw_angle1; // signed (wrapping) normal-to-vertex angle
    var offsetangle = dnorm;
    if (offsetangle > fixed.ANG180) offsetangle = 0 -% offsetangle; // abs() in angle space
    if (offsetangle > fixed.ANG90) offsetangle = fixed.ANG90; // clamp
    const distangle = fixed.ANG90 -% offsetangle;

    const v1 = &level.vertices[seg.v1];
    const hyp = distToPoint(rstate.viewx, rstate.viewy, v1.x, v1.y);
    const sineval = tables.sinAngle(distangle);
    const rw_distance = Fixed.mul(hyp, sineval);
    const rw_distance_abs = if (rw_distance.raw() > 0) rw_distance else Fixed.fromRaw(1);

    // Perpendicular texture offset along the wall: hyp * sin(offsetangle),
    // signed by which side of the normal the first vertex lies on. (r_segs.c)
    var rw_offset_perp = Fixed.mul(hyp, tables.sinAngle(offsetangle));
    if (dnorm < fixed.ANG180) rw_offset_perp = Fixed.fromRaw(-rw_offset_perp.raw());

    // Angle from the wall normal to screen-center; per column we add
    // xtoviewangle[x] to get that column's angle off the wall normal.
    const rw_centerangle = fixed.ANG90 +% rstate.viewangle -% rw_normalangle;

    // Calculate scale at x1 and x2
    const rw_scale = state_mod.scaleFromGlobalAngle(rstate, rw_angle1, rw_distance_abs, rw_normalangle);

    var rw_scalestep = Fixed.ZERO;
    var scale2 = rw_scale;
    if (x2 > x1) {
        // visangle for the seg's far edge is the global angle to vertex 2.
        // (Previously this passed end_angle + viewangle == 2*viewangle - angle_v2,
        // which is not a real view angle and skewed the per-column scale ramp.)
        const angle_v2 = state_mod.pointToAngle2(
            rstate.viewx,
            rstate.viewy,
            level.vertices[seg.v2].x,
            level.vertices[seg.v2].y,
        );
        scale2 = state_mod.scaleFromGlobalAngle(rstate, angle_v2, rw_distance_abs, rw_normalangle);
        rw_scalestep = Fixed.fromRaw(@divTrunc(scale2.raw() - rw_scale.raw(), x2 - x1));
    }

    // Calculate texture boundaries
    const worldtop = Fixed.sub(frontsector.ceilingheight, rstate.viewz);
    const worldbottom = Fixed.sub(frontsector.floorheight, rstate.viewz);

    var worldhigh = Fixed.ZERO;
    var worldlow = Fixed.ZERO;
    var has_top = false;
    var has_bottom = false;
    const has_mid = (line.sidenum[1] < 0); // One-sided line always has mid texture

    if (backsector) |back| {
        worldhigh = Fixed.sub(back.ceilingheight, rstate.viewz);
        worldlow = Fixed.sub(back.floorheight, rstate.viewz);

        if (worldhigh.lt(worldtop)) has_top = true;
        if (worldlow.gt(worldbottom)) has_bottom = true;
    }

    // Texture horizontal offset: perpendicular term + sidedef + seg offsets.
    var rw_offset = rw_offset_perp;
    rw_offset = Fixed.add(rw_offset, side.textureoffset);
    rw_offset = Fixed.add(rw_offset, seg.offset);

    const texturemid = Fixed.add(worldtop, side.rowoffset);

    // Check for visplane updates
    if (pstate.floorplane) |fp| {
        const checked = pstate.checkPlane(fp, x1, x2);
        pstate.floorplane = checked;
    }
    if (pstate.ceilingplane) |cp| {
        const checked = pstate.checkPlane(cp, x1, x2);
        pstate.ceilingplane = checked;
    }

    // Get texture data
    const mid_tex: i16 = side.midtexture;
    const top_tex: i16 = side.toptexture;
    const bot_tex: i16 = side.bottomtexture;

    // Light level
    const lightlevel = frontsector.lightlevel;

    // Render each column
    var curscale = rw_scale;
    var x = x1;
    while (x <= x2) : (x += 1) {
        if (x < 0 or x >= SCREENWIDTH) {
            curscale = Fixed.add(curscale, rw_scalestep);
            continue;
        }
        const ux: usize = @intCast(x);

        // Calculate ceiling and floor for this column
        const scale_val = curscale;
        if (scale_val.raw() <= 0) {
            curscale = Fixed.add(curscale, rw_scalestep);
            continue;
        }

        // Perspective-correct texture column for this screen column:
        //   texcol = (rw_offset - tan(centerangle + xtoviewangle[x]) * rw_distance) >> FRACBITS
        const colangle = rw_centerangle +% xToViewAngle(x);
        const tex_col = Fixed.sub(rw_offset, Fixed.mul(fineTan(colangle), rw_distance_abs)).toInt();

        // Top of wall (ceiling line on screen)
        const ceilingline = rstate.centery - Fixed.mul(worldtop, scale_val).toInt();
        // Bottom of wall (floor line on screen)
        const floorline = rstate.centery - Fixed.mul(worldbottom, scale_val).toInt();

        // Clip to ceiling/floor clip arrays
        var yl = ceilingline;
        if (yl < rstate.ceilingclip[ux] + 1) yl = rstate.ceilingclip[ux] + 1;
        var yh = floorline;
        if (yh > rstate.floorclip[ux] - 1) yh = rstate.floorclip[ux] - 1;

        // Mark ceiling visplane
        if (pstate.ceilingplane) |cp| {
            const ceil_top = rstate.ceilingclip[ux] + 1;
            const ceil_bot = @min(ceilingline - 1, rstate.floorclip[ux] - 1);
            if (ceil_top <= ceil_bot and cp < pstate.num_visplanes) {
                const vp = &pstate.visplanes[cp];
                const top_u16: u16 = @intCast(std.math.clamp(ceil_top, 0, SCREENHEIGHT - 1));
                const bot_u16: u16 = @intCast(std.math.clamp(ceil_bot, 0, SCREENHEIGHT - 1));
                vp.top[ux] = top_u16;
                vp.bottom[ux] = bot_u16;
            }
        }

        // Mark floor visplane
        if (pstate.floorplane) |fp| {
            const floor_top = @max(floorline + 1, rstate.ceilingclip[ux] + 1);
            const floor_bot = rstate.floorclip[ux] - 1;
            if (floor_top <= floor_bot and fp < pstate.num_visplanes) {
                const vp = &pstate.visplanes[fp];
                const top_u16: u16 = @intCast(std.math.clamp(floor_top, 0, SCREENHEIGHT - 1));
                const bot_u16: u16 = @intCast(std.math.clamp(floor_bot, 0, SCREENHEIGHT - 1));
                vp.top[ux] = top_u16;
                vp.bottom[ux] = bot_u16;
            }
        }

        if (backsector) |back| {
            // Two-sided line

            // Upper texture (ceiling step down)
            if (has_top and top_tex > 0) {
                const high_line = rstate.centery - Fixed.mul(worldhigh, scale_val).toInt();
                const top_yh = @min(high_line - 1, yh);
                if (yl <= top_yh) {
                    drawWallColumn(rdata, screen, @intCast(top_tex), x, yl, top_yh, scale_val, texturemid, tex_col, seg, rstate, lightlevel);
                }
                // Update clip
                if (high_line > rstate.ceilingclip[ux]) {
                    rstate.ceilingclip[ux] = @intCast(std.math.clamp(high_line, 0, SCREENHEIGHT));
                }
            }

            // Lower texture (floor step up)
            if (has_bottom and bot_tex > 0) {
                const low_line = rstate.centery - Fixed.mul(worldlow, scale_val).toInt();
                const bot_yl = @max(low_line, yl);
                if (bot_yl <= yh) {
                    const bottexmid = Fixed.add(worldlow, side.rowoffset);
                    drawWallColumn(rdata, screen, @intCast(bot_tex), x, bot_yl, yh, scale_val, bottexmid, tex_col, seg, rstate, lightlevel);
                }
                // Update clip
                if (low_line < rstate.floorclip[ux]) {
                    rstate.floorclip[ux] = @intCast(std.math.clamp(low_line, 0, SCREENHEIGHT));
                }
            }

            // If the line has no top or bottom gap, close off the clips
            _ = back;
        } else {
            // One-sided line — draw mid texture, close off column
            if (has_mid and mid_tex > 0 and yl <= yh) {
                drawWallColumn(rdata, screen, @intCast(mid_tex), x, yl, yh, scale_val, texturemid, tex_col, seg, rstate, lightlevel);
            }

            // One-sided line fully occludes
            rstate.ceilingclip[ux] = @intCast(SCREENHEIGHT);
            rstate.floorclip[ux] = -1;
        }

        curscale = Fixed.add(curscale, rw_scalestep);
    }
}

/// Draw a single wall texture column
fn drawWallColumn(
    rdata: *RenderData,
    screen: [*]u8,
    tex_num: usize,
    x: i32,
    yl: i32,
    yh: i32,
    scale: Fixed,
    texturemid: Fixed,
    tex_col: i32,
    seg: *const setup.Seg,
    rstate: *const RenderState,
    lightlevel: i16,
) void {
    _ = seg;
    _ = rstate;
    if (yl > yh) return;
    if (yl >= SCREENHEIGHT or yh < 0) return;

    // Get texture column data (tex_col is the perspective-correct column
    // computed per screen column by the caller; getTextureColumn masks it
    // to the texture width).
    const col_data = rdata.getTextureColumn(tex_num, tex_col);
    if (col_data.len == 0) return;

    // Get colormap for this light level and distance
    const light_idx = RenderData.lightIndex(lightlevel, scale);
    const colormap = rdata.getColormap(light_idx);

    // Compute inverse scale for texel stepping
    const iscale = if (scale.raw() != 0) Fixed.div(Fixed.ONE, scale) else Fixed.ONE;

    const clipped_yl = std.math.clamp(yl, 0, SCREENHEIGHT - 1);
    const clipped_yh = std.math.clamp(yh, 0, SCREENHEIGHT - 1);

    const dc = draw.DrawColumnContext{
        .source = col_data,
        .colormap = colormap,
        .x = x,
        .yl = clipped_yl,
        .yh = clipped_yh,
        .iscale = iscale,
        .texturemid = texturemid,
        .screen = screen,
    };

    draw.drawColumn(&dc);
}

/// Distance from point to point
fn distToPoint(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Fixed {
    const dx = Fixed.abs(Fixed.sub(x2, x1));
    const dy = Fixed.abs(Fixed.sub(y2, y1));
    // Approximate: max(dx,dy) + min(dx,dy)/2
    if (dx.gt(dy)) {
        return Fixed.add(dx, Fixed.fromRaw(@divTrunc(dy.raw(), 2)));
    }
    return Fixed.add(dy, Fixed.fromRaw(@divTrunc(dx.raw(), 2)));
}

test "distToPoint" {
    const d = distToPoint(Fixed.fromInt(0), Fixed.fromInt(0), Fixed.fromInt(3), Fixed.fromInt(4));
    // Approximate distance should be roughly 5 (3+4/2=5 or 4+3/2=5.5)
    try std.testing.expect(d.toInt() >= 4 and d.toInt() <= 6);
}
