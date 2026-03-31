//! zig_doom/src/play/maputl.zig
//!
//! Map geometry utilities — point/line tests, distance, angles.
//! Translated from: linuxdoom-1.10/p_maputl.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const ANG90 = fixed.ANG90;
const ANG180 = fixed.ANG180;
const ANG270 = fixed.ANG270;
const tables = @import("../tables.zig");
const bbox_mod = @import("../bbox.zig");
const BBox = bbox_mod.BBox;
const BOXTOP = bbox_mod.BOXTOP;
const BOXBOTTOM = bbox_mod.BOXBOTTOM;
const BOXLEFT = bbox_mod.BOXLEFT;
const BOXRIGHT = bbox_mod.BOXRIGHT;
const setup = @import("setup.zig");
const Line = setup.Line;
const SlopeType = setup.SlopeType;
const Vertex = setup.Vertex;

// ============================================================================
// Point-on-line-side test
// ============================================================================

/// Returns 0 if the point is on the front side, 1 if on the back side.
/// Uses the line's precomputed dx/dy.
pub fn pointOnLineSide(x: Fixed, y: Fixed, line: *const Line, vertices: []const Vertex) i32 {
    const v1 = vertices[line.v1];
    const dx = line.dx;
    const dy = line.dy;

    if (dx.raw() == 0) {
        if (x.raw() <= v1.x.raw()) {
            return if (dy.raw() > 0) @as(i32, 1) else @as(i32, 0);
        }
        return if (dy.raw() < 0) @as(i32, 1) else @as(i32, 0);
    }

    if (dy.raw() == 0) {
        if (y.raw() <= v1.y.raw()) {
            return if (dx.raw() < 0) @as(i32, 1) else @as(i32, 0);
        }
        return if (dx.raw() > 0) @as(i32, 1) else @as(i32, 0);
    }

    // General case: cross product
    const pdx = Fixed.sub(x, v1.x);
    const pdy = Fixed.sub(y, v1.y);

    // left = (dy>>FRACBITS) * pdx - (dx>>FRACBITS) * pdy
    const left: i64 = @as(i64, dy.raw() >> 16) * @as(i64, pdx.raw());
    const right: i64 = @as(i64, dx.raw() >> 16) * @as(i64, pdy.raw());

    if (left < right) return 1; // back side
    return 0; // front side
}

/// Returns 0 if box is on front side, 1 if on back side, -1 if box crosses the line.
pub fn boxOnLineSide(box: *const BBox, line: *const Line, vertices: []const Vertex) i32 {
    var p1: i32 = 0;
    var p2: i32 = 0;

    switch (line.slopetype) {
        .horizontal => {
            p1 = if (box[BOXTOP].raw() > vertices[line.v1].y.raw()) @as(i32, 1) else @as(i32, 0);
            p2 = if (box[BOXBOTTOM].raw() > vertices[line.v1].y.raw()) @as(i32, 1) else @as(i32, 0);
            if (line.dx.raw() < 0) {
                p1 ^= 1;
                p2 ^= 1;
            }
        },
        .vertical => {
            p1 = if (box[BOXRIGHT].raw() < vertices[line.v1].x.raw()) @as(i32, 1) else @as(i32, 0);
            p2 = if (box[BOXLEFT].raw() < vertices[line.v1].x.raw()) @as(i32, 1) else @as(i32, 0);
            if (line.dy.raw() < 0) {
                p1 ^= 1;
                p2 ^= 1;
            }
        },
        .positive => {
            p1 = pointOnLineSide(box[BOXLEFT], box[BOXTOP], line, vertices);
            p2 = pointOnLineSide(box[BOXRIGHT], box[BOXBOTTOM], line, vertices);
        },
        .negative => {
            p1 = pointOnLineSide(box[BOXRIGHT], box[BOXTOP], line, vertices);
            p2 = pointOnLineSide(box[BOXLEFT], box[BOXBOTTOM], line, vertices);
        },
    }

    if (p1 == p2) return p1;
    return -1; // Crosses the line
}

// ============================================================================
// Angle and distance
// ============================================================================

