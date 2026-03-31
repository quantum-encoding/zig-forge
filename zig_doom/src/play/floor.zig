//! zig_doom/src/play/floor.zig
//!
//! Floor movement — raising/lowering sector floors.
//! Translated from: linuxdoom-1.10/p_floor.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const random = @import("../random.zig");
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const setup = @import("setup.zig");
const Sector = setup.Sector;
const Line = setup.Line;
const Level = setup.Level;

// ============================================================================
// Constants
// ============================================================================

pub const FLOORSPEED = Fixed.fromRaw(fixed.FRAC_UNIT.raw());

// ============================================================================
// Floor Types
// ============================================================================

pub const FloorType = enum {
    lower_floor, // Lower to highest surrounding floor
    lower_floor_to_lowest, // Lower to lowest surrounding floor
    turbo_lower, // Fast lower to 8 above highest surrounding floor
    raise_floor, // Raise to lowest surrounding ceiling
    raise_floor_to_nearest, // Raise to next higher surrounding floor
    raise_to_texture, // Raise by height of shortest lower texture
    lower_and_change, // Lower + change texture/type
    raise_floor_24,
    raise_floor_24_and_change,
    raise_floor_crush, // Raise to ceiling (crushing)
    raise_floor_turbo, // Fast raise
    donut_raise, // Donut inner ring raise
    raise_floor_512,
    raise_floor_by_value, // Generalized
};

pub const StairType = enum {
    build_8, // 8 unit steps
    turbo_16, // 16 unit steps, fast
};

// ============================================================================
// FloorMover thinker
// ============================================================================

pub const FloorMover = struct {
    thinker: Thinker = .{},
    floor_type: FloorType = .lower_floor,
    crush: bool = false,
    sector_idx: u16 = 0,
    direction: i32 = 0, // 1=up, -1=down
    new_special: i16 = 0,
    texture: i16 = 0,
    floor_dest_height: Fixed = Fixed.ZERO,
    speed: Fixed = FLOORSPEED,
};

/// Floor thinker — moves sector floor toward destination
pub fn T_MoveFloor(thinker_ptr: *Thinker) void {
    const floor_mover: *FloorMover = @fieldParentPtr("thinker", thinker_ptr);
    const level = level_ptr orelse return;
    if (floor_mover.sector_idx >= level.sectors.len) return;
    const sector = &level.sectors[floor_mover.sector_idx];

    const result = moveFloor(sector, floor_mover.speed, floor_mover.floor_dest_height, floor_mover.crush, floor_mover.direction);

    switch (result) {
        .pastdest => {
            if (floor_mover.direction == 1) {
                switch (floor_mover.floor_type) {
                    .donut_raise => {
                        sector.special = floor_mover.new_special;
                        sector.floorpic = floor_mover.texture;
                    },
                    else => {},
                }
            } else if (floor_mover.direction == -1) {
                switch (floor_mover.floor_type) {
                    .lower_and_change => {
                        sector.special = floor_mover.new_special;
                        sector.floorpic = floor_mover.texture;
                    },
                    else => {},
                }
            }
            tick.removeThinker(&floor_mover.thinker);
        },
        .crushed => {
            if (floor_mover.crush) {
                // Continue crushing — slow down
                floor_mover.speed = FLOORSPEED;
            }
        },
        .ok => {},
    }
}

// ============================================================================
// Floor movement result
// ============================================================================

const MoveResult = enum {
    ok,
    crushed,
    pastdest,
};

/// Move a sector's floor toward dest
fn moveFloor(sector: *Sector, speed: Fixed, dest: Fixed, crush: bool, direction: i32) MoveResult {
    _ = crush;

    if (direction == -1) {
        // Moving down
        const new_height = Fixed.sub(sector.floorheight, speed);
        if (new_height.raw() <= dest.raw()) {
            sector.floorheight = dest;
            return .pastdest;
        }
        sector.floorheight = new_height;
    } else if (direction == 1) {
        // Moving up
        const new_height = Fixed.add(sector.floorheight, speed);

        // Check if hitting ceiling
        if (new_height.raw() >= sector.ceilingheight.raw()) {
            sector.floorheight = sector.ceilingheight;
            return .crushed;
        }

        if (new_height.raw() >= dest.raw()) {
            sector.floorheight = dest;
            return .pastdest;
        }
        sector.floorheight = new_height;
    }

    return .ok;
}

// ============================================================================
// Level pointer
// ============================================================================

