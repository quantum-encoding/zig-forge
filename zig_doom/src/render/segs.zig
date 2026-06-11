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

/// tan(angle) for a signed view-relative angle using the VANILLA table:
/// finetangent[i] = tan((i - 2048 + 0.5)*pi/4096), so i = 2048 + (angle >> 19).
fn fineTan(angle: Angle) Fixed {
    const s: i32 = @bitCast(angle);
    var i: i32 = 2048 + (s >> tables.ANGLETOFINESHIFT);
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
    //
    // NOTE: vanilla writes ANG90 + viewangle - rw_normalangle and indexes
    // finetangent[] directly, but vanilla's finetangent[a>>19] equals
    // tan(a - 90°) — the table bakes in a -90° offset. Our fineTan(θ) is a
    // plain tan(θ), so the ANG90 must NOT be added here: with it, every
    // column sampled tan(θ+90°) = -cot(θ), which is singular at screen
    // center and scrambled texture columns across all walls.
    const rw_centerangle = rstate.viewangle -% rw_normalangle;

    // NOTE: scale is computed exactly per-column in the loop below via
    // scaleFromGlobalAngle(viewangle + xtoviewangle[x]). DOOM approximates this
    // with a linear rw_scalestep ramp, which is fine for ordinary walls but
    // diverges badly for grazing walls (scale falls off hyperbolically, not
    // linearly) — producing the over-magnified "venetian blind" smear. Exact
    // per-column scale removes that.

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

        // Sky hack: if both ceilings are sky, never draw or step the top —
        // the sky is drawn by the ceiling visplanes on both sides.
        if (frontsector.ceilingpic == pstate.skyflatnum and back.ceilingpic == pstate.skyflatnum) {
            worldhigh = worldtop;
        }

        if (worldhigh.lt(worldtop)) has_top = true;
        if (worldlow.gt(worldbottom)) has_bottom = true;
    }

    // Texture horizontal offset: perpendicular term + sidedef + seg offsets.
    var rw_offset = rw_offset_perp;
    rw_offset = Fixed.add(rw_offset, side.textureoffset);
    rw_offset = Fixed.add(rw_offset, seg.offset);

    // Texture pegging (linuxdoom-1.10 r_segs.c R_StoreWallRange):
    // mid (one-sided): pegged to ceiling, or with ML_DONTPEGBOTTOM the bottom
    //   of the texture sits on the floor.
    // upper: pegged to the back ceiling (texture hangs below it), or with
    //   ML_DONTPEGTOP pegged to the front ceiling.
    // lower: pegged to the back floor, or with ML_DONTPEGBOTTOM pegged to the
    //   front ceiling (so door tracks don't move with the door).
    const texturemid = blk: {
        if (line.flags & defs.ML_DONTPEGBOTTOM != 0 and side.midtexture > 0) {
            const texh = rdata.textureHeightFixed(@intCast(side.midtexture));
            break :blk Fixed.add(Fixed.add(worldbottom, texh), side.rowoffset);
        }
        break :blk Fixed.add(worldtop, side.rowoffset);
    };
    const toptexturemid = blk: {
        if (line.flags & defs.ML_DONTPEGTOP != 0) {
            break :blk Fixed.add(worldtop, side.rowoffset);
        }
        if (side.toptexture > 0) {
            const texh = rdata.textureHeightFixed(@intCast(side.toptexture));
            break :blk Fixed.add(Fixed.add(worldhigh, texh), side.rowoffset);
        }
        break :blk Fixed.add(worldtop, side.rowoffset);
    };
    const bottomtexturemid = blk: {
        if (line.flags & defs.ML_DONTPEGBOTTOM != 0) {
            break :blk Fixed.add(worldtop, side.rowoffset);
        }
        break :blk Fixed.add(worldlow, side.rowoffset);
    };

    // markfloor/markceiling — whether this seg terminates the front sector's
    // floor/ceiling at its columns (used for clip-array updates so farther
    // geometry and sprites get clipped correctly).
    var markfloor = true;
    var markceiling = true;
    if (backsector) |back| {
        const closed = back.ceilingheight.le(frontsector.floorheight) or
            back.floorheight.ge(frontsector.ceilingheight);
        if (!closed) {
            markfloor = worldlow.raw() != worldbottom.raw() or
                back.floorpic != frontsector.floorpic or
                back.lightlevel != frontsector.lightlevel;
            markceiling = worldhigh.raw() != worldtop.raw() or
                back.ceilingpic != frontsector.ceilingpic or
                back.lightlevel != frontsector.lightlevel;
        }
    }
    // Planes that don't exist (floor above eye / ceiling below eye) can't be marked.
    if (pstate.floorplane == null) markfloor = false;
    if (pstate.ceilingplane == null) markceiling = false;

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

    // ------------------------------------------------------------------
    // Drawseg setup (for sprite clipping + masked mid textures)
    // ------------------------------------------------------------------
    const cx1 = std.math.clamp(x1, 0, SCREENWIDTH - 1);
    const cx2 = std.math.clamp(x2, 0, SCREENWIDTH - 1);
    const range_w: usize = @intCast(cx2 - cx1 + 1);

    const masked = backsector != null and mid_tex > 0;

    var ds: ?*state_mod.DrawSeg = null;
    if (rstate.num_drawsegs < state_mod.MAXDRAWSEGS) {
        const d = &rstate.drawsegs[rstate.num_drawsegs];
        rstate.num_drawsegs += 1;
        d.* = .{
            .curline = seg_idx,
            .x1 = cx1,
            .x2 = cx2,
            .scale1 = state_mod.scaleFromGlobalAngle(rstate, rstate.viewangle +% xToViewAngle(cx1), rw_distance_abs, rw_normalangle),
            .scale2 = state_mod.scaleFromGlobalAngle(rstate, rstate.viewangle +% xToViewAngle(cx2), rw_distance_abs, rw_normalangle),
            .rw_distance = rw_distance_abs,
            .rw_normalangle = rw_normalangle,
        };

        if (backsector) |back| {
            // Silhouette flags (which sprite edges this seg can clip)
            if (frontsector.floorheight.gt(back.floorheight)) {
                d.silhouette |= state_mod.SIL_BOTTOM;
                d.bsilheight = frontsector.floorheight;
            } else if (back.floorheight.gt(rstate.viewz)) {
                d.silhouette |= state_mod.SIL_BOTTOM;
                d.bsilheight = Fixed.MAX;
            }
            if (frontsector.ceilingheight.lt(back.ceilingheight)) {
                d.silhouette |= state_mod.SIL_TOP;
                d.tsilheight = frontsector.ceilingheight;
            } else if (back.ceilingheight.lt(rstate.viewz)) {
                d.silhouette |= state_mod.SIL_TOP;
                d.tsilheight = Fixed.MIN;
            }
            if (back.ceilingheight.le(frontsector.floorheight)) {
                d.sprbottomclip = state_mod.OPENING_NEG1_BASE;
                d.bsilheight = Fixed.MAX;
                d.silhouette |= state_mod.SIL_BOTTOM;
            }
            if (back.floorheight.ge(frontsector.ceilingheight)) {
                d.sprtopclip = state_mod.OPENING_SHA_BASE;
                d.tsilheight = Fixed.MIN;
                d.silhouette |= state_mod.SIL_TOP;
            }

            // Masked mid texture: reserve a texture-column array in openings
            if (masked and rstate.lastopening + range_w <= state_mod.MAXOPENINGS) {
                d.maskedtexturecol = rstate.lastopening;
                for (rstate.openings[rstate.lastopening .. rstate.lastopening + range_w]) |*o| {
                    o.* = state_mod.MASKED_NONE;
                }
                rstate.lastopening += range_w;
            }
        } else {
            // One-sided wall: fully occludes sprites behind it
            d.silhouette = state_mod.SIL_BOTH;
            d.sprtopclip = state_mod.OPENING_SHA_BASE;
            d.sprbottomclip = state_mod.OPENING_NEG1_BASE;
            d.bsilheight = Fixed.MAX;
            d.tsilheight = Fixed.MIN;
        }
        ds = d;
    }

    // Render each column
    var x = x1;
    while (x <= x2) : (x += 1) {
        if (x < 0 or x >= SCREENWIDTH) continue;
        const ux: usize = @intCast(x);

        // Exact per-column scale (not a linear ramp). visangle for column x is
        // viewangle + xtoviewangle[x]; scaleFromGlobalAngle gives the true
        // hyperbolic falloff, so grazing walls shrink correctly with distance.
        const scale_val = state_mod.scaleFromGlobalAngle(rstate, rstate.viewangle +% xToViewAngle(x), rw_distance_abs, rw_normalangle);
        if (scale_val.raw() <= 0) continue;

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

        if (backsector != null) {
            // Two-sided line

            // Upper texture (ceiling step down)
            if (has_top and top_tex > 0) {
                const high_line = rstate.centery - Fixed.mul(worldhigh, scale_val).toInt();
                const top_yh = @min(high_line - 1, yh);
                if (yl <= top_yh) {
                    drawWallColumn(rdata, screen, @intCast(top_tex), x, yl, top_yh, scale_val, toptexturemid, tex_col, seg, rstate, lightlevel);
                    rstate.ceilingclip[ux] = @intCast(std.math.clamp(top_yh, -1, SCREENHEIGHT));
                } else {
                    rstate.ceilingclip[ux] = @intCast(std.math.clamp(yl - 1, -1, SCREENHEIGHT));
                }
            } else if (markceiling) {
                rstate.ceilingclip[ux] = @intCast(std.math.clamp(yl - 1, -1, SCREENHEIGHT));
            }

            // Lower texture (floor step up)
            if (has_bottom and bot_tex > 0) {
                const low_line = rstate.centery - Fixed.mul(worldlow, scale_val).toInt();
                const bot_yl = @max(low_line, yl);
                if (bot_yl <= yh) {
                    drawWallColumn(rdata, screen, @intCast(bot_tex), x, bot_yl, yh, scale_val, bottomtexturemid, tex_col, seg, rstate, lightlevel);
                    rstate.floorclip[ux] = @intCast(std.math.clamp(bot_yl, -1, SCREENHEIGHT));
                } else {
                    rstate.floorclip[ux] = @intCast(std.math.clamp(yh + 1, -1, SCREENHEIGHT));
                }
            } else if (markfloor) {
                rstate.floorclip[ux] = @intCast(std.math.clamp(yh + 1, -1, SCREENHEIGHT));
            }

            // Record the texture column for the masked mid texture pass
            if (ds) |d| {
                if (d.maskedtexturecol) |base| {
                    if (x >= d.x1 and x <= d.x2) {
                        const mi = base + @as(usize, @intCast(x - d.x1));
                        rstate.openings[mi] = @intCast(std.math.clamp(tex_col, -32768, 32766));
                    }
                }
            }
        } else {
            // One-sided line — draw mid texture, close off column
            if (has_mid and mid_tex > 0 and yl <= yh) {
                drawWallColumn(rdata, screen, @intCast(mid_tex), x, yl, yh, scale_val, texturemid, tex_col, seg, rstate, lightlevel);
            }

            // One-sided line fully occludes
            rstate.ceilingclip[ux] = @intCast(SCREENHEIGHT);
            rstate.floorclip[ux] = -1;
        }
    }

    // ------------------------------------------------------------------
    // Save post-render clip arrays into the drawseg for sprite clipping
    // ------------------------------------------------------------------
    if (ds) |d| {
        if ((d.silhouette & state_mod.SIL_TOP != 0 or d.maskedtexturecol != null) and d.sprtopclip == null) {
            if (rstate.lastopening + range_w <= state_mod.MAXOPENINGS) {
                const base = rstate.lastopening;
                for (0..range_w) |i| {
                    rstate.openings[base + i] = rstate.ceilingclip[@intCast(cx1 + @as(i32, @intCast(i)))];
                }
                d.sprtopclip = base;
                rstate.lastopening += range_w;
            }
        }
        if ((d.silhouette & state_mod.SIL_BOTTOM != 0 or d.maskedtexturecol != null) and d.sprbottomclip == null) {
            if (rstate.lastopening + range_w <= state_mod.MAXOPENINGS) {
                const base = rstate.lastopening;
                for (0..range_w) |i| {
                    rstate.openings[base + i] = rstate.floorclip[@intCast(cx1 + @as(i32, @intCast(i)))];
                }
                d.sprbottomclip = base;
                rstate.lastopening += range_w;
            }
        }
        // A masked mid texture acts as a full silhouette for sprites behind it
        if (d.maskedtexturecol != null) {
            if (d.silhouette & state_mod.SIL_TOP == 0) {
                d.silhouette |= state_mod.SIL_TOP;
                d.tsilheight = Fixed.MIN;
            }
            if (d.silhouette & state_mod.SIL_BOTTOM == 0) {
                d.silhouette |= state_mod.SIL_BOTTOM;
                d.bsilheight = Fixed.MAX;
            }
        }
    }
}

