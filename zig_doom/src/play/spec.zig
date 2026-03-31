//! zig_doom/src/play/spec.zig
//!
//! Special line/sector actions — the main dispatch for DOOM's trigger system.
//! Translated from: linuxdoom-1.10/p_spec.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! When a player crosses, uses, or shoots a linedef with a non-zero special,
//! that special number determines which action occurs (open door, raise floor, etc).

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const defs = @import("../defs.zig");
const random = @import("../random.zig");
const tick = @import("tick.zig");
const setup = @import("setup.zig");
const Sector = setup.Sector;
const Line = setup.Line;
const Level = setup.Level;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const user = @import("user.zig");
const Player = user.Player;
const doors = @import("doors.zig");
const floor_mod = @import("floor.zig");
const ceiling = @import("ceiling.zig");
const lights = @import("lights.zig");
const switch_mod = @import("switch.zig");
const telept = @import("telept.zig");

// ============================================================================
// Module-level state
// ============================================================================

var spec_level: ?*Level = null;
var spec_allocator: ?std.mem.Allocator = null;

// ============================================================================
// crossSpecialLine — player/monster crosses a linedef trigger
// ============================================================================

/// Dispatch when a thing crosses a special linedef.
/// side: 0 = front, 1 = back
pub fn crossSpecialLine(line_idx: usize, side: i32, thing: *MapObject, level: *Level, allocator: std.mem.Allocator) void {
    if (line_idx >= level.lines.len) return;
    const line = &level.lines[line_idx];

    if (line.special == 0) return;

    // Most W1/WR specials only trigger from front side
    const is_player = thing.player != null;

    // Monsters can only trigger certain specials
    if (!is_player) {
        // Monsters can trigger: teleporters and a few walk triggers
        switch (line.special) {
            39, 97, 125, 126 => {}, // Teleporters — monsters OK
            4 => {}, // W1 raise door
            10, 88 => {}, // Lifts
            else => return, // Monsters can't trigger other walk specials
        }
    }

    switch (line.special) {
        // ---- Exits ----
        11 => {
            // S1 Exit level (handled as walk in some maps)
            // Full implementation: G_ExitLevel()
        },
        51 => {
            // S1 Secret exit
            // Full implementation: G_SecretExitLevel()
        },
        52 => {
            // W1 Exit level
            // Full implementation: G_ExitLevel()
        },
        124 => {
            // W1 Secret exit
            // Full implementation: G_SecretExitLevel()
        },

        // ---- Doors (Walk triggers) ----
        2 => {
            // W1 Open door stay open
            _ = doors.EV_DoDoor(line, .door_open, level, allocator);
            line.special = 0;
        },
        3 => {
            // W1 Close door
            _ = doors.EV_DoDoor(line, .door_close, level, allocator);
            line.special = 0;
        },
        4 => {
            // W1 Raise door (open, wait, close)
            _ = doors.EV_DoDoor(line, .normal, level, allocator);
            line.special = 0;
        },
        16 => {
            // W1 Close door, wait 30s, open
            _ = doors.EV_DoDoor(line, .close_30_open, level, allocator);
            line.special = 0;
        },
        75 => {
            // WR Close door, wait 30s, open
            _ = doors.EV_DoDoor(line, .close_30_open, level, allocator);
        },
        76 => {
            // WR Close door (fast)
            _ = doors.EV_DoDoor(line, .blaze_close, level, allocator);
        },
        86 => {
            // WR Open door stay
            _ = doors.EV_DoDoor(line, .door_open, level, allocator);
        },
        90 => {
            // WR Raise door
            _ = doors.EV_DoDoor(line, .normal, level, allocator);
        },
        105 => {
            // WR Open door fast (blazing)
            _ = doors.EV_DoDoor(line, .blaze_raise, level, allocator);
        },
        108 => {
            // WR Open door fast stay
            _ = doors.EV_DoDoor(line, .blaze_open, level, allocator);
        },
        109 => {
            // WR Open door fast (blazing)
            _ = doors.EV_DoDoor(line, .blaze_raise, level, allocator);
        },
        110 => {
            // WR Close door fast
            _ = doors.EV_DoDoor(line, .blaze_close, level, allocator);
        },

        // ---- Floors (Walk triggers) ----
        5 => {
            // W1 Raise floor to lowest ceiling
            _ = floor_mod.EV_DoFloor(line, .raise_floor, level, allocator);
            line.special = 0;
        },
        18 => {
            // S1 Raise floor to next higher
            _ = floor_mod.EV_DoFloor(line, .raise_floor_to_nearest, level, allocator);
            line.special = 0;
        },
        19 => {
            // W1 Lower floor to highest surrounding
            _ = floor_mod.EV_DoFloor(line, .lower_floor, level, allocator);
            line.special = 0;
        },
        22 => {
            // W1 Raise floor to nearest + change texture
            _ = floor_mod.EV_DoFloor(line, .raise_floor_to_nearest, level, allocator);
            line.special = 0;
        },
        23 => {
            // S1 Lower floor to lowest
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
            line.special = 0;
        },
        30 => {
            // W1 Raise floor to shortest lower texture
            _ = floor_mod.EV_DoFloor(line, .raise_to_texture, level, allocator);
            line.special = 0;
        },
        36 => {
            // W1 Lower floor turbo (to 8 above HEF)
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
            line.special = 0;
        },
        37 => {
            // W1 Lower floor + change
            _ = floor_mod.EV_DoFloor(line, .lower_and_change, level, allocator);
            line.special = 0;
        },
        38 => {
            // W1 Lower floor to lowest
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
            line.special = 0;
        },
        56 => {
            // W1 Raise floor crush
            _ = floor_mod.EV_DoFloor(line, .raise_floor_crush, level, allocator);
            line.special = 0;
        },
        58 => {
            // W1 Raise floor 24
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24, level, allocator);
            line.special = 0;
        },
        59 => {
            // W1 Raise floor 24 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24_and_change, level, allocator);
            line.special = 0;
        },
        82 => {
            // WR Lower floor to lowest
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
        },
        83 => {
            // WR Lower floor to highest
            _ = floor_mod.EV_DoFloor(line, .lower_floor, level, allocator);
        },
        84 => {
            // WR Lower floor + change
            _ = floor_mod.EV_DoFloor(line, .lower_and_change, level, allocator);
        },
        91 => {
            // WR Raise floor to lowest ceiling
            _ = floor_mod.EV_DoFloor(line, .raise_floor, level, allocator);
        },
        92 => {
            // WR Raise floor 24
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24, level, allocator);
        },
        93 => {
            // WR Raise floor 24 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24_and_change, level, allocator);
        },
        94 => {
            // WR Raise floor crush
            _ = floor_mod.EV_DoFloor(line, .raise_floor_crush, level, allocator);
        },
        96 => {
            // WR Raise floor to shortest texture
            _ = floor_mod.EV_DoFloor(line, .raise_to_texture, level, allocator);
        },
        98 => {
            // WR Lower floor turbo
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
        },

        // ---- Stairs ----
        8 => {
            // W1 Build stairs 8
            _ = floor_mod.EV_BuildStairs(line, .build_8, level, allocator);
            line.special = 0;
        },
        100 => {
            // W1 Build stairs turbo 16
            _ = floor_mod.EV_BuildStairs(line, .turbo_16, level, allocator);
            line.special = 0;
        },

        // ---- Ceilings ----
        40 => {
            // W1 Raise ceiling to highest ceiling
            // Simplified: uses ceiling lower logic in reverse
        },
        41 => {
            // S1 Lower ceiling to floor
            _ = ceiling.EV_DoCeiling(line, .lower_to_floor, level, allocator);
            line.special = 0;
        },
        43 => {
            // SR Lower ceiling to floor
            _ = ceiling.EV_DoCeiling(line, .lower_to_floor, level, allocator);
        },
        44 => {
            // W1 Lower ceiling to 8 above floor
            _ = ceiling.EV_DoCeiling(line, .lower_and_crush, level, allocator);
            line.special = 0;
        },
        49 => {
            // S1 Slow crush ceiling
            _ = ceiling.EV_DoCeiling(line, .crush_and_raise, level, allocator);
            line.special = 0;
        },
        57 => {
            // W1 Stop crusher
            _ = ceiling.EV_CeilingCrushStop(line, level);
            line.special = 0;
        },
        72 => {
            // WR Lower ceiling to 8 above floor
            _ = ceiling.EV_DoCeiling(line, .lower_and_crush, level, allocator);
        },
        73 => {
            // WR Crush and raise ceiling
            _ = ceiling.EV_DoCeiling(line, .crush_and_raise, level, allocator);
        },
        74 => {
            // WR Stop crusher
            _ = ceiling.EV_CeilingCrushStop(line, level);
        },
        77 => {
            // WR Fast crush and raise
            _ = ceiling.EV_DoCeiling(line, .fast_crush_and_raise, level, allocator);
        },
        141 => {
            // W1 Silent crush and raise
            _ = ceiling.EV_DoCeiling(line, .silent_crush_and_raise, level, allocator);
            line.special = 0;
        },

        // ---- Lifts / Platforms ----
        10 => {
            // W1 Lift (lower-wait-raise)
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
            line.special = 0;
        },
        21 => {
            // S1 Lift
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
            line.special = 0;
        },
        62 => {
            // SR Lift
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
        },
        88 => {
            // WR Lift
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
        },
        120 => {
            // WR Turbo lift
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
        },
        121 => {
            // WR Turbo lift
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
        },
        122 => {
            // S1 Turbo lift
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
            line.special = 0;
        },
        123 => {
            // SR Turbo lift
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
        },

        // ---- Lights ----
        12 => {
            // W1 Light to highest surrounding
            lights.EV_LightTurnOn(line, level, 0);
            line.special = 0;
        },
        13 => {
            // W1 Light to 255
            lights.EV_LightTurnOn(line, level, 255);
            line.special = 0;
        },
        17 => {
            // W1 Start strobe
            lights.EV_StartLightStrobing(line, level, allocator);
            line.special = 0;
        },
        35 => {
            // W1 Light to 35
            lights.EV_TurnTagLightsOff(line, level);
            line.special = 0;
        },
        79 => {
            // WR Light to 35
            lights.EV_TurnTagLightsOff(line, level);
        },
        80 => {
            // WR Light to brightest
            lights.EV_LightTurnOn(line, level, 0);
        },
        81 => {
            // WR Light to 255
            lights.EV_LightTurnOn(line, level, 255);
        },
        104 => {
            // W1 Light to lowest
            lights.EV_TurnTagLightsOff(line, level);
            line.special = 0;
        },
        138 => {
            // SR Light to 255
            lights.EV_LightTurnOn(line, level, 255);
        },
        139 => {
            // SR Light to 35
            lights.EV_TurnTagLightsOff(line, level);
        },

        // ---- Teleporters ----
        39 => {
            // W1 Teleport
            if (telept.EV_Teleport(line, side, thing, level, allocator)) {
                line.special = 0;
            }
        },
        97 => {
            // WR Teleport
            _ = telept.EV_Teleport(line, side, thing, level, allocator);
        },
        125 => {
            // W1 Monster teleport
            if (!is_player) {
                if (telept.EV_Teleport(line, side, thing, level, allocator)) {
                    line.special = 0;
                }
            }
        },
        126 => {
            // WR Monster teleport
            if (!is_player) {
                _ = telept.EV_Teleport(line, side, thing, level, allocator);
            }
        },

        // ---- Donut ----
        9 => {
            // S1 Donut
            _ = floor_mod.EV_DoDonut(line, level, allocator);
            line.special = 0;
        },

        else => {
            // Unhandled special — do nothing
        },
    }
}