var level_ptr: ?*Level = null;

pub fn setLevel(level: *Level) void {
    level_ptr = level;
}

// ============================================================================
// Helper functions — find surrounding sector heights
// ============================================================================

/// Find the lowest floor height among surrounding sectors
pub fn findLowestFloorSurrounding(sector_idx: u16, level: *Level) Fixed {
    var min_floor = level.sectors[sector_idx].floorheight;

    for (level.lines) |line| {
        const adj = getAdjacentSector(sector_idx, &line);
        if (adj) |adj_idx| {
            if (level.sectors[adj_idx].floorheight.raw() < min_floor.raw()) {
                min_floor = level.sectors[adj_idx].floorheight;
            }
        }
    }

    return min_floor;
}

/// Find the highest floor height among surrounding sectors
pub fn findHighestFloorSurrounding(sector_idx: u16, level: *Level) Fixed {
    var max_floor = Fixed.MIN;

    for (level.lines) |line| {
        const adj = getAdjacentSector(sector_idx, &line);
        if (adj) |adj_idx| {
            if (level.sectors[adj_idx].floorheight.raw() > max_floor.raw()) {
                max_floor = level.sectors[adj_idx].floorheight;
            }
        }
    }

    // If no adjacent sectors found, return sector's own floor
    if (max_floor.eql(Fixed.MIN)) {
        max_floor = level.sectors[sector_idx].floorheight;
    }

    return max_floor;
}

/// Find the next highest floor above the current sector's floor
pub fn findNextHighestFloor(sector_idx: u16, level: *Level) Fixed {
    const current_height = level.sectors[sector_idx].floorheight;
    var min_above = Fixed.MAX;

    for (level.lines) |line| {
        const adj = getAdjacentSector(sector_idx, &line);
        if (adj) |adj_idx| {
            const adj_height = level.sectors[adj_idx].floorheight;
            if (adj_height.raw() > current_height.raw() and adj_height.raw() < min_above.raw()) {
                min_above = adj_height;
            }
        }
    }

    if (min_above.eql(Fixed.MAX)) {
        return current_height;
    }

    return min_above;
}

/// Find the lowest ceiling height among surrounding sectors
pub fn findLowestCeilingSurrounding(sector_idx: u16, level: *Level) Fixed {
    var min_ceil = Fixed.MAX;

    for (level.lines) |line| {
        const adj = getAdjacentSector(sector_idx, &line);
        if (adj) |adj_idx| {
            if (level.sectors[adj_idx].ceilingheight.raw() < min_ceil.raw()) {
                min_ceil = level.sectors[adj_idx].ceilingheight;
            }
        }
    }

    if (min_ceil.eql(Fixed.MAX)) {
        return level.sectors[sector_idx].ceilingheight;
    }

    return min_ceil;
}

/// Find the highest ceiling height among surrounding sectors
pub fn findHighestCeilingSurrounding(sector_idx: u16, level: *Level) Fixed {
    var max_ceil = Fixed.MIN;

    for (level.lines) |line| {
        const adj = getAdjacentSector(sector_idx, &line);
        if (adj) |adj_idx| {
            if (level.sectors[adj_idx].ceilingheight.raw() > max_ceil.raw()) {
                max_ceil = level.sectors[adj_idx].ceilingheight;
            }
        }
    }

    if (max_ceil.eql(Fixed.MIN)) {
        return level.sectors[sector_idx].ceilingheight;
    }

    return max_ceil;
}

/// Get the adjacent sector index on the other side of a line
fn getAdjacentSector(sector_idx: u16, line: *const Line) ?u16 {
    const front = line.frontsector;
    const back = line.backsector;

    if (front) |f| {
        if (f == sector_idx) {
            return back;
        }
    }
    if (back) |b| {
        if (b == sector_idx) {
            return front;
        }
    }
    return null;
}

// ============================================================================
// EV_DoFloor — activate floor movement by tag
// ============================================================================

