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
const world = @import("world.zig");
const inter = @import("inter.zig");
const enemy = @import("enemy.zig");
const maputl = @import("maputl.zig");
const tables = @import("../tables.zig");
const SfxId = @import("../sound/defs.zig").SfxId;

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
        // Rocket launcher and BFG require releasing fire between shots
        if (!player.attackdown or
            (player.ready_weapon != .missile and player.ready_weapon != .bfg))
        {
            player.attackdown = true;
            fireWeapon(player);
            return;
        }
    } else {
        player.attackdown = false;
    }

    // Bob the weapon while moving
    const angle: usize = @intCast((128 * @as(i64, @intCast(@max(0, world.leveltime)))) & tables.FINEMASK);
    player.psprites[ps_weapon].sx = Fixed.add(Fixed.ONE, Fixed.mul(player.bob, tables.finecosine[angle]));
    player.psprites[ps_weapon].sy = Fixed.add(WEAPONTOP, Fixed.mul(player.bob, tables.finesine[angle & (tables.FINEMASK / 2)]));
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
        player.refire += 1;
        fireWeapon(player);
    } else {
        player.refire = 0;
        _ = checkAmmo(player);
    }
}

// ============================================================================
// Firing core (P_FireWeapon, P_CheckAmmo, P_BulletSlope, P_GunShot)
// ============================================================================

/// Ammo needed per shot
fn ammoPerShot(weapon: WeaponType) i32 {
    return if (weapon == .bfg) 40 else 1;
}

/// Verify ammo for the ready weapon; if out, switch to the best available
/// weapon and return false.
pub fn checkAmmo(player: *Player) bool {
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    if (winfo.ammo == .no_ammo) return true;
    if (player.ammo[@intFromEnum(winfo.ammo)] >= ammoPerShot(player.ready_weapon)) return true;

    // Out of ammo — pick a new weapon (vanilla preference order)
    if (player.weapon_owned[@intFromEnum(WeaponType.chaingun)] and
        player.ammo[@intFromEnum(AmmoType.clip)] > 0)
    {
        player.pending_weapon = .chaingun;
    } else if (player.weapon_owned[@intFromEnum(WeaponType.shotgun)] and
        player.ammo[@intFromEnum(AmmoType.shell)] > 0)
    {
        player.pending_weapon = .shotgun;
    } else if (player.ammo[@intFromEnum(AmmoType.clip)] > 0) {
        player.pending_weapon = .pistol;
    } else if (player.weapon_owned[@intFromEnum(WeaponType.chainsaw)]) {
        player.pending_weapon = .chainsaw;
    } else if (player.weapon_owned[@intFromEnum(WeaponType.missile)] and
        player.ammo[@intFromEnum(AmmoType.missile)] > 0)
    {
        player.pending_weapon = .missile;
    } else if (player.weapon_owned[@intFromEnum(WeaponType.plasma)] and
        player.ammo[@intFromEnum(AmmoType.cell)] > 0)
    {
        player.pending_weapon = .plasma;
    } else {
        player.pending_weapon = .fist;
    }

    dropWeapon(player);
    return false;
}

/// Start the firing sequence for the ready weapon (P_FireWeapon)
pub fn fireWeapon(player: *Player) void {
    if (!checkAmmo(player)) return;

    if (player.mobj) |mo| {
        _ = mo.setState(.S_PLAY_ATK1);
        enemy.noiseAlert(mo);
    }
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    setPsprite(player, ps_weapon, winfo.atkstate);
}

fn decAmmo(player: *Player) void {
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    if (winfo.ammo == .no_ammo) return;
    const idx = @intFromEnum(winfo.ammo);
    player.ammo[idx] -= ammoPerShot(player.ready_weapon);
    if (player.ammo[idx] < 0) player.ammo[idx] = 0;
}

fn startFlash(player: *Player) void {
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    if (winfo.flashstate != .S_NULL) {
        setPsprite(player, ps_flash, winfo.flashstate);
    }
}

var bulletslope: Fixed = Fixed.ZERO;

