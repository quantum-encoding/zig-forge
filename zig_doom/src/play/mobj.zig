//! zig_doom/src/play/mobj.zig
//!
//! Map object (mobj) management — spawn, remove, think.
//! Translated from: linuxdoom-1.10/p_mobj.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! MapObject is DOOM's central game entity: players, monsters, projectiles,
//! items, and decorations. Each has an embedded Thinker for the game loop.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const info = @import("../info.zig");
const SpriteNum = info.SpriteNum;
const StateNum = info.StateNum;
const MobjType = info.MobjType;
const MobjInfo = info.MobjInfo;
const State = info.State;
const defs = @import("../defs.zig");
const MapThing = defs.MapThing;
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const level_mod = @import("level.zig");
const random = @import("../random.zig");

// ============================================================================
// MapObject — DOOM's central game entity
// ============================================================================

pub const MapObject = struct {
    // Thinker MUST be first field for @fieldParentPtr
    thinker: Thinker = .{},

    // Position
    x: Fixed = Fixed.ZERO,
    y: Fixed = Fixed.ZERO,
    z: Fixed = Fixed.ZERO,

    // Sector thing list links
    snext: ?*MapObject = null,
    sprev: ?*MapObject = null,

    // Angle and visual
    angle: Angle = 0,
    sprite: SpriteNum = .SPR_TROO,
    frame: i32 = 0,

    // Blockmap links
    bnext: ?*MapObject = null,
    bprev: ?*MapObject = null,

    // Subsector index (null until placed in level)
    subsector_id: ?u16 = null,

    // Geometry
    floorz: Fixed = Fixed.ZERO,
    ceilingz: Fixed = Fixed.ZERO,
    radius: Fixed = Fixed.ZERO,
    height: Fixed = Fixed.ZERO,

    // Movement
    momx: Fixed = Fixed.ZERO,
    momy: Fixed = Fixed.ZERO,
    momz: Fixed = Fixed.ZERO,

    // State machine
    valid_count: i32 = 0,
    mobj_type: MobjType = .MT_PLAYER,
    tics: i32 = 0,
    state_num: StateNum = .S_NULL,
    flags: u32 = 0,
    health: i32 = 0,

    // Movement direction (monsters)
    movedir: i32 = 0,
    movecount: i32 = 0,

    // Monster target/tracer
    target: ?*MapObject = null,
    tracer: ?*MapObject = null,

    // Reaction
    reaction_time: i32 = 0,
    threshold: i32 = 0,

    // Player reference (null for non-player mobjs)
    player: ?*anyopaque = null,

    // Player search
    last_look: i32 = 0,

    // Spawn point (for respawning)
    spawn_point: MapThing = std.mem.zeroes(MapThing),

    // Allocator used to create this mobj (for deallocation)
    allocator: ?std.mem.Allocator = null,

    /// Get the mobjinfo for this mobj's type
    pub fn getInfo(self: *const MapObject) *const MobjInfo {
        return &info.mobjinfo[@intFromEnum(self.mobj_type)];
    }

    /// Get the current state
    pub fn getState(self: *const MapObject) *const State {
        return &info.states[@intFromEnum(self.state_num)];
    }

    /// Set state, returning false if the object was removed (S_NULL)
    pub fn setState(self: *MapObject, st: StateNum) bool {
        var state_num = st;

        // Process state chain (handle 0-tic states)
        while (true) {
            if (state_num == .S_NULL) {
                self.state_num = .S_NULL;
                removeMobj(self);
                return false;
            }

            const state = &info.states[@intFromEnum(state_num)];
            self.state_num = state_num;
            self.tics = state.tics;
            self.sprite = state.sprite;
            self.frame = state.frame;

            // Call action function if present
            if (state.action) |action_fn| {
                action_fn(@ptrCast(self));
            }

            // If tics is 0, immediately transition to next state
            if (self.tics != 0) break;
            state_num = state.next_state;
        }

        return true;
    }
};

// ============================================================================
// Spawn and Remove
// ============================================================================

