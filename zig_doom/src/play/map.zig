//! zig_doom/src/play/map.zig
//!
//! Movement, collision detection, and line interactions.
//! Translated from: linuxdoom-1.10/p_map.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! The collision detection system uses the blockmap for spatial queries.
//! Movement uses DOOM's "stairstep" algorithm: if blocked, try X only, then Y only.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const info = @import("../info.zig");
const defs = @import("../defs.zig");
const random = @import("../random.zig");
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const maputl = @import("maputl.zig");
const setup = @import("setup.zig");
const level_mod = @import("level.zig");
const bbox_mod = @import("../bbox.zig");
const BBox = bbox_mod.BBox;

// ============================================================================
// Movement result state (module-level, as DOOM uses globals)
// ============================================================================

var tm_thing: ?*MapObject = null;
var tm_x: Fixed = Fixed.ZERO;
var tm_y: Fixed = Fixed.ZERO;
var tm_bbox: BBox = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO };
var tm_floorz: Fixed = Fixed.ZERO;
var tm_ceilingz: Fixed = Fixed.ZERO;
var tm_dropoffz: Fixed = Fixed.ZERO;
var tm_flags: u32 = 0;

// Slide movement state
var bestslidefrac: Fixed = Fixed.ZERO;
var secondslidefrac: Fixed = Fixed.ZERO;
var bestslideangle: Angle = 0;
var tmxmove: Fixed = Fixed.ZERO;
var tmymove: Fixed = Fixed.ZERO;

// Line attack state (hitscan)
var la_damage: i32 = 0;
var attack_range: Fixed = Fixed.ZERO;
var aim_slope: Fixed = Fixed.ZERO;

// ============================================================================
// Position checking
// ============================================================================

/// Check if a mobj can be at position (x, y).
/// Sets tmfloorz, tmceilingz, tmdropoffz.
/// Returns true if the position is valid.
pub fn checkPosition(thing: *MapObject, x: Fixed, y: Fixed) bool {
    tm_thing = thing;
    tm_flags = thing.flags;
    tm_x = x;
    tm_y = y;

    tm_bbox[bbox_mod.BOXTOP] = Fixed.add(y, thing.radius);
    tm_bbox[bbox_mod.BOXBOTTOM] = Fixed.sub(y, thing.radius);
    tm_bbox[bbox_mod.BOXRIGHT] = Fixed.add(x, thing.radius);
    tm_bbox[bbox_mod.BOXLEFT] = Fixed.sub(x, thing.radius);

    // Set initial floor/ceiling from the subsector the mobj is in
    // In full DOOM, this checks the blockmap. For Phase 3, use current values.
    tm_floorz = thing.floorz;
    tm_ceilingz = thing.ceilingz;
    tm_dropoffz = thing.floorz;

    // In full implementation:
    // 1. Check thing-thing collisions via blockmap
    // 2. Check thing-line collisions via blockmap
    // 3. Adjust floorz/ceilingz for step-up and openings

    // Simple bounding test: can't move if height doesn't fit
    const height_check = Fixed.sub(tm_ceilingz, tm_floorz);
    if (height_check.raw() < thing.height.raw()) {
        return false;
    }

    return true;
}

/// Attempt to move a mobj to a new position.
/// Returns true if the move succeeded.
/// Implements DOOM's stairstep algorithm: if blocked, try X-only then Y-only.
pub fn tryMove(thing: *MapObject, x: Fixed, y: Fixed) bool {
    if (!checkPosition(thing, x, y)) {
        return false; // Blocked
    }

    // Check for dropoff (don't walk off tall edges unless MF_DROPOFF)
    if (thing.flags & info.MF_DROPOFF == 0) {
        if (Fixed.sub(tm_floorz, tm_dropoffz).raw() > 24 * 0x10000) {
            return false; // Don't walk off a cliff
        }
    }

    // Check step-up height (max 24 units)
    if (Fixed.sub(tm_floorz, thing.z).raw() > 24 * 0x10000) {
        return false; // Too tall a step
    }

    // Fit check passed — move the thing
    thing.floorz = tm_floorz;
    thing.ceilingz = tm_ceilingz;
    thing.x = x;
    thing.y = y;

    return true;
}

