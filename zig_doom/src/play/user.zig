//! zig_doom/src/play/user.zig
//!
//! Player movement and controls.
//! Translated from: linuxdoom-1.10/p_user.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Processes player input (ticcmd) into movement, handles view bobbing,
//! death camera, and basic player state management.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const info = @import("../info.zig");
const tables = @import("../tables.zig");
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const map_mod = @import("map.zig");
const level_mod = @import("level.zig");

// ============================================================================
// Constants
// ============================================================================

pub const MAXHEALTH = 200;
pub const MAXARMOR = 200;
pub const MAXAMMO_CLIP = 200;
pub const MAXAMMO_SHELL = 50;
pub const MAXAMMO_CELL = 300;
pub const MAXAMMO_MISSILE = 50;

const VIEWHEIGHT = level_mod.VIEWHEIGHT;
const MAXBOB = Fixed.fromRaw(16 * 0x10000); // 16.0 max view bob

// Player movement speed multipliers
const FORWARDMOVE = [2]i32{ 0x19, 0x32 }; // walk, run
const SIDEMOVE = [2]i32{ 0x18, 0x28 }; // strafe walk, strafe run
const ANGLETURN = [3]i16{ 640, 1280, 320 }; // slow, fast, slow-turnheld

// Button flags
pub const BT_ATTACK = 1;
pub const BT_USE = 2;
pub const BT_CHANGE = 4; // Weapon change
pub const BT_SPECIAL = 128;
pub const BT_WEAPONMASK = 0x38;
pub const BT_WEAPONSHIFT = 3;

// ============================================================================
// TicCmd — one game tic of player input
// ============================================================================

pub const TicCmd = struct {
    forwardmove: i8 = 0,
    sidemove: i8 = 0,
    angleturn: i16 = 0,
    buttons: u8 = 0,
    consistancy: u8 = 0,
};

// ============================================================================
// Player State
// ============================================================================

pub const PlayerState = enum {
    alive,
    dead,
    reborn,
};

/// PSpriteDef — player sprite (weapon overlay) state
pub const PSpriteDef = struct {
    state: ?*const info.State = null,
    tics: i32 = 0,
    sx: Fixed = Fixed.ZERO,
    sy: Fixed = Fixed.ZERO,
};

pub const NUMPSPRITES = 2;

// ============================================================================
// Player — full player state
// ============================================================================

pub const Player = struct {
    mobj: ?*MapObject = null,
    player_state: PlayerState = .alive,

    // Input
    cmd: TicCmd = .{},

    // View
    viewz: Fixed = Fixed.ZERO,
    viewheight: Fixed = VIEWHEIGHT,
    deltaviewheight: Fixed = Fixed.ZERO,
    bob: Fixed = Fixed.ZERO,

    // Health/armor
    health: i32 = 100,
    armor_points: i32 = 0,
    armor_type: i32 = 0,

    // Keys
    cards: [defs.NUMCARDS]bool = [_]bool{false} ** defs.NUMCARDS,
    backpack: bool = false,

    // Weapons
    ready_weapon: defs.WeaponType = .pistol,
    pending_weapon: defs.WeaponType = .pistol,
    weapon_owned: [defs.NUMWEAPONS]bool = blk: {
        var wep = [_]bool{false} ** defs.NUMWEAPONS;
        wep[@intFromEnum(defs.WeaponType.fist)] = true;
        wep[@intFromEnum(defs.WeaponType.pistol)] = true;
        break :blk wep;
    },
    ammo: [defs.NUMAMMO]i32 = .{ 50, 0, 0, 0 }, // Start with 50 bullets
    max_ammo: [defs.NUMAMMO]i32 = .{ 200, 50, 300, 50 },

    // Powers
    powers: [defs.NUMPOWERS]i32 = [_]i32{0} ** defs.NUMPOWERS,

    // Stats
    kill_count: i32 = 0,
    item_count: i32 = 0,
    secret_count: i32 = 0,

    // Damage
    damage_count: i32 = 0,
    bonus_count: i32 = 0,
    attacker: ?*MapObject = null,
    extra_light: i32 = 0,

    // Weapon sprites
    psprites: [NUMPSPRITES]PSpriteDef = [_]PSpriteDef{.{}} ** NUMPSPRITES,

    // Cheats
    cheats: u32 = 0,

    // Reborn
    player_num: i32 = 0,
};

// ============================================================================
// Player Think — main per-tic update
// ============================================================================

