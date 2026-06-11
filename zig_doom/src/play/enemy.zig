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
const world = @import("world.zig");
const inter = @import("inter.zig");
const sight = @import("sight.zig");
const spec = @import("spec.zig");
const user = @import("user.zig");
const floor_mod = @import("floor.zig");
const setup = @import("setup.zig");
const SfxId = @import("../sound/defs.zig").SfxId;
const defs = @import("../defs.zig");

fn sfx(comptime id: SfxId) i32 {
    return @intFromEnum(id);
}

// ============================================================================
// Action Functions — called from state table via function pointers
// All take *anyopaque and cast to *MapObject internally.
// ============================================================================

var noise_validcount: i32 = 0;

/// P_RecursiveSound — flood sound from a sector through two-sided line
/// openings. ML_SOUNDBLOCK lines eat one "hop": sound crosses one blocking
/// line but not two.
fn recursiveSound(lvl: *setup.Level, sec_idx: usize, soundblocks: i32, emitter: *MapObject) void {
    const sec = &lvl.sectors[sec_idx];

    // Wavefront check
    if (sec.validcount == noise_validcount and sec.soundtraversed <= soundblocks + 1) {
        return; // Already flooded at least this well
    }
    sec.validcount = noise_validcount;
    sec.soundtraversed = soundblocks + 1;
    sec.soundtarget = @ptrCast(emitter);

    // Spread through every two-sided line bordering this sector
    for (lvl.lines) |*line| {
        if (line.flags & defs.ML_TWOSIDED == 0) continue;
        const fi = line.frontsector orelse continue;
        const bi = line.backsector orelse continue;
        if (fi != sec_idx and bi != sec_idx) continue;

        const op = maputl.lineOpening(line, lvl.sectors) orelse continue;
        if (op.range.raw() <= 0) continue; // Closed door

        const other: usize = if (fi == sec_idx) bi else fi;

        if (line.flags & defs.ML_SOUNDBLOCK != 0) {
            if (soundblocks == 0) {
                recursiveSound(lvl, other, 1, emitter);
            }
        } else {
            recursiveSound(lvl, other, soundblocks, emitter);
        }
    }
}

/// P_NoiseAlert — wake monsters when the player fires, by flooding the
/// sector graph with a sound target that A_Look picks up.
pub fn noiseAlert(emitter: *MapObject) void {
    const lvl = world.level orelse return;
    const sec = map_mod.sectorAtPoint(lvl, emitter.x, emitter.y) orelse return;
    const sec_idx = (@intFromPtr(sec) - @intFromPtr(lvl.sectors.ptr)) / @sizeOf(setup.Sector);
    noise_validcount +%= 1;
    recursiveSound(lvl, sec_idx, 0, emitter);
}

/// P_LookForPlayers — acquire a living, visible player as the target.
/// Faithful port including the lastlook round-robin (which is why
/// P_SpawnMobj seeds lastlook from P_Random — affects demo sync).
fn lookForPlayers(actor: *MapObject, allaround: bool) bool {
    const players_ptr = world.players orelse return false;
    const players: *[4]user.Player = @ptrCast(@alignCast(players_ptr));
    const in_game = world.player_in_game orelse return false;

    var c: i32 = 0;
    const stop: i32 = (actor.last_look - 1) & 3;

    while (true) : (actor.last_look = (actor.last_look + 1) & 3) {
        const idx: usize = @intCast(actor.last_look & 3);
        if (!in_game[idx]) continue;

        if (c == 2 or actor.last_look == stop) {
            return false; // Done looking
        }
        c += 1;

        const player = &players[idx];
        if (player.health <= 0) continue; // Dead — don't chase corpses
        const mo = player.mobj orelse continue;

        if (world.level) |lvl| {
            if (!sight.checkSight(actor, mo, lvl)) continue; // Out of sight
        }

        if (!allaround) {
            const an = maputl.pointToAngle2(actor.x, actor.y, mo.x, mo.y) -% actor.angle;
            if (an > fixed.ANG90 and an < fixed.ANG270) {
                // Behind the monster — only noticed if really close
                const dist = maputl.aproxDistance(Fixed.sub(mo.x, actor.x), Fixed.sub(mo.y, actor.y));
                if (dist.raw() > level_mod.MELEERANGE.raw()) continue;
            }
        }

        actor.target = mo;
        return true;
    }
}

