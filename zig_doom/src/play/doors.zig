//! zig_doom/src/play/doors.zig
//!
//! Vertical door logic — sector ceilings that open and close.
//! Translated from: linuxdoom-1.10/p_doors.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const defs = @import("../defs.zig");
const random = @import("../random.zig");
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const setup = @import("setup.zig");
const Sector = setup.Sector;
const Line = setup.Line;
const Level = setup.Level;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const user = @import("user.zig");
const Player = user.Player;

// ============================================================================
// Constants
// ============================================================================

pub const VDOORSPEED = Fixed.fromRaw(2 * fixed.FRAC_UNIT.raw());
pub const VDOORWAIT: i32 = 150; // ~4.3 seconds

// ============================================================================
// Door Types
// ============================================================================

pub const DoorType = enum {
    normal, // Open, wait, close
    close_30_open, // Close, wait 30s, open
    door_close, // Close
    door_open, // Open and stay
    raise_in_5_mins, // Wait 5 min, then raise
    blaze_raise, // Fast open, wait, close
    blaze_open, // Fast open, stay
    blaze_close, // Fast close
};

// ============================================================================
// VerticalDoor thinker
// ============================================================================

pub const VerticalDoor = struct {
    thinker: Thinker = .{},
    door_type: DoorType = .normal,
    sector_idx: u16 = 0,
    top_height: Fixed = Fixed.ZERO,
    speed: Fixed = VDOORSPEED,
    direction: i32 = 0, // 1=up, 0=waiting, -1=down
    top_wait: i32 = VDOORWAIT,
    top_count_down: i32 = 0,
};

/// Door thinker — moves ceiling up/down, handles waiting
pub fn T_VerticalDoor(thinker_ptr: *Thinker) void {
    const door: *VerticalDoor = @fieldParentPtr("thinker", thinker_ptr);
    const level = level_ptr orelse return;
    if (door.sector_idx >= level.sectors.len) return;
    const sector = &level.sectors[door.sector_idx];

    switch (door.direction) {
        0 => {
            // Waiting at top
            door.top_count_down -= 1;
            if (door.top_count_down <= 0) {
                switch (door.door_type) {
                    .blaze_raise => {
                        door.direction = -1; // Start closing
                    },
                    .normal => {
                        door.direction = -1; // Start closing
                    },
                    .close_30_open => {
                        door.direction = 1; // Open after wait
                    },
                    else => {},
                }
            }
        },
        2 => {
            // Initial wait (used by close_30_open and raise_in_5_mins)
            door.top_count_down -= 1;
            if (door.top_count_down <= 0) {
                switch (door.door_type) {
                    .raise_in_5_mins => {
                        door.direction = 1;
                        door.door_type = .normal;
                    },
                    else => {},
                }
            }
        },
        -1 => {
            // Door closing
            const result = moveCeiling(sector, door.speed.negate(), sector.floorheight, false);
            switch (result) {
                .pastdest => {
                    // Reached bottom
                    switch (door.door_type) {
                        .blaze_raise, .blaze_close => {
                            sector.ceilingheight = sector.floorheight;
                            tick.removeThinker(&door.thinker);
                        },
                        .normal, .door_close => {
                            sector.ceilingheight = sector.floorheight;
                            tick.removeThinker(&door.thinker);
                        },
                        .close_30_open => {
                            door.direction = 0;
                            door.top_count_down = 35 * 30; // 30 seconds
                        },
                        else => {},
                    }
                },
                .crushed => {
                    // Door hit something — reopen (not for blaze_close/door_close)
                    switch (door.door_type) {
                        .blaze_close, .door_close => {},
                        else => {
                            door.direction = 1;
                        },
                    }
                },
                .ok => {},
            }
        },
        1 => {
            // Door opening
            const result = moveCeiling(sector, door.speed, door.top_height, false);
            switch (result) {
                .pastdest => {
                    // Reached top
                    switch (door.door_type) {
                        .blaze_raise, .normal => {
                            sector.ceilingheight = door.top_height;
                            door.direction = 0;
                            door.top_count_down = door.top_wait;
                        },
                        .close_30_open, .blaze_open, .door_open => {
                            sector.ceilingheight = door.top_height;
                            tick.removeThinker(&door.thinker);
                        },
                        else => {},
                    }
                },
                .crushed => {},
                .ok => {},
            }
        },
        else => {},
    }
}

