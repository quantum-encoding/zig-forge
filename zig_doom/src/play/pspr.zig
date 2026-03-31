//! zig_doom/src/play/pspr.zig
//!
//! Player weapon sprite (psprite) animation and firing.
//! Translated from: linuxdoom-1.10/p_pspr.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Each player has two psprites: the weapon (ps_weapon=0) and the flash (ps_flash=1).
//! Weapon states control the raise/lower/ready/fire animations.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const info = @import("../info.zig");
const StateNum = info.StateNum;
const State = info.State;
const defs = @import("../defs.zig");
const WeaponType = defs.WeaponType;
const AmmoType = defs.AmmoType;
const random = @import("../random.zig");
const user = @import("user.zig");
const Player = user.Player;
const PSpriteDef = user.PSpriteDef;
const NUMPSPRITES = user.NUMPSPRITES;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const map_mod = @import("map.zig");
const level_mod = @import("level.zig");

// ============================================================================
// Constants
// ============================================================================

pub const ps_weapon = 0;
pub const ps_flash = 1;

// Weapon Y positions
const WEAPONTOP = Fixed.fromRaw(32 * 0x10000);
const WEAPONBOTTOM = Fixed.fromRaw(128 * 0x10000);
const LOWERSPEED = Fixed.fromRaw(6 * 0x10000);
const RAISESPEED = Fixed.fromRaw(6 * 0x10000);

// ============================================================================
// Weapon info — links weapon types to states and ammo
// ============================================================================

pub const WeaponInfo = struct {
    ammo: AmmoType,
    upstate: StateNum,
    downstate: StateNum,
    readystate: StateNum,
    atkstate: StateNum,
    flashstate: StateNum,
};

pub const weaponinfo = [defs.NUMWEAPONS]WeaponInfo{
    // Fist
    .{ .ammo = .no_ammo, .upstate = .S_PUNCHUP, .downstate = .S_PUNCHDOWN, .readystate = .S_PUNCH, .atkstate = .S_PUNCH1, .flashstate = .S_NULL },
    // Pistol
    .{ .ammo = .clip, .upstate = .S_PISTOLUP, .downstate = .S_PISTOLDOWN, .readystate = .S_PISTOL, .atkstate = .S_PISTOL1, .flashstate = .S_PISTOLFLASH },
    // Shotgun
    .{ .ammo = .shell, .upstate = .S_SGUNUP, .downstate = .S_SGUNDOWN, .readystate = .S_SGUN, .atkstate = .S_SGUN1, .flashstate = .S_SGUNFLASH1 },
    // Chaingun
    .{ .ammo = .clip, .upstate = .S_CHAINUP, .downstate = .S_CHAINDOWN, .readystate = .S_CHAIN, .atkstate = .S_CHAIN1, .flashstate = .S_CHAINFLASH1 },
    // Rocket launcher
    .{ .ammo = .missile, .upstate = .S_MISSILEUP, .downstate = .S_MISSILEDOWN, .readystate = .S_MISSILE, .atkstate = .S_MISSILE1, .flashstate = .S_MISSILEFLASH1 },
    // Plasma
    .{ .ammo = .cell, .upstate = .S_PLASMAUP, .downstate = .S_PLASMADOWN, .readystate = .S_PLASMA, .atkstate = .S_PLASMA1, .flashstate = .S_PLASMAFLASH1 },
    // BFG
    .{ .ammo = .cell, .upstate = .S_BFGUP, .downstate = .S_BFGDOWN, .readystate = .S_BFG, .atkstate = .S_BFG1, .flashstate = .S_BFGFLASH1 },
    // Chainsaw
    .{ .ammo = .no_ammo, .upstate = .S_SAWUP, .downstate = .S_SAWDOWN, .readystate = .S_SAW, .atkstate = .S_SAW1, .flashstate = .S_NULL },
    // Super shotgun (DOOM II)
    .{ .ammo = .shell, .upstate = .S_SGUNUP, .downstate = .S_SGUNDOWN, .readystate = .S_SGUN, .atkstate = .S_SGUN1, .flashstate = .S_SGUNFLASH1 },
};

// ============================================================================
// Psprite management
// ============================================================================

/// Set a player sprite to a specific state
pub fn setPsprite(player: *Player, position: usize, statenum: StateNum) void {
    var state_num = statenum;

    while (true) {
        if (state_num == .S_NULL) {
            player.psprites[position].state = null;
            return;
        }

        const state = &info.states[@intFromEnum(state_num)];
        player.psprites[position].state = state;
        player.psprites[position].tics = state.tics;

        // Call action function
        if (state.action) |action_fn| {
            action_fn(@ptrCast(player));
        }

        if (player.psprites[position].tics != 0) break;
        state_num = state.next_state;
    }
}