/// Spawn a new map object at the given position
pub fn spawnMobj(x: Fixed, y: Fixed, z: Fixed, mobj_type: MobjType, allocator: std.mem.Allocator) !*MapObject {
    const mobj = try allocator.create(MapObject);
    mobj.* = MapObject{};

    const mobj_info = &info.mobjinfo[@intFromEnum(mobj_type)];

    mobj.mobj_type = mobj_type;
    mobj.x = x;
    mobj.y = y;
    mobj.radius = mobj_info.radius;
    mobj.height = mobj_info.height;
    mobj.flags = mobj_info.flags;
    mobj.health = mobj_info.spawn_health;
    mobj.reaction_time = mobj_info.reaction_time;
    mobj.allocator = allocator;

    // Set initial state
    _ = mobj.setState(mobj_info.spawn_state);

    // Set z position
    // ONFLOORZ = minInt, ONCEILINGZ = maxInt, otherwise use provided z
    if (z.raw() == std.math.minInt(i32)) {
        mobj.z = mobj.floorz;
    } else if (z.raw() == std.math.maxInt(i32)) {
        mobj.z = Fixed.sub(mobj.ceilingz, mobj.height);
    } else {
        mobj.z = z;
    }

    // Add to thinker list
    mobj.thinker.function = mobjThinker;
    tick.addThinker(&mobj.thinker);

    return mobj;
}

/// Special z values for spawnMobj
pub const ONFLOORZ = Fixed.MIN;
pub const ONCEILINGZ = Fixed.MAX;

/// Remove a map object from the game
pub fn removeMobj(mobj: *MapObject) void {
    // Clear sector/blockmap links would go here in full implementation
    // For now, just remove from thinker list

    // Mark for deferred removal from thinker list
    tick.removeThinker(&mobj.thinker);

    // Note: In DOOM, the zone allocator handles deallocation via tags.
    // Here we rely on the caller or a garbage collection pass.
    // In a full implementation, we'd free via mobj.allocator.
}

/// Deallocate a mobj's memory (call after it's been unlinked from thinker list)
pub fn freeMobj(mobj: *MapObject) void {
    if (mobj.allocator) |alloc| {
        alloc.destroy(mobj);
    }
}

// ============================================================================
// Mobj Thinker — main per-tic update
// ============================================================================

/// Main thinker function for map objects. Called once per tic.
pub fn mobjThinker(thinker: *Thinker) void {
    const mobj: *MapObject = @fieldParentPtr("thinker", thinker);

    // Apply momentum (movement)
    if (mobj.momx.raw() != 0 or mobj.momy.raw() != 0 or
        (mobj.flags & info.MF_SKULLFLY != 0))
    {
        xyMovement(mobj);

        // Check if mobj was removed during movement
        if (mobj.thinker.function == null) return;
    }

    // Apply vertical momentum / gravity
    if (mobj.z.raw() != mobj.floorz.raw() or mobj.momz.raw() != 0) {
        zMovement(mobj);

        if (mobj.thinker.function == null) return;
    }

    // Cycle through states, calling action functions
    if (mobj.tics != -1) {
        mobj.tics -= 1;
        if (mobj.tics <= 0) {
            if (!mobj.setState(mobj.getState().next_state)) {
                return; // mobj was removed
            }
        }
    } else {
        // Check for nightmare respawn (not implemented in Phase 3)
    }
}

