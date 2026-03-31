//! zig_doom/src/render/state.zig
//!
//! Renderer state — viewpoint, clipping arrays, and frame-global data.
//! Translated from: linuxdoom-1.10/r_state.h, r_main.c (globals)
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const tables = @import("../tables.zig");
const defs = @import("../defs.zig");

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const MAXVISPLANES = 256;
pub const MAXOPENINGS = SCREENWIDTH * 64;
pub const MAXDRAWSEGS = 512;

/// The full renderer state for one frame.
pub const RenderState = struct {
    // Viewpoint
    viewx: Fixed = Fixed.ZERO,
    viewy: Fixed = Fixed.ZERO,
    viewz: Fixed = Fixed.ZERO,
    viewangle: Angle = 0,
    viewcos: Fixed = Fixed.ONE,
    viewsin: Fixed = Fixed.ZERO,

    // Derived from viewpoint
    centerx: i32 = SCREENWIDTH / 2,
    centery: i32 = SCREENHEIGHT / 2,
    centerxfrac: Fixed = Fixed.fromInt(SCREENWIDTH / 2),
    centeryfrac: Fixed = Fixed.fromInt(SCREENHEIGHT / 2),
    projection: Fixed = Fixed.fromInt(SCREENWIDTH / 2), // Focal length

    // Screen clip arrays — these track which columns are still open for rendering
    // Each entry stores the top/bottom clip for that screen column
    ceilingclip: [SCREENWIDTH]i16 = [_]i16{-1} ** SCREENWIDTH,
    floorclip: [SCREENWIDTH]i16 = [_]i16{@intCast(SCREENHEIGHT)} ** SCREENWIDTH,

    // Solid segs list — tracks fully occluded column ranges
    solidsegs: [SCREENWIDTH / 2 + 2]ClipRange = undefined,
    num_solidsegs: usize = 0,

    // Draw segs (rendered wall segments for sprite clipping)
    drawsegs: [MAXDRAWSEGS]DrawSeg = undefined,
    num_drawsegs: usize = 0,

    // Visplanes for floors/ceilings
    num_visplanes: usize = 0,

    // Openings array — shared pool for drawseg silhouette clips
    openings: [MAXOPENINGS]i16 = undefined,
    lastopening: usize = 0,

    // Current frame number (for caching)
    framecount: u32 = 0,

    // Extra light (gun flash, etc.)
    extralight: i32 = 0,

    // Fixed-point light levels per distance
    // scalelight[lightlevel][distance]
    // Set up each frame in setupFrame

    // Vissprites for things
    num_vissprites: usize = 0,

    pub fn init() RenderState {
        var state = RenderState{};
        state.clearClipSegs();
        return state;
    }

    /// Set up frame from player viewpoint
    pub fn setupFrame(self: *RenderState, x: Fixed, y: Fixed, z: Fixed, angle: Angle) void {
        self.viewx = x;
        self.viewy = y;
        self.viewz = z;
        self.viewangle = angle;
        self.viewsin = tables.sinAngle(angle);
        self.viewcos = tables.cosAngle(angle);

        self.framecount +%= 1;
        self.num_drawsegs = 0;
        self.num_visplanes = 0;
        self.num_vissprites = 0;
        self.lastopening = 0;

        // Reset clip arrays
        for (0..SCREENWIDTH) |i| {
            self.ceilingclip[i] = -1;
            self.floorclip[i] = @intCast(SCREENHEIGHT);
        }
        self.clearClipSegs();
    }

    /// Initialize solid segs with screen edges
    pub fn clearClipSegs(self: *RenderState) void {
        // Start with two sentinel entries covering everything outside the screen
        self.solidsegs[0] = .{ .first = -0x7fff, .last = -1 };
        self.solidsegs[1] = .{ .first = SCREENWIDTH, .last = 0x7fff };
        self.num_solidsegs = 2;
    }

    /// Point-to-angle from viewpoint
    pub fn pointToAngle(self: *const RenderState, x: Fixed, y: Fixed) Angle {
        return pointToAngle2(self.viewx, self.viewy, x, y);
    }

    /// Check if a bounding box is potentially visible
    pub fn checkBBox(self: *const RenderState, bspcoord: [4]Fixed) bool {
        // Check box against each solidsegs range
        // Transform box corners to view angles
        const boxx: usize = if (self.viewx.raw() <= bspcoord[2].raw())
            0
        else if (self.viewx.raw() < bspcoord[3].raw())
            1
        else
            2;
        const boxy: usize = if (self.viewy.raw() >= bspcoord[0].raw())
            0
        else if (self.viewy.raw() > bspcoord[1].raw())
            1
        else
            2;

        const boxpos = boxy * 3 + boxx;
        if (boxpos == 4) return true; // Viewpoint is inside the box

        // Check corner angles
        const checkcoord = [9][4]usize{
            .{ 3, 0, 2, 1 }, // top-left
            .{ 3, 0, 2, 0 }, // top
            .{ 3, 1, 2, 0 }, // top-right
            .{ 3, 0, 3, 1 }, // left
            .{ 0, 0, 0, 0 }, // center (never used)
            .{ 2, 0, 2, 1 }, // right
            .{ 3, 1, 3, 0 }, // bottom-left
            .{ 2, 1, 3, 0 }, // bottom
            .{ 2, 1, 2, 0 }, // bottom-right
        };

        const cc = checkcoord[boxpos];
        const angle1 = self.pointToAngle(bspcoord[cc[0]], bspcoord[cc[1]]) -% self.viewangle;
        const angle2 = self.pointToAngle(bspcoord[cc[2]], bspcoord[cc[3]]) -% self.viewangle;

        // Check span
        const span = angle1 -% angle2;

        // Entirely behind?
        if (span >= fixed.ANG180) return true;

        var tspan = angle1 +% (fixed.ANG90 -% fixed.ANG45); // Shift to 0..ANG180 range
        if (tspan > 2 * fixed.ANG90) {
            tspan -%= 2 * fixed.ANG90;
            if (tspan >= span) return false;
        }

        tspan = (fixed.ANG90 -% fixed.ANG45) -% angle2;
        if (tspan > 2 * fixed.ANG90) return true;

        return true;
    }
};

