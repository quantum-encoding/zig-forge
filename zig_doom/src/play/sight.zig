//! zig_doom/src/play/sight.zig
//!
//! Line of sight / sight checking.
//! Translated from: linuxdoom-1.10/p_sight.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Determines whether one mobj can see another using BSP tree traversal.
//! Checks the REJECT lump for quick sector-pair rejection, then traces
//! a line through the BSP checking for blocking one-sided lines and
//! floor/ceiling height restrictions.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const defs = @import("../defs.zig");
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const maputl = @import("maputl.zig");
const setup = @import("setup.zig");
const Level = setup.Level;

// ============================================================================
// Module-level state (DOOM uses globals for sight checking)
// ============================================================================

var sight_zstart: Fixed = Fixed.ZERO; // z to shoot from (source z + height*3/4)
var sight_ztopslope: Fixed = Fixed.ZERO; // top of target
var sight_zbottomslope: Fixed = Fixed.ZERO; // bottom of target
var sight_strace: maputl.DivLine = undefined; // from source to target
var sight_t2x: Fixed = Fixed.ZERO;
var sight_t2y: Fixed = Fixed.ZERO;

// ============================================================================
// Line of sight check
// ============================================================================

/// Check if source can see target.
/// Requires a loaded level for BSP/reject data.
/// Returns true if there is a clear line of sight.
pub fn checkSight(t1: *const MapObject, t2: *const MapObject, level: ?*const Level) bool {
    // Quick reject: same position
    if (t1.x.eql(t2.x) and t1.y.eql(t2.y)) return true;

    // Check REJECT lump (precomputed sector-pair visibility matrix)
    if (level) |lvl| {
        if (rejectCheck(t1, t2, lvl)) return false;
    }

    // Set up sight trace
    sight_zstart = Fixed.add(t1.z, Fixed.fromRaw(@divTrunc(t1.height.raw() * 3, 4)));

    sight_ztopslope = Fixed.sub(
        Fixed.add(t2.z, t2.height),
        sight_zstart,
    );
    sight_zbottomslope = Fixed.sub(t2.z, sight_zstart);

    sight_strace = .{
        .x = t1.x,
        .y = t1.y,
        .dx = Fixed.sub(t2.x, t1.x),
        .dy = Fixed.sub(t2.y, t1.y),
    };

    if (level) |lvl| resetLineChecked(lvl.lines.len);

    sight_t2x = t2.x;
    sight_t2y = t2.y;

    // Traverse BSP tree for LOS
    if (level) |lvl| {
        if (lvl.num_nodes > 0) {
            return crossBSPNode(lvl.num_nodes - 1, lvl);
        }
    }

    // No BSP data available — assume visible
    return true;
}

/// Quick check using REJECT lump.
/// Returns true if the sectors can NOT see each other (rejected).
fn rejectCheck(t1: *const MapObject, t2: *const MapObject, level: *const Level) bool {
    if (level.reject_data.len == 0) return false;

    const sec1 = sectorIndexAt(level, t1.x, t1.y) orelse return false;
    const sec2 = sectorIndexAt(level, t2.x, t2.y) orelse return false;

    const num_sectors = level.sectors.len;
    if (sec1 >= num_sectors or sec2 >= num_sectors) return false;

    // REJECT is a bit matrix: sectors * sectors bits
    const idx = sec1 * num_sectors + sec2;
    const byte_idx = idx / 8;
    const bit_idx: u3 = @intCast(idx % 8);

    if (byte_idx >= level.reject_data.len) return false;

    return (level.reject_data[byte_idx] >> bit_idx) & 1 != 0;
}

/// Sector index containing a point (BSP walk)
fn sectorIndexAt(level: *const Level, x: Fixed, y: Fixed) ?usize {
    if (level.num_nodes == 0) {
        if (level.subsectors.len > 0) { if (level.subsectors[0].sector) |si| return si; }
        return null;
    }
    var node_id: u16 = @intCast(level.num_nodes - 1);
    while (node_id & defs.NF_SUBSECTOR == 0) {
        if (node_id >= level.nodes.len) return null;
        const node = &level.nodes[node_id];
        const side = maputl.rPointOnSide(x, y, node.x, node.y, node.dx, node.dy);
        node_id = node.children[side];
    }
    const ssi = node_id & ~@as(u16, defs.NF_SUBSECTOR);
    if (ssi >= level.subsectors.len) return null;
    if (level.subsectors[ssi].sector) |si| return si;
    return null;
}