// ============================================================================
// shootSpecialLine — player shoots a linedef
// ============================================================================

pub fn shootSpecialLine(thing: *MapObject, line_idx: usize, level: *Level, allocator: std.mem.Allocator) void {
    if (line_idx >= level.lines.len) return;
    const line = &level.lines[line_idx];

    // Only players can trigger gun specials
    if (thing.player == null) return;

    switch (line.special) {
        46 => {
            // GR Open door
            _ = doors.EV_DoDoor(line, .door_open, level, allocator);
            // GR = repeatable, don't clear special
        },
        else => {},
    }
}

// ============================================================================
// useSpecialLine — player uses (activates) a linedef
// ============================================================================

pub fn useSpecialLine(thing: *MapObject, line_idx: usize, side: i32, level: *Level, allocator: std.mem.Allocator) void {
    if (line_idx >= level.lines.len) return;
    const line = &level.lines[line_idx];

    _ = side;

    switch (line.special) {
        // ---- Manual doors (no tag — affect back sector directly) ----
        1, 26, 27, 28, 31, 32, 33, 34, 117, 118 => {
            doors.EV_VerticalDoor(line, thing, level, allocator);
            return;
        },
        else => {},
    }

    // Only players can trigger switch specials
    if (thing.player == null) return;

    var use_again = false;

    switch (line.special) {
        // ---- Switch doors (S1) ----
        29 => {
            // S1 Raise door
            _ = doors.EV_DoDoor(line, .normal, level, allocator);
        },
        103 => {
            // S1 Open door stay
            _ = doors.EV_DoDoor(line, .door_open, level, allocator);
        },
        111 => {
            // S1 Open door fast
            _ = doors.EV_DoDoor(line, .blaze_raise, level, allocator);
        },
        112 => {
            // S1 Open door fast stay
            _ = doors.EV_DoDoor(line, .blaze_open, level, allocator);
        },
        113 => {
            // S1 Close door fast
            _ = doors.EV_DoDoor(line, .blaze_close, level, allocator);
        },

        // ---- Switch doors (SR) ----
        61 => {
            // SR Open door stay
            _ = doors.EV_DoDoor(line, .door_open, level, allocator);
            use_again = true;
        },
        63 => {
            // SR Open door close
            _ = doors.EV_DoDoor(line, .normal, level, allocator);
            use_again = true;
        },
        114 => {
            // SR Open door fast
            _ = doors.EV_DoDoor(line, .blaze_raise, level, allocator);
            use_again = true;
        },
        115 => {
            // SR Open door fast stay
            _ = doors.EV_DoDoor(line, .blaze_open, level, allocator);
            use_again = true;
        },
        116 => {
            // SR Close door fast
            _ = doors.EV_DoDoor(line, .blaze_close, level, allocator);
            use_again = true;
        },

        // ---- Switch floors (S1) ----
        14 => {
            // S1 Raise floor 32 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_by_value, level, allocator);
        },
        15 => {
            // S1 Raise floor 24 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24_and_change, level, allocator);
        },
        20 => {
            // S1 Raise floor to next + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_to_nearest, level, allocator);
        },
        45 => {
            // SR Lower floor to highest
            _ = floor_mod.EV_DoFloor(line, .lower_floor, level, allocator);
            use_again = true;
        },
        55 => {
            // S1 Raise floor crush
            _ = floor_mod.EV_DoFloor(line, .raise_floor_crush, level, allocator);
        },
        60 => {
            // SR Lower floor to lowest
            _ = floor_mod.EV_DoFloor(line, .lower_floor_to_lowest, level, allocator);
            use_again = true;
        },
        64 => {
            // SR Raise floor to lowest ceiling
            _ = floor_mod.EV_DoFloor(line, .raise_floor, level, allocator);
            use_again = true;
        },
        65 => {
            // SR Raise floor crush
            _ = floor_mod.EV_DoFloor(line, .raise_floor_crush, level, allocator);
            use_again = true;
        },
        66 => {
            // SR Raise floor 24 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_24_and_change, level, allocator);
            use_again = true;
        },
        67 => {
            // SR Raise floor 32 + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_by_value, level, allocator);
            use_again = true;
        },
        68 => {
            // SR Raise floor to next + change
            _ = floor_mod.EV_DoFloor(line, .raise_floor_to_nearest, level, allocator);
            use_again = true;
        },
        69 => {
            // SR Raise floor to next
            _ = floor_mod.EV_DoFloor(line, .raise_floor_to_nearest, level, allocator);
            use_again = true;
        },
        70 => {
            // SR Turbo lower floor
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
            use_again = true;
        },
        71 => {
            // S1 Turbo lower floor
            _ = floor_mod.EV_DoFloor(line, .turbo_lower, level, allocator);
        },
        102 => {
            // S1 Lower floor to highest
            _ = floor_mod.EV_DoFloor(line, .lower_floor, level, allocator);
        },
        131 => {
            // S1 Raise floor turbo
            _ = floor_mod.EV_DoFloor(line, .raise_floor_turbo, level, allocator);
        },
        132 => {
            // SR Raise floor turbo
            _ = floor_mod.EV_DoFloor(line, .raise_floor_turbo, level, allocator);
            use_again = true;
        },

        // ---- Switch ceilings ----
        42 => {
            // SR Close door
            _ = doors.EV_DoDoor(line, .door_close, level, allocator);
            use_again = true;
        },

        // ---- Switch lights ----
        48 => {
            // Scrolling wall (handled in updateSpecials)
        },

        // ---- Exit switches ----
        11 => {
            // S1 Exit level
            switch_mod.changeSwitchTexture(line_idx, false, level);
            // Full implementation: G_ExitLevel()
            return;
        },
        51 => {
            // S1 Secret exit
            switch_mod.changeSwitchTexture(line_idx, false, level);
            // Full implementation: G_SecretExitLevel()
            return;
        },

        else => return, // Unknown special — do nothing, don't swap texture
    }

    // Swap switch texture
    switch_mod.changeSwitchTexture(line_idx, use_again, level);

    // Clear one-time specials
    if (!use_again) {
        line.special = 0;
    }
}

