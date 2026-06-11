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

    // Firing state
    refire: i32 = 0, // Consecutive-shot counter (accuracy penalty)
    attackdown: bool = false, // Fire held (missile/BFG don't auto-repeat)
    usedown: bool = false, // Use held (don't re-trigger every tic)

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

/// Main player think function — faithful port of P_PlayerThink.
pub fn playerThink(player: *Player) void {
    const mo = player.mobj orelse return;
    const cmd = &player.cmd;

    // Chainsaw lunge: A_Saw sets MF_JUSTATTACKED to run the player forward
    if (mo.flags & info.MF_JUSTATTACKED != 0) {
        cmd.angleturn = 0;
        cmd.forwardmove = 0xc8 / 2; // 100
        cmd.sidemove = 0;
        mo.flags &= ~info.MF_JUSTATTACKED;
    }

    // Handle death
    if (player.player_state == .dead) {
        deathThink(player);
        return;
    }

    // Move around. Reactiontime prevents movement right after a teleport.
    if (mo.reaction_time > 0) {
        mo.reaction_time -= 1;
    } else {
        movePlayer(player);
    }

    // View bobbing
    calcHeight(player);

    // Weapon change from the ticcmd (demos carry these)
    if (cmd.buttons & BT_SPECIAL != 0) cmd.buttons = 0;
    if (cmd.buttons & BT_CHANGE != 0) {
        var newweapon: u8 = (cmd.buttons & BT_WEAPONMASK) >> BT_WEAPONSHIFT;

        // Fist slot toggles to chainsaw when owned (unless berserk-fisting)
        if (newweapon == @intFromEnum(defs.WeaponType.fist) and
            player.weapon_owned[@intFromEnum(defs.WeaponType.chainsaw)] and
            !(player.ready_weapon == .chainsaw and
                player.powers[@intFromEnum(defs.PowerType.strength)] != 0))
        {
            newweapon = @intFromEnum(defs.WeaponType.chainsaw);
        }

        if (newweapon < defs.NUMWEAPONS and
            player.weapon_owned[newweapon] and
            newweapon != @intFromEnum(player.ready_weapon))
        {
            player.pending_weapon = @enumFromInt(newweapon);
        }
    }

    // Use button (edge-triggered)
    if (cmd.buttons & BT_USE != 0) {
        if (!player.usedown) {
            map_mod.useLines(mo);
            player.usedown = true;
        }
    } else {
        player.usedown = false;
    }

    // Counters, time-dependent powerups (vanilla semantics: strength counts
    // UP and never expires; invisibility clears MF_SHADOW when it runs out)
    if (player.powers[@intFromEnum(defs.PowerType.strength)] != 0) {
        player.powers[@intFromEnum(defs.PowerType.strength)] += 1;
    }
    if (player.powers[@intFromEnum(defs.PowerType.invulnerability)] > 0) {
        player.powers[@intFromEnum(defs.PowerType.invulnerability)] -= 1;
    }
    if (player.powers[@intFromEnum(defs.PowerType.invisibility)] > 0) {
        player.powers[@intFromEnum(defs.PowerType.invisibility)] -= 1;
        if (player.powers[@intFromEnum(defs.PowerType.invisibility)] == 0) {
            mo.flags &= ~info.MF_SHADOW;
        }
    }
    if (player.powers[@intFromEnum(defs.PowerType.infrared)] > 0) {
        player.powers[@intFromEnum(defs.PowerType.infrared)] -= 1;
    }
    if (player.powers[@intFromEnum(defs.PowerType.iron_feet)] > 0) {
        player.powers[@intFromEnum(defs.PowerType.iron_feet)] -= 1;
    }
    if (player.powers[@intFromEnum(defs.PowerType.all_map)] > 0) {
        // All-map is permanent once picked up (vanilla never decrements it)
    }

    if (player.damage_count > 0) player.damage_count -= 1;
    if (player.bonus_count > 0) player.bonus_count -= 1;
}

/// Apply turn + forward/side movement from ticcmd (P_MovePlayer).
fn movePlayer(player: *Player) void {
    const mo = player.mobj orelse return;
    const cmd = &player.cmd;

    mo.angle +%= @as(u32, @bitCast(@as(i32, cmd.angleturn))) << 16;

    // No air control: thrust only when on the ground
    const onground = mo.z.raw() <= mo.floorz.raw();

    if (cmd.forwardmove != 0 and onground) {
        thrust(mo, mo.angle, @as(i32, cmd.forwardmove) * 2048);
    }
    if (cmd.sidemove != 0 and onground) {
        thrust(mo, mo.angle -% fixed.ANG90, @as(i32, cmd.sidemove) * 2048);
    }

    // Start the walk animation only from the standing frame
    if ((cmd.forwardmove != 0 or cmd.sidemove != 0) and
        mo.state_num == .S_PLAY)
    {
        _ = mo.setState(info.StateNum.S_PLAY_RUN1);
    }
}

