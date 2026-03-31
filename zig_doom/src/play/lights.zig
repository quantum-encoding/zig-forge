//! zig_doom/src/play/lights.zig
//!
//! Sector lighting effects — blink, strobe, glow.
//! Translated from: linuxdoom-1.10/p_lights.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const random = @import("../random.zig");
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const setup = @import("setup.zig");
const Sector = setup.Sector;
const Level = setup.Level;

// ============================================================================
// Light Flash — random blink between min/max
// ============================================================================

pub const LightFlash = struct {
    thinker: Thinker = .{},
    sector_idx: u16 = 0,
    count: i32 = 0,
    max_light: i16 = 0,
    min_light: i16 = 0,
};

pub fn T_LightFlash(thinker_ptr: *Thinker) void {
    const flash: *LightFlash = @fieldParentPtr("thinker", thinker_ptr);
    flash.count -= 1;
    if (flash.count > 0) return;

    // Toggle between max and min light
    if (flash.sector_idx < sector_ptr_level.?.sectors.len) {
        const sector = &sector_ptr_level.?.sectors[flash.sector_idx];
        if (sector.lightlevel == flash.max_light) {
            sector.lightlevel = flash.min_light;
            flash.count = @as(i32, random.pRandom() & 7) + 1;
        } else {
            sector.lightlevel = flash.max_light;
            flash.count = @as(i32, random.pRandom() & 63) + 1;
        }
    }
}

// ============================================================================
// Strobe Flash — regular alternation
// ============================================================================

pub const StrobeFlash = struct {
    thinker: Thinker = .{},
    sector_idx: u16 = 0,
    count: i32 = 0,
    min_light: i16 = 0,
    max_light: i16 = 0,
    dark_time: i32 = 0,
    bright_time: i32 = 0,
};

pub fn T_StrobeFlash(thinker_ptr: *Thinker) void {
    const strobe: *StrobeFlash = @fieldParentPtr("thinker", thinker_ptr);
    strobe.count -= 1;
    if (strobe.count > 0) return;

    if (strobe.sector_idx < sector_ptr_level.?.sectors.len) {
        const sector = &sector_ptr_level.?.sectors[strobe.sector_idx];
        if (sector.lightlevel == strobe.min_light) {
            sector.lightlevel = strobe.max_light;
            strobe.count = strobe.bright_time;
        } else {
            sector.lightlevel = strobe.min_light;
            strobe.count = strobe.dark_time;
        }
    }
}

// ============================================================================
// Glow — smooth oscillation between min/max
// ============================================================================

pub const Glow = struct {
    thinker: Thinker = .{},
    sector_idx: u16 = 0,
    min_light: i16 = 0,
    max_light: i16 = 0,
    direction: i32 = 0, // -1 = darkening, 1 = brightening
};

const GLOWSPEED: i16 = 8;

pub fn T_Glow(thinker_ptr: *Thinker) void {
    const glow: *Glow = @fieldParentPtr("thinker", thinker_ptr);

    if (glow.sector_idx < sector_ptr_level.?.sectors.len) {
        const sector = &sector_ptr_level.?.sectors[glow.sector_idx];
        if (glow.direction == -1) {
            // Darkening
            sector.lightlevel -= GLOWSPEED;
            if (sector.lightlevel <= glow.min_light) {
                sector.lightlevel = glow.min_light;
                glow.direction = 1;
            }
        } else {
            // Brightening
            sector.lightlevel += GLOWSPEED;
            if (sector.lightlevel >= glow.max_light) {
                sector.lightlevel = glow.max_light;
                glow.direction = -1;
            }
        }
    }
}

// ============================================================================
// Level pointer (set during spawnSpecials)
// ============================================================================

var sector_ptr_level: ?*Level = null;

pub fn setLevel(level: *Level) void {
    sector_ptr_level = level;
}

// ============================================================================
// Spawn functions
// ============================================================================

/// Find the minimum light level among surrounding sectors
pub fn findMinSurroundingLight(sector_idx: u16, level: *Level, max_val: i16) i16 {
    var min_light = max_val;
    const sector = &level.sectors[sector_idx];
    _ = sector;

    // Iterate all lines to find adjacent sectors
    for (level.lines) |line| {
        const front = line.frontsector;
        const back = line.backsector;

        if (front) |f| {
            if (f == sector_idx) {
                if (back) |b| {
                    if (level.sectors[b].lightlevel < min_light) {
                        min_light = level.sectors[b].lightlevel;
                    }
                }
            }
        }
        if (back) |b| {
            if (b == sector_idx) {
                if (front) |f| {
                    if (level.sectors[f].lightlevel < min_light) {
                        min_light = level.sectors[f].lightlevel;
                    }
                }
            }
        }
    }

    return min_light;
}

/// Spawn a random light flash effect for a sector
pub fn spawnLightFlash(sector_idx: u16, level: *Level, allocator: std.mem.Allocator) void {
    const flash = allocator.create(LightFlash) catch return;
    flash.* = .{
        .sector_idx = sector_idx,
        .max_light = level.sectors[sector_idx].lightlevel,
        .min_light = findMinSurroundingLight(sector_idx, level, level.sectors[sector_idx].lightlevel),
        .count = @as(i32, random.pRandom() & 63) + 1,
    };

    flash.thinker.function = @ptrCast(&T_LightFlash);
    tick.addThinker(&flash.thinker);
}

