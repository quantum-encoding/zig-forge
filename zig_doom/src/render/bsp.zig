//! zig_doom/src/render/bsp.zig
//!
//! BSP tree traversal for front-to-back rendering.
//! Translated from: linuxdoom-1.10/r_bsp.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! The BSP tree divides the map into convex subsectors. We walk it front-to-back,
//! rendering wall segments and accumulating floor/ceiling visplanes.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const tables = @import("../tables.zig");
const setup = @import("../play/setup.zig");
const state_mod = @import("state.zig");
const RenderState = state_mod.RenderState;
const segs = @import("segs.zig");
const planes = @import("planes.zig");
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;

/// Render the BSP tree starting from the root node
pub fn renderBSPNode(
    node_id: u16,
    level: *const setup.Level,
    rstate: *RenderState,
    pstate: *planes.PlaneState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    // Check if this is a subsector (leaf node)
    if (node_id & defs.NF_SUBSECTOR != 0) {
        const ssec_idx = node_id & ~defs.NF_SUBSECTOR;
        if (ssec_idx < level.subsectors.len) {
            drawSubsector(ssec_idx, level, rstate, pstate, rdata, screen);
        }
        return;
    }

    if (node_id >= level.nodes.len) return;
    const node = &level.nodes[node_id];

    // Determine which side of the partition line the viewpoint is on
    const side = pointOnSide(rstate.viewx, rstate.viewy, node);

    // Render front side first (closest to viewer)
    renderBSPNode(node.children[side], level, rstate, pstate, rdata, screen);

    // Check if back side is potentially visible
    if (rstate.checkBBox(node.bbox[side ^ 1])) {
        renderBSPNode(node.children[side ^ 1], level, rstate, pstate, rdata, screen);
    }
}

/// Determine which side of a BSP partition line a point is on
fn pointOnSide(x: Fixed, y: Fixed, node: *const setup.Node) usize {
    // If the partition line is axis-aligned, use fast test
    if (node.dx.raw() == 0) {
        if (x.raw() <= node.x.raw()) {
            return if (node.dy.raw() > 0) @as(usize, 1) else @as(usize, 0);
        }
        return if (node.dy.raw() > 0) @as(usize, 0) else @as(usize, 1);
    }
    if (node.dy.raw() == 0) {
        if (y.raw() <= node.y.raw()) {
            return if (node.dx.raw() < 0) @as(usize, 1) else @as(usize, 0);
        }
        return if (node.dx.raw() < 0) @as(usize, 0) else @as(usize, 1);
    }

    // General case: cross product
    const dx: i64 = x.raw() -% node.x.raw();
    const dy: i64 = y.raw() -% node.y.raw();

    const left: i64 = @as(i64, node.dy.raw()) * dx;
    const right: i64 = dy * @as(i64, node.dx.raw());

    if (right < left) return 0; // front side
    return 1; // back side
}

/// Draw all segs in a subsector
fn drawSubsector(
    ssec_idx: u16,
    level: *const setup.Level,
    rstate: *RenderState,
    pstate: *planes.PlaneState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    const ssec = &level.subsectors[ssec_idx];

    // Set up floor and ceiling visplanes for this subsector
    const sector_idx = ssec.sector orelse return;
    if (sector_idx >= level.sectors.len) return;
    const sector = &level.sectors[sector_idx];

    // Find or create floor visplane
    if (sector.floorheight.lt(rstate.viewz)) {
        pstate.floorplane = pstate.findPlane(
            sector.floorheight,
            sector.floorpic,
            sector.lightlevel,
        );
    } else {
        pstate.floorplane = null;
    }

    // Find or create ceiling visplane
    if (sector.ceilingheight.gt(rstate.viewz) or sector.ceilingpic == pstate.skyflatnum) {
        pstate.ceilingplane = pstate.findPlane(
            sector.ceilingheight,
            sector.ceilingpic,
            sector.lightlevel,
        );
    } else {
        pstate.ceilingplane = null;
    }

    // Render each seg in this subsector
    const first = ssec.firstline;
    const count = ssec.numlines;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const seg_idx = first + i;
        if (seg_idx < level.segs.len) {
            addLine(seg_idx, level, rstate, pstate, rdata, screen);
        }
    }
}