/// Autoaim slope for hitscan weapons (P_BulletSlope)
fn bulletSlope(mo: *MapObject) void {
    var an = mo.angle;
    bulletslope = map_mod.aimLineAttack(mo, an, Fixed.fromInt(16 * 64));
    if (map_mod.linetarget == null) {
        an +%= @as(u32, 1) << 26;
        bulletslope = map_mod.aimLineAttack(mo, an, Fixed.fromInt(16 * 64));
        if (map_mod.linetarget == null) {
            an -%= @as(u32, 2) << 26;
            bulletslope = map_mod.aimLineAttack(mo, an, Fixed.fromInt(16 * 64));
            if (map_mod.linetarget == null) bulletslope = Fixed.ZERO;
        }
    }
}

/// One bullet (P_GunShot)
fn gunShot(mo: *MapObject, accurate: bool) void {
    const damage: i32 = 5 * (@as(i32, random.pRandom() % 3) + 1);
    var angle = mo.angle;
    if (!accurate) {
        angle +%= @as(u32, @bitCast(random.pSubRandom() << 18));
    }
    map_mod.lineAttack(mo, angle, level_mod.MISSILERANGE, bulletslope, damage);
}

// ============================================================================
// Weapon attack action functions
// ============================================================================

pub fn A_Punch(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;

    var damage: i32 = (@as(i32, random.pRandom() % 10) + 1) * 2;
    if (player.powers[@intFromEnum(defs.PowerType.strength)] != 0) damage *= 10; // Berserk

    var angle = mo.angle;
    angle +%= @as(u32, @bitCast(random.pSubRandom() << 18));
    const slope = map_mod.aimLineAttack(mo, angle, level_mod.MELEERANGE);
    map_mod.lineAttack(mo, angle, level_mod.MELEERANGE, slope, damage);

    // Connected: thud + face the victim
    if (map_mod.linetarget) |t| {
        world.playSfx(@ptrCast(mo), .punch);
        mo.angle = maputl.pointToAngle2(mo.x, mo.y, t.x, t.y);
    }
}

pub fn A_Saw(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;

    const damage: i32 = (@as(i32, random.pRandom() % 10) + 1) * 2;
    var angle = mo.angle;
    angle +%= @as(u32, @bitCast(random.pSubRandom() << 18));

    // Use MELEERANGE+1 so the puff doesn't skip if the target is in range
    const range = Fixed.add(level_mod.MELEERANGE, Fixed.ONE);
    const slope = map_mod.aimLineAttack(mo, angle, range);
    map_mod.lineAttack(mo, angle, range, slope, damage);

    const target = map_mod.linetarget orelse {
        world.playSfx(@ptrCast(mo), .sawful);
        return;
    };
    world.playSfx(@ptrCast(mo), .sawhit);

    // Turn to face the target, sawing away
    const an = maputl.pointToAngle2(mo.x, mo.y, target.x, target.y);
    const diff: i32 = @bitCast(an -% mo.angle);
    if (diff > @as(i32, @bitCast(fixed.ANG90 / 20))) {
        mo.angle = an -% fixed.ANG90 / 21;
    } else if (diff < -@as(i32, @bitCast(fixed.ANG90 / 20))) {
        mo.angle = an +% fixed.ANG90 / 21;
    } else {
        mo.angle = an;
    }
    mo.flags |= info.MF_JUSTATTACKED;
}

pub fn A_FirePistol(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;

    world.playSfx(@ptrCast(mo), .pistol);
    _ = mo.setState(.S_PLAY_ATK2);
    decAmmo(player);
    startFlash(player);

    bulletSlope(mo);
    gunShot(mo, player.refire == 0);
}

pub fn A_FireShotgun(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;

    world.playSfx(@ptrCast(mo), .shotgn);
    _ = mo.setState(.S_PLAY_ATK2);
    decAmmo(player);
    startFlash(player);

    bulletSlope(mo);
    for (0..7) |_| {
        gunShot(mo, false);
    }
}