/// Main player think function — process movement and actions
pub fn playerThink(player: *Player) void {
    const mo = player.mobj orelse return;
    const cmd = &player.cmd;

    // Turn
    if (cmd.angleturn != 0) {
        mo.angle +%= @as(u32, @bitCast(@as(i32, cmd.angleturn))) << 16;
    }

    // Handle death
    if (player.player_state == .dead) {
        deathThink(player);
        return;
    }

    // Movement
    movePlayer(player);

    // View bobbing
    calcHeight(player);

    // Decrement damage/bonus display counters
    if (player.damage_count > 0) player.damage_count -= 1;
    if (player.bonus_count > 0) player.bonus_count -= 1;

    // Power timers
    for (&player.powers) |*power| {
        if (power.* > 0) power.* -= 1;
    }

    // Use button
    if (cmd.buttons & BT_USE != 0) {
        map_mod.useLines(mo);
    }
}

/// Apply forward/side movement from ticcmd
fn movePlayer(player: *Player) void {
    const mo = player.mobj orelse return;
    const cmd = &player.cmd;

    mo.angle +%= @as(u32, @bitCast(@as(i32, cmd.angleturn))) << 16;

    // Forward/backward movement
    if (cmd.forwardmove != 0) {
        const thrust = Fixed.fromRaw(@as(i32, cmd.forwardmove) * 2048);
        const fine = mo.angle >> tables.ANGLETOFINESHIFT;
        mo.momx = Fixed.add(mo.momx, Fixed.mul(thrust, tables.finecosine[fine & tables.FINEMASK]));
        mo.momy = Fixed.add(mo.momy, Fixed.mul(thrust, tables.finesine[fine & tables.FINEMASK]));
    }

    // Strafe movement
    if (cmd.sidemove != 0) {
        const thrust = Fixed.fromRaw(@as(i32, cmd.sidemove) * 2048);
        const fine = (mo.angle -% fixed.ANG90) >> tables.ANGLETOFINESHIFT;
        mo.momx = Fixed.add(mo.momx, Fixed.mul(thrust, tables.finecosine[fine & tables.FINEMASK]));
        mo.momy = Fixed.add(mo.momy, Fixed.mul(thrust, tables.finesine[fine & tables.FINEMASK]));
    }

    // Check for running (if forward or side exceeds walk threshold)
    if (cmd.forwardmove > FORWARDMOVE[0] or cmd.forwardmove < -FORWARDMOVE[0] or
        cmd.sidemove > SIDEMOVE[0] or cmd.sidemove < -SIDEMOVE[0])
    {
        _ = mo.setState(info.StateNum.S_PLAY_RUN1);
    }
}

/// Calculate view height with bobbing
fn calcHeight(player: *Player) void {
    const mo = player.mobj orelse return;

    // Calculate view bob based on speed
    var bob_raw: i64 = 0;
    if (mo.momx.raw() != 0) {
        bob_raw += @as(i64, mo.momx.raw()) * @as(i64, mo.momx.raw());
    }
    if (mo.momy.raw() != 0) {
        bob_raw += @as(i64, mo.momy.raw()) * @as(i64, mo.momy.raw());
    }
    bob_raw >>= 18; // Scale down

    // Clamp bob
    const bob_clamped: i32 = @intCast(@min(@as(i64, MAXBOB.raw()), bob_raw));
    player.bob = Fixed.fromRaw(bob_clamped);

    // Deltaviewheight: smoothly adjust toward standard VIEWHEIGHT
    if (player.deltaviewheight.raw() != 0) {
        player.viewheight = Fixed.add(player.viewheight, player.deltaviewheight);

        if (player.viewheight.raw() > VIEWHEIGHT.raw()) {
            player.viewheight = VIEWHEIGHT;
            player.deltaviewheight = Fixed.ZERO;
        } else if (player.viewheight.raw() < @divTrunc(VIEWHEIGHT.raw(), 2)) {
            player.viewheight = Fixed.fromRaw(@divTrunc(VIEWHEIGHT.raw(), 2));
            if (player.deltaviewheight.raw() <= 0) {
                player.deltaviewheight = Fixed.fromRaw(1);
            }
        }

        if (player.deltaviewheight.raw() > 0) {
            player.deltaviewheight = Fixed.sub(player.deltaviewheight, Fixed.fromRaw(0x4000)); // Decrease
            if (player.deltaviewheight.raw() < 0) player.deltaviewheight = Fixed.ZERO;
        } else if (player.deltaviewheight.raw() < 0) {
            player.deltaviewheight = Fixed.add(player.deltaviewheight, Fixed.fromRaw(0x4000));
            if (player.deltaviewheight.raw() > 0) player.deltaviewheight = Fixed.ZERO;
        }
    }

    // Calculate final viewz
    player.viewz = Fixed.add(mo.z, player.viewheight);

    // Add bob (using fine angle based on game tic count)
    // Simplified: bob oscillates
    const bob_angle: usize = 0; // Would use leveltime * FINEANGLES/20 in full DOOM
    _ = bob_angle;
    player.viewz = Fixed.add(player.viewz, Fixed.fromRaw(@divTrunc(player.bob.raw(), 2)));

    // Clamp viewz to floor+1 .. ceiling-4
    const floor_limit = Fixed.add(mo.floorz, Fixed.ONE);
    const ceiling_limit = Fixed.sub(mo.ceilingz, Fixed.fromRaw(4 * 0x10000));

    if (player.viewz.raw() < floor_limit.raw()) {
        player.viewz = floor_limit;
    }
    if (player.viewz.raw() > ceiling_limit.raw()) {
        player.viewz = ceiling_limit;
    }
}