/// Recursively traverse BSP tree to check sight.
/// Returns true if sight is not blocked.
fn crossBSPNode(bsp_num: u16, level: *const Level) bool {
    if (bsp_num & defs.NF_SUBSECTOR != 0) {
        // It's a subsector — check the segs
        const sub_num = bsp_num & ~defs.NF_SUBSECTOR;
        return crossSubsector(sub_num, level);
    }

    if (bsp_num >= level.nodes.len) return true;

    const node = &level.nodes[bsp_num];
    const dl = maputl.DivLine{ .x = node.x, .y = node.y, .dx = node.dx, .dy = node.dy };

    // Which side is the source on? (on-line counts as front)
    var side = divlineSide(sight_strace.x, sight_strace.y, &dl);
    if (side == 2) side = 0;

    // Check the side that the source is on
    if (!crossBSPNode(node.children[@intCast(side)], level)) return false;

    // The partition plane is crossed here?
    if (divlineSide(sight_t2x, sight_t2y, &dl) == side) {
        return true; // The line doesn't touch the other side
    }

    // Cross the ending side
    return crossBSPNode(node.children[@intCast(side ^ 1)], level);
}

/// Vanilla p_sight.c P_DivlineSide — coarse (FRACBITS-shifted) side test.
/// Returns 0 (front), 1 (back), or 2 (on the line). Faithfully includes the
/// vanilla `x == node->y` typo in the horizontal-line branch.
fn divlineSide(x: Fixed, y: Fixed, node: *const maputl.DivLine) i32 {
    if (node.dx.raw() == 0) {
        if (x.raw() == node.x.raw()) return 2;
        if (x.raw() <= node.x.raw()) {
            return if (node.dy.raw() > 0) 1 else 0;
        }
        return if (node.dy.raw() < 0) 1 else 0;
    }

    if (node.dy.raw() == 0) {
        if (x.raw() == node.y.raw()) return 2; // vanilla typo: x vs y — kept!
        if (y.raw() <= node.y.raw()) {
            return if (node.dx.raw() < 0) 1 else 0;
        }
        return if (node.dx.raw() > 0) 1 else 0;
    }

    const dx = x.raw() -% node.x.raw();
    const dy = y.raw() -% node.y.raw();
    const left: i32 = (node.dy.raw() >> 16) *% (dx >> 16);
    const right: i32 = (dy >> 16) *% (node.dx.raw() >> 16);

    if (right < left) return 0; // front side
    if (left == right) return 2;
    return 1; // back side
}

/// Per-call line-visited guard (vanilla uses line->validcount)
var line_checked: [8192]bool = undefined;
var line_checked_len: usize = 0;

pub fn resetLineChecked(count: usize) void {
    line_checked_len = @min(count, line_checked.len);
    @memset(line_checked[0..line_checked_len], false);
}

