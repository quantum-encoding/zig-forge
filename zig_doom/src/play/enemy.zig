//! zig_doom/src/play/enemy.zig
//!
//! Monster AI — action functions for enemy behavior.
//! Translated from: linuxdoom-1.10/p_enemy.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM's monster AI is state-machine-based with action functions:
//! A_Look: scan for players, A_Chase: pursue target, A_*Attack: attack routines.
//! Movement uses 8 cardinal+diagonal directions with wall avoidance.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const info = @import("../info.zig");
const MobjType = info.MobjType;
const StateNum = info.StateNum;
const random = @import("../random.zig");
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const level_mod = @import("level.zig");
const maputl = @import("maputl.zig");
const map_mod = @import("map.zig");
const tables = @import("../tables.zig");

// ============================================================================
// Action Functions — called from state table via function pointers
// All take *anyopaque and cast to *MapObject internally.
// ============================================================================

/// A_Look — Monster idle state: scan for players.
/// If a player is found in line of sight, switch to see_state.
pub fn A_Look(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    // Reset threshold (infighting timer)
    actor.threshold = 0;

    // In full DOOM, this checks sound targets and performs LOS checks.
    // Phase 3: check if we have a target assigned and switch to see state.
    if (actor.target) |_| {
        const mobj_info = actor.getInfo();
        if (mobj_info.see_state != .S_NULL) {
            _ = actor.setState(mobj_info.see_state);
        }
    }
}

/// A_Chase — Monster chase state: move toward target, attempt attacks.
/// This is the core AI loop for active monsters.
pub fn A_Chase(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    const mobj_info = actor.getInfo();

    // Decrement reaction time
    if (actor.reaction_time > 0) {
        actor.reaction_time -= 1;
    }

    // Decrease threshold
    if (actor.threshold > 0) {
        // If target is dead/gone, reset threshold
        if (actor.target == null or
            (actor.target != null and actor.target.?.health <= 0))
        {
            actor.threshold = 0;
        } else {
            actor.threshold -= 1;
        }
    }

    // Floating monsters: adjust z toward target
    if (actor.flags & info.MF_FLOAT != 0) {
        if (actor.target) |target| {
            if (actor.z.raw() < target.z.raw()) {
                actor.z = Fixed.add(actor.z, level_mod.FLOATSPEED);
            } else if (actor.z.raw() > target.z.raw()) {
                actor.z = Fixed.sub(actor.z, level_mod.FLOATSPEED);
            }
        }
    }

    // Check for melee attack
    if (mobj_info.melee_state != .S_NULL and checkMeleeRange(actor)) {
        // A_FaceTarget before attacking
        faceTarget(actor);
        _ = actor.setState(mobj_info.melee_state);
        return;
    }

    // Check for missile attack
    if (mobj_info.missile_state != .S_NULL) {
        if (actor.movecount == 0 or actor.reaction_time <= 0) {
            if (checkMissileRange(actor)) {
                faceTarget(actor);
                _ = actor.setState(mobj_info.missile_state);
                actor.flags |= info.MF_JUSTATTACKED;
                return;
            }
        }
    }

    // Just attacked — take at least one step before attacking again
    if (actor.flags & info.MF_JUSTATTACKED != 0) {
        actor.flags &= ~info.MF_JUSTATTACKED;
        // Don't attack again immediately
    }

    // Chase target
    if (actor.movecount > 0) {
        actor.movecount -= 1;
    }

    if (actor.movecount <= 0) {
        newChaseDir(actor);
    }

    // Try to move in current direction
    if (actor.movedir < 8) {
        _ = doMove(actor);
    }
}

/// A_FaceTarget — Turn to face the current target
pub fn A_FaceTarget(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    faceTarget(actor);
}

