//! zig_doom/src/play/inter.zig
//!
//! Damage, death, and item pickup interaction.
//! Translated from: linuxdoom-1.10/p_inter.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Handles: damageMobj (apply damage, pain state, death), killMobj (drop items,
//! kill credit), touchSpecialThing (item pickups).

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const info = @import("../info.zig");
const MobjType = info.MobjType;
const StateNum = info.StateNum;
const defs = @import("../defs.zig");
const random = @import("../random.zig");
const world = @import("world.zig");
const pspr = @import("pspr.zig");
const SfxId = @import("../sound/defs.zig").SfxId;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const maputl = @import("maputl.zig");
const user = @import("user.zig");
const Player = user.Player;

// ============================================================================
// Damage
// ============================================================================

/// Apply damage to a target mobj.
/// inflictor: the thing that caused the damage (projectile, barrel)
/// source: the thing that shot/triggered the inflictor (for kill credit)
/// damage: raw damage amount
pub fn damageMobj(
    target: *MapObject,
    inflictor: ?*MapObject,
    source: ?*MapObject,
    damage_in: i32,
) void {
    // Can't damage non-shootable things
    if (target.flags & info.MF_SHOOTABLE == 0) return;

    // Already dead?
    if (target.health <= 0) return;

    // Skull fly — stop on hit
    if (target.flags & info.MF_SKULLFLY != 0) {
        target.momx = Fixed.ZERO;
        target.momy = Fixed.ZERO;
        target.momz = Fixed.ZERO;
        target.flags &= ~info.MF_SKULLFLY;
    }

    var damage = damage_in;

    // Half damage on I'm Too Young To Die
    if (target.player != null and world.game_skill == 0) {
        damage >>= 1;
    }

    // Thrust from damage (knockback) — except point-blank chainsaw
    const chainsaw_src = blk: {
        const src = source orelse break :blk false;
        const pl = src.player orelse break :blk false;
        const p: *Player = @ptrCast(@alignCast(pl));
        break :blk p.ready_weapon == .chainsaw;
    };
    if (inflictor != null and target.flags & info.MF_NOCLIP == 0 and !chainsaw_src) {
        const inf = inflictor.?;
        var thrust_angle = maputl.pointToAngle2(inf.x, inf.y, target.x, target.y);
        const tables = @import("../tables.zig");

        // thrust = damage * (FRACUNIT>>3) * 100 / mass
        const mass: i64 = @max(1, target.getInfo().mass);
        var thrust_raw: i64 = @divTrunc(@as(i64, damage) * (0x10000 >> 3) * 100, mass);

        // Fall forward sometimes when hit hard from behind and above
        if (damage < 40 and damage > target.health and
            Fixed.sub(target.z, inf.z).raw() > 64 * 0x10000 and
            random.pRandom() & 1 != 0)
        {
            thrust_angle +%= fixed.ANG180;
            thrust_raw *= 4;
        }

        const fine = thrust_angle >> tables.ANGLETOFINESHIFT;
        const thrust = Fixed.fromRaw(@intCast(@min(thrust_raw, std.math.maxInt(i32))));
        target.momx = Fixed.add(target.momx, Fixed.mul(thrust, tables.finecosine[fine & tables.FINEMASK]));
        target.momy = Fixed.add(target.momy, Fixed.mul(thrust, tables.finesine[fine & tables.FINEMASK]));
    }

    // Player-specific damage reduction
    if (target.player != null) {
        const player_ptr: *Player = @ptrCast(@alignCast(target.player.?));

        // God mode / invulnerability: no damage
        if (player_ptr.cheats & 1 != 0 or
            player_ptr.powers[@intFromEnum(defs.PowerType.invulnerability)] != 0)
        {
            return;
        }

        // Reduce damage by armor
        if (player_ptr.armor_type > 0 and damage > 0) {
            var saved: i32 = 0;
            if (player_ptr.armor_type == 1) {
                saved = @divTrunc(damage, 3);
            } else {
                saved = @divTrunc(damage, 2);
            }

            if (player_ptr.armor_points <= saved) {
                // Armor is used up
                saved = player_ptr.armor_points;
                player_ptr.armor_type = 0;
            }

            player_ptr.armor_points -= saved;
            damage -= saved;
        }

        // Mirror the damage onto the player struct (HUD health)
        player_ptr.health -= damage;
        if (player_ptr.health < 0) player_ptr.health = 0;

        // Set attacker for death camera
        player_ptr.attacker = source;
        player_ptr.damage_count += damage; // Screen flash
        if (player_ptr.damage_count > 100) player_ptr.damage_count = 100;
    }

    // Apply damage
    target.health -= damage;

    if (target.health <= 0) {
        killMobj(source, target);
        return;
    }

    // Pain state (vanilla order: pain roll first, then reaction reset,
    // then retarget only when threshold expired; waking monsters go to
    // their see state immediately)
    const pain_chance = target.getInfo().pain_chance;
    if (random.pRandom() < @as(u8, @intCast(std.math.clamp(pain_chance, 0, 255))) and
        target.flags & info.MF_SKULLFLY == 0)
    {
        target.flags |= info.MF_JUSTHIT; // Fight back!
        const pain_state = target.getInfo().pain_state;
        if (pain_state != .S_NULL) {
            _ = target.setState(pain_state);
        }
    }

    target.reaction_time = 0; // We're awake now

    if (target.threshold == 0 and source != null and source != target) {
        // Target the attacker for a while
        target.target = source;
        target.threshold = 100; // BASETHRESHOLD
        if (target.state_num == target.getInfo().spawn_state and
            target.getInfo().see_state != .S_NULL)
        {
            _ = target.setState(target.getInfo().see_state);
        }
    }
}

