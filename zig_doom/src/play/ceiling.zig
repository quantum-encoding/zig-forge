//! zig_doom/src/play/ceiling.zig
//!
//! Ceiling movement — crushers and lowering ceilings.
//! Translated from: linuxdoom-1.10/p_ceilng.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const setup = @import("setup.zig");
const Sector = setup.Sector;
const Line = setup.Line;
const Level = setup.Level;
const floor_mod = @import("floor.zig");

// ============================================================================
// Constants
// ============================================================================

pub const CEILSPEED = Fixed.fromRaw(fixed.FRAC_UNIT.raw());
pub const MAXCEILINGS = 30;

// ============================================================================
// Ceiling Types
// ============================================================================

pub const CeilingType = enum {
    lower_to_floor,
    crush_and_raise,
    lower_and_crush,
    fast_crush_and_raise,
    silent_crush_and_raise,
};

// ============================================================================
// CeilingMover thinker
// ============================================================================

pub const CeilingMover = struct {
    thinker: Thinker = .{},
    ceiling_type: CeilingType = .lower_to_floor,
    sector_idx: u16 = 0,
    bottom_height: Fixed = Fixed.ZERO,
    top_height: Fixed = Fixed.ZERO,
    speed: Fixed = CEILSPEED,
    crush: bool = false,
    direction: i32 = 0, // 1=up, -1=down
    tag: i16 = 0,
    old_direction: i32 = 0,
};

/// Active ceilings list — for stop/restart
var active_ceilings: [MAXCEILINGS]?*CeilingMover = [_]?*CeilingMover{null} ** MAXCEILINGS;

fn addActiveCeiling(ceiling: *CeilingMover) void {
    for (&active_ceilings) |*slot| {
        if (slot.* == null) {
            slot.* = ceiling;
            return;
        }
    }
}

fn removeActiveCeiling(ceiling: *CeilingMover) void {
    for (&active_ceilings) |*slot| {
        if (slot.* == ceiling) {
            slot.* = null;
            return;
        }
    }
}

/// Ceiling thinker — move ceiling up/down, handle crushing
pub fn T_MoveCeiling(thinker_ptr: *Thinker) void {
    const ceiling: *CeilingMover = @fieldParentPtr("thinker", thinker_ptr);
    const level = level_ptr orelse return;
    if (ceiling.sector_idx >= level.sectors.len) return;
    const sector = &level.sectors[ceiling.sector_idx];

    switch (ceiling.direction) {
        0 => {
            // Stopped (in stasis)
        },
        1 => {
            // Moving up
            const result = moveCeiling(sector, ceiling.speed, ceiling.top_height);
            switch (result) {
                .pastdest => {
                    switch (ceiling.ceiling_type) {
                        .crush_and_raise, .fast_crush_and_raise, .silent_crush_and_raise => {
                            ceiling.direction = -1;
                        },
                        else => {
                            removeActiveCeiling(ceiling);
                            tick.removeThinker(&ceiling.thinker);
                        },
                    }
                },
                .ok => {},
                .crushed => {},
            }
        },
        -1 => {
            // Moving down
            const result = moveCeiling(sector, ceiling.speed.negate(), ceiling.bottom_height);
            switch (result) {
                .pastdest => {
                    switch (ceiling.ceiling_type) {
                        .crush_and_raise, .silent_crush_and_raise => {
                            ceiling.speed = CEILSPEED;
                            ceiling.direction = 1;
                        },
                        .fast_crush_and_raise => {
                            ceiling.direction = 1;
                        },
                        .lower_and_crush, .lower_to_floor => {
                            removeActiveCeiling(ceiling);
                            tick.removeThinker(&ceiling.thinker);
                        },
                    }
                },
                .crushed => {
                    // Slow down on crush (except fast mode)
                    switch (ceiling.ceiling_type) {
                        .crush_and_raise, .lower_and_crush, .silent_crush_and_raise => {
                            ceiling.speed = Fixed.fromRaw(@divTrunc(CEILSPEED.raw(), 8));
                        },
                        else => {},
                    }
                },
                .ok => {},
            }
        },
        else => {},
    }
}

// ============================================================================
// Ceiling movement helper
// ============================================================================

const MoveResult = enum {
    ok,
    crushed,
    pastdest,
};