// ============================================================================
// Ceiling movement result
// ============================================================================

const MoveResult = enum {
    ok,
    crushed,
    pastdest,
};

/// Move a sector's ceiling. Returns movement result.
fn moveCeiling(sector: *Sector, speed: Fixed, dest: Fixed, crush: bool) MoveResult {
    _ = crush;
    const old_height = sector.ceilingheight;

    if (speed.raw() < 0) {
        // Moving down
        const new_height = Fixed.add(sector.ceilingheight, speed);
        if (new_height.raw() <= dest.raw()) {
            sector.ceilingheight = dest;
            return .pastdest;
        }
        sector.ceilingheight = new_height;

        // Check crush (ceiling <= floor means crushed)
        if (sector.ceilingheight.raw() <= sector.floorheight.raw()) {
            sector.ceilingheight = old_height;
            return .crushed;
        }
    } else {
        // Moving up
        const new_height = Fixed.add(sector.ceilingheight, speed);
        if (new_height.raw() >= dest.raw()) {
            sector.ceilingheight = dest;
            return .pastdest;
        }
        sector.ceilingheight = new_height;
    }

    return .ok;
}

// ============================================================================
// Level pointer (set during spawnSpecials)
// ============================================================================

var level_ptr: ?*Level = null;

pub fn setLevel(level: *Level) void {
    level_ptr = level;
}

// ============================================================================
// EV_DoDoor — activate doors by line tag
// ============================================================================

/// Find the lowest ceiling of surrounding sectors
fn findLowestCeilingSurrounding(sector_idx: u16, level: *Level) Fixed {
    var min_ceil = Fixed.MAX;

    for (level.lines) |line| {
        const front = line.frontsector;
        const back = line.backsector;

        if (front) |f| {
            if (f == sector_idx) {
                if (back) |b| {
                    if (level.sectors[b].ceilingheight.raw() < min_ceil.raw()) {
                        min_ceil = level.sectors[b].ceilingheight;
                    }
                }
            }
        }
        if (back) |b| {
            if (b == sector_idx) {
                if (front) |f| {
                    if (level.sectors[f].ceilingheight.raw() < min_ceil.raw()) {
                        min_ceil = level.sectors[f].ceilingheight;
                    }
                }
            }
        }
    }

    return min_ceil;
}

pub fn EV_DoDoor(line: *const Line, door_type: DoorType, level: *Level, allocator: std.mem.Allocator) bool {
    var rtn = false;

    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag != line.tag) continue;

        const door = allocator.create(VerticalDoor) catch continue;
        door.* = .{
            .door_type = door_type,
            .sector_idx = @intCast(i),
        };

        tick.addThinker(&door.thinker);
        rtn = true;

        switch (door_type) {
            .blaze_close => {
                door.top_height = findLowestCeilingSurrounding(@intCast(i), level);
                door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
                door.speed = Fixed.fromRaw(VDOORSPEED.raw() * 4);
                door.direction = -1;
            },
            .door_close => {
                door.top_height = findLowestCeilingSurrounding(@intCast(i), level);
                door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
                door.direction = -1;
            },
            .close_30_open => {
                door.top_height = level.sectors[i].ceilingheight;
                door.direction = -1;
            },
            .blaze_raise, .blaze_open => {
                door.direction = 1;
                door.top_height = findLowestCeilingSurrounding(@intCast(i), level);
                door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
                door.speed = Fixed.fromRaw(VDOORSPEED.raw() * 4);
                if (door.top_height.raw() != level.sectors[i].ceilingheight.raw()) {
                    // Sound: blaze open
                }
            },
            .normal, .door_open => {
                door.direction = 1;
                door.top_height = findLowestCeilingSurrounding(@intCast(i), level);
                door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
            },
            .raise_in_5_mins => {
                door.direction = 2; // Initial wait
                door.top_height = findLowestCeilingSurrounding(@intCast(i), level);
                door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
                door.top_count_down = 35 * 60 * 5; // 5 minutes
            },
        }

        door.thinker.function = @ptrCast(&T_VerticalDoor);
    }

    return rtn;
}