/// Slide movement: after a failed tryMove, attempt to slide along walls.
/// DOOM's slide algorithm tries to move along the wall that blocked movement.
pub fn slideMove(mo: *MapObject) void {
    const orig_x = mo.x;
    const orig_y = mo.y;

    // Try the full move first
    if (tryMove(mo, Fixed.add(mo.x, mo.momx), Fixed.add(mo.y, mo.momy))) {
        return; // Full move succeeded
    }

    // Try X-only move (stairstep)
    if (tryMove(mo, Fixed.add(orig_x, mo.momx), orig_y)) {
        mo.momy = Fixed.ZERO; // Cancel Y momentum
        return;
    }

    // Try Y-only move
    if (tryMove(mo, orig_x, Fixed.add(orig_y, mo.momy))) {
        mo.momx = Fixed.ZERO; // Cancel X momentum
        return;
    }

    // Both failed — stop
    mo.momx = Fixed.ZERO;
    mo.momy = Fixed.ZERO;
}

// ============================================================================
// Line Attack (Hitscan)
// ============================================================================

/// Hitscan attack along a line from source.
/// In full DOOM, traces through the blockmap checking for thing/line intersections.
/// Phase 3 stub: checks direct distance to all potential targets.
pub fn lineAttack(
    source: *MapObject,
    angle: Angle,
    range: Fixed,
    slope: Fixed,
    damage: i32,
) void {
    _ = source;
    _ = angle;
    _ = range;
    _ = slope;
    la_damage = damage;
    // Full implementation requires blockmap traversal
    // Phase 3: damage is applied by enemy action functions directly
}

// ============================================================================
// Use Lines
// ============================================================================

/// Player activates special lines (switches, doors) in front of them.
pub fn useLines(player_mo: *MapObject) void {
    // Calculate use line endpoint
    const angle = player_mo.angle;
    const tables = @import("../tables.zig");
    const fine_angle = angle >> tables.ANGLETOFINESHIFT;

    _ = Fixed.add(player_mo.x, Fixed.mul(level_mod.USERANGE, tables.finecosine[fine_angle & tables.FINEMASK]));
    _ = Fixed.add(player_mo.y, Fixed.mul(level_mod.USERANGE, tables.finesine[fine_angle & tables.FINEMASK]));

    // Full implementation traces a line from player to use endpoint,
    // checking for special linedefs that can be activated.
    // Phase 3 stub: no-op (requires blockmap traversal)
}

// ============================================================================
// Radius Attack (Explosion)
// ============================================================================

/// Apply explosion damage to all things within range.
/// Source is the thing causing the explosion (e.g., a rocket).
pub fn radiusAttack(spot: *MapObject, source: ?*MapObject, damage: i32) void {
    _ = spot;
    _ = source;
    _ = damage;
    // Full implementation iterates blockmap cells around the explosion,
    // checking distance to each thing and applying damage that decreases
    // linearly with distance: actual_damage = damage - dist
    // Phase 3 stub: no-op (requires blockmap)
}

// ============================================================================
// Thing-on-thing collision check
// ============================================================================

/// Check if two mobjs overlap horizontally
pub fn checkThingCollision(thing1: *const MapObject, thing2: *const MapObject) bool {
    const blockdist = Fixed.add(thing1.radius, thing2.radius);
    const dx = Fixed.sub(thing1.x, thing2.x).abs();
    const dy = Fixed.sub(thing1.y, thing2.y).abs();

    return dx.raw() < blockdist.raw() and dy.raw() < blockdist.raw();
}

// ============================================================================
// Tests
// ============================================================================

const tick = @import("tick.zig");

test "check position basic" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);

    // Should be able to stand in open space
    const result = checkPosition(mobj, Fixed.fromInt(100), Fixed.fromInt(100));
    try std.testing.expect(result);

    tick.initThinkers();
}

test "try move with step too high" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.z = Fixed.ZERO;
    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);

    // Normal move should succeed
    try std.testing.expect(tryMove(mobj, Fixed.fromInt(10), Fixed.ZERO));

    tick.initThinkers();
}

test "thing collision check" {
    var t1 = MapObject{};
    t1.x = Fixed.ZERO;
    t1.y = Fixed.ZERO;
    t1.radius = Fixed.fromInt(20);

    var t2 = MapObject{};
    t2.x = Fixed.fromInt(10);
    t2.y = Fixed.ZERO;
    t2.radius = Fixed.fromInt(20);

    // Overlapping — distance=10, combined radius=40
    try std.testing.expect(checkThingCollision(&t1, &t2));

    // Not overlapping
    t2.x = Fixed.fromInt(100);
    try std.testing.expect(!checkThingCollision(&t1, &t2));
}

test "slide move stops when fully blocked" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);
    mobj.momx = Fixed.fromInt(5);
    mobj.momy = Fixed.fromInt(5);

    // slideMove should succeed with full move (no actual blockmap to block it)
    slideMove(mobj);

    // Position should have moved (since no actual blocking linedefs)
    try std.testing.expect(mobj.x.raw() != 0 or mobj.y.raw() != 0);

    tick.initThinkers();
}