// ============================================================================
// playerInSpecialSector — damage/secret sectors
// ============================================================================

pub fn playerInSpecialSector(player: *Player, sector: *Sector) void {
    // Check if player is on the floor
    const mo = player.mobj orelse return;
    if (mo.z.raw() != mo.floorz.raw()) return;

    switch (sector.special) {
        5 => {
            // -10% health (no flash)
            if (player.powers[@intFromEnum(defs.PowerType.iron_feet)] == 0) {
                // Damage every 32 tics
                if (player.health > 10) {
                    player.health -= 5;
                    mo.health = player.health;
                }
            }
        },
        7 => {
            // -5% health (no flash)
            if (player.powers[@intFromEnum(defs.PowerType.iron_feet)] == 0) {
                if (player.health > 5) {
                    player.health -= 2;
                    mo.health = player.health;
                }
            }
        },
        16, 4 => {
            // -20% health + light blink
            if (player.powers[@intFromEnum(defs.PowerType.iron_feet)] == 0) {
                if (player.health > 20) {
                    player.health -= 10;
                    mo.health = player.health;
                }
            }
        },
        11 => {
            // -20% health + end level on death
            if (player.powers[@intFromEnum(defs.PowerType.iron_feet)] == 0) {
                if (player.health > 20) {
                    player.health -= 10;
                    mo.health = player.health;
                }
            }
            if (player.health <= 10) {
                // Full implementation: G_ExitLevel()
            }
        },
        9 => {
            // Secret sector — count and clear
            player.secret_count += 1;
            sector.special = 0;
        },
        else => {},
    }
}