/// Manual door activation (player uses a door linedef directly)
pub fn EV_VerticalDoor(line: *const Line, thing: *MapObject, level: *Level, allocator: std.mem.Allocator) void {
    // Check for locked doors
    const player_ptr: ?*Player = if (thing.player) |p| @ptrCast(@alignCast(p)) else null;

    switch (line.special) {
        26, 32 => {
            // Blue door
            if (player_ptr) |player| {
                if (!player.cards[@intFromEnum(defs.Card.blue_card)] and
                    !player.cards[@intFromEnum(defs.Card.blue_skull)])
                {
                    // Need blue key message
                    return;
                }
            }
        },
        27, 34 => {
            // Yellow door
            if (player_ptr) |player| {
                if (!player.cards[@intFromEnum(defs.Card.yellow_card)] and
                    !player.cards[@intFromEnum(defs.Card.yellow_skull)])
                {
                    // Need yellow key message
                    return;
                }
            }
        },
        28, 33 => {
            // Red door
            if (player_ptr) |player| {
                if (!player.cards[@intFromEnum(defs.Card.red_card)] and
                    !player.cards[@intFromEnum(defs.Card.red_skull)])
                {
                    // Need red key message
                    return;
                }
            }
        },
        else => {},
    }

    // Get the sector on the back side of the line
    const back_sector_idx = line.backsector orelse return;

    const door = allocator.create(VerticalDoor) catch return;
    door.* = .{
        .sector_idx = back_sector_idx,
    };

    tick.addThinker(&door.thinker);

    // Determine door type from line special
    switch (line.special) {
        1, 31, 26, 27, 28 => {
            // Normal open-wait-close
            door.door_type = .normal;
            door.direction = 1;
            door.top_height = findLowestCeilingSurrounding(back_sector_idx, level);
            door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
        },
        117 => {
            // Blazing open-wait-close
            door.door_type = .blaze_raise;
            door.direction = 1;
            door.speed = Fixed.fromRaw(VDOORSPEED.raw() * 4);
            door.top_height = findLowestCeilingSurrounding(back_sector_idx, level);
            door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
        },
        32, 33, 34 => {
            // Locked blazing door
            door.door_type = .blaze_open;
            door.direction = 1;
            door.speed = Fixed.fromRaw(VDOORSPEED.raw() * 4);
            door.top_height = findLowestCeilingSurrounding(back_sector_idx, level);
            door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
        },
        else => {
            door.door_type = .normal;
            door.direction = 1;
            door.top_height = findLowestCeilingSurrounding(back_sector_idx, level);
            door.top_height = Fixed.sub(door.top_height, Fixed.fromRaw(4 * fixed.FRAC_UNIT.raw()));
        },
    }

    door.thinker.function = @ptrCast(&T_VerticalDoor);
}

// ============================================================================
// Tests
// ============================================================================

test "vertical door fieldParentPtr" {
    var door = VerticalDoor{};
    const thinker_ptr = &door.thinker;
    const recovered: *VerticalDoor = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&door, recovered);
}

test "door constants" {
    try std.testing.expectEqual(@as(i32, 2 * 0x10000), VDOORSPEED.raw());
    try std.testing.expectEqual(@as(i32, 150), VDOORWAIT);
}

test "moveCeiling down" {
    var sector = Sector{
        .floorheight = Fixed.ZERO,
        .ceilingheight = Fixed.fromInt(128),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 0,
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    // Move down toward floor
    const result = moveCeiling(&sector, Fixed.fromInt(-10), Fixed.ZERO, false);
    try std.testing.expectEqual(MoveResult.ok, result);
    try std.testing.expectEqual(@as(i32, 118), sector.ceilingheight.toInt());
}

test "moveCeiling pastdest" {
    var sector = Sector{
        .floorheight = Fixed.ZERO,
        .ceilingheight = Fixed.fromInt(5),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 0,
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    // Move down past destination
    const result = moveCeiling(&sector, Fixed.fromInt(-10), Fixed.ZERO, false);
    try std.testing.expectEqual(MoveResult.pastdest, result);
    try std.testing.expectEqual(@as(i32, 0), sector.ceilingheight.toInt());
}
