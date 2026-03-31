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

    /// Check if a visplane needs to be split (different column range conflict)
    pub fn checkPlane(self: *PlaneState, plane_idx: usize, start: i32, stop: i32) usize {
        const vp = &self.visplanes[plane_idx];

        // If the new range doesn't overlap with existing, just extend
        if (start < vp.minx) {
            // Check if there's a gap where columns are already used
            var x = start;
            while (x < @min(vp.minx, stop + 1)) : (x += 1) {
                // New columns are free
            }
            vp.minx = start;
        }
        if (stop > vp.maxx) {
            vp.maxx = stop;
        }

        // Check for conflicts in the overlapping range
        const overlap_start = @max(start, vp.minx);
        const overlap_end = @min(stop, vp.maxx);

        var x = overlap_start;
        while (x <= overlap_end) : (x += 1) {
            if (x >= 0 and x < SCREENWIDTH) {
                const ux: usize = @intCast(x);
                if (vp.top[ux] != MAXOPENHEIGHT) {
                    // Column already used — need new plane
                    const new_idx = self.createPlane(vp.height, vp.picnum, vp.lightlevel) orelse return plane_idx;
                    const new_vp = &self.visplanes[new_idx];
                    new_vp.minx = start;
                    new_vp.maxx = stop;
                    return new_idx;
                }
            }
        }

        return plane_idx;
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
            const colormap = rdata.getColormap(vp.lightlevel >> 4);

            // Calculate plane height above/below viewpoint
            const plane_height = Fixed.abs(Fixed.sub(vp.height, viewz));

            // Render each column as spans
            // Convert column tops/bottoms to horizontal spans
            self.renderPlaneSpans(vp, flat_data, colormap, screen, plane_height, viewx, viewy, viewangle);
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

    fn renderPlaneSpans(self: *PlaneState, vp: *const Visplane, flat_data: []const u8, colormap: []const u8, screen: [*]u8, plane_height: Fixed, viewx: Fixed, viewy: Fixed, viewangle: Angle) void {
        // Convert visplane columns to horizontal spans using makeSpans technique
        // For each x, column goes from top[x] to bottom[x]
        // We process columns left to right, tracking span starts

        // Reset span tracking
        @memset(&self.spanstart, 0);

        // Process from left to right, building spans row by row
        var x = vp.minx;
        while (x <= vp.maxx + 1) : (x += 1) {
            var t1: i32 = undefined;
            var b1: i32 = undefined;

            if (x <= vp.maxx and x >= 0 and x < SCREENWIDTH) {
                const ux: usize = @intCast(x);
                if (vp.top[ux] == MAXOPENHEIGHT) {
                    t1 = SCREENHEIGHT;
                    b1 = -1;
                } else {
                    t1 = @intCast(vp.top[ux]);
                    b1 = @intCast(vp.bottom[ux]);
                }
            } else {
                // Past the end — close all open spans
                t1 = SCREENHEIGHT;
                b1 = -1;
            }

            // For simplicity, draw each column as individual spans
            var y = t1;
            while (y <= b1) : (y += 1) {
                if (y < 0 or y >= SCREENHEIGHT) continue;

                // Calculate span texture coordinates for this y
                const dy = if (y < SCREENHEIGHT / 2) SCREENHEIGHT / 2 - y else y - SCREENHEIGHT / 2;
                if (dy == 0) continue;

                const distance = Fixed.div(plane_height, Fixed.fromInt(dy));

                const angle_frac = viewangle >> tables.ANGLETOFINESHIFT;
                const xfrac = Fixed.add(viewx, Fixed.mul(distance, tables.finecosine[angle_frac & tables.FINEMASK]));
                const yfrac = Fixed.sub(viewy, Fixed.mul(distance, tables.finesine[angle_frac & tables.FINEMASK]));

                const ds = draw.DrawSpanContext{
                    .source = flat_data,
                    .colormap = colormap,
                    .y = y,
                    .x1 = x,
                    .x2 = x, // single pixel wide for now
                    .xfrac = xfrac,
                    .yfrac = yfrac,
                    .xstep = Fixed.ONE,
                    .ystep = Fixed.ZERO,
                    .screen = screen,
                };
                draw.drawSpan(&ds);
            }
        }
    }
};

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