/// Player death camera — slowly lower view to ground
fn deathThink(player: *Player) void {
    const mo = player.mobj orelse return;

    // Lower view to floor
    if (player.viewheight.raw() > Fixed.fromRaw(6 * 0x10000).raw()) {
        player.viewheight = Fixed.sub(player.viewheight, Fixed.ONE);
    }

    // Calculate final viewz
    player.viewz = Fixed.add(mo.z, player.viewheight);
    if (player.viewz.raw() < Fixed.add(mo.floorz, Fixed.ONE).raw()) {
        player.viewz = Fixed.add(mo.floorz, Fixed.ONE);
    }

    // Look at killer
    if (player.attacker) |attacker| {
        if (attacker != mo) {
            const angle = maputl_pointToAngle(mo.x, mo.y, attacker.x, attacker.y);
            const delta = angle -% mo.angle;

            if (delta < fixed.ANG45 / 2 or delta > 0 -% fixed.ANG45 / 2) {
                // Face killer
                mo.angle = angle;
            } else if (delta < fixed.ANG180) {
                mo.angle +%= fixed.ANG45 / 4;
            } else {
                mo.angle -%= fixed.ANG45 / 4;
            }
        }
    }

    // Press use to respawn
    if (player.cmd.buttons & BT_USE != 0) {
        player.player_state = .reborn;
    }
}

fn maputl_pointToAngle(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Angle {
    return @import("maputl.zig").pointToAngle2(x1, y1, x2, y2);
}

// ============================================================================
// Tests
// ============================================================================

const tick = @import("tick.zig");

test "player init defaults" {
    const player = Player{};
    try std.testing.expectEqual(PlayerState.alive, player.player_state);
    try std.testing.expectEqual(@as(i32, 100), player.health);
    try std.testing.expectEqual(defs.WeaponType.pistol, player.ready_weapon);
    try std.testing.expect(player.weapon_owned[@intFromEnum(defs.WeaponType.fist)]);
    try std.testing.expect(player.weapon_owned[@intFromEnum(defs.WeaponType.pistol)]);
    try std.testing.expect(!player.weapon_owned[@intFromEnum(defs.WeaponType.shotgun)]);
    try std.testing.expectEqual(@as(i32, 50), player.ammo[0]); // 50 bullets
}

test "player forward movement" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mo = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_PLAYER, alloc);
    defer alloc.destroy(mo);

    mo.floorz = Fixed.ZERO;
    mo.ceilingz = Fixed.fromInt(128);
    mo.angle = 0; // Facing east

    var player = Player{};
    player.mobj = mo;
    mo.player = @ptrCast(&player);

    // Set forward movement
    player.cmd.forwardmove = 25; // Walk speed

    movePlayer(&player);

    // Should have gained eastward momentum
    try std.testing.expect(mo.momx.raw() > 0);

    tick.initThinkers();
}

test "player strafe movement" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mo = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_PLAYER, alloc);
    defer alloc.destroy(mo);

    mo.floorz = Fixed.ZERO;
    mo.ceilingz = Fixed.fromInt(128);
    mo.angle = 0; // Facing east

    var player = Player{};
    player.mobj = mo;

    // Set strafe right
    player.cmd.sidemove = 24;

    movePlayer(&player);

    // Strafing right while facing east should add southward momentum
    try std.testing.expect(mo.momy.raw() < 0);

    tick.initThinkers();
}

test "death think lowers view" {
    var mo = MapObject{};
    mo.z = Fixed.ZERO;
    mo.floorz = Fixed.ZERO;
    mo.ceilingz = Fixed.fromInt(128);

    var player = Player{};
    player.mobj = &mo;
    player.player_state = .dead;
    player.viewheight = VIEWHEIGHT;

    deathThink(&player);

    // Viewheight should decrease
    try std.testing.expect(player.viewheight.raw() < VIEWHEIGHT.raw());
}