/// P_Thrust — push along an angle
fn thrust(mo: *MapObject, angle: Angle, move: i32) void {
    const fine = angle >> tables.ANGLETOFINESHIFT;
    const m = Fixed.fromRaw(move);
    mo.momx = Fixed.add(mo.momx, Fixed.mul(m, tables.finecosine[fine & tables.FINEMASK]));
    mo.momy = Fixed.add(mo.momy, Fixed.mul(m, tables.finesine[fine & tables.FINEMASK]));
}

/// Calculate view height with bobbing (P_CalcHeight).
fn calcHeight(player: *Player) void {
    const mo = player.mobj orelse return;

    // Bob amount from momentum: (momx² + momy²) >> 2 in fixed-mul terms
    var bob_raw: i64 = (@as(i64, mo.momx.raw()) * @as(i64, mo.momx.raw())) >> 16;
    bob_raw += (@as(i64, mo.momy.raw()) * @as(i64, mo.momy.raw())) >> 16;
    bob_raw >>= 2;
    if (bob_raw > MAXBOB.raw()) bob_raw = MAXBOB.raw();
    player.bob = Fixed.fromRaw(@intCast(bob_raw));

    const onground = mo.z.raw() <= mo.floorz.raw();
    if (!onground) {
        player.viewz = Fixed.add(mo.z, player.viewheight);
        const ceil_lim = Fixed.sub(mo.ceilingz, Fixed.fromRaw(4 * 0x10000));
        if (player.viewz.raw() > ceil_lim.raw()) player.viewz = ceil_lim;
        return;
    }

    // Bob phase from leveltime (FINEANGLES/20 per tic)
    const world_mod = @import("world.zig");
    const phase: usize = @intCast((@as(i64, tables.FINEANGLES / 20) * @as(i64, @max(0, world_mod.leveltime))) & tables.FINEMASK);
    const bob = Fixed.mul(Fixed.fromRaw(@divTrunc(player.bob.raw(), 2)), tables.finesine[phase]);

    // Move viewheight (squat recovery is upward-only, FRACUNIT/4 per tic)
    if (player.player_state == .alive) {
        player.viewheight = Fixed.add(player.viewheight, player.deltaviewheight);

        if (player.viewheight.raw() > VIEWHEIGHT.raw()) {
            player.viewheight = VIEWHEIGHT;
            player.deltaviewheight = Fixed.ZERO;
        }
        if (player.viewheight.raw() < @divTrunc(VIEWHEIGHT.raw(), 2)) {
            player.viewheight = Fixed.fromRaw(@divTrunc(VIEWHEIGHT.raw(), 2));
            if (player.deltaviewheight.raw() <= 0) {
                player.deltaviewheight = Fixed.fromRaw(1);
            }
        }
        if (player.deltaviewheight.raw() != 0) {
            player.deltaviewheight = Fixed.add(player.deltaviewheight, Fixed.fromRaw(0x4000));
            if (player.deltaviewheight.raw() == 0) {
                player.deltaviewheight = Fixed.fromRaw(1);
            }
        }
    }

    player.viewz = Fixed.add(Fixed.add(mo.z, player.viewheight), bob);

    const ceil_lim = Fixed.sub(mo.ceilingz, Fixed.fromRaw(4 * 0x10000));
    if (player.viewz.raw() > ceil_lim.raw()) player.viewz = ceil_lim;
}

/// Player death camera — slowly lower view to ground
fn deathThink(player: *Player) void {
    const mo = player.mobj orelse return;

    // Lower view to floor
    if (player.viewheight.raw() > Fixed.fromRaw(6 * 0x10000).raw()) {
        player.viewheight = Fixed.sub(player.viewheight, Fixed.ONE);
    }
    if (player.viewheight.raw() < 6 * 0x10000) {
        player.viewheight = Fixed.fromRaw(6 * 0x10000);
    }

    // Calculate final viewz
    player.viewz = Fixed.add(mo.z, player.viewheight);
    if (player.viewz.raw() < Fixed.add(mo.floorz, Fixed.ONE).raw()) {
        player.viewz = Fixed.add(mo.floorz, Fixed.ONE);
    }

    // Look at killer — vanilla turns in ANG5 (= ANG90/18) increments
    const ANG5: u32 = fixed.ANG90 / 18;
    if (player.attacker) |attacker| {
        if (attacker != mo) {
            const angle = maputl_pointToAngle(mo.x, mo.y, attacker.x, attacker.y);
            const delta = angle -% mo.angle;

            if (delta < ANG5 or delta > 0 -% ANG5) {
                // Face killer
                mo.angle = angle;
            } else if (delta < fixed.ANG180) {
                mo.angle +%= ANG5;
            } else {
                mo.angle -%= ANG5;
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