/// A_PosAttack — Zombieman attack: single bullet hitscan
pub fn A_PosAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;

    faceTarget(actor);

    // Angle spread
    var angle = actor.angle;
    const spread: i32 = random.pSubRandom();
    angle +%= @as(u32, @bitCast(spread << 20));

    // Damage: 1d5 * 3 (3-15)
    const damage: i32 = (@as(i32, random.pRandom() % 5) + 1) * 3;

    // Fire hitscan
    map_mod.lineAttack(actor, angle, level_mod.MISSILERANGE, Fixed.ZERO, damage);
}

/// A_SPosAttack — Shotgun Guy attack: 3 bullets
pub fn A_SPosAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;

    faceTarget(actor);

    // Fire 3 bullets
    for (0..3) |_| {
        var angle = actor.angle;
        const spread: i32 = random.pSubRandom();
        angle +%= @as(u32, @bitCast(spread << 20));

        const damage: i32 = (@as(i32, random.pRandom() % 5) + 1) * 3;
        map_mod.lineAttack(actor, angle, level_mod.MISSILERANGE, Fixed.ZERO, damage);
    }
}

/// A_TroopAttack — Imp attack: melee claw or fireball
pub fn A_TroopAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    faceTarget(actor);

    // Melee range check
    if (checkMeleeRange(actor)) {
        // Melee damage: 1d8 * 3 (3-24)
        const damage: i32 = (@as(i32, random.pRandom() % 8) + 1) * 3;
        // In full DOOM: damageMobj(target, actor, actor, damage)
        _ = damage;
        _ = target;
        return;
    }

    // Fire imp fireball
    // In full DOOM: P_SpawnMissile(actor, target, MT_TROOPSHOT)
    // Phase 3: no-op without full spawn infrastructure
}

/// A_SargAttack — Demon bite attack (melee only)
pub fn A_SargAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;

    faceTarget(actor);

    if (checkMeleeRange(actor)) {
        const damage: i32 = (@as(i32, random.pRandom() % 10) + 1) * 4;
        _ = damage;
        // damageMobj(target, actor, actor, damage)
    }
}

/// A_SkullAttack — Lost Soul charge attack
pub fn A_SkullAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    // Set skull fly mode
    actor.flags |= info.MF_SKULLFLY;

    // Calculate angle and speed toward target
    const an = maputl.pointToAngle2(actor.x, actor.y, target.x, target.y);
    actor.angle = an;

    const speed = Fixed.fromRaw(20 * 0x10000); // SKULLSPEED
    const fine = an >> tables.ANGLETOFINESHIFT;
    actor.momx = Fixed.mul(speed, tables.finecosine[fine & tables.FINEMASK]);
    actor.momy = Fixed.mul(speed, tables.finesine[fine & tables.FINEMASK]);

    const dist = maputl.aproxDistance(Fixed.sub(target.x, actor.x), Fixed.sub(target.y, actor.y));
    if (dist.raw() != 0) {
        var num_raw = Fixed.sub(target.z, actor.z).raw();
        num_raw = @divTrunc(num_raw, @max(1, dist.raw() >> 16));
        actor.momz = Fixed.fromRaw(num_raw *% speed.raw() >> 16);
    }
}

/// A_Scream — Death scream (sound — no-op for Phase 3)
pub fn A_Scream(_: *anyopaque) void {
    // Sound system not yet implemented
}

/// A_XScream — Gib death scream
pub fn A_XScream(_: *anyopaque) void {
    // Sound system not yet implemented
}

/// A_Pain — Pain sound
pub fn A_Pain(_: *anyopaque) void {
    // Sound system not yet implemented
}

/// A_Fall — Remove MF_SOLID flag on death (things can walk over corpse)
pub fn A_Fall(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    actor.flags &= ~info.MF_SOLID;
}

/// A_Explode — Barrel/rocket explosion (radius damage)
pub fn A_Explode(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    map_mod.radiusAttack(actor, actor.target, 128);
}

// ============================================================================
// Internal helper functions
// ============================================================================