/// Horizontal movement and collision
fn xyMovement(mobj: *MapObject) void {
    if (mobj.momx.raw() == 0 and mobj.momy.raw() == 0) {
        // No movement, but check skull fly
        if (mobj.flags & info.MF_SKULLFLY != 0) {
            // Skull flew into something — stop
            mobj.flags &= ~info.MF_SKULLFLY;
            mobj.momx = Fixed.ZERO;
            mobj.momy = Fixed.ZERO;
            mobj.momz = Fixed.ZERO;

            // Return to spawn state
            const mobj_info = mobj.getInfo();
            _ = mobj.setState(mobj_info.see_state);
        }
        return;
    }

    // Clamp momentum to max
    if (mobj.momx.raw() > level_mod.MAXMOVE.raw()) {
        mobj.momx = level_mod.MAXMOVE;
    } else if (mobj.momx.raw() < -level_mod.MAXMOVE.raw()) {
        mobj.momx = level_mod.MAXMOVE.negate();
    }

    if (mobj.momy.raw() > level_mod.MAXMOVE.raw()) {
        mobj.momy = level_mod.MAXMOVE;
    } else if (mobj.momy.raw() < -level_mod.MAXMOVE.raw()) {
        mobj.momy = level_mod.MAXMOVE.negate();
    }

    // Try to move (simplified without full collision detection for Phase 3)
    // In full DOOM, this calls P_TryMove which does blockmap collision
    var xmove = mobj.momx;
    var ymove = mobj.momy;

    // Move in steps for large moves (DOOM splits into 32-unit steps)
    while (xmove.raw() > Fixed.fromRaw(30 * 0x10000).raw() or
        ymove.raw() > Fixed.fromRaw(30 * 0x10000).raw() or
        xmove.raw() < -Fixed.fromRaw(30 * 0x10000).raw() or
        ymove.raw() < -Fixed.fromRaw(30 * 0x10000).raw())
    {
        // Half the movement
        const ptrx_raw = @divTrunc(xmove.raw(), 2);
        const ptry_raw = @divTrunc(ymove.raw(), 2);
        xmove = Fixed.fromRaw(ptrx_raw);
        ymove = Fixed.fromRaw(ptry_raw);

        // Simple move (no collision in Phase 3 stub)
        mobj.x = Fixed.add(mobj.x, xmove);
        mobj.y = Fixed.add(mobj.y, ymove);
    }

    // Apply remaining movement
    mobj.x = Fixed.add(mobj.x, xmove);
    mobj.y = Fixed.add(mobj.y, ymove);

    // Apply friction (only for non-flying, non-missile objects on the floor)
    if (mobj.flags & (info.MF_MISSILE | info.MF_SKULLFLY) == 0) {
        if (mobj.z.raw() <= mobj.floorz.raw()) {
            // Apply DOOM's friction (0xE800/0x10000 = ~0.90625)
            mobj.momx = Fixed.mul(mobj.momx, level_mod.FRICTION);
            mobj.momy = Fixed.mul(mobj.momy, level_mod.FRICTION);

            // Stop tiny movements
            if (mobj.momx.raw() > -0x800 and mobj.momx.raw() < 0x800) {
                mobj.momx = Fixed.ZERO;
            }
            if (mobj.momy.raw() > -0x800 and mobj.momy.raw() < 0x800) {
                mobj.momy = Fixed.ZERO;
            }
        }
    }
}

/// Vertical movement and gravity
fn zMovement(mobj: *MapObject) void {
    // Apply gravity
    if (mobj.flags & info.MF_NOGRAVITY == 0) {
        if (mobj.z.raw() > mobj.floorz.raw()) {
            // Falling — apply gravity
            mobj.momz = Fixed.sub(mobj.momz, level_mod.GRAVITY);
        }
    }

    // Apply vertical momentum
    mobj.z = Fixed.add(mobj.z, mobj.momz);

    // Hit the floor
    if (mobj.z.raw() <= mobj.floorz.raw()) {
        // Missile hit floor — explode
        if (mobj.flags & info.MF_MISSILE != 0) {
            mobj.z = mobj.floorz;
            // Explode
            explodeMissile(mobj);
            return;
        }

        mobj.z = mobj.floorz;

        if (mobj.momz.raw() < 0) {
            // Landing impact
            mobj.momz = Fixed.ZERO;
        }

        // Skull fly stops on landing
        if (mobj.flags & info.MF_SKULLFLY != 0) {
            mobj.momz = Fixed.ZERO;
        }
    } else if (mobj.flags & info.MF_NOGRAVITY == 0) {
        // Still in the air — gravity already applied above
    }

    // Hit the ceiling
    if (mobj.z.raw() +% mobj.height.raw() > mobj.ceilingz.raw()) {
        // Missile hit ceiling — explode
        if (mobj.flags & info.MF_MISSILE != 0) {
            explodeMissile(mobj);
            return;
        }

        mobj.z = Fixed.sub(mobj.ceilingz, mobj.height);

        if (mobj.momz.raw() > 0) {
            mobj.momz = Fixed.ZERO;
        }
    }
}

/// Missile explosion — transition to death state
fn explodeMissile(mobj: *MapObject) void {
    mobj.momx = Fixed.ZERO;
    mobj.momy = Fixed.ZERO;
    mobj.momz = Fixed.ZERO;

    const mobj_info = mobj.getInfo();
    _ = mobj.setState(mobj_info.death_state);

    mobj.tics -%= @as(i32, @intCast(random.pRandom() & 3));
    if (mobj.tics < 1) mobj.tics = 1;

    mobj.flags &= ~info.MF_MISSILE;
}