/// A_Look — Monster idle state: scan for players.
/// If a player is found in line of sight, switch to see_state.
pub fn A_Look(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    // Reset threshold (infighting timer)
    actor.threshold = 0;

    // Any noise in this sector? (set by P_NoiseAlert flood)
    var has_target = false;
    if (world.level) |lvl| {
        if (map_mod.sectorAtPoint(lvl, actor.x, actor.y)) |sec| {
            if (sec.soundtarget) |st| {
                const targ: *MapObject = @ptrCast(@alignCast(st));
                if (targ.flags & info.MF_SHOOTABLE != 0) {
                    actor.target = targ;
                    if (actor.flags & info.MF_AMBUSH != 0) {
                        // Deaf monsters need to see the noisemaker
                        if (sight.checkSight(actor, targ, lvl)) has_target = true;
                    } else {
                        has_target = true;
                    }
                }
            }
        }
    }

    if (!has_target) {
        if (!lookForPlayers(actor, false)) return;
    }

    // Spotted — sight sound, then chase
    const mobj_info = actor.getInfo();
    if (mobj_info.see_sound != 0) {
        var snd = mobj_info.see_sound;
        // Randomized variants (vanilla: posit1-3, bgsit1-2)
        if (snd == sfx(.posit1) or snd == sfx(.posit2) or snd == sfx(.posit3)) {
            snd = sfx(.posit1) + @as(i32, random.pRandom() % 3);
        } else if (snd == sfx(.bgsit1) or snd == sfx(.bgsit2)) {
            snd = sfx(.bgsit1) + @as(i32, random.pRandom() % 2);
        }
        world.playSound(@ptrCast(actor), snd);
    }

    if (mobj_info.see_state != .S_NULL) {
        _ = actor.setState(mobj_info.see_state);
    }
}

/// A_Chase — Monster chase state: move toward target, attempt attacks.
/// This is the core AI loop for active monsters. (Faithful port.)
pub fn A_Chase(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    const mobj_info = actor.getInfo();

    // Decrement reaction time
    if (actor.reaction_time > 0) {
        actor.reaction_time -= 1;
    }

    // Decrease threshold (infighting target lock)
    if (actor.threshold > 0) {
        if (actor.target == null or actor.target.?.health <= 0) {
            actor.threshold = 0;
        } else {
            actor.threshold -= 1;
        }
    }

    // Turn towards movement direction (45° steps)
    if (actor.movedir < 8) {
        actor.angle &= @as(u32, 7) << 29;
        const delta: i32 = @bitCast(actor.angle -% (@as(u32, @intCast(actor.movedir)) << 29));
        if (delta > 0) {
            actor.angle -%= fixed.ANG90 / 2;
        } else if (delta < 0) {
            actor.angle +%= fixed.ANG90 / 2;
        }
    }

    // No live target? Look for one, else return to idle
    const target_ok = if (actor.target) |t|
        t.flags & info.MF_SHOOTABLE != 0 and t.health > 0
    else
        false;
    if (!target_ok) {
        if (lookForPlayers(actor, true)) return; // Got a new target
        _ = actor.setState(mobj_info.spawn_state);
        return;
    }

    // Don't attack twice in a row
    if (actor.flags & info.MF_JUSTATTACKED != 0) {
        actor.flags &= ~info.MF_JUSTATTACKED;
        newChaseDir(actor);
        return;
    }

    // Melee attack
    if (mobj_info.melee_state != .S_NULL and checkMeleeRange(actor)) {
        if (mobj_info.attack_sound != 0) {
            world.playSound(@ptrCast(actor), mobj_info.attack_sound);
        }
        _ = actor.setState(mobj_info.melee_state);
        return;
    }

    // Missile attack
    if (mobj_info.missile_state != .S_NULL) {
        if (actor.movecount == 0 and checkMissileRange(actor)) {
            _ = actor.setState(mobj_info.missile_state);
            actor.flags |= info.MF_JUSTATTACKED;
            return;
        }
    }

    // Chase toward player
    actor.movecount -= 1;
    if (actor.movecount < 0 or !doMove(actor)) {
        newChaseDir(actor);
    }

    // Occasionally grunt
    if (random.pRandom() < 3 and mobj_info.active_sound != 0) {
        world.playSound(@ptrCast(actor), mobj_info.active_sound);
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

    var angle = actor.angle;
    const slope = map_mod.aimLineAttack(actor, angle, level_mod.MISSILERANGE);

    world.playSound(@ptrCast(actor), sfx(.pistol));

    // Angle spread
    const spread: i32 = random.pSubRandom();
    angle +%= @as(u32, @bitCast(spread << 20));

    // Damage: 1d5 * 3 (3-15)
    const damage: i32 = (@as(i32, random.pRandom() % 5) + 1) * 3;

    map_mod.lineAttack(actor, angle, level_mod.MISSILERANGE, slope, damage);
}

/// A_SPosAttack — Shotgun Guy attack: 3 bullets
pub fn A_SPosAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;

    world.playSound(@ptrCast(actor), sfx(.shotgn));
    faceTarget(actor);

    const bangle = actor.angle;
    const slope = map_mod.aimLineAttack(actor, bangle, level_mod.MISSILERANGE);

    // Fire 3 bullets
    for (0..3) |_| {
        var angle = bangle;
        const spread: i32 = random.pSubRandom();
        angle +%= @as(u32, @bitCast(spread << 20));

        const damage: i32 = (@as(i32, random.pRandom() % 5) + 1) * 3;
        map_mod.lineAttack(actor, angle, level_mod.MISSILERANGE, slope, damage);
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
        world.playSound(@ptrCast(actor), sfx(.claw));
        const damage: i32 = (@as(i32, random.pRandom() % 8) + 1) * 3;
        inter.damageMobj(target, actor, actor, damage);
        return;
    }

    // Fire imp fireball
    const alloc = world.allocator orelse return;
    _ = mobj_mod.spawnMissile(actor, target, .MT_TROOPSHOT, alloc) catch return;
}