pub fn EV_DoFloor(line: *const Line, floor_type: FloorType, level: *Level, allocator: std.mem.Allocator) bool {
    var rtn = false;

    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag != line.tag) continue;

        const floor_mover = allocator.create(FloorMover) catch continue;
        floor_mover.* = .{
            .floor_type = floor_type,
            .sector_idx = @intCast(i),
            .crush = false,
        };

        tick.addThinker(&floor_mover.thinker);
        rtn = true;

        switch (floor_type) {
            .lower_floor => {
                floor_mover.direction = -1;
                floor_mover.floor_dest_height = findHighestFloorSurrounding(@intCast(i), level);
            },
            .lower_floor_to_lowest => {
                floor_mover.direction = -1;
                floor_mover.floor_dest_height = findLowestFloorSurrounding(@intCast(i), level);
            },
            .turbo_lower => {
                floor_mover.direction = -1;
                floor_mover.speed = Fixed.fromRaw(FLOORSPEED.raw() * 4);
                floor_mover.floor_dest_height = Fixed.add(
                    findHighestFloorSurrounding(@intCast(i), level),
                    Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()),
                );
                // Don't go below current floor
                if (floor_mover.floor_dest_height.raw() > level.sectors[i].floorheight.raw()) {
                    floor_mover.floor_dest_height = level.sectors[i].floorheight;
                }
            },
            .raise_floor => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = findLowestCeilingSurrounding(@intCast(i), level);
                if (floor_mover.floor_dest_height.raw() > level.sectors[i].ceilingheight.raw()) {
                    floor_mover.floor_dest_height = level.sectors[i].ceilingheight;
                }
            },
            .raise_floor_to_nearest => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = findNextHighestFloor(@intCast(i), level);
            },
            .raise_to_texture => {
                // Raise floor by shortest lower texture height
                // Simplified: raise by 64 units (common texture height)
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = Fixed.add(
                    level.sectors[i].floorheight,
                    Fixed.fromRaw(64 * fixed.FRAC_UNIT.raw()),
                );
            },
            .lower_and_change => {
                floor_mover.direction = -1;
                floor_mover.floor_dest_height = findLowestFloorSurrounding(@intCast(i), level);
            },
            .raise_floor_24 => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = Fixed.add(
                    level.sectors[i].floorheight,
                    Fixed.fromRaw(24 * fixed.FRAC_UNIT.raw()),
                );
            },
            .raise_floor_24_and_change => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = Fixed.add(
                    level.sectors[i].floorheight,
                    Fixed.fromRaw(24 * fixed.FRAC_UNIT.raw()),
                );
            },
            .raise_floor_crush => {
                floor_mover.direction = 1;
                floor_mover.crush = true;
                floor_mover.floor_dest_height = Fixed.sub(
                    level.sectors[i].ceilingheight,
                    Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()),
                );
            },
            .raise_floor_turbo => {
                floor_mover.direction = 1;
                floor_mover.speed = Fixed.fromRaw(FLOORSPEED.raw() * 4);
                floor_mover.floor_dest_height = findNextHighestFloor(@intCast(i), level);
            },
            .raise_floor_512 => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = Fixed.add(
                    level.sectors[i].floorheight,
                    Fixed.fromRaw(512 * fixed.FRAC_UNIT.raw()),
                );
            },
            .raise_floor_by_value => {
                floor_mover.direction = 1;
                floor_mover.floor_dest_height = Fixed.add(
                    level.sectors[i].floorheight,
                    Fixed.fromRaw(32 * fixed.FRAC_UNIT.raw()),
                );
            },
            .donut_raise => {
                floor_mover.direction = 1;
            },
        }

        floor_mover.thinker.function = @ptrCast(&T_MoveFloor);
    }

    return rtn;
}

// ============================================================================
// EV_BuildStairs — build a staircase
// ============================================================================

pub fn EV_BuildStairs(line: *const Line, stair_type: StairType, level: *Level, allocator: std.mem.Allocator) bool {
    var rtn = false;

    const stair_height: Fixed = switch (stair_type) {
        .build_8 => Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()),
        .turbo_16 => Fixed.fromRaw(16 * fixed.FRAC_UNIT.raw()),
    };

    const speed: Fixed = switch (stair_type) {
        .build_8 => FLOORSPEED,
        .turbo_16 => Fixed.fromRaw(FLOORSPEED.raw() * 4),
    };

    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag != line.tag) continue;

        rtn = true;

        // Build the stair from this sector
        var height = Fixed.add(level.sectors[i].floorheight, stair_height);

        const floor_mover = allocator.create(FloorMover) catch continue;
        floor_mover.* = .{
            .floor_type = .raise_floor_to_nearest,
            .sector_idx = @intCast(i),
            .direction = 1,
            .floor_dest_height = height,
            .speed = speed,
        };
        floor_mover.thinker.function = @ptrCast(&T_MoveFloor);
        tick.addThinker(&floor_mover.thinker);

        // Follow adjacent sectors with matching floor texture to build stair
        var current_sector: u16 = @intCast(i);
        const floor_pic = level.sectors[i].floorpic;

        while (true) {
            var found = false;
            for (level.lines) |ln| {
                const adj = getAdjacentSector(current_sector, &ln);
                if (adj) |adj_idx| {
                    if (level.sectors[adj_idx].floorpic == floor_pic) {
                        height = Fixed.add(height, stair_height);
                        const step = allocator.create(FloorMover) catch break;
                        step.* = .{
                            .floor_type = .raise_floor_to_nearest,
                            .sector_idx = adj_idx,
                            .direction = 1,
                            .floor_dest_height = height,
                            .speed = speed,
                        };
                        step.thinker.function = @ptrCast(&T_MoveFloor);
                        tick.addThinker(&step.thinker);
                        current_sector = adj_idx;
                        found = true;
                        break;
                    }
                }
            }
            if (!found) break;
        }
    }

    return rtn;
}