/// Spawn a map thing (from WAD data) as a map object
pub fn spawnMapThing(mthing: *const MapThing, allocator: std.mem.Allocator) !?*MapObject {
    // Look up the mobj type from the editor number
    const mobj_type = info.findMobjType(mthing.thing_type) orelse {
        return null; // Unknown thing type
    };

    // Spawn it
    const x = Fixed.fromInt(@as(i32, mthing.x));
    const y = Fixed.fromInt(@as(i32, mthing.y));

    const mobj_info = &info.mobjinfo[@intFromEnum(mobj_type)];

    // Determine z
    const z = if (mobj_info.flags & info.MF_SPAWNCEILING != 0)
        ONCEILINGZ
    else
        ONFLOORZ;

    const mobj = try spawnMobj(x, y, z, mobj_type, allocator);

    // Set angle from thing data
    mobj.angle = @as(Angle, @intCast(mthing.angle)) *% (0x100000000 / 360);

    // Set ambush flag
    if (mthing.options & defs.MTF_AMBUSH != 0) {
        mobj.flags |= info.MF_AMBUSH;
    }

    // Store spawn point for respawning
    mobj.spawn_point = mthing.*;

    return mobj;
}

/// Spawn a missile aimed at a target
pub fn spawnMissile(source: *MapObject, dest: *MapObject, missile_type: MobjType, allocator: std.mem.Allocator) !*MapObject {
    const mobj = try spawnMobj(source.x, source.y, Fixed.add(source.z, Fixed.fromRaw(32 * 0x10000)), missile_type, allocator);

    // Set target to source (for kill credit)
    mobj.target = source;

    // Calculate angle to target
    const an = pointToAngle(source.x, source.y, dest.x, dest.y);
    mobj.angle = an;

    // Calculate speed components
    const mobj_info = &info.mobjinfo[@intFromEnum(missile_type)];
    const speed = Fixed.fromRaw(mobj_info.speed);

    mobj.momx = Fixed.mul(speed, cosAngle(an));
    mobj.momy = Fixed.mul(speed, sinAngle(an));

    // Calculate vertical aim
    const dist = pointToDist(source.x, source.y, dest.x, dest.y);
    const dz = Fixed.sub(dest.z, source.z);
    if (dist.raw() != 0) {
        mobj.momz = Fixed.div(dz, Fixed.div(dist, speed));
    }

    return mobj;
}

// ============================================================================
// Geometry helpers (simplified versions — full versions in maputl.zig)
// ============================================================================

fn pointToAngle(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Angle {
    const dx = Fixed.sub(x2, x1);
    const dy = Fixed.sub(y2, y1);

    if (dx.raw() == 0 and dy.raw() == 0) return 0;

    // Use atan2 approximation via DOOM's tantoangle table
    const tables = @import("../tables.zig");

    const adx = dx.abs();
    const ady = dy.abs();

    // Calculate slope as ady/adx or adx/ady
    var angle: Angle = 0;

    if (adx.raw() != 0) {
        if (ady.raw() <= adx.raw()) {
            // slope <= 1, use ady/adx
            const slope_idx: usize = @intCast(@min(2048, @as(u32, @intCast(Fixed.div(ady, adx).raw() >> 5))));
            angle = tables.tantoangle[@min(slope_idx, 2048)];
        } else {
            // slope > 1, use pi/2 - atan(adx/ady)
            const slope_idx: usize = @intCast(@min(2048, @as(u32, @intCast(Fixed.div(adx, ady).raw() >> 5))));
            angle = fixed.ANG90 -% tables.tantoangle[@min(slope_idx, 2048)];
        }
    } else {
        angle = fixed.ANG90;
    }

    // Adjust for quadrant
    if (dx.raw() >= 0) {
        if (dy.raw() >= 0) {
            return angle; // Q1
        } else {
            return 0 -% angle; // Q4
        }
    } else {
        if (dy.raw() >= 0) {
            return fixed.ANG180 -% angle; // Q2
        } else {
            return fixed.ANG180 +% angle; // Q3
        }
    }
}

fn pointToDist(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Fixed {
    var dx = Fixed.sub(x2, x1).abs();
    var dy = Fixed.sub(y2, y1).abs();

    if (dy.raw() > dx.raw()) {
        const temp = dx;
        dx = dy;
        dy = temp;
    }

    if (dx.raw() == 0) return Fixed.ZERO;

    // Approximate distance: dx + dy * 0.414 ≈ sqrt(dx^2 + dy^2)
    // DOOM uses: angle = tantoangle[dy/dx * 2048], dist = dx / cos(angle)
    // Simplified: just use dx + dy/2 as rough approximation for now
    return Fixed.add(dx, Fixed.fromRaw(@divTrunc(dy.raw(), 2)));
}

fn cosAngle(an: Angle) Fixed {
    const tables = @import("../tables.zig");
    return tables.finecosine[an >> tables.ANGLETOFINESHIFT & tables.FINEMASK];
}

fn sinAngle(an: Angle) Fixed {
    const tables = @import("../tables.zig");
    return tables.finesine[an >> tables.ANGLETOFINESHIFT & tables.FINEMASK];
}

// ============================================================================
// Tests
// ============================================================================

test "spawn mobj" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try spawnMobj(
        Fixed.fromInt(100),
        Fixed.fromInt(200),
        Fixed.ZERO,
        .MT_POSSESSED,
        alloc,
    );
    defer alloc.destroy(mobj);

    try std.testing.expectEqual(Fixed.fromInt(100), mobj.x);
    try std.testing.expectEqual(Fixed.fromInt(200), mobj.y);
    try std.testing.expectEqual(MobjType.MT_POSSESSED, mobj.mobj_type);
    try std.testing.expectEqual(@as(i32, 20), mobj.health);
    try std.testing.expect(mobj.flags & info.MF_SOLID != 0);
    try std.testing.expect(mobj.flags & info.MF_SHOOTABLE != 0);
    try std.testing.expectEqual(StateNum.S_POSS_STND, mobj.state_num);

    // Verify it was added to thinker list
    try std.testing.expectEqual(@as(usize, 1), tick.countThinkers());

    // Clean up
    tick.initThinkers();
}

test "mobj state transition" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    // Zombieman starts in S_POSS_STND
    try std.testing.expectEqual(StateNum.S_POSS_STND, mobj.state_num);
    try std.testing.expectEqual(@as(i32, 10), mobj.tics);

    // Advance to next state
    _ = mobj.setState(.S_POSS_STND2);
    try std.testing.expectEqual(StateNum.S_POSS_STND2, mobj.state_num);
    try std.testing.expectEqual(@as(i32, 10), mobj.tics);

    tick.initThinkers();
}