/// A_SargAttack — Demon bite attack (melee only)
pub fn A_SargAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    faceTarget(actor);

    if (checkMeleeRange(actor)) {
        const damage: i32 = (@as(i32, random.pRandom() % 10) + 1) * 4;
        inter.damageMobj(target, actor, actor, damage);
    }
}

/// A_HeadAttack — Cacodemon: melee bite or fireball
pub fn A_HeadAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    faceTarget(actor);

    if (checkMeleeRange(actor)) {
        const damage: i32 = (@as(i32, random.pRandom() % 6) + 1) * 10;
        inter.damageMobj(target, actor, actor, damage);
        return;
    }

    const alloc = world.allocator orelse return;
    _ = mobj_mod.spawnMissile(actor, target, .MT_HEADSHOT, alloc) catch return;
}

/// A_BruisAttack — Baron of Hell: melee claw or green fireball
pub fn A_BruisAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    if (checkMeleeRange(actor)) {
        world.playSound(@ptrCast(actor), sfx(.claw));
        const damage: i32 = (@as(i32, random.pRandom() % 8) + 1) * 10;
        inter.damageMobj(target, actor, actor, damage);
        return;
    }

    const alloc = world.allocator orelse return;
    _ = mobj_mod.spawnMissile(actor, target, .MT_BRUISERSHOT, alloc) catch return;
}

/// A_PlayerScream — player death sound
pub fn A_PlayerScream(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    world.playSound(@ptrCast(actor), sfx(.pldeth));
}

/// A_BossDeath — E1M8 special: when the last Baron dies, lower the
/// tag-666 floor to open the way out.
pub fn A_BossDeath(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (world.episode != 1 or world.map != 8) return;
    if (actor.mobj_type != .MT_BRUISER) return;

    // Any other Baron still alive?
    const cap = tick.getThinkerCap();
    var current = cap.next;
    while (current != null and current != cap) {
        const thinker = current.?;
        current = thinker.next;
        if (thinker.function) |func| {
            if (func == @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) {
                const mo: *MapObject = @fieldParentPtr("thinker", thinker);
                if (mo != actor and mo.mobj_type == actor.mobj_type and mo.health > 0) {
                    return; // Not the last one
                }
            }
        }
    }

    // Lower all tag-666 floors (the dummy line carries the tag)
    const lvl = world.level orelse return;
    const alloc = world.allocator orelse return;
    var junk = std.mem.zeroes(setup.Line);
    junk.tag = 666;
    _ = floor_mod.EV_DoFloor(&junk, .lower_floor_to_lowest, lvl, alloc);
}

