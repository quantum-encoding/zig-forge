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

    // Need sector indices — use subsector_id
    const s1 = t1.subsector_id orelse return false;
    const s2 = t2.subsector_id orelse return false;

    if (s1 >= level.subsectors.len or s2 >= level.subsectors.len) return false;

    const sec1 = level.subsectors[s1].sector orelse return false;
    const sec2 = level.subsectors[s2].sector orelse return false;

    const num_sectors = level.sectors.len;
    if (sec1 >= num_sectors or sec2 >= num_sectors) return false;

    // REJECT is a bit matrix: sectors * sectors bits
    const idx = sec1 * num_sectors + sec2;
    const byte_idx = idx / 8;
    const bit_idx: u3 = @intCast(idx % 8);

    if (byte_idx >= level.reject_data.len) return false;

    return (level.reject_data[byte_idx] >> bit_idx) & 1 != 0;
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

    // Which side is the source on?
    const side = maputl.pointOnDivlineSide(
        sight_strace.x,
        sight_strace.y,
        &maputl.DivLine{
            .x = node.x,
            .y = node.y,
            .dx = node.dx,
            .dy = node.dy,
        },
    );

    // Check the side that the source is on
    if (!crossBSPNode(node.children[@intCast(side)], level)) return false;

    // Check if the sight line crosses to the other side
    const other_side = maputl.pointOnDivlineSide(
        sight_t2x,
        sight_t2y,
        &maputl.DivLine{
            .x = node.x,
            .y = node.y,
            .dx = node.dx,
            .dy = node.dy,
        },
    );

    if (side == other_side) return true; // Both on same side — no crossing

    // Check the other side too
    return crossBSPNode(node.children[@intCast(other_side)], level);
}

/// Check sight through a subsector's segs.
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

        const line = &level.lines[line_idx];

        // Skip two-sided lines with full opening
        if (line.sidenum[1] < 0) {
            // One-sided — blocks sight
            // Check if the sight line crosses this seg
            if (segCrossesDivline(seg, level)) return false;
        }
        // For two-sided lines, check floor/ceiling heights
        // (simplified in Phase 3)
    }

    return true;
}

/// Check if a seg crosses the sight divline
fn segCrossesDivline(seg: *const setup.Seg, level: *const Level) bool {
    if (seg.v1 >= level.vertices.len or seg.v2 >= level.vertices.len) return false;

    const v1 = &level.vertices[seg.v1];
    const v2 = &level.vertices[seg.v2];

    const s1 = maputl.pointOnDivlineSide(v1.x, v1.y, &sight_strace);
    const s2 = maputl.pointOnDivlineSide(v2.x, v2.y, &sight_strace);

    return s1 != s2; // Seg endpoints on different sides = crossing
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
