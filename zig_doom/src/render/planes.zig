//! zig_doom/src/render/planes.zig
//!
//! Visplane (floor/ceiling) rendering.
//! Translated from: linuxdoom-1.10/r_plane.c, r_plane.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Floors and ceilings are rendered as "visplanes" — collections of horizontal
//! spans sharing the same height, flat texture, and light level.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const tables = @import("../tables.zig");
const defs = @import("../defs.zig");
const draw = @import("draw.zig");
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const MAXVISPLANES = 256;
pub const MAXOPENHEIGHT = 0xFFFF;

pub const Visplane = struct {
    height: Fixed,
    picnum: i32, // flat number
    lightlevel: i32,
    minx: i32,
    maxx: i32,
    // Top and bottom of each column for this visplane
    top: [SCREENWIDTH]u16,
    bottom: [SCREENWIDTH]u16,

    pub fn init() Visplane {
        return .{
            .height = Fixed.ZERO,
            .picnum = 0,
            .lightlevel = 0,
            .minx = SCREENWIDTH,
            .maxx = -1,
            .top = [_]u16{MAXOPENHEIGHT} ** SCREENWIDTH,
            .bottom = [_]u16{0} ** SCREENWIDTH,
        };
    }
};

pub const PlaneState = struct {
    visplanes: [MAXVISPLANES]Visplane = undefined,
    num_visplanes: usize = 0,

    // Floor/ceiling openings for the current seg being rendered
    floorplane: ?usize = null, // index into visplanes
    ceilingplane: ?usize = null,

    // Span rendering state
    spanstart: [SCREENHEIGHT]i32 = [_]i32{0} ** SCREENHEIGHT,

    // Sky flat number
    skyflatnum: i32 = -1,

    pub fn init() PlaneState {
        return .{};
    }

    /// Clear all visplanes at start of frame
    pub fn clearPlanes(self: *PlaneState) void {
        self.num_visplanes = 0;
        self.floorplane = null;
        self.ceilingplane = null;
    }

    /// Find an existing visplane or create a new one matching the given properties
    pub fn findPlane(self: *PlaneState, height: Fixed, picnum: i32, lightlevel: i32) ?usize {
        // Search for matching existing plane
        for (0..self.num_visplanes) |i| {
            const vp = &self.visplanes[i];
            if (vp.height.eql(height) and
                vp.picnum == picnum and
                vp.lightlevel == lightlevel)
            {
                return i;
            }
        }

        // Create new plane
        return self.createPlane(height, picnum, lightlevel);
    }

    fn createPlane(self: *PlaneState, height: Fixed, picnum: i32, lightlevel: i32) ?usize {
        if (self.num_visplanes >= MAXVISPLANES) return null;

        const idx = self.num_visplanes;
        self.visplanes[idx] = Visplane.init();
        self.visplanes[idx].height = height;
        self.visplanes[idx].picnum = picnum;
        self.visplanes[idx].lightlevel = lightlevel;
        self.num_visplanes += 1;
        return idx;
    }

    /// Reserve columns [start, stop] on a visplane, splitting into a fresh plane
    /// if any of them are already occupied. Faithful port of r_plane.c R_CheckPlane.
    ///
    /// The previous version mutated minx/maxx *before* the conflict test, so a
    /// split corrupted the original plane's range and dropped columns — leaving
    /// black gaps in floors/ceilings seen in separate patches (e.g. around a
    /// nearer pillar).
    pub fn checkPlane(self: *PlaneState, plane_idx: usize, start: i32, stop: i32) usize {
        const vp = &self.visplanes[plane_idx];

        // Intersection (intrl..intrh) and union (unionl..unionh) of the existing
        // range with the requested one.
        var intrl: i32 = undefined;
        var unionl: i32 = undefined;
        var intrh: i32 = undefined;
        var unionh: i32 = undefined;
        if (start < vp.minx) {
            intrl = vp.minx;
            unionl = start;
        } else {
            unionl = vp.minx;
            intrl = start;
        }
        if (stop > vp.maxx) {
            intrh = vp.maxx;
            unionh = stop;
        } else {
            unionh = vp.maxx;
            intrh = stop;
        }

        // Does any already-used column fall in the intersection?
        var x = intrl;
        while (x <= intrh) : (x += 1) {
            if (x >= 0 and x < SCREENWIDTH and vp.top[@intCast(x)] != MAXOPENHEIGHT) break;
        }

        if (x > intrh) {
            // No conflict — extend this plane to the union.
            vp.minx = unionl;
            vp.maxx = unionh;
            return plane_idx;
        }

        // Conflict — allocate a fresh plane with the same surface for [start, stop].
        const new_idx = self.createPlane(vp.height, vp.picnum, vp.lightlevel) orelse return plane_idx;
        const new_vp = &self.visplanes[new_idx];
        new_vp.minx = start;
        new_vp.maxx = stop;
        return new_idx;
    }

    /// Render all accumulated visplanes
    pub fn drawPlanes(self: *PlaneState, rdata: *RenderData, screen: [*]u8, viewx: Fixed, viewy: Fixed, viewangle: Angle, viewz: Fixed) void {
        for (0..self.num_visplanes) |i| {
            const vp = &self.visplanes[i];
            if (vp.minx > vp.maxx) continue;

            // Sky handling
            if (vp.picnum == self.skyflatnum) {
                self.drawSkyPlane(vp, rdata, screen, viewangle);
                continue;
            }

            // Get flat data
            const flat_data = rdata.getFlatData(vp.picnum);

            // Calculate plane height above/below viewpoint
            const plane_height = Fixed.abs(Fixed.sub(vp.height, viewz));

            // Render each column as spans
            // Convert column tops/bottoms to horizontal spans
            self.renderPlaneSpans(vp, flat_data, rdata, screen, plane_height, viewx, viewy, viewangle);
        }
    }

    fn drawSkyPlane(self: *PlaneState, vp: *const Visplane, rdata: *RenderData, screen: [*]u8, viewangle: Angle) void {
        _ = self;
        // Sky texture: look up "SKY1" texture and draw as columns
        const sky_tex = rdata.textureNumForName("SKY1\x00\x00\x00\x00".*);
        if (sky_tex < 0) {
            // No sky texture — draw dark blue
            var x = vp.minx;
            while (x <= vp.maxx) : (x += 1) {
                if (x < 0 or x >= SCREENWIDTH) continue;
                const ux: usize = @intCast(x);
                if (vp.top[ux] == MAXOPENHEIGHT) continue;
                const t: i32 = @intCast(vp.top[ux]);
                const b: i32 = @intCast(vp.bottom[ux]);
                draw.drawSolidColumn(screen, x, t, b, 0); // black sky
            }
            return;
        }

        // Draw sky columns — texture wraps based on viewangle
        var x = vp.minx;
        while (x <= vp.maxx) : (x += 1) {
            if (x < 0 or x >= SCREENWIDTH) continue;
            const ux: usize = @intCast(x);
            if (vp.top[ux] == MAXOPENHEIGHT) continue;

            const t: i32 = @intCast(vp.top[ux]);
            const b: i32 = @intCast(vp.bottom[ux]);

            // Sky angle — based on viewangle and screen column
            const angle_offset: u32 = @intCast(@as(u64, @intCast(x)) * (fixed.ANG90 / 160));
            const sky_angle = viewangle +% angle_offset;
            const tex_col: i32 = @intCast((sky_angle >> 22) & 0xFF); // 256-wide sky

            const col_data = rdata.getTextureColumn(@intCast(sky_tex), tex_col);
            if (col_data.len == 0) {
                draw.drawSolidColumn(screen, x, t, b, 0);
                continue;
            }

            // Identity colormap for sky (full bright)
            const identity = rdata.getColormap(0);

            const dc = draw.DrawColumnContext{
                .source = col_data,
                .colormap = identity,
                .x = x,
                .yl = t,
                .yh = b,
                .iscale = Fixed.ONE,
                .texturemid = Fixed.fromInt(100), // Sky texture centering
                .screen = screen,
            };
            draw.drawColumn(&dc);
        }
    }

    fn renderPlaneSpans(self: *PlaneState, vp: *const Visplane, flat_data: []const u8, rdata: *const RenderData, screen: [*]u8, plane_height: Fixed, viewx: Fixed, viewy: Fixed, viewangle: Angle) void {
        _ = self;
        // Proper R_MapPlane: for each screen row, the floor/ceiling distance is
        // constant, so a horizontal span maps to a straight line across the flat.
        // We sweep rows, find covered column runs, and draw a perspective-correct
        // textured span per run. (The old version sampled one texel for the whole
        // plane via viewangle only — hence the flat navy/dark "weird pixels".)
        const centery: i32 = SCREENHEIGHT / 2;
        const centerx: i32 = SCREENWIDTH / 2;

        var y: i32 = 0;
        while (y < SCREENHEIGHT) : (y += 1) {
            const ady: i32 = if (y >= centery) y - centery else centery - y;
            if (ady == 0) continue; // horizon row maps to infinity

            // distance to the plane along the ground for this row
            const yslope = Fixed.div(Fixed.fromInt(centerx), Fixed.fromInt(ady));
            const distance = Fixed.mul(plane_height, yslope);

            // Per-row light diminishing (vanilla zlight): farther rows darker
            const colormap = rdata.getColormap(RenderData.zlightIndex(vp.lightlevel, distance));

            var x = vp.minx;
            while (x <= vp.maxx) {
                if (!covers(vp, x, y)) {
                    x += 1;
                    continue;
                }
                const xs = x;
                while (x <= vp.maxx and covers(vp, x, y)) : (x += 1) {}
                const xe = x - 1;

                const ws = worldPoint(xs, distance, viewx, viewy, viewangle);
                const we = worldPoint(xe, distance, viewx, viewy, viewangle);
                const span_cols = xe - xs;
                var xstep = Fixed.ZERO;
                var ystep = Fixed.ZERO;
                if (span_cols > 0) {
                    xstep = Fixed.fromRaw(@divTrunc(we[0].raw() - ws[0].raw(), span_cols));
                    ystep = Fixed.fromRaw(@divTrunc(we[1].raw() - ws[1].raw(), span_cols));
                }

                const ds = draw.DrawSpanContext{
                    .source = flat_data,
                    .colormap = colormap,
                    .y = y,
                    .x1 = xs,
                    .x2 = xe,
                    .xfrac = ws[0],
                    .yfrac = ws[1],
                    .xstep = xstep,
                    .ystep = ystep,
                    .screen = screen,
                };
                draw.drawSpan(&ds);
            }
        }
    }
};