/// A_SkullAttack — Lost Soul charge attack
pub fn A_SkullAttack(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));

    if (actor.target == null) return;
    const target = actor.target.?;

    // Set skull fly mode
    actor.flags |= info.MF_SKULLFLY;
    world.playSound(@ptrCast(actor), actor.getInfo().attack_sound);
    faceTarget(actor);

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

/// A_Scream — Death scream
pub fn A_Scream(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    var snd = actor.getInfo().death_sound;
    if (snd == 0) return;

    // Randomized variants (vanilla: podth1-3, bgdth1-2)
    if (snd == sfx(.podth1) or snd == sfx(.podth2) or snd == sfx(.podth3)) {
        snd = sfx(.podth1) + @as(i32, random.pRandom() % 3);
    } else if (snd == sfx(.bgdth1) or snd == sfx(.bgdth2)) {
        snd = sfx(.bgdth1) + @as(i32, random.pRandom() % 2);
    }
    world.playSound(@ptrCast(actor), snd);
}

/// A_XScream — Gib death scream
pub fn A_XScream(actor_ptr: *anyopaque) void {
    world.playSound(actor_ptr, sfx(.slop));
}

/// A_Pain — Pain sound
pub fn A_Pain(actor_ptr: *anyopaque) void {
    const actor: *MapObject = @ptrCast(@alignCast(actor_ptr));
    const snd = actor.getInfo().pain_sound;
    if (snd != 0) world.playSound(@ptrCast(actor), snd);
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
    actor.flags &= ~info.MF_AMBUSH;
    if (actor.target) |target| {
        actor.angle = maputl.pointToAngle2(actor.x, actor.y, target.x, target.y);

        // If target has MF_SHADOW (spectre), add randomized spread
        if (target.flags & info.MF_SHADOW != 0) {
            const spread: i32 = random.pSubRandom();
            actor.angle +%= @as(u32, @bitCast(spread << 21));
        }
    }
}

/// Check if actor is within melee range of target (and can see it)
fn checkMeleeRange(actor: *MapObject) bool {
    const target = actor.target orelse return false;

    const dist = maputl.aproxDistance(
        Fixed.sub(target.x, actor.x),
        Fixed.sub(target.y, actor.y),
    );

    // Vanilla: MELEERANGE - 20 + target radius
    if (dist.raw() >= level_mod.MELEERANGE.raw() - 20 * 0x10000 + target.getInfo().radius.raw()) return false;

    if (world.level) |lvl| {
        if (!sight.checkSight(actor, target, lvl)) return false;
    }
    return true;
}

