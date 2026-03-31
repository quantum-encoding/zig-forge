//! zig_doom/src/play/telept.zig
//!
//! Teleportation — move player/monster to teleport destination.
//! Translated from: linuxdoom-1.10/p_telept.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const ANG180 = fixed.ANG180;
const info = @import("../info.zig");
const MobjType = info.MobjType;
const MF_MISSILE = info.MF_MISSILE;
const defs = @import("../defs.zig");
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const setup = @import("setup.zig");
const Level = setup.Level;

// ============================================================================
// EV_Teleport — teleport a thing to a tagged sector's teleport destination
// ============================================================================

/// Teleport thing to a sector matching the line's tag.
/// Returns true if teleportation occurred.
pub fn EV_Teleport(line: *const setup.Line, side: i32, thing: *MapObject, level: *Level, allocator: std.mem.Allocator) bool {
    // Don't teleport missiles
    if (thing.flags & MF_MISSILE != 0) {
        return false;
    }

    // Only teleport from front side (side 0)
    if (side == 1) {
        return false;
    }

    // Search for a teleport destination in tagged sectors
    for (level.sectors, 0..) |sector, sector_i| {
        if (sector.tag != line.tag) continue;

        // Find a MT_TELEPORTMAN in this sector
        // We need to search all thinkers for a MapObject of type MT_TELEPORTMAN
        // whose position falls within this sector
        const dest = findTeleportDest(sector_i, level) orelse continue;

        // Save old position for fog
        const old_x = thing.x;
        const old_y = thing.y;
        const old_z = thing.z;
        const old_angle = thing.angle;

        // Move the thing to destination
        thing.x = dest.x;
        thing.y = dest.y;
        thing.z = dest.floorz;
        thing.angle = dest.angle;

        // Stop all momentum
        thing.momx = Fixed.ZERO;
        thing.momy = Fixed.ZERO;
        thing.momz = Fixed.ZERO;

        // Set reaction time to prevent immediate re-trigger
        thing.reaction_time = 18;

        // Spawn teleport fog at old and new positions
        _ = mobj_mod.spawnMobj(old_x, old_y, old_z, .MT_TFOG, allocator) catch {};
        const an = dest.angle >> @import("../tables.zig").ANGLETOFINESHIFT;
        const tables = @import("../tables.zig");
        const fog_x = Fixed.add(dest.x, Fixed.mul(Fixed.fromRaw(20 * fixed.FRAC_UNIT.raw()), tables.finecosine[an & tables.FINEMASK]));
        const fog_y = Fixed.add(dest.y, Fixed.mul(Fixed.fromRaw(20 * fixed.FRAC_UNIT.raw()), tables.finesine[an & tables.FINEMASK]));
        _ = mobj_mod.spawnMobj(fog_x, fog_y, thing.z, .MT_TFOG, allocator) catch {};

        // If player, set delta viewheight for landing effect
        if (thing.player != null) {
            const user = @import("user.zig");
            const player: *user.Player = @ptrCast(@alignCast(thing.player.?));
            player.viewz = Fixed.add(thing.z, player.viewheight);
            player.deltaviewheight = Fixed.ZERO;
        }

        _ = old_angle;

        return true;
    }

    return false;
}

/// Teleport destination info
const TeleportDest = struct {
    x: Fixed,
    y: Fixed,
    floorz: Fixed,
    angle: Angle,
};

/// Find a MT_TELEPORTMAN mobj in the given sector.
/// Searches the thinker list for map objects.
fn findTeleportDest(sector_idx: usize, level: *Level) ?TeleportDest {
    // Search all things in the level (spawn points) for teleport destinations
    for (level.things) |thing| {
        // MT_TELEPORTMAN has doomednum 14
        if (thing.thing_type == 14) {
            // Check if this thing is in the target sector
            // Simplified: check if the thing's position falls within any subsector of the target sector
            // For now, just match by checking which sector the position belongs to
            const thing_sector = findSectorForPoint(
                Fixed.fromInt(@as(i32, thing.x)),
                Fixed.fromInt(@as(i32, thing.y)),
                level,
            );
            if (thing_sector == sector_idx) {
                return TeleportDest{
                    .x = Fixed.fromInt(@as(i32, thing.x)),
                    .y = Fixed.fromInt(@as(i32, thing.y)),
                    .floorz = level.sectors[sector_idx].floorheight,
                    .angle = @as(Angle, @intCast(thing.angle)) *% (0x100000000 / 360),
                };
            }
        }
    }
    return null;
}

/// Find which sector a point belongs to using BSP traversal
fn findSectorForPoint(x: Fixed, y: Fixed, level: *Level) usize {
    if (level.nodes.len == 0) {
        // No BSP nodes — single subsector
        if (level.subsectors.len > 0) {
            return level.subsectors[0].sector orelse 0;
        }
        return 0;
    }

    var node_idx: u16 = level.num_nodes -% 1;

    while (true) {
        if (node_idx & defs.NF_SUBSECTOR != 0) {
            // It's a subsector
            const ss_idx = node_idx & ~defs.NF_SUBSECTOR;
            if (ss_idx < level.subsectors.len) {
                return level.subsectors[ss_idx].sector orelse 0;
            }
            return 0;
        }

        if (node_idx >= level.nodes.len) return 0;

        const node = &level.nodes[node_idx];
        // Point on which side of partition line?
        const side = pointOnSide(x, y, node);
        node_idx = node.children[side];
    }
}

/// Determine which side of a BSP node partition line a point is on
fn pointOnSide(x: Fixed, y: Fixed, node: *const setup.Node) usize {
    const dx = Fixed.sub(x, node.x);
    const dy = Fixed.sub(y, node.y);

    // Cross product: (dx * node.dy - dy * node.dx)
    const left: i64 = @as(i64, dy.raw()) * @as(i64, node.dx.raw());
    const right: i64 = @as(i64, dx.raw()) * @as(i64, node.dy.raw());

    if (right < left) return 0; // Front (right side)
    return 1; // Back (left side)
}

// ============================================================================
// Tests
// ============================================================================

test "teleport dest struct size" {
    try std.testing.expect(@sizeOf(TeleportDest) > 0);
}

test "pointOnSide basic" {
    const node = setup.Node{
        .x = Fixed.ZERO,
        .y = Fixed.ZERO,
        .dx = Fixed.fromInt(10), // Eastward partition
        .dy = Fixed.ZERO,
        .bbox = undefined,
        .children = .{ 0, 1 },
    };

    // Point above partition (positive y) — cross product determines side
    const side1 = pointOnSide(Fixed.fromInt(5), Fixed.fromInt(5), &node);
    // Point below partition (negative y)
    const side2 = pointOnSide(Fixed.fromInt(5), Fixed.fromInt(-5), &node);
    // The two sides should be different
    try std.testing.expect(side1 != side2);
}