pub fn A_FireCGun(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;

    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    if (winfo.ammo != .no_ammo and player.ammo[@intFromEnum(winfo.ammo)] <= 0) return;

    world.playSfx(@ptrCast(mo), .pistol);
    _ = mo.setState(.S_PLAY_ATK2);
    decAmmo(player);

    // Alternate the two flash frames with the barrels
    if (winfo.flashstate != .S_NULL) {
        const base = @intFromEnum(winfo.flashstate);
        const which: usize = if (player.psprites[ps_weapon].state == &info.states[@intFromEnum(StateNum.S_CHAIN1)]) 0 else 1;
        setPsprite(player, ps_flash, @enumFromInt(base + which));
    }

    bulletSlope(mo);
    gunShot(mo, player.refire == 0);
}

pub fn A_FireMissile(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;
    const alloc = world.allocator orelse return;

    decAmmo(player);
    _ = mobj_mod.spawnPlayerMissile(mo, .MT_ROCKET, alloc) catch return;
}

pub fn A_FirePlasma(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;
    const alloc = world.allocator orelse return;

    decAmmo(player);
    const winfo = weaponinfo[@intFromEnum(player.ready_weapon)];
    if (winfo.flashstate != .S_NULL) {
        const base = @intFromEnum(winfo.flashstate);
        setPsprite(player, ps_flash, @enumFromInt(base + @as(usize, random.pRandom() & 1)));
    }
    _ = mobj_mod.spawnPlayerMissile(mo, .MT_PLASMA, alloc) catch return;
}

pub fn A_BFGsound(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    if (player.mobj) |mo| world.playSfx(@ptrCast(mo), .bfg);
}

pub fn A_FireBFG(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    const mo = player.mobj orelse return;
    const alloc = world.allocator orelse return;

    decAmmo(player);
    _ = mobj_mod.spawnPlayerMissile(mo, .MT_BFG, alloc) catch return;
}

/// A_BFGSpray — called by the BFG ball's explosion state. The actor is the
/// BFG missile; its target is the player who fired.
pub fn A_BFGSpray(actor_ptr: *anyopaque) void {
    const mo: *MapObject = @ptrCast(@alignCast(actor_ptr));
    const shooter = mo.target orelse return;
    const alloc = world.allocator orelse return;

    // 40 rays spread across 90 degrees
    for (0..40) |i| {
        const an = mo.angle -% fixed.ANG90 / 2 +% (fixed.ANG90 / 40) *% @as(u32, @intCast(i));

        _ = map_mod.aimLineAttack(shooter, an, Fixed.fromInt(16 * 32));
        const target = map_mod.linetarget orelse continue;

        const fz = Fixed.add(target.z, Fixed.fromRaw(target.height.raw() >> 2));
        _ = mobj_mod.spawnMobj(target.x, target.y, fz, .MT_EXTRABFG, alloc) catch {};

        var damage: i32 = 0;
        for (0..15) |_| damage += @as(i32, random.pRandom() & 7) + 1;
        inter.damageMobj(target, shooter, shooter, damage);
    }
}

pub fn A_GunFlash(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    if (player.mobj) |mo| _ = mo.setState(.S_PLAY_ATK2);
    startFlash(player);
}

pub fn A_Light0(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    player.extra_light = 0;
}

pub fn A_Light1(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    player.extra_light = 1;
}

pub fn A_Light2(player_ptr: *anyopaque) void {
    const player: *Player = @ptrCast(@alignCast(player_ptr));
    player.extra_light = 2;
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

    // Weapon should be in raise state. Entering the up-state runs A_Raise
    // once (actions fire on state entry), so sy is one raise step above
    // WEAPONBOTTOM.
    try std.testing.expect(player.psprites[ps_weapon].state != null);
    try std.testing.expectEqual(Fixed.sub(WEAPONBOTTOM, RAISESPEED), player.psprites[ps_weapon].sy);
}

test "set psprite to null" {
    var player = Player{};

    setPsprite(&player, ps_flash, .S_NULL);
    try std.testing.expect(player.psprites[ps_flash].state == null);
}
