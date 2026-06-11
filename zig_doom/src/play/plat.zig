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

pub const PLATSPEED: i32 = 0x10000; // 1 unit/tic
pub const PLATWAIT: i32 = 3; // seconds

pub const PlatStatus = enum { up, down, waiting };

pub const PlatType = enum {
    down_wait_up_stay,
    blaze_dwus,
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

/// Move a sector's floor toward dest, clamped. Returns true when it arrives.
fn movePlatFloor(level: *Level, sector_idx: u16, speed: Fixed, dest: Fixed, up: bool) bool {
    const sec = &level.sectors[sector_idx];
    var arrived = false;

    if (up) {
        var nh = Fixed.add(sec.floorheight, speed);
        if (nh.raw() >= dest.raw()) {
            nh = dest;
            arrived = true;
        }
        sec.floorheight = nh;
    } else {
        var nh = Fixed.sub(sec.floorheight, speed);
        if (nh.raw() <= dest.raw()) {
            nh = dest;
            arrived = true;
        }
        sec.floorheight = nh;
    }

    // Carry/adjust the things standing in this sector (P_ChangeSector lite)
    map_mod.changeSector(level, sector_idx);
    return arrived;
}

/// T_PlatRaise — platform thinker
pub fn T_PlatRaise(thinker_ptr: *Thinker) void {
    const plat: *Plat = @fieldParentPtr("thinker", thinker_ptr);
    const level = plat_level orelse return;
    if (plat.sector_idx >= level.sectors.len) return;

    switch (plat.status) {
        .up => {
            if (movePlatFloor(level, plat.sector_idx, plat.speed, plat.high, true)) {
                // Reached the top — lifts are done
                world.playSfx(null, .pstop);
                level.sectors[plat.sector_idx].floordata_busy = false;
                tick.removeThinker(&plat.thinker);
            }
        },
        .down => {
            if (movePlatFloor(level, plat.sector_idx, plat.speed, plat.low, false)) {
                plat.count = plat.wait;
                plat.status = .waiting;
                world.playSfx(null, .pstop);
            }
        },
        .waiting => {
            plat.count -= 1;
            if (plat.count <= 0) {
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
pub fn EV_DoPlat(line: *const Line, plat_type: PlatType, level: *Level, allocator: std.mem.Allocator) bool {
    plat_level = level;
    var rtn = false;

    for (level.sectors, 0..) |*sec, i| {
        if (sec.tag != line.tag) continue;
        if (sec.floordata_busy) continue; // Already moving

        const plat = allocator.create(Plat) catch continue;
        plat.* = .{
            .sector_idx = @intCast(i),
            .plat_type = plat_type,
            .high = sec.floorheight,
            .wait = 35 * PLATWAIT,
            .status = .down,
        };

        switch (plat_type) {
            .down_wait_up_stay => plat.speed = Fixed.fromRaw(PLATSPEED * 4),
            .blaze_dwus => plat.speed = Fixed.fromRaw(PLATSPEED * 8),
        }

        var low = floor_mod.findLowestFloorSurrounding(@intCast(i), level);
        if (low.raw() > sec.floorheight.raw()) low = sec.floorheight;
        plat.low = low;

        sec.floordata_busy = true;
        plat.thinker.function = @ptrCast(&T_PlatRaise);
        tick.addThinker(&plat.thinker);
        world.playSfx(null, .pstart);
        rtn = true;
    }
    return rtn;
}

test "plat type speeds" {
    try std.testing.expectEqual(@as(i32, 0x10000), PLATSPEED);
}