/// Calculate the angle from (x1,y1) to (x2,y2).
/// Returns a binary angle (0 = east, ANG90 = north).
pub fn pointToAngle2(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Angle {
    const dx = Fixed.sub(x2, x1);
    const dy = Fixed.sub(y2, y1);

    if (dx.raw() == 0 and dy.raw() == 0) return 0;

    if (dx.raw() >= 0) {
        if (dy.raw() >= 0) {
            // First quadrant
            if (dx.raw() == 0) return ANG90;
            if (dy.raw() == 0) return 0;
            return slopeToAngle(dy, dx);
        } else {
            // Fourth quadrant
            if (dx.raw() == 0) return ANG270;
            return 0 -% slopeToAngle(dy.negate(), dx);
        }
    } else {
        if (dy.raw() >= 0) {
            // Second quadrant
            if (dy.raw() == 0) return ANG180;
            return ANG180 -% slopeToAngle(dy, dx.negate());
        } else {
            // Third quadrant
            return ANG180 +% slopeToAngle(dy.negate(), dx.negate());
        }
    }
}

fn slopeToAngle(num: Fixed, den: Fixed) Angle {
    if (den.raw() == 0) return ANG90;

    // Use tantoangle table: slope = num/den, index = slope * 2048
    if (num.abs().raw() <= den.abs().raw()) {
        const slope = Fixed.div(num, den);
        var idx: u32 = @intCast(@min(2048, @as(u32, @intCast(@max(0, slope.raw()))) >> 5));
        if (idx > 2048) idx = 2048;
        return tables.tantoangle[idx];
    } else {
        const slope = Fixed.div(den, num);
        var idx: u32 = @intCast(@min(2048, @as(u32, @intCast(@max(0, slope.raw()))) >> 5));
        if (idx > 2048) idx = 2048;
        return ANG90 -% tables.tantoangle[idx];
    }
}

/// Approximate distance between two points.
/// Uses DOOM's approximation: max(|dx|, |dy|) + min(|dx|, |dy|) / 2
pub fn aproxDistance(dx: Fixed, dy: Fixed) Fixed {
    var adx = dx.abs();
    var ady = dy.abs();

    if (ady.raw() > adx.raw()) {
        const tmp = adx;
        adx = ady;
        ady = tmp;
    }

    return Fixed.fromRaw(adx.raw() +% @divTrunc(ady.raw(), 2));
}

/// Calculate the opening (gap) between floor and ceiling at a line.
/// Returns opening height, top/bottom of opening, and lowest floor.
pub const LineOpening = struct {
    range: Fixed, // Total gap height
    top: Fixed, // Top of opening
    bottom: Fixed, // Bottom of opening
    lowfloor: Fixed, // Lowest floor (for dropoff)
};

pub fn lineOpening(line: *const Line, sectors: []const setup.Sector) ?LineOpening {
    if (line.sidenum[1] < 0) {
        // Single sided line — no opening
        return null;
    }

    const front_idx = line.frontsector orelse return null;
    const back_idx = line.backsector orelse return null;
    const front = &sectors[front_idx];
    const back = &sectors[back_idx];

    const top = if (front.ceilingheight.raw() < back.ceilingheight.raw())
        front.ceilingheight
    else
        back.ceilingheight;

    const bottom = if (front.floorheight.raw() > back.floorheight.raw())
        front.floorheight
    else
        back.floorheight;

    const lowfloor = if (front.floorheight.raw() < back.floorheight.raw())
        front.floorheight
    else
        back.floorheight;

    return .{
        .range = Fixed.sub(top, bottom),
        .top = top,
        .bottom = bottom,
        .lowfloor = lowfloor,
    };
}

/// Intercept vector — find fractional intersection of two line segments.
/// Returns the fraction (0.0 to 1.0 in fixed point) along the first segment
/// where it intersects the second segment.
pub fn interceptVector(
    v2x: Fixed,
    v2y: Fixed,
    v2dx: Fixed,
    v2dy: Fixed,
    v1x: Fixed,
    v1y: Fixed,
    v1dx: Fixed,
    v1dy: Fixed,
) Fixed {
    const den_wide: i64 = @as(i64, v1dy.raw() >> 8) * @as(i64, v2dx.raw()) -
        @as(i64, v1dx.raw() >> 8) * @as(i64, v2dy.raw());

    if (den_wide == 0) return Fixed.ZERO;

    const num_wide: i64 = @as(i64, (v1x.raw() - v2x.raw()) >> 8) * @as(i64, v1dy.raw()) +
        @as(i64, (v2y.raw() - v1y.raw()) >> 8) * @as(i64, v1dx.raw());

    const frac: i64 = @divTrunc(num_wide << 16, den_wide);

    return Fixed.fromRaw(@as(i32, @truncate(frac)));
}

// ============================================================================
// Divline — a partition line for BSP traversal
// ============================================================================

pub const DivLine = struct {
    x: Fixed,
    y: Fixed,
    dx: Fixed,
    dy: Fixed,
};

/// Determine which side of a divline a point is on.
/// Returns 0 for front, 1 for back.
pub fn pointOnDivlineSide(x: Fixed, y: Fixed, line: *const DivLine) i32 {
    if (line.dx.raw() == 0) {
        if (x.raw() <= line.x.raw()) {
            return if (line.dy.raw() > 0) @as(i32, 1) else @as(i32, 0);
        }
        return if (line.dy.raw() < 0) @as(i32, 1) else @as(i32, 0);
    }

    if (line.dy.raw() == 0) {
        if (y.raw() <= line.y.raw()) {
            return if (line.dx.raw() < 0) @as(i32, 1) else @as(i32, 0);
        }
        return if (line.dx.raw() > 0) @as(i32, 1) else @as(i32, 0);
    }

    const pdx = Fixed.sub(x, line.x);
    const pdy = Fixed.sub(y, line.y);

    const left: i64 = @as(i64, line.dy.raw() >> 16) * @as(i64, pdx.raw());
    const right: i64 = @as(i64, line.dx.raw() >> 16) * @as(i64, pdy.raw());

    if (left < right) return 1;
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "aprox distance" {
    // Horizontal distance
    const d1 = aproxDistance(Fixed.fromInt(10), Fixed.ZERO);
    try std.testing.expectEqual(@as(i32, 10), d1.toInt());

    // Vertical distance
    const d2 = aproxDistance(Fixed.ZERO, Fixed.fromInt(10));
    try std.testing.expectEqual(@as(i32, 10), d2.toInt());

    // Diagonal — should be approximately sqrt(2) * 10 ≈ 14.14
    // DOOM approximation gives 15 (10 + 10/2)
    const d3 = aproxDistance(Fixed.fromInt(10), Fixed.fromInt(10));
    try std.testing.expectEqual(@as(i32, 15), d3.toInt());
}

test "point to angle basic" {
    // East (positive x) = 0
    const a1 = pointToAngle2(Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(10), Fixed.ZERO);
    try std.testing.expect(a1 < fixed.ANG45 / 2); // roughly 0

    // North (positive y) = ANG90
    const a2 = pointToAngle2(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(10));
    const diff90 = if (a2 > ANG90) a2 - ANG90 else ANG90 - a2;
    try std.testing.expect(diff90 < fixed.ANG45 / 4); // roughly ANG90
}

test "point on divline side" {
    // Horizontal line going east
    const line = DivLine{
        .x = Fixed.ZERO,
        .y = Fixed.ZERO,
        .dx = Fixed.fromInt(10),
        .dy = Fixed.ZERO,
    };

    // DOOM convention: for eastward line, front (0) is south (negative y)
    // Point above the line (positive y) = back (1)
    const side1 = pointOnDivlineSide(Fixed.fromInt(5), Fixed.fromInt(5), &line);
    try std.testing.expectEqual(@as(i32, 1), side1);

    // Point below (negative y) = front (0)
    const side2 = pointOnDivlineSide(Fixed.fromInt(5), Fixed.fromInt(-5), &line);
    try std.testing.expectEqual(@as(i32, 0), side2);
}