/// Turn actor to face its target
fn faceTarget(actor: *MapObject) void {
    if (actor.target) |target| {
        actor.angle = maputl.pointToAngle2(actor.x, actor.y, target.x, target.y);

        // If target has MF_SHADOW (spectre), add randomized spread
        if (target.flags & info.MF_SHADOW != 0) {
            const spread: i32 = random.pSubRandom();
            actor.angle +%= @as(u32, @bitCast(spread << 21));
        }
    }
}

/// Check if actor is within melee range of target
fn checkMeleeRange(actor: *MapObject) bool {
    const target = actor.target orelse return false;

    const dist = maputl.aproxDistance(
        Fixed.sub(target.x, actor.x),
        Fixed.sub(target.y, actor.y),
    );

    // Melee range = 64 + 20 (target radius fudge)
    return dist.raw() < level_mod.MELEERANGE.raw() + 20 * 0x10000;
}

/// Check if actor should fire a missile
fn checkMissileRange(actor: *MapObject) bool {
    const target = actor.target orelse return false;

    // Can't see target? Don't fire
    // (Full DOOM does LOS check here)

    if (actor.flags & info.MF_JUSTHIT != 0) {
        // Just been hit — retaliate
        actor.flags &= ~info.MF_JUSTHIT;
        return true;
    }

    if (actor.reaction_time > 0) return false;

    var dist = maputl.aproxDistance(
        Fixed.sub(target.x, actor.x),
        Fixed.sub(target.y, actor.y),
    );

    // No melee attack? Use longer range
    if (actor.getInfo().melee_state == .S_NULL) {
        dist = Fixed.sub(dist, Fixed.fromRaw(128 * 0x10000));
    }

    // Further away = less likely to fire
    const dist_int = dist.toInt();
    var chance = dist_int;

    // Specific adjustments per monster type
    if (actor.mobj_type == .MT_SKULL) {
        chance = @divTrunc(chance, 2); // Lost souls are more aggressive
    }

    if (chance > 200) chance = 200;
    if (chance < 0) chance = 0;

    return random.pRandom() >= @as(u8, @intCast(@min(255, chance)));
}

/// Choose a new chase direction toward target
fn newChaseDir(actor: *MapObject) void {
    const target = actor.target orelse return;

    const deltax = Fixed.sub(target.x, actor.x);
    const deltay = Fixed.sub(target.y, actor.y);

    // Determine preferred X and Y directions
    const d1: u8 = if (deltax.raw() > 10 * 0x10000)
        level_mod.DI_EAST
    else if (deltax.raw() < -10 * 0x10000)
        level_mod.DI_WEST
    else
        level_mod.DI_NODIR;

    const d2: u8 = if (deltay.raw() > 10 * 0x10000)
        level_mod.DI_NORTH
    else if (deltay.raw() < -10 * 0x10000)
        level_mod.DI_SOUTH
    else
        level_mod.DI_NODIR;

    // Try diagonal first
    if (d1 != level_mod.DI_NODIR and d2 != level_mod.DI_NODIR) {
        const diag_idx: usize = switch (d2) {
            level_mod.DI_NORTH => if (d1 == level_mod.DI_EAST) @as(usize, 1) else @as(usize, 0),
            level_mod.DI_SOUTH => if (d1 == level_mod.DI_EAST) @as(usize, 3) else @as(usize, 2),
            else => 0,
        };
        actor.movedir = level_mod.diags[diag_idx];
        if (tryDir(actor)) return;
    }

    // Try direct directions (randomly choose which axis to try first)
    if (random.pRandom() > 200 or deltay.abs().raw() > deltax.abs().raw()) {
        // Try Y first, then X
        if (d2 != level_mod.DI_NODIR) {
            actor.movedir = d2;
            if (tryDir(actor)) return;
        }
        if (d1 != level_mod.DI_NODIR) {
            actor.movedir = d1;
            if (tryDir(actor)) return;
        }
    } else {
        // Try X first, then Y
        if (d1 != level_mod.DI_NODIR) {
            actor.movedir = d1;
            if (tryDir(actor)) return;
        }
        if (d2 != level_mod.DI_NODIR) {
            actor.movedir = d2;
            if (tryDir(actor)) return;
        }
    }

    // Try other directions
    const old_dir = actor.movedir;
    if (old_dir != level_mod.DI_NODIR) {
        actor.movedir = level_mod.opposite[@intCast(old_dir)];
        if (tryDir(actor)) return;
    }

    // Random direction
    var tdir: u8 = 0;
    while (tdir < 8) : (tdir += 1) {
        actor.movedir = tdir;
        if (tryDir(actor)) return;
    }

    // Can't move at all
    actor.movedir = level_mod.DI_NODIR;
    actor.movecount = 0;
}

