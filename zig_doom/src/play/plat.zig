//! zig_doom/src/play/plat.zig
//!
//! Platforms / lifts — lower-wait-raise floors.
//! Translated from: linuxdoom-1.10/p_plat.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const setup = @import("setup.zig");
const Level = setup.Level;
const Line = setup.Line;
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const floor_mod = @import("floor.zig");
const map_mod = @import("map.zig");
const world = @import("world.zig");
const random = @import("../random.zig");

pub const PLATSPEED: i32 = 0x10000; // 1 unit/tic
pub const PLATWAIT: i32 = 3; // seconds

pub const PlatStatus = enum { up, down, waiting };

pub const PlatType = enum {
    down_wait_up_stay,
    blaze_dwus,
    raise_and_change, // raise floor by N units at half speed, change floorpic
    raise_to_nearest_and_change, // raise to next higher floor at half speed, change floorpic
    perpetual_raise, // bounce between low and high forever
};

pub const Plat = struct {
    thinker: Thinker = .{},
    sector_idx: u16 = 0,
    speed: Fixed = Fixed.ZERO,
    low: Fixed = Fixed.ZERO,
    high: Fixed = Fixed.ZERO,
    wait: i32 = 0,
    count: i32 = 0,
    status: PlatStatus = .down,
    plat_type: PlatType = .down_wait_up_stay,
};

var plat_level: ?*Level = null;

pub fn setLevel(level: *Level) void {
    plat_level = level;
}

/// T_PlatRaise — platform thinker (vanilla p_plat.c)
pub fn T_PlatRaise(thinker_ptr: *Thinker) void {
    const plat: *Plat = @fieldParentPtr("thinker", thinker_ptr);
    const level = plat_level orelse return;
    if (plat.sector_idx >= level.sectors.len) return;

    switch (plat.status) {
        .up => {
            const res = map_mod.movePlane(level, plat.sector_idx, plat.speed, plat.high, false, 0, 1);

            if (plat.plat_type == .raise_and_change or plat.plat_type == .raise_to_nearest_and_change) {
                if (world.leveltime & 7 == 0) world.playSfx(null, .stnmov);
            }

            if (res == .crushed) {
                // Blocked while rising — go back down and wait
                plat.count = plat.wait;
                plat.status = .down;
                world.playSfx(null, .pstart);
            } else if (res == .pastdest) {
                plat.count = plat.wait;
                plat.status = .waiting;
                world.playSfx(null, .pstop);
                switch (plat.plat_type) {
                    .down_wait_up_stay, .blaze_dwus, .raise_and_change, .raise_to_nearest_and_change => {
                        level.sectors[plat.sector_idx].floordata_busy = false;
                        tick.removeThinker(&plat.thinker);
                    },
                    else => {},
                }
            }
        },
        .down => {
            const res = map_mod.movePlane(level, plat.sector_idx, plat.speed, plat.low, false, 0, -1);
            if (res == .pastdest) {
                plat.count = plat.wait;
                plat.status = .waiting;
                world.playSfx(null, .pstop);
            }
        },
        .waiting => {
            // vanilla `if (!--plat->count)`: fires only when count hits
            // exactly 0 (a wait of 0 parks the plat forever)
            plat.count -= 1;
            if (plat.count == 0) {
                plat.status = if (level.sectors[plat.sector_idx].floorheight.raw() == plat.low.raw())
                    .up
                else
                    .down;
                world.playSfx(null, .pstart);
            }
        },
    }
}

/// EV_DoPlat — activate platforms on all sectors matching the line's tag.
pub fn EV_DoPlat(line: *const Line, plat_type: PlatType, amount: i32, level: *Level, allocator: std.mem.Allocator) bool {
    plat_level = level;
    var rtn = false;

    for (level.sectors, 0..) |*sec, i| {
        if (sec.tag != line.tag) continue;
        if (sec.floordata_busy) continue; // Already moving

        const plat = allocator.create(Plat) catch continue;
        plat.* = .{
            .sector_idx = @intCast(i),
            .plat_type = plat_type,
        };

        switch (plat_type) {
            .raise_to_nearest_and_change => {
                plat.speed = Fixed.fromRaw(@divTrunc(PLATSPEED, 2));
                if (line.sidenum[0] >= 0) {
                    const fsec = level.sides[@intCast(line.sidenum[0])].sector;
                    sec.floorpic = level.sectors[fsec].floorpic;
                }
                plat.high = floor_mod.findNextHighestFloor(@intCast(i), level);
                plat.wait = 0;
                plat.status = .up;
                sec.special = 0; // no more damage, if applicable
                world.playSfx(null, .stnmov);
            },
            .raise_and_change => {
                plat.speed = Fixed.fromRaw(@divTrunc(PLATSPEED, 2));
                if (line.sidenum[0] >= 0) {
                    const fsec = level.sides[@intCast(line.sidenum[0])].sector;
                    sec.floorpic = level.sectors[fsec].floorpic;
                }
                plat.high = Fixed.add(sec.floorheight, Fixed.fromInt(amount));
                plat.wait = 0;
                plat.status = .up;
                world.playSfx(null, .stnmov);
            },
            .down_wait_up_stay => {
                plat.speed = Fixed.fromRaw(PLATSPEED * 4);
                var low = floor_mod.findLowestFloorSurrounding(@intCast(i), level);
                if (low.raw() > sec.floorheight.raw()) low = sec.floorheight;
                plat.low = low;
                plat.high = sec.floorheight;
                plat.wait = 35 * PLATWAIT;
                plat.status = .down;
                world.playSfx(null, .pstart);
            },
            .blaze_dwus => {
                plat.speed = Fixed.fromRaw(PLATSPEED * 8);
                var low = floor_mod.findLowestFloorSurrounding(@intCast(i), level);
                if (low.raw() > sec.floorheight.raw()) low = sec.floorheight;
                plat.low = low;
                plat.high = sec.floorheight;
                plat.wait = 35 * PLATWAIT;
                plat.status = .down;
                world.playSfx(null, .pstart);
            },
            .perpetual_raise => {
                plat.speed = Fixed.fromRaw(PLATSPEED);
                var low = floor_mod.findLowestFloorSurrounding(@intCast(i), level);
                if (low.raw() > sec.floorheight.raw()) low = sec.floorheight;
                plat.low = low;
                var high = floor_mod.findHighestFloorSurrounding(@intCast(i), level);
                if (high.raw() < sec.floorheight.raw()) high = sec.floorheight;
                plat.high = high;
                plat.wait = 35 * PLATWAIT;
                plat.status = if (random.pRandom() & 1 == 0) .up else .down;
                world.playSfx(null, .pstart);
            },
        }

        sec.floordata_busy = true;
        plat.thinker.function = @ptrCast(&T_PlatRaise);
        tick.addThinker(&plat.thinker);
        rtn = true;
    }
    return rtn;
}

test "plat type speeds" {
    try std.testing.expectEqual(@as(i32, 0x10000), PLATSPEED);
}