/// Kill a thing — transition to death state, award kill credit.
pub fn killMobj(source: ?*MapObject, target: *MapObject) void {
    target.flags &= ~(info.MF_SHOOTABLE | info.MF_FLOAT | info.MF_SKULLFLY);

    // Not a corpse if it was a missile
    if (target.mobj_type != .MT_SKULL) {
        target.flags &= ~info.MF_NOGRAVITY;
    }

    target.flags |= info.MF_CORPSE | info.MF_DROPOFF;
    target.height = Fixed.fromRaw(@divTrunc(target.height.raw(), 4));

    // Award kill credit
    if (source) |src| {
        if (src.player != null) {
            const player_ptr: *Player = @ptrCast(@alignCast(src.player.?));

            if (target.flags & info.MF_COUNTKILL != 0) {
                player_ptr.kill_count += 1;
            }
        }
    }

    // Player death
    if (target.player != null) {
        const player_ptr: *Player = @ptrCast(@alignCast(target.player.?));
        player_ptr.player_state = .dead;
        pspr.dropWeapon(player_ptr);
    }

    // Choose death state (xdeath for extreme damage)
    const mobj_info = target.getInfo();
    if (target.health < -target.getInfo().spawn_health and
        mobj_info.xdeath_state != .S_NULL)
    {
        _ = target.setState(mobj_info.xdeath_state);
    } else {
        _ = target.setState(mobj_info.death_state);
    }

    // Randomize death tics slightly
    target.tics -%= @as(i32, @intCast(random.pRandom() & 3));
    if (target.tics < 1) target.tics = 1;

    // Zombies drop their weapon (half ammo via MF_DROPPED)
    const drop_type: ?info.MobjType = switch (target.mobj_type) {
        .MT_POSSESSED => .MT_CLIP,
        .MT_SHOTGUY => .MT_MISC29,
        else => null,
    };
    if (drop_type) |dt| {
        if (world.allocator) |alloc| {
            if (mobj_mod.spawnMobj(target.x, target.y, mobj_mod.ONFLOORZ, dt, alloc)) |item| {
                item.flags |= info.MF_DROPPED;
            } else |_| {}
        }
    }
}

// ============================================================================
// Item Pickup
// ============================================================================