/// Spawn a strobe flash effect for a sector
pub fn spawnStrobeFlash(sector_idx: u16, level: *Level, dark_time: i32, in_sync: bool, allocator: std.mem.Allocator) void {
    const strobe = allocator.create(StrobeFlash) catch return;
    strobe.* = .{
        .sector_idx = sector_idx,
        .max_light = level.sectors[sector_idx].lightlevel,
        .min_light = findMinSurroundingLight(sector_idx, level, level.sectors[sector_idx].lightlevel),
        .dark_time = dark_time,
        .bright_time = STROBEBRIGHT,
    };

    if (strobe.min_light == strobe.max_light) {
        strobe.min_light = 0;
    }

    // Start not in sync unless requested
    if (!in_sync) {
        strobe.count = @as(i32, random.pRandom() & 7) + 1;
    } else {
        strobe.count = 1;
    }

    strobe.thinker.function = @ptrCast(&T_StrobeFlash);
    tick.addThinker(&strobe.thinker);
}

/// Spawn a glowing light effect for a sector
pub fn spawnGlowing(sector_idx: u16, level: *Level, allocator: std.mem.Allocator) void {
    const glow = allocator.create(Glow) catch return;
    glow.* = .{
        .sector_idx = sector_idx,
        .max_light = level.sectors[sector_idx].lightlevel,
        .min_light = findMinSurroundingLight(sector_idx, level, level.sectors[sector_idx].lightlevel),
        .direction = -1,
    };

    glow.thinker.function = @ptrCast(&T_Glow);
    tick.addThinker(&glow.thinker);
}

// ============================================================================
// EV_ functions — triggered by line specials
// ============================================================================

const STROBEBRIGHT: i32 = 5;
const FASTDARK: i32 = 15;
const SLOWDARK: i32 = 35;

/// Start light strobing in sectors with matching tag
pub fn EV_StartLightStrobing(line: *const setup.Line, level: *Level, allocator: std.mem.Allocator) void {
    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag == line.tag) {
            // Don't start if already flashing
            spawnStrobeFlash(@intCast(i), level, SLOWDARK, false, allocator);
        }
    }
}

/// Turn off lights in sectors with matching tag (set to min surrounding light)
pub fn EV_TurnTagLightsOff(line: *const setup.Line, level: *Level) void {
    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag == line.tag) {
            const min = findMinSurroundingLight(@intCast(i), level, level.sectors[i].lightlevel);
            level.sectors[i].lightlevel = min;
        }
    }
}

/// Turn on lights in sectors with matching tag.
/// If bright is 0, set to max surrounding. Otherwise set to bright.
pub fn EV_LightTurnOn(line: *const setup.Line, level: *Level, bright: i16) void {
    for (level.sectors, 0..) |_, i| {
        if (level.sectors[i].tag == line.tag) {
            if (bright == 0) {
                // Find max surrounding light
                var max_light: i16 = 0;
                for (level.lines) |ln| {
                    const front = ln.frontsector;
                    const back = ln.backsector;
                    if (front) |f| {
                        if (f == i) {
                            if (back) |b| {
                                if (level.sectors[b].lightlevel > max_light) {
                                    max_light = level.sectors[b].lightlevel;
                                }
                            }
                        }
                    }
                    if (back) |b| {
                        if (b == i) {
                            if (front) |f| {
                                if (level.sectors[f].lightlevel > max_light) {
                                    max_light = level.sectors[f].lightlevel;
                                }
                            }
                        }
                    }
                }
                level.sectors[i].lightlevel = max_light;
            } else {
                level.sectors[i].lightlevel = bright;
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "light flash fieldParentPtr" {
    var flash = LightFlash{};
    const thinker_ptr = &flash.thinker;
    const recovered: *LightFlash = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&flash, recovered);
}

test "strobe flash fieldParentPtr" {
    var strobe = StrobeFlash{};
    const thinker_ptr = &strobe.thinker;
    const recovered: *StrobeFlash = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&strobe, recovered);
}

test "glow fieldParentPtr" {
    var glow = Glow{};
    const thinker_ptr = &glow.thinker;
    const recovered: *Glow = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&glow, recovered);
}

test "glow direction toggle" {
    // Create a minimal sector array
    const allocator = std.testing.allocator;
    const sectors = try allocator.alloc(Sector, 1);
    defer allocator.free(sectors);
    sectors[0] = .{
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

    var glow = Glow{
        .sector_idx = 0,
        .min_light = 100,
        .max_light = 200,
        .direction = -1,
    };

    // Set up level pointer
    var level = Level{
        .vertices = &.{},
        .sectors = sectors,
        .sides = &.{},
        .lines = &.{},
        .segs = &.{},
        .subsectors = &.{},
        .nodes = &.{},
        .things = &.{},
        .blockmap_data = &.{},
        .reject_data = &.{},
        .num_nodes = 0,
        .allocator = allocator,
    };
    sector_ptr_level = &level;
    defer {
        sector_ptr_level = null;
    }

    // Tick the glow
    T_Glow(&glow.thinker);
    try std.testing.expectEqual(@as(i16, 192), sectors[0].lightlevel);
    try std.testing.expectEqual(@as(i32, -1), glow.direction);
}