fn moveCeiling(sector: *Sector, speed: Fixed, dest: Fixed) MoveResult {
    if (speed.raw() < 0) {
        // Moving down
        const new_height = Fixed.add(sector.ceilingheight, speed);
        if (new_height.raw() <= dest.raw()) {
            sector.ceilingheight = dest;
            return .pastdest;
        }
        sector.ceilingheight = new_height;

        // Check crush
        if (sector.ceilingheight.raw() <= sector.floorheight.raw()) {
            sector.ceilingheight = Fixed.add(sector.floorheight, Fixed.fromRaw(fixed.FRAC_UNIT.raw()));
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
// Level pointer
// ============================================================================

var level_ptr: ?*Level = null;

pub fn setLevel(level: *Level) void {
    level_ptr = level;
}

// ============================================================================
// EV_DoCeiling — activate ceiling movement by tag
// ============================================================================

pub fn EV_DoCeiling(line: *const Line, ceiling_type: CeilingType, level: *Level, allocator: std.mem.Allocator) bool {
    var rtn = false;

    // Restart stopped crushers first
    switch (ceiling_type) {
        .fast_crush_and_raise, .silent_crush_and_raise, .crush_and_raise => {
            if (activateCeilingsInStasis(line.tag)) {
                rtn = true;
            }
        },
        else => {},
    }

    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag != line.tag) continue;

        const ceiling = allocator.create(CeilingMover) catch continue;
        ceiling.* = .{
            .ceiling_type = ceiling_type,
            .sector_idx = @intCast(i),
            .tag = line.tag,
        };

        tick.addThinker(&ceiling.thinker);
        addActiveCeiling(ceiling);
        rtn = true;

        switch (ceiling_type) {
            .fast_crush_and_raise => {
                ceiling.crush = true;
                ceiling.top_height = level.sectors[i].ceilingheight;
                ceiling.bottom_height = Fixed.add(level.sectors[i].floorheight, Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()));
                ceiling.direction = -1;
                ceiling.speed = Fixed.fromRaw(CEILSPEED.raw() * 2);
            },
            .silent_crush_and_raise, .crush_and_raise => {
                ceiling.crush = true;
                ceiling.top_height = level.sectors[i].ceilingheight;
                ceiling.bottom_height = Fixed.add(level.sectors[i].floorheight, Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()));
                ceiling.direction = -1;
                ceiling.speed = CEILSPEED;
            },
            .lower_and_crush, .lower_to_floor => {
                ceiling.bottom_height = level.sectors[i].floorheight;
                if (ceiling_type == .lower_and_crush) {
                    ceiling.bottom_height = Fixed.add(ceiling.bottom_height, Fixed.fromRaw(8 * fixed.FRAC_UNIT.raw()));
                }
                ceiling.direction = -1;
                ceiling.speed = CEILSPEED;
            },
        }

        ceiling.thinker.function = @ptrCast(&T_MoveCeiling);
    }

    return rtn;
}

/// Stop crushing ceiling by tag
pub fn EV_CeilingCrushStop(line: *const Line, level: *Level) bool {
    _ = level;
    var rtn = false;

    for (&active_ceilings) |*slot| {
        if (slot.*) |ceiling| {
            if (ceiling.tag == line.tag and ceiling.direction != 0) {
                ceiling.old_direction = ceiling.direction;
                ceiling.direction = 0; // Stop
                ceiling.thinker.function = null; // Don't tick
                rtn = true;
            }
        }
    }

    return rtn;
}

/// Restart stopped ceilings with matching tag
fn activateCeilingsInStasis(tag: i16) bool {
    var rtn = false;

    for (&active_ceilings) |*slot| {
        if (slot.*) |ceiling| {
            if (ceiling.tag == tag and ceiling.direction == 0) {
                ceiling.direction = ceiling.old_direction;
                ceiling.thinker.function = @ptrCast(&T_MoveCeiling);
                rtn = true;
            }
        }
    }

    return rtn;
}

/// Clear active ceilings list (for level init)
pub fn clearActiveCeilings() void {
    for (&active_ceilings) |*slot| {
        slot.* = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ceiling mover fieldParentPtr" {
    var ceiling = CeilingMover{};
    const thinker_ptr = &ceiling.thinker;
    const recovered: *CeilingMover = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&ceiling, recovered);
}

test "active ceilings add/remove" {
    clearActiveCeilings();

    var c1 = CeilingMover{};
    var c2 = CeilingMover{};

    addActiveCeiling(&c1);
    addActiveCeiling(&c2);

    try std.testing.expectEqual(&c1, active_ceilings[0].?);
    try std.testing.expectEqual(&c2, active_ceilings[1].?);

    removeActiveCeiling(&c1);
    try std.testing.expectEqual(@as(?*CeilingMover, null), active_ceilings[0]);
    try std.testing.expectEqual(&c2, active_ceilings[1].?);

    clearActiveCeilings();
}

test "moveCeiling down" {
    var sector = setup.Sector{
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

    const result = moveCeiling(&sector, Fixed.fromInt(-10), Fixed.fromInt(64));
    try std.testing.expectEqual(MoveResult.ok, result);
    try std.testing.expectEqual(@as(i32, 118), sector.ceilingheight.toInt());
}

test "ceiling speed constant" {
    try std.testing.expectEqual(@as(i32, 0x10000), CEILSPEED.raw());
}