/// Initialize player sprites for a new level
pub fn setupPSprites(player: *Player) void {
    // Remove all psprites
    for (&player.psprites) |*psp| {
        psp.tics = -1;
        psp.state = null;
    }

    // Bring up the ready weapon
    player.pending_weapon = player.ready_weapon;
    bringUpWeapon(player);
}

/// Tick player sprite animations
pub fn movePSprites(player: *Player) void {
    for (0..NUMPSPRITES) |i| {
        if (player.psprites[i].tics != -1 and player.psprites[i].tics != 0) {
            player.psprites[i].tics -= 1;
            if (player.psprites[i].tics == 0) {
                if (player.psprites[i].state) |state| {
                    setPsprite(player, i, state.next_state);
                }
            }
        }
    }

    // Zero out flash psprite if done
    if (player.psprites[ps_flash].state == null) {
        player.psprites[ps_flash] = .{};
    }
}

/// Start raising the weapon
pub fn bringUpWeapon(player: *Player) void {
    const new_weapon = player.pending_weapon;
    player.pending_weapon = player.ready_weapon; // Will be reset once raised

    player.psprites[ps_weapon].sy = WEAPONBOTTOM;

    const winfo = weaponinfo[@intFromEnum(new_weapon)];
    setPsprite(player, ps_weapon, winfo.upstate);
}

/// Start lowering the weapon
pub fn dropWeapon(player: *Player) void {
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    setPsprite(player, ps_weapon, winfo.downstate);
}

// ============================================================================
// Weapon action functions (called from state table)
// These take *anyopaque which is the player pointer.
// ============================================================================

/// A_WeaponReady — weapon is ready to fire
pub fn A_WeaponReady(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));

    // Check for weapon change
    if (player.pending_weapon != player.ready_weapon) {
        dropWeapon(player);
        return;
    }

    // Check for fire
    if (player.cmd.buttons & user.BT_ATTACK != 0) {
        const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];

        // Check ammo
        if (winfo.ammo != .no_ammo) {
            if (player.ammo[@intFromEnum(winfo.ammo)] <= 0) return;
        }

        setPsprite(player, ps_weapon, winfo.atkstate);
        return;
    }

    // Bob the weapon
    const angle: usize = 0; // Would use leveltime in full DOOM
    _ = angle;
    player.psprites[ps_weapon].sx = Fixed.ZERO;
    player.psprites[ps_weapon].sy = WEAPONTOP;
}

/// A_Lower — lower weapon (switching weapons)
pub fn A_Lower(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));

    player.psprites[ps_weapon].sy = Fixed.add(player.psprites[ps_weapon].sy, LOWERSPEED);

    if (player.psprites[ps_weapon].sy.raw() < WEAPONBOTTOM.raw()) return;

    // Player is dead — keep weapon lowered
    if (player.player_state == .dead) {
        player.psprites[ps_weapon].sy = WEAPONBOTTOM;
        return;
    }

    // Switch weapons
    player.ready_weapon = player.pending_weapon;
    bringUpWeapon(player);
}

/// A_Raise — raise weapon
pub fn A_Raise(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));

    player.psprites[ps_weapon].sy = Fixed.sub(player.psprites[ps_weapon].sy, RAISESPEED);

    if (player.psprites[ps_weapon].sy.raw() > WEAPONTOP.raw()) return;

    // Weapon is raised — switch to ready state
    player.psprites[ps_weapon].sy = WEAPONTOP;
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    setPsprite(player, ps_weapon, winfo.readystate);
}

/// A_ReFire — check if player wants to keep firing
pub fn A_ReFire(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));

    if (player.cmd.buttons & user.BT_ATTACK != 0 and
        player.pending_weapon == player.ready_weapon and
        player.health > 0)
    {
        // Keep firing
        const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
        if (winfo.ammo != .no_ammo and player.ammo[@intFromEnum(winfo.ammo)] <= 0) {
            return; // Out of ammo
        }
        setPsprite(player, ps_weapon, winfo.atkstate);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "weapon info table" {
    // Pistol uses clip ammo
    try std.testing.expectEqual(AmmoType.clip, weaponinfo[@intFromEnum(WeaponType.pistol)].ammo);
    // Fist uses no ammo
    try std.testing.expectEqual(AmmoType.no_ammo, weaponinfo[@intFromEnum(WeaponType.fist)].ammo);
    // Shotgun uses shells
    try std.testing.expectEqual(AmmoType.shell, weaponinfo[@intFromEnum(WeaponType.shotgun)].ammo);
}

test "setup psprites" {
    var player = Player{};

    setupPSprites(&player);

    // Weapon should be in raise state
    try std.testing.expect(player.psprites[ps_weapon].state != null);
    try std.testing.expectEqual(WEAPONBOTTOM, player.psprites[ps_weapon].sy);
}

test "set psprite to null" {
    var player = Player{};

    setPsprite(&player, ps_flash, .S_NULL);
    try std.testing.expect(player.psprites[ps_flash].state == null);
}