/// Does this visplane cover screen pixel (x, y)?
fn covers(vp: *const Visplane, x: i32, y: i32) bool {
    if (x < 0 or x >= SCREENWIDTH) return false;
    const ux: usize = @intCast(x);
    if (vp.top[ux] == MAXOPENHEIGHT) return false;
    const t: i32 = @intCast(vp.top[ux]);
    const b: i32 = @intCast(vp.bottom[ux]);
    return y >= t and y <= b;
}

/// World (x, y) of the flat point seen at screen column `x` for the given
/// ground distance — the texture coordinate fed to the span renderer.
fn worldPoint(x: i32, distance: Fixed, viewx: Fixed, viewy: Fixed, viewangle: Angle) [2]Fixed {
    const xva = xToViewAngle(x);
    // length = distance / cos(column angle)  (distscale)
    var cosx = tables.cosAngle(xva);
    if (cosx.raw() < 0) cosx = Fixed.fromRaw(-cosx.raw());
    const length = if (cosx.raw() != 0) Fixed.div(distance, cosx) else distance;

    const fine: usize = @intCast((((viewangle +% xva) >> tables.ANGLETOFINESHIFT)) & tables.FINEMASK);
    const xfrac = Fixed.add(viewx, Fixed.mul(tables.finecosine[fine], length));
    const yfrac = Fixed.sub(Fixed.fromRaw(-viewy.raw()), Fixed.mul(tables.finesine[fine], length));
    return .{ xfrac, yfrac };
}