// ============================================================================
// EV_DoDonut — donut effect
// ============================================================================

pub fn EV_DoDonut(line: *const Line, level: *Level, allocator: std.mem.Allocator) bool {
    var rtn = false;

    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag != line.tag) continue;

        // Find the first adjacent sector (the "ring")
        var ring_idx: ?u16 = null;
        for (level.lines) |ln| {
            const adj = getAdjacentSector(@intCast(i), &ln);
            if (adj != null) {
                ring_idx = adj;
                break;
            }
        }

        const ring = ring_idx orelse continue;

        // Find the sector adjacent to the ring (the "outer")
        var outer_idx: ?u16 = null;
        for (level.lines) |ln| {
            const adj = getAdjacentSector(ring, &ln);
            if (adj) |adj_idx| {
                if (adj_idx != i) {
                    outer_idx = adj_idx;
                    break;
                }
            }
        }

        const outer = outer_idx orelse continue;

        rtn = true;

        // Raise the center (pool) sector
        const pool_mover = allocator.create(FloorMover) catch continue;
        pool_mover.* = .{
            .floor_type = .donut_raise,
            .sector_idx = @intCast(i),
            .direction = 1,
            .floor_dest_height = level.sectors[ring].floorheight,
            .speed = Fixed.fromRaw(@divTrunc(FLOORSPEED.raw(), 2)),
            .texture = level.sectors[ring].floorpic,
            .new_special = 0,
        };
        pool_mover.thinker.function = @ptrCast(&T_MoveFloor);
        tick.addThinker(&pool_mover.thinker);

        // Lower the ring to match outer
        const ring_mover = allocator.create(FloorMover) catch continue;
        ring_mover.* = .{
            .floor_type = .lower_floor,
            .sector_idx = ring,
            .direction = -1,
            .floor_dest_height = level.sectors[outer].floorheight,
            .speed = Fixed.fromRaw(@divTrunc(FLOORSPEED.raw(), 2)),
            .texture = level.sectors[outer].floorpic,
            .new_special = level.sectors[outer].special,
        };
        ring_mover.thinker.function = @ptrCast(&T_MoveFloor);
        tick.addThinker(&ring_mover.thinker);
    }

    return rtn;
}

// ============================================================================
// Tests
// ============================================================================

test "floor mover fieldParentPtr" {
    var mover = FloorMover{};
    const thinker_ptr = &mover.thinker;
    const recovered: *FloorMover = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&mover, recovered);
}

test "moveFloor down" {
    var sector = Sector{
        .floorheight = Fixed.fromInt(64),
        .ceilingheight = Fixed.fromInt(128),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 0,
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    const result = moveFloor(&sector, Fixed.fromInt(1), Fixed.fromInt(32), false, -1);
    try std.testing.expectEqual(MoveResult.ok, result);
    try std.testing.expectEqual(@as(i32, 63), sector.floorheight.toInt());
}

test "moveFloor up pastdest" {
    var sector = Sector{
        .floorheight = Fixed.fromInt(60),
        .ceilingheight = Fixed.fromInt(128),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 0,
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    const result = moveFloor(&sector, Fixed.fromInt(10), Fixed.fromInt(64), false, 1);
    try std.testing.expectEqual(MoveResult.pastdest, result);
    try std.testing.expectEqual(@as(i32, 64), sector.floorheight.toInt());
}

test "floor speed constant" {
    try std.testing.expectEqual(@as(i32, 0x10000), FLOORSPEED.raw());
}