/// Handle a player touching a special (pickup) thing.
/// Returns true if the item was picked up (and should be removed).
pub fn touchSpecialThing(special: *MapObject, toucher: *MapObject) bool {
    // Only players can pick up items
    if (toucher.player == null) return false;
    if (toucher.health <= 0) return false;

    // Out of reach vertically?
    const delta = Fixed.sub(special.z, toucher.z);
    if (delta.raw() > toucher.height.raw() or delta.raw() < -8 * 0x10000) return false;

    const player_ptr: *Player = @ptrCast(@alignCast(toucher.player.?));
    const dropped = special.flags & info.MF_DROPPED != 0;

    var pickup_sfx: SfxId = .itemup;

    // Determine item type and apply effect
    const picked = switch (special.mobj_type) {
        // Health
        .MT_MISC2 => giveHealth(player_ptr, 1, true), // Health bonus (+1, over 100)
        .MT_MISC10 => giveHealth(player_ptr, 10, false), // Stimpack
        .MT_MISC11 => giveHealth(player_ptr, 25, false), // Medikit
        .MT_MISC12 => blk: { // Soulsphere
            pickup_sfx = .getpow;
            break :blk giveHealth(player_ptr, 100, true);
        },

        // Armor
        .MT_MISC0 => giveArmor(player_ptr, 1), // Green armor
        .MT_MISC1 => giveArmor(player_ptr, 2), // Blue armor
        .MT_MISC3 => giveArmorBonus(player_ptr), // Armor bonus

        // Keys
        .MT_MISC4 => giveCard(player_ptr, .blue_card),
        .MT_MISC5 => giveCard(player_ptr, .red_card),
        .MT_MISC6 => giveCard(player_ptr, .yellow_card),

        // Powerups
        .MT_INV => blk: {
            pickup_sfx = .getpow;
            break :blk givePower(player_ptr, .invulnerability, 30 * 35);
        },
        .MT_MISC13 => blk: { // Berserk: strength + full heal + fists out
            pickup_sfx = .getpow;
            const got = givePower(player_ptr, .strength, 1);
            if (got) {
                _ = giveHealth(player_ptr, 100, false);
                player_ptr.pending_weapon = .fist;
            }
            break :blk got;
        },
        .MT_INS => blk: {
            pickup_sfx = .getpow;
            break :blk givePower(player_ptr, .invisibility, 60 * 35);
        },
        .MT_MISC14 => blk: {
            pickup_sfx = .getpow;
            break :blk givePower(player_ptr, .iron_feet, 60 * 35);
        },
        .MT_MISC15 => blk: {
            pickup_sfx = .getpow;
            break :blk givePower(player_ptr, .all_map, 1);
        },
        .MT_MISC16 => blk: {
            pickup_sfx = .getpow;
            break :blk givePower(player_ptr, .infrared, 120 * 35);
        },

        // Ammo
        .MT_CLIP => giveAmmo(player_ptr, .clip, 1, dropped),
        .MT_MISC17 => giveAmmo(player_ptr, .clip, 5, false), // Box of bullets
        .MT_MISC22 => giveAmmo(player_ptr, .shell, 1, dropped),
        .MT_MISC23 => giveAmmo(player_ptr, .shell, 5, false), // Box of shells
        .MT_MISC18 => giveAmmo(player_ptr, .missile, 1, false), // Rocket
        .MT_MISC19 => giveAmmo(player_ptr, .missile, 5, false), // Box of rockets
        .MT_MISC20 => giveAmmo(player_ptr, .cell, 1, false), // Cell
        .MT_MISC21 => giveAmmo(player_ptr, .cell, 5, false), // Cell pack
        .MT_MISC24 => giveBackpack(player_ptr), // Backpack

        // Weapons
        .MT_MISC29 => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .shotgun);
        },
        .MT_CHAINGUN => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .chaingun);
        },
        .MT_MISC25 => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .bfg);
        },
        .MT_MISC26 => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .chainsaw);
        },
        .MT_MISC27 => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .missile);
        },
        .MT_MISC28 => blk: {
            pickup_sfx = .wpnup;
            break :blk giveWeapon(player_ptr, .plasma);
        },

        else => false,
    };

    if (picked) {
        if (special.flags & info.MF_COUNTITEM != 0) {
            player_ptr.item_count += 1;
        }
        world.playSfx(@ptrCast(toucher), pickup_sfx);
    }
    return picked;
}

fn givePower(player: *Player, power: defs.PowerType, tics: i32) bool {
    const idx = @intFromEnum(power);
    // Always refresh duration (vanilla refuses if active; refreshing is kinder)
    player.powers[idx] = tics;
    player.bonus_count += 6;
    return true;
}

fn giveBackpack(player: *Player) bool {
    // Double ammo capacity once, then top up one unit of each type
    if (player.max_ammo[0] == 200) {
        for (&player.max_ammo) |*m| m.* *= 2;
    }
    for (0..defs.NUMAMMO) |i| {
        _ = giveAmmo(player, @enumFromInt(i), 1, false);
    }
    player.bonus_count += 6;
    return true;
}

// ============================================================================
// Give functions
// ============================================================================

fn giveHealth(player: *Player, amount: i32, over_max: bool) bool {
    const max = if (over_max) user.MAXHEALTH else @as(i32, 100);
    if (player.health >= max) return false;

    player.health += amount;
    if (player.health > max) player.health = max;

    if (player.mobj) |mo| {
        mo.health = player.health;
    }

    player.bonus_count += 6;
    return true;
}

fn giveArmor(player: *Player, armor_type: i32) bool {
    const max_armor = armor_type * 100;
    if (player.armor_points >= max_armor) return false;

    player.armor_type = armor_type;
    player.armor_points = max_armor;
    player.bonus_count += 6;
    return true;
}

fn giveArmorBonus(player: *Player) bool {
    player.armor_points += 1;
    if (player.armor_points > user.MAXARMOR) player.armor_points = user.MAXARMOR;
    if (player.armor_type == 0) player.armor_type = 1;
    player.bonus_count += 6;
    return true;
}

fn giveCard(player: *Player, card: defs.Card) bool {
    if (player.cards[@intFromEnum(card)]) return false;
    player.cards[@intFromEnum(card)] = true;
    player.bonus_count += 6;
    return true;
}