/// Check if actor should fire a missile
fn checkMissileRange(actor: *MapObject) bool {
    const target = actor.target orelse return false;

    // Can't see the target? Don't fire.
    if (world.level) |lvl| {
        if (!sight.checkSight(actor, target, lvl)) return false;
    }

    if (actor.flags & info.MF_JUSTHIT != 0) {
        // Just been hit — retaliate
        actor.flags &= ~info.MF_JUSTHIT;
        return true;
    }

    if (actor.reaction_time > 0) return false;

    var dist = Fixed.sub(maputl.aproxDistance(
        Fixed.sub(target.x, actor.x),
        Fixed.sub(target.y, actor.y),
    ), Fixed.fromRaw(64 * 0x10000));

    // No melee attack? Fire from farther away
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

/// Choose a new chase direction toward target (P_NewChaseDir, faithful).
fn newChaseDir(actor: *MapObject) void {
    const target = actor.target orelse return;

    const olddir: u8 = @intCast(@min(actor.movedir, 8));
    const turnaround: u8 = level_mod.opposite[olddir];

    const deltax = Fixed.sub(target.x, actor.x);
    const deltay = Fixed.sub(target.y, actor.y);

    var d1: u8 = if (deltax.raw() > 10 * 0x10000)
        level_mod.DI_EAST
    else if (deltax.raw() < -10 * 0x10000)
        level_mod.DI_WEST
    else
        level_mod.DI_NODIR;

    var d2: u8 = if (deltay.raw() < -10 * 0x10000)
        level_mod.DI_SOUTH
    else if (deltay.raw() > 10 * 0x10000)
        level_mod.DI_NORTH
    else
        level_mod.DI_NODIR;

    // Try direct (diagonal) route
    if (d1 != level_mod.DI_NODIR and d2 != level_mod.DI_NODIR) {
        const diag_idx: usize = (@as(usize, if (deltay.raw() < 0) 1 else 0) << 1) +
            @as(usize, if (deltax.raw() > 0) 1 else 0);
        actor.movedir = level_mod.diags[diag_idx];
        if (actor.movedir != turnaround and tryDir(actor)) return;
    }

    // Try other directions
    if (random.pRandom() > 200 or deltay.abs().raw() > deltax.abs().raw()) {
        const tmp = d1;
        d1 = d2;
        d2 = tmp;
    }
    if (d1 == turnaround) d1 = level_mod.DI_NODIR;
    if (d2 == turnaround) d2 = level_mod.DI_NODIR;

    if (d1 != level_mod.DI_NODIR) {
        actor.movedir = d1;
        if (tryDir(actor)) return; // Either moved forward or attacked
    }
    if (d2 != level_mod.DI_NODIR) {
        actor.movedir = d2;
        if (tryDir(actor)) return;
    }

    // There is no direct path to the player: try the old direction
    if (olddir != level_mod.DI_NODIR) {
        actor.movedir = olddir;
        if (tryDir(actor)) return;
    }

    // Pick another direction to try, sweep order randomized
    if (random.pRandom() & 1 != 0) {
        var tdir: u8 = level_mod.DI_EAST;
        while (tdir <= level_mod.DI_SOUTHEAST) : (tdir += 1) {
            if (tdir != turnaround) {
                actor.movedir = tdir;
                if (tryDir(actor)) return;
            }
        }
    } else {
        var tdir: i32 = level_mod.DI_SOUTHEAST;
        while (tdir >= level_mod.DI_EAST) : (tdir -= 1) {
            if (tdir != turnaround) {
                actor.movedir = @intCast(tdir);
                if (tryDir(actor)) return;
            }
        }
    }

    // Last resort: turn around
    if (turnaround != level_mod.DI_NODIR) {
        actor.movedir = turnaround;
        if (tryDir(actor)) return;
    }

    actor.movedir = level_mod.DI_NODIR; // Cannot move
}

/// Try to move in the current direction. Returns true if successful.
fn tryDir(actor: *MapObject) bool {
    if (doMove(actor)) {
        actor.movecount = @as(i32, @intCast(random.pRandom() & 15));
        return true;
    }
    return false;
}

/// Attempt one step in the actor's current movedir (P_Move). Floating
/// monsters drift vertically through blocked-but-fitting gaps; walkers
/// try to open any door they bumped into.
fn doMove(actor: *MapObject) bool {
    if (actor.movedir == level_mod.DI_NODIR) return false;
    const dir: usize = @intCast(actor.movedir);
    if (dir >= 8) return false;

    const speed = Fixed.fromRaw(actor.getInfo().speed * 0x10000);
    const tryx = Fixed.add(actor.x, Fixed.mul(speed, level_mod.xspeed[dir]));
    const tryy = Fixed.add(actor.y, Fixed.mul(speed, level_mod.yspeed[dir]));

    if (!map_mod.tryMove(actor, tryx, tryy)) {
        // Floating monsters can go up/down to clear the blocker
        if (actor.flags & info.MF_FLOAT != 0 and map_mod.floatok) {
            if (actor.z.raw() < actor.floorz.raw()) {
                actor.z = Fixed.add(actor.z, level_mod.FLOATSPEED);
            } else {
                actor.z = Fixed.sub(actor.z, level_mod.FLOATSPEED);
            }
            actor.flags |= info.MF_INFLOAT;
            return true;
        }

        // Try to open a door we walked into
        if (map_mod.numspechit == 0) return false;
        actor.movedir = level_mod.DI_NODIR;
        var good = false;
        const lvl = world.level orelse return false;
        const alloc = world.allocator orelse return false;
        while (map_mod.numspechit > 0) {
            map_mod.numspechit -= 1;
            const li = map_mod.spechit[map_mod.numspechit];
            if (spec.useSpecialLine(actor, li, 0, lvl, alloc)) good = true;
        }
        return good;
    }

    actor.flags &= ~info.MF_INFLOAT;
    if (actor.flags & info.MF_FLOAT == 0) {
        actor.z = actor.floorz;
    }
    return true;
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