/// Render the masked (transparent) mid texture of a two-sided seg for screen
/// columns x1..x2. Called from the sprite pass, back to front.
/// Port of linuxdoom-1.10 r_segs.c R_RenderMaskedSegRange.
pub fn renderMaskedSegRange(
    d: *state_mod.DrawSeg,
    x1: i32,
    x2: i32,
    level: *const setup.Level,
    rstate: *RenderState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    const base = d.maskedtexturecol orelse return;
    if (d.curline >= level.segs.len) return;
    const seg = &level.segs[d.curline];
    const side = &level.sides[seg.sidedef];
    const line = &level.lines[seg.linedef];
    if (side.midtexture <= 0) return;
    const tex_num: usize = @intCast(side.midtexture);

    const front_idx = seg.frontsector orelse return;
    const back_idx = seg.backsector orelse return;
    if (front_idx >= level.sectors.len or back_idx >= level.sectors.len) return;
    const frontsector = &level.sectors[front_idx];
    const backsector = &level.sectors[back_idx];

    const lightlevel = frontsector.lightlevel;
    const texh = rdata.textureHeightFixed(tex_num);

    // Vertical pegging: bottom-pegged mid textures rise from the higher floor;
    // otherwise they hang from the lower ceiling.
    var texturemid: Fixed = undefined;
    if (line.flags & defs.ML_DONTPEGBOTTOM != 0) {
        const f = if (frontsector.floorheight.gt(backsector.floorheight))
            frontsector.floorheight
        else
            backsector.floorheight;
        texturemid = Fixed.add(Fixed.sub(f, rstate.viewz), texh);
    } else {
        const c = if (frontsector.ceilingheight.lt(backsector.ceilingheight))
            frontsector.ceilingheight
        else
            backsector.ceilingheight;
        texturemid = Fixed.sub(c, rstate.viewz);
    }
    texturemid = Fixed.add(texturemid, side.rowoffset);

    var x = @max(x1, d.x1);
    const xe = @min(x2, d.x2);
    while (x <= xe) : (x += 1) {
        if (x < 0 or x >= SCREENWIDTH) continue;
        const mi = base + @as(usize, @intCast(x - d.x1));
        const tcol = rstate.openings[mi];
        if (tcol == state_mod.MASKED_NONE) continue;

        const spryscale = state_mod.scaleFromGlobalAngle(rstate, rstate.viewangle +% xToViewAngle(x), d.rw_distance, d.rw_normalangle);
        if (spryscale.raw() <= 0) continue;

        const light_idx = RenderData.lightIndex(lightlevel, spryscale);
        const colormap = rdata.getColormap(light_idx);
        const iscale = Fixed.div(Fixed.ONE, spryscale);
        const sprtopscreen = Fixed.sub(rstate.centeryfrac, Fixed.mul(texturemid, spryscale));

        const ceilclip = drawSegClipValue(rstate, d, d.sprtopclip, x, -1);
        const florclip = drawSegClipValue(rstate, d, d.sprbottomclip, x, SCREENHEIGHT);

        if (rdata.getMaskedTextureColumnPosts(tex_num, tcol)) |posts| {
            draw.drawMaskedColumn(screen, x, posts, colormap, spryscale, sprtopscreen, texturemid, iscale, ceilclip, florclip, rstate.centery);
        }

        rstate.openings[mi] = state_mod.MASKED_NONE; // drawn — don't draw again
    }
}

/// Resolve a drawseg clip array value for screen column x (default when the
/// drawseg recorded no clip on that edge).
pub fn drawSegClipValue(rstate: *const RenderState, d: *const state_mod.DrawSeg, clip: ?usize, x: i32, default: i32) i32 {
    const base = clip orelse return default;
    const idx = base + @as(usize, @intCast(std.math.clamp(x - d.x1, 0, SCREENWIDTH - 1)));
    if (idx >= state_mod.MAXOPENINGS) return default;
    return rstate.openings[idx];
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