/// Try to move in the current direction. Returns true if successful.
fn tryDir(actor: *MapObject) bool {
    if (doMove(actor)) {
        actor.movecount = @as(i32, @intCast(random.pRandom() & 15));
        return true;
    }
    return false;
}

/// Attempt one step in the actor's current movedir
fn doMove(actor: *MapObject) bool {
    const dir: usize = @intCast(actor.movedir);
    if (dir >= 8) return false;

    const speed = Fixed.fromRaw(actor.getInfo().speed * 0x10000);
    const tryx = Fixed.add(actor.x, Fixed.mul(speed, level_mod.xspeed[dir]));
    const tryy = Fixed.add(actor.y, Fixed.mul(speed, level_mod.yspeed[dir]));

    return map_mod.tryMove(actor, tryx, tryy);
}

// ============================================================================
// Tests
// ============================================================================

test "face target calculates angle" {
    var actor = MapObject{};
    actor.x = Fixed.ZERO;
    actor.y = Fixed.ZERO;

    var target = MapObject{};
    target.x = Fixed.fromInt(100);
    target.y = Fixed.ZERO;
    target.flags = 0;

    actor.target = &target;

    faceTarget(&actor);

    // Target is to the east, angle should be ~0
    try std.testing.expect(actor.angle < fixed.ANG45 / 2 or actor.angle > 0xF0000000);
}

test "check melee range" {
    var actor = MapObject{};
    actor.x = Fixed.ZERO;
    actor.y = Fixed.ZERO;
    actor.mobj_type = .MT_SERGEANT;

    // Target within melee range
    var close_target = MapObject{};
    close_target.x = Fixed.fromInt(50);
    close_target.y = Fixed.ZERO;
    actor.target = &close_target;
    try std.testing.expect(checkMeleeRange(&actor));

    // Target out of melee range
    var far_target = MapObject{};
    far_target.x = Fixed.fromInt(200);
    far_target.y = Fixed.ZERO;
    actor.target = &far_target;
    try std.testing.expect(!checkMeleeRange(&actor));
}

test "A_Fall clears solid flag" {
    var actor = MapObject{};
    actor.flags = info.MF_SOLID | info.MF_SHOOTABLE;

    A_Fall(@ptrCast(&actor));

    try std.testing.expect(actor.flags & info.MF_SOLID == 0);
    try std.testing.expect(actor.flags & info.MF_SHOOTABLE != 0);
}

test "skull attack sets velocity toward target" {
    var actor = MapObject{};
    actor.x = Fixed.ZERO;
    actor.y = Fixed.ZERO;
    actor.z = Fixed.ZERO;
    actor.flags = 0;

    var target = MapObject{};
    target.x = Fixed.fromInt(100);
    target.y = Fixed.ZERO;
    target.z = Fixed.ZERO;
    target.flags = 0;

    actor.target = &target;

    A_SkullAttack(@ptrCast(&actor));

    // Should now be in skull fly mode
    try std.testing.expect(actor.flags & info.MF_SKULLFLY != 0);
    // Should have positive X momentum (target is to the east)
    try std.testing.expect(actor.momx.raw() > 0);
}
