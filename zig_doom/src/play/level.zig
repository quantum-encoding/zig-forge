//! zig_doom/src/play/level.zig
//!
//! Runtime level types shared between renderer and playsim.
//! Extends setup.zig's basic structures with gameplay fields.
//! Translated from: linuxdoom-1.10/p_local.h, r_defs.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const bbox_mod = @import("../bbox.zig");
const BBox = bbox_mod.BBox;
const setup = @import("setup.zig");

// Re-export setup types that playsim uses directly
pub const Vertex = setup.Vertex;
pub const SlopeType = setup.SlopeType;
pub const Node = setup.Node;
pub const Level = setup.Level;

// Forward-declare MapObject from mobj.zig — use opaque pointer to break circular dependency
pub const MapObjectPtr = *anyopaque;

// ============================================================================
// Constants
// ============================================================================

pub const MAXRADIUS = Fixed.fromRaw(32 * fixed.FRAC_UNIT.raw()); // 32.0 in fixed
pub const MAXMOVE = Fixed.fromRaw(30 * fixed.FRAC_UNIT.raw()); // 30.0
pub const GRAVITY = Fixed.fromRaw(fixed.FRAC_UNIT.raw()); // 1.0
pub const VIEWHEIGHT = Fixed.fromRaw(41 * fixed.FRAC_UNIT.raw()); // 41.0
pub const USERANGE = Fixed.fromRaw(64 * fixed.FRAC_UNIT.raw()); // 64.0
pub const MELEERANGE = Fixed.fromRaw(64 * fixed.FRAC_UNIT.raw()); // 64.0
pub const MISSILERANGE = Fixed.fromRaw(32 * 64 * fixed.FRAC_UNIT.raw()); // 2048.0
pub const FLOATSPEED = Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()); // 4.0
pub const FRICTION = Fixed.fromRaw(0xE800); // 0.90625

// Movement directions: 8 cardinal+diagonal + DI_NODIR
pub const DI_EAST = 0;
pub const DI_NORTHEAST = 1;
pub const DI_NORTH = 2;
pub const DI_NORTHWEST = 3;
pub const DI_WEST = 4;
pub const DI_SOUTHWEST = 5;
pub const DI_SOUTH = 6;
pub const DI_SOUTHEAST = 7;
pub const DI_NODIR = 8;
pub const NUMDIRS = 8;

// Direction deltas: x and y movement for each direction
pub const xspeed = [8]Fixed{
    Fixed.fromRaw(fixed.FRAC_UNIT.raw()), // east
    Fixed.fromRaw(47000), // northeast (~0.7071)
    Fixed.ZERO, // north
    Fixed.fromRaw(-47000), // northwest
    Fixed.fromRaw(-fixed.FRAC_UNIT.raw()), // west
    Fixed.fromRaw(-47000), // southwest
    Fixed.ZERO, // south
    Fixed.fromRaw(47000), // southeast
};

pub const yspeed = [8]Fixed{
    Fixed.ZERO, // east
    Fixed.fromRaw(47000), // northeast
    Fixed.fromRaw(fixed.FRAC_UNIT.raw()), // north
    Fixed.fromRaw(47000), // northwest
    Fixed.ZERO, // west
    Fixed.fromRaw(-47000), // southwest
    Fixed.fromRaw(-fixed.FRAC_UNIT.raw()), // south
    Fixed.fromRaw(-47000), // southeast
};

// Opposite and diagonal direction tables for monster movement
pub const opposite = [9]u8{ DI_WEST, DI_SOUTHWEST, DI_SOUTH, DI_SOUTHEAST, DI_EAST, DI_NORTHEAST, DI_NORTH, DI_NORTHWEST, DI_NODIR };
pub const diags = [4]u8{ DI_NORTHWEST, DI_NORTHEAST, DI_SOUTHWEST, DI_SOUTHEAST };

test "level constants" {
    try std.testing.expect(GRAVITY.raw() == fixed.FRAC_UNIT.raw());
    try std.testing.expect(FRICTION.raw() == 0xE800);
    try std.testing.expectEqual(@as(usize, 8), xspeed.len);
    try std.testing.expectEqual(@as(usize, 8), yspeed.len);
}