const plane_centerx: i32 = SCREENWIDTH / 2;

/// View angle of screen column x relative to center (left positive). Mirrors
/// the helper in segs.zig.
fn xToViewAngle(x: i32) Angle {
    const dx = plane_centerx - x;
    if (dx == 0) return 0;
    const adx: u32 = @intCast(if (dx < 0) -dx else dx);
    const den: u32 = @intCast(plane_centerx);
    const idx = @min((adx << 11) / den, 2048);
    const a = tables.tantoangle[idx];
    return if (dx > 0) a else 0 -% a;
}

test "visplane init" {
    const vp = Visplane.init();
    try std.testing.expectEqual(@as(i32, SCREENWIDTH), vp.minx);
    try std.testing.expectEqual(@as(i32, -1), vp.maxx);
    try std.testing.expectEqual(@as(u16, MAXOPENHEIGHT), vp.top[0]);
}

test "plane state create" {
    var ps = PlaneState.init();
    const idx = ps.findPlane(Fixed.fromInt(0), 1, 160);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 1), ps.num_visplanes);

    // Finding the same plane should return the same index
    const idx2 = ps.findPlane(Fixed.fromInt(0), 1, 160);
    try std.testing.expectEqual(idx, idx2);
    try std.testing.expectEqual(@as(usize, 1), ps.num_visplanes);
}