/// Process a single seg — clip to view and add visible portion
fn addLine(
    seg_idx: u16,
    level: *const setup.Level,
    rstate: *RenderState,
    pstate: *planes.PlaneState,
    rdata: *RenderData,
    screen: [*]u8,
) void {
    const seg = &level.segs[seg_idx];
    const v1 = &level.vertices[seg.v1];
    const v2 = &level.vertices[seg.v2];

    // Transform to view-relative angles
    const angle1 = rstate.pointToAngle(v1.x, v1.y);
    const angle2 = rstate.pointToAngle(v2.x, v2.y);

    // Back face cull
    const span = angle1 -% angle2;
    if (span >= fixed.ANG180) return; // facing away

    // Clip to field of view
    var rw_angle1 = angle1;
    const offset_angle = angle1 -% rstate.viewangle;

    // Normalize to clip against screen edges
    var tspan = offset_angle +% fixed.ANG90;
    if (tspan > 2 * fixed.ANG90) {
        // Partially or fully off left edge
        tspan -%= 2 * fixed.ANG90;
        if (tspan >= span) return; // Completely off screen
        rw_angle1 = rstate.viewangle +% fixed.ANG90;
    }

    const offset_angle2 = rstate.viewangle -% angle2;
    tspan = offset_angle2 +% fixed.ANG90;
    if (tspan > 2 * fixed.ANG90) {
        tspan -%= 2 * fixed.ANG90;
        if (tspan >= span) return;
    }

    // Project to screen columns
    const x1 = viewAngleToX(rw_angle1 -% rstate.viewangle);
    const x2 = viewAngleToX((rstate.viewangle -% angle2));

    if (x1 >= x2) return; // zero width

    // Check against solid segs for occlusion
    if (isRangeOccluded(rstate, x1, x2 - 1)) return;

    // Render this seg
    segs.renderSeg(seg_idx, x1, x2 - 1, rw_angle1, level, rstate, pstate, rdata, screen);

    // If one-sided, add to solidsegs
    const line = &level.lines[seg.linedef];
    if (line.sidenum[1] < 0) {
        clipSolidSegRange(rstate, x1, x2 - 1);
    } else if (seg.backsector) |back_idx| {
        if (back_idx < level.sectors.len) {
            const front_idx = seg.frontsector orelse return;
            if (front_idx >= level.sectors.len) return;
            const front = &level.sectors[front_idx];
            const back = &level.sectors[back_idx];

            // Close door or window that blocks all view
            if (back.ceilingheight.le(front.floorheight) or
                back.floorheight.ge(front.ceilingheight))
            {
                clipSolidSegRange(rstate, x1, x2 - 1);
            }
        }
    }
}

/// Convert a view-relative angle to a screen X coordinate
fn viewAngleToX(angle: Angle) i32 {
    // Angle is relative to center of view
    // ANG90 maps to x=0, -ANG90 maps to x=SCREENWIDTH
    if (angle > fixed.ANG180) {
        // Negative angle (right side of screen)
        const neg_angle = 0 -% angle;
        const fine = neg_angle >> tables.ANGLETOFINESHIFT;
        if (fine < 4096) {
            const t = tables.finetangent[fine];
            const x = SCREENWIDTH / 2 + Fixed.mul(t, Fixed.fromInt(SCREENWIDTH / 2)).toInt();
            return std.math.clamp(x, 0, SCREENWIDTH);
        }
        return SCREENWIDTH;
    } else {
        // Positive angle (left side of screen)
        const fine = angle >> tables.ANGLETOFINESHIFT;
        if (fine < 4096) {
            const t = tables.finetangent[fine];
            const x = SCREENWIDTH / 2 - Fixed.mul(t, Fixed.fromInt(SCREENWIDTH / 2)).toInt();
            return std.math.clamp(x, 0, SCREENWIDTH);
        }
        return 0;
    }
}

/// Check if a screen column range is fully occluded
fn isRangeOccluded(rstate: *const RenderState, first: i32, last: i32) bool {
    for (rstate.solidsegs[0..rstate.num_solidsegs]) |ss| {
        if (ss.first <= first and ss.last >= last) return true;
    }
    return false;
}

/// Add a range to the solid segments list
fn clipSolidSegRange(rstate: *RenderState, first: i32, last: i32) void {
    // Find the solid seg to merge with or insert before
    var i: usize = 0;
    while (i < rstate.num_solidsegs) : (i += 1) {
        if (rstate.solidsegs[i].last >= first - 1) break;
    }

    if (i >= rstate.num_solidsegs) return;

    // Merge with existing ranges
    if (first < rstate.solidsegs[i].first) {
        if (last < rstate.solidsegs[i].first - 1) {
            // Insert new range before i
            if (rstate.num_solidsegs >= rstate.solidsegs.len) return;
            var j = rstate.num_solidsegs;
            while (j > i) : (j -= 1) {
                rstate.solidsegs[j] = rstate.solidsegs[j - 1];
            }
            rstate.solidsegs[i] = .{ .first = first, .last = last };
            rstate.num_solidsegs += 1;
            return;
        }
        rstate.solidsegs[i].first = first;
    }

    if (last <= rstate.solidsegs[i].last) return;

    // Extend and merge with subsequent ranges
    rstate.solidsegs[i].last = last;

    // Remove any ranges that are now covered
    const j = i + 1;
    while (j < rstate.num_solidsegs and rstate.solidsegs[j].first <= last + 1) {
        if (rstate.solidsegs[j].last > last) {
            rstate.solidsegs[i].last = rstate.solidsegs[j].last;
        }
        // Remove range j by shifting
        var k = j;
        while (k + 1 < rstate.num_solidsegs) : (k += 1) {
            rstate.solidsegs[k] = rstate.solidsegs[k + 1];
        }
        rstate.num_solidsegs -= 1;
    }
}

test "viewAngleToX" {
    // Angle 0 (looking straight ahead) should map to center of screen
    const center = viewAngleToX(0);
    // viewAngleToX maps view-relative angles, 0 = center
    try std.testing.expect(center >= 0 and center <= SCREENWIDTH);
}

test "pointOnSide axis-aligned" {
    const node = setup.Node{
        .x = Fixed.fromInt(0),
        .y = Fixed.fromInt(0),
        .dx = Fixed.ZERO,
        .dy = Fixed.fromInt(1),
        .bbox = undefined,
        .children = .{ 0, 0 },
    };
    // Point to the right of a vertical partition
    const side = pointOnSide(Fixed.fromInt(10), Fixed.fromInt(0), &node);
    try std.testing.expectEqual(@as(usize, 0), side);
    // Point to the left
    const side2 = pointOnSide(Fixed.fromInt(-10), Fixed.fromInt(0), &node);
    try std.testing.expectEqual(@as(usize, 1), side2);
}