/// Solid segment range for occlusion culling
pub const ClipRange = struct {
    first: i32,
    last: i32,
};

/// Draw seg — represents a rendered wall segment for sprite clipping
pub const DrawSeg = struct {
    curline: u32 = 0, // seg index
    x1: i32 = 0,
    x2: i32 = 0,
    scale1: Fixed = Fixed.ZERO,
    scale2: Fixed = Fixed.ZERO,
    scalestep: Fixed = Fixed.ZERO,
    silhouette: u32 = 0, // SIL_NONE, SIL_BOTTOM, SIL_TOP, SIL_BOTH
    bsilheight: Fixed = Fixed.ZERO,
    tsilheight: Fixed = Fixed.ZERO,
    sprtopclip: ?usize = null, // index into openings
    sprbottomclip: ?usize = null,
    maskedtexturecol: ?usize = null,
};

pub const SIL_NONE = 0;
pub const SIL_BOTTOM = 1;
pub const SIL_TOP = 2;
pub const SIL_BOTH = 3;

/// Point-to-angle lookup (R_PointToAngle2 from r_main.c)
pub fn pointToAngle2(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Angle {
    const dx_raw = x2.raw() -% x1.raw();
    const dy_raw = y2.raw() -% y1.raw();
    return pointToAngleRaw(dx_raw, dy_raw);
}

fn pointToAngleRaw(x: i32, y: i32) Angle {
    if (x == 0 and y == 0) return 0;

    if (x >= 0) {
        if (y >= 0) {
            // Octant 0-1
            if (x > y) {
                return tanToAngle(slopeDiv(@intCast(y), @intCast(x)));
            } else {
                return fixed.ANG90 -% 1 -% tanToAngle(slopeDiv(@intCast(x), @intCast(y)));
            }
        } else {
            // Octant 7-8
            const ay: u32 = @intCast(-y);
            if (x > ay) {
                return 0 -% tanToAngle(slopeDiv(ay, @intCast(x)));
            } else {
                return fixed.ANG270 +% tanToAngle(slopeDiv(@intCast(x), ay));
            }
        }
    } else {
        const ax: u32 = @intCast(-x);
        if (y >= 0) {
            // Octant 2-3
            if (ax > @as(u32, @intCast(y))) {
                return fixed.ANG180 -% 1 -% tanToAngle(slopeDiv(@intCast(y), ax));
            } else {
                return fixed.ANG90 +% tanToAngle(slopeDiv(ax, @intCast(y)));
            }
        } else {
            // Octant 4-5
            const ay: u32 = @intCast(-y);
            if (ax > ay) {
                return fixed.ANG180 +% tanToAngle(slopeDiv(ay, ax));
            } else {
                return fixed.ANG270 -% 1 -% tanToAngle(slopeDiv(ax, ay));
            }
        }
    }
}

fn slopeDiv(num: u32, den: u32) u32 {
    if (den < 512) return 2048; // Clamp near-vertical
    const ans = @min((num << 3) / (den >> 8), 2048);
    return ans;
}

fn tanToAngle(idx: u32) Angle {
    const clamped = @min(idx, 2048);
    return tables.tantoangle[clamped];
}

/// Scale from global distance to screen column height
pub fn scaleFromGlobalAngle(rstate: *const RenderState, visangle: Angle, rw_distance: Fixed, rw_normalangle: Angle) Fixed {
    const anglea = fixed.ANG90 +% (visangle -% rstate.viewangle);
    const angleb = fixed.ANG90 +% (visangle -% rw_normalangle);

    const sinea = tables.sinAngle(anglea);
    const sineb = tables.sinAngle(angleb);

    if (sineb.raw() == 0) return Fixed.fromRaw(0x7fff_ffff);

    // num = projection * sinb
    const num: i64 = @as(i64, rstate.projection.raw()) * @as(i64, sineb.raw());
    // den = distance * sina
    const den: i64 = @as(i64, rw_distance.raw()) * @as(i64, sinea.raw());

    if (den == 0) return Fixed.fromRaw(0x7fff_ffff);

    const result = @divTrunc(num << 16, den);
    const clamped = std.math.clamp(result, 256, @as(i64, 64) * @as(i64, 1 << fixed.FRAC_BITS));
    return Fixed.fromRaw(@intCast(clamped));
}

test "render state init" {
    const state = RenderState.init();
    try std.testing.expectEqual(@as(i32, SCREENWIDTH / 2), state.centerx);
    try std.testing.expectEqual(@as(usize, 2), state.num_solidsegs);
}

test "point to angle basic" {
    // Point directly east should be angle 0
    const angle = pointToAngle2(Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(100), Fixed.ZERO);
    try std.testing.expect(angle < fixed.ANG45); // Should be near 0

    // Point directly north should be ~ANG90
    const angle_n = pointToAngle2(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(100));
    const diff = if (angle_n > fixed.ANG90) angle_n - fixed.ANG90 else fixed.ANG90 - angle_n;
    try std.testing.expect(diff < fixed.ANG45);
}