// ============================================================================
// spawnSpecials — init sector lighting effects and scrolling walls
// ============================================================================

pub fn spawnSpecials(level: *Level, allocator: std.mem.Allocator) void {
    spec_level = level;
    spec_allocator = allocator;

    // Set level pointers for all sub-modules
    doors.setLevel(level);
    floor_mod.setLevel(level);
    ceiling.setLevel(level);
    lights.setLevel(level);

    // Clear active ceilings
    ceiling.clearActiveCeilings();

    // Initialize switch list (episode 1 for shareware)
    switch_mod.initSwitchList(1);
    switch_mod.clearButtons();

    // Spawn sector light effects based on sector.special
    for (level.sectors, 0..) |sector, i| {
        switch (sector.special) {
            1 => {
                // Light blinks randomly
                lights.spawnLightFlash(@intCast(i), level, allocator);
            },
            2 => {
                // Fast strobe (0.5 second dark)
                lights.spawnStrobeFlash(@intCast(i), level, 15, false, allocator);
            },
            3 => {
                // Slow strobe (1 second dark)
                lights.spawnStrobeFlash(@intCast(i), level, 35, false, allocator);
            },
            4 => {
                // Fast strobe + -20% damage
                lights.spawnStrobeFlash(@intCast(i), level, 15, false, allocator);
            },
            8 => {
                // Glow
                lights.spawnGlowing(@intCast(i), level, allocator);
            },
            10 => {
                // 30 second door close
                _ = doors.EV_DoDoor(&makeDummyLine(sector.tag), .close_30_open, level, allocator);
            },
            12 => {
                // Sync fast strobe
                lights.spawnStrobeFlash(@intCast(i), level, 15, true, allocator);
            },
            13 => {
                // Sync slow strobe
                lights.spawnStrobeFlash(@intCast(i), level, 35, true, allocator);
            },
            14 => {
                // Door raise in 5 minutes
                _ = doors.EV_DoDoor(&makeDummyLine(sector.tag), .raise_in_5_mins, level, allocator);
            },
            17 => {
                // Light flickers
                lights.spawnLightFlash(@intCast(i), level, allocator);
            },
            else => {},
        }
    }
}