/// Check sight through a subsector's segs (PS_CrossSubsector, faithful).
/// Narrows the vertical sight window through two-sided openings; one-sided
/// lines and closed openings block.
fn crossSubsector(sub_num: u16, level: *const Level) bool {
    if (sub_num >= level.subsectors.len) return true;

    const sub = &level.subsectors[sub_num];
    const first_line: usize = sub.firstline;
    const num_lines: usize = sub.numlines;

    for (first_line..first_line + num_lines) |seg_idx| {
        if (seg_idx >= level.segs.len) continue;

        const seg = &level.segs[seg_idx];
        const line_idx: usize = seg.linedef;
        if (line_idx >= level.lines.len) continue;

        // Each line only needs checking once per sight trace
        if (line_idx < line_checked_len) {
            if (line_checked[line_idx]) continue;
            line_checked[line_idx] = true;
        }

        const line = &level.lines[line_idx];
        const v1 = &level.vertices[line.v1];
        const v2 = &level.vertices[line.v2];

        // Line endpoints on the same side of the trace? Not crossed.
        const s1 = divlineSide(v1.x, v1.y, &sight_strace);
        const s2 = divlineSide(v2.x, v2.y, &sight_strace);
        if (s1 == s2) continue;

        // Trace endpoints on the same side of the line? Not crossed.
        const dl = maputl.DivLine{ .x = v1.x, .y = v1.y, .dx = line.dx, .dy = line.dy };
        const t1s = divlineSide(sight_strace.x, sight_strace.y, &dl);
        const t2s = divlineSide(sight_t2x, sight_t2y, &dl);
        if (t1s == t2s) continue;

        // One-sided lines always block sight
        if (line.backsector == null) return false;
        if (line.flags & defs.ML_TWOSIDED == 0) return false;

        // Heights come from the SEG's sectors (vanilla), not the line's
        const front_idx = seg.frontsector orelse return false;
        const back_idx = seg.backsector orelse return false;
        const front = &level.sectors[front_idx];
        const back = &level.sectors[back_idx];

        // No height change — nothing to block with
        if (front.floorheight.raw() == back.floorheight.raw() and
            front.ceilingheight.raw() == back.ceilingheight.raw())
        {
            continue;
        }

        const opentop = if (front.ceilingheight.raw() < back.ceilingheight.raw())
            front.ceilingheight
        else
            back.ceilingheight;
        const openbottom = if (front.floorheight.raw() > back.floorheight.raw())
            front.floorheight
        else
            back.floorheight;

        // Totally closed (door)?
        if (openbottom.raw() >= opentop.raw()) return false;

        const frac = maputl.interceptVector(
            sight_strace.x,
            sight_strace.y,
            sight_strace.dx,
            sight_strace.dy,
            dl.x,
            dl.y,
            dl.dx,
            dl.dy,
        );
        // Narrow the vertical window through this opening (FixedDiv exact)
        if (front.floorheight.raw() != back.floorheight.raw()) {
            const slope = Fixed.div(Fixed.sub(openbottom, sight_zstart), frac);
            if (slope.raw() > sight_zbottomslope.raw()) sight_zbottomslope = slope;
        }
        if (front.ceilingheight.raw() != back.ceilingheight.raw()) {
            const slope = Fixed.div(Fixed.sub(opentop, sight_zstart), frac);
            if (slope.raw() < sight_ztopslope.raw()) sight_ztopslope = slope;
        }

        if (sight_ztopslope.raw() <= sight_zbottomslope.raw()) return false; // Window closed
    }

    return true;
}

// ============================================================================
// Simplified sight check (no level data needed)
// ============================================================================

/// Simple distance-based sight check (no BSP, no REJECT).
/// Uses maximum sight range of 1024 map units.
pub fn simpleSightCheck(t1: *const MapObject, t2: *const MapObject) bool {
    const dist = maputl.aproxDistance(
        Fixed.sub(t2.x, t1.x),
        Fixed.sub(t2.y, t1.y),
    );

    // Max sight range: 1024 units
    return dist.raw() < 1024 * 0x10000;
}

// ============================================================================
// Tests
// ============================================================================

test "simple sight check" {
    var t1 = MapObject{};
    t1.x = Fixed.ZERO;
    t1.y = Fixed.ZERO;

    var t2 = MapObject{};
    t2.x = Fixed.fromInt(100);
    t2.y = Fixed.ZERO;

    // Within range
    try std.testing.expect(simpleSightCheck(&t1, &t2));

    // Out of range
    t2.x = Fixed.fromInt(2000);
    try std.testing.expect(!simpleSightCheck(&t1, &t2));
}

test "check sight without level data" {
    var t1 = MapObject{};
    t1.x = Fixed.ZERO;
    t1.y = Fixed.ZERO;
    t1.z = Fixed.ZERO;
    t1.height = Fixed.fromInt(56);

    var t2 = MapObject{};
    t2.x = Fixed.fromInt(100);
    t2.y = Fixed.ZERO;
    t2.z = Fixed.ZERO;
    t2.height = Fixed.fromInt(56);

    // Without level data, checkSight should return true (assume visible)
    try std.testing.expect(checkSight(&t1, &t2, null));
}

test "sight same position" {
    var t1 = MapObject{};
    t1.x = Fixed.fromInt(50);
    t1.y = Fixed.fromInt(50);
    t1.z = Fixed.ZERO;
    t1.height = Fixed.fromInt(56);

    // Same position should always be visible
    try std.testing.expect(checkSight(&t1, &t1, null));
}