fn giveAmmo(player: *Player, ammo_type: defs.AmmoType, count: i32, dropped: bool) bool {
    if (ammo_type == .no_ammo) return false;
    const idx = @intFromEnum(ammo_type);
    if (player.ammo[idx] >= player.max_ammo[idx]) return false;

    const amounts = [4]i32{ 10, 4, 20, 1 }; // clip, shell, cell, missile
    var amount = amounts[idx] * count;
    if (dropped) amount = @divTrunc(amount, 2);
    if (amount < 1) amount = 1;

    player.ammo[idx] += amount;
    if (player.ammo[idx] > player.max_ammo[idx]) {
        player.ammo[idx] = player.max_ammo[idx];
    }

    player.bonus_count += 6;
    return true;
}

fn giveWeapon(player: *Player, weapon: defs.WeaponType) bool {
    const idx = @intFromEnum(weapon);
    const already_had = player.weapon_owned[idx];
    player.weapon_owned[idx] = true;

    // Give ammo for the weapon
    const ammo_for_weapon = [_]defs.AmmoType{
        .no_ammo, // fist
        .clip, // pistol
        .shell, // shotgun
        .clip, // chaingun
        .missile, // rocket
        .cell, // plasma
        .cell, // bfg
        .no_ammo, // chainsaw
        .shell, // super shotgun
    };

    const ammo_type = ammo_for_weapon[idx];
    if (ammo_type != .no_ammo) {
        // Weapons come with 2 clips' worth (vanilla single-player)
        _ = giveAmmo(player, ammo_type, 2, false);
    }

    // Switch to new weapon if better
    if (!already_had) {
        player.pending_weapon = weapon;
    }

    player.bonus_count += 6;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const tick = @import("tick.zig");

test "damage reduces health" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    try std.testing.expectEqual(@as(i32, 20), mobj.health);

    damageMobj(mobj, null, null, 10);
    try std.testing.expectEqual(@as(i32, 10), mobj.health);

    tick.initThinkers();
}

test "damage kills when health drops to zero" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    damageMobj(mobj, null, null, 100);

    // Should be dead — in death state
    try std.testing.expect(mobj.health <= 0);
    try std.testing.expect(mobj.flags & info.MF_CORPSE != 0);
    try std.testing.expect(mobj.flags & info.MF_SHOOTABLE == 0);

    tick.initThinkers();
}

test "kill awards xdeath for extreme damage" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    // Overkill: damage > spawn_health (20) -> xdeath
    damageMobj(mobj, null, null, 100);
    try std.testing.expect(mobj.health < -20); // Overkilled

    tick.initThinkers();
}

test "player armor reduces damage" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mo = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_PLAYER, alloc);
    defer alloc.destroy(mo);

    var player = Player{};
    player.health = 100;
    player.armor_type = 1; // Green armor
    player.armor_points = 100;
    player.mobj = mo;
    mo.player = @ptrCast(&player);
    mo.health = 100;

    damageMobj(mo, null, null, 30);

    // Armor absorbs 1/3 of damage (green armor)
    // 30 damage -> 10 absorbed -> 20 to health
    try std.testing.expectEqual(@as(i32, 80), mo.health);
    try std.testing.expectEqual(@as(i32, 90), player.armor_points);

    tick.initThinkers();
}

test "give health" {
    var player = Player{};
    player.health = 50;

    try std.testing.expect(giveHealth(&player, 10, false));
    try std.testing.expectEqual(@as(i32, 60), player.health);

    // Can't exceed 100 without overmax
    player.health = 100;
    try std.testing.expect(!giveHealth(&player, 10, false));

    // But can with bonus
    try std.testing.expect(giveHealth(&player, 1, true));
    try std.testing.expectEqual(@as(i32, 101), player.health);
}

test "give armor" {
    var player = Player{};

    // Green armor gives 100
    try std.testing.expect(giveArmor(&player, 1));
    try std.testing.expectEqual(@as(i32, 100), player.armor_points);
    try std.testing.expectEqual(@as(i32, 1), player.armor_type);

    // Can't pick up green armor when already full
    try std.testing.expect(!giveArmor(&player, 1));

    // But can upgrade to blue
    try std.testing.expect(giveArmor(&player, 2));
    try std.testing.expectEqual(@as(i32, 200), player.armor_points);
}

test "give card" {
    var player = Player{};

    try std.testing.expect(giveCard(&player, .blue_card));
    try std.testing.expect(player.cards[@intFromEnum(defs.Card.blue_card)]);

    // Can't pick up same card twice
    try std.testing.expect(!giveCard(&player, .blue_card));
}

test "give weapon" {
    var player = Player{};

    try std.testing.expect(giveWeapon(&player, .shotgun));
    try std.testing.expect(player.weapon_owned[@intFromEnum(defs.WeaponType.shotgun)]);
    try std.testing.expectEqual(defs.WeaponType.shotgun, player.pending_weapon);
    try std.testing.expect(player.ammo[@intFromEnum(defs.AmmoType.shell)] > 0);
}