/// Create a dummy line with just a tag for sector-based triggers
fn makeDummyLine(tag: i16) Line {
    return .{
        .v1 = 0,
        .v2 = 0,
        .flags = 0,
        .special = 0,
        .tag = tag,
        .sidenum = .{ -1, -1 },
        .dx = Fixed.ZERO,
        .dy = Fixed.ZERO,
        .slopetype = .horizontal,
        .frontsector = null,
        .backsector = null,
        .bbox = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
    };
}

// ============================================================================
// updateSpecials — per-tic updates (animated textures, scrolling walls)
// ============================================================================

pub fn updateSpecials(level: *Level) void {
    // Check switch button timers
    switch_mod.checkButtons(level);

    // Animated textures would be updated here (flat/wall animation cycles)
    // Scrolling walls (special 48) would update texture offsets here
    // These require the full texture system which isn't implemented yet
}

// ============================================================================
// Tests
// ============================================================================

test "playerInSpecialSector secret" {
    var mo = MapObject{};
    mo.z = Fixed.ZERO;
    mo.floorz = Fixed.ZERO;

    var player = Player{};
    player.mobj = &mo;

    var sector = Sector{
        .floorheight = Fixed.ZERO,
        .ceilingheight = Fixed.fromInt(128),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 9, // Secret
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    playerInSpecialSector(&player, &sector);
    try std.testing.expectEqual(@as(i32, 1), player.secret_count);
    try std.testing.expectEqual(@as(i16, 0), sector.special); // Cleared after pickup
}

test "playerInSpecialSector damage" {
    var mo = MapObject{};
    mo.z = Fixed.ZERO;
    mo.floorz = Fixed.ZERO;
    mo.health = 100;

    var player = Player{};
    player.mobj = &mo;
    player.health = 100;

    var sector = Sector{
        .floorheight = Fixed.ZERO,
        .ceilingheight = Fixed.fromInt(128),
        .floorpic = 0,
        .ceilingpic = 0,
        .lightlevel = 200,
        .special = 5, // -10% damage
        .tag = 0,
        .floor_name = [_]u8{0} ** 8,
        .ceiling_name = [_]u8{0} ** 8,
    };

    playerInSpecialSector(&player, &sector);
    try std.testing.expectEqual(@as(i32, 95), player.health);
}

test "makeDummyLine" {
    const line = makeDummyLine(42);
    try std.testing.expectEqual(@as(i16, 42), line.tag);
    try std.testing.expectEqual(@as(i16, 0), line.special);
}