test "mobj thinker tic countdown" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    // Initial state: S_POSS_STND, tics=10
    const initial_tics = mobj.tics;
    try std.testing.expectEqual(@as(i32, 10), initial_tics);

    // Simulate one tic (call the thinker)
    mobjThinker(&mobj.thinker);
    try std.testing.expectEqual(@as(i32, 9), mobj.tics);

    // Run 9 more tics — should transition to S_POSS_STND2
    for (0..9) |_| {
        mobjThinker(&mobj.thinker);
    }
    try std.testing.expectEqual(StateNum.S_POSS_STND2, mobj.state_num);

    tick.initThinkers();
}

test "mobj gravity" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    // Spawn above floor
    const mobj = try spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(100), .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.z = Fixed.fromInt(100);
    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(256);

    // Apply gravity by calling zMovement
    zMovement(mobj);

    // Should have gained downward momentum and moved down
    try std.testing.expect(mobj.momz.raw() < 0);
    try std.testing.expect(mobj.z.raw() < Fixed.fromInt(100).raw());

    tick.initThinkers();
}

test "mobj friction" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.floorz = Fixed.ZERO;
    mobj.z = Fixed.ZERO;
    mobj.momx = Fixed.fromInt(10);
    mobj.momy = Fixed.ZERO;

    xyMovement(mobj);

    // After friction, momentum should be reduced
    try std.testing.expect(mobj.momx.raw() < Fixed.fromInt(10).raw());
    try std.testing.expect(mobj.momx.raw() > 0);

    tick.initThinkers();
}

test "missile explosion on floor" {
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.fromInt(2), .MT_TROOPSHOT, alloc);
    defer alloc.destroy(mobj);

    mobj.z = Fixed.fromInt(2);
    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(256);
    mobj.momz = Fixed.fromInt(-10); // Moving down fast enough to hit floor

    // Apply z movement — should hit floor and explode
    zMovement(mobj);

    // Should now be in death state (explosion)
    try std.testing.expectEqual(StateNum.S_TBALLX1, mobj.state_num);
    try std.testing.expect(mobj.flags & info.MF_MISSILE == 0);

    tick.initThinkers();
}

test "fieldParentPtr recovery" {
    var mobj = MapObject{};
    const thinker_ptr = &mobj.thinker;

    // Recover mobj from thinker pointer
    const recovered: *MapObject = @fieldParentPtr("thinker", thinker_ptr);
    try std.testing.expectEqual(&mobj, recovered);
}
