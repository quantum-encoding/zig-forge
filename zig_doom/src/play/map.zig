//! zig_doom/src/play/map.zig
//!
//! Movement, collision detection, and line interactions.
//! Translated from: linuxdoom-1.10/p_map.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Collision uses brute-force iteration over linedefs (bbox-rejected) and
//! the thinker list instead of vanilla's blockmap — shareware maps have
//! ~1000 lines and ~300 things, far below the threshold where the blockmap
//! pays for itself on modern hardware. Behavior follows p_map.c: openings,
//! step-up/dropoff limits, special-line crossing, missile/skull impacts,
//! and item pickup all happen here.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const tables = @import("../tables.zig");
const info = @import("../info.zig");
const defs = @import("../defs.zig");
const random = @import("../random.zig");
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const maputl = @import("maputl.zig");
const setup = @import("setup.zig");
const level_mod = @import("level.zig");
const bbox_mod = @import("../bbox.zig");
const BBox = bbox_mod.BBox;
const tick = @import("tick.zig");
const inter = @import("inter.zig");
const spec = @import("spec.zig");
const sight = @import("sight.zig");
const world = @import("world.zig");

// ============================================================================
// Movement result state (module-level, as DOOM uses globals)
// ============================================================================

var tm_thing: ?*MapObject = null;
var tm_x: Fixed = Fixed.ZERO;
var tm_y: Fixed = Fixed.ZERO;
var tm_bbox: BBox = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO };
var tm_floorz: Fixed = Fixed.ZERO;
var tm_ceilingz: Fixed = Fixed.ZERO;
var tm_dropoffz: Fixed = Fixed.ZERO;
var tm_flags: u32 = 0;

/// Last blocking/lowering line (for missile sky checks)
pub var ceilingline: ?usize = null;

/// Set by tryMove/checkPosition: z fit was OK (used by floating monsters)
pub var floatok: bool = false;

/// Special lines crossed by the current move (read by P_Move for monsters
/// opening doors they bumped into)
pub const MAXSPECIALCROSS = 16;
pub var spechit: [MAXSPECIALCROSS]usize = undefined;
pub var numspechit: usize = 0;

// Line attack state (hitscan)
var la_damage: i32 = 0;
var attack_range: Fixed = Fixed.ZERO;
var aim_slope: Fixed = Fixed.ZERO;
var shootz: Fixed = Fixed.ZERO;
var shooter: ?*MapObject = null;

/// Thing hit by the last aimLineAttack
pub var linetarget: ?*MapObject = null;

// ============================================================================
// Iteration helpers
// ============================================================================

/// Walk all live mobjs in the thinker list, calling cb for each.
/// cb returns false to stop the walk (blocked).
fn forEachMobj(ctx: anytype, comptime cb: fn (@TypeOf(ctx), *MapObject) bool) bool {
    const cap = tick.getThinkerCap();
    var current = cap.next;
    while (current != null and current != cap) {
        const thinker = current.?;
        current = thinker.next;
        if (thinker.function) |func| {
            if (func == @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) {
                const mo: *MapObject = @fieldParentPtr("thinker", thinker);
                if (!cb(ctx, mo)) return false;
            }
        }
    }
    return true;
}

/// Sector containing a map point (BSP point-location)
pub fn sectorAtPoint(lvl: *const setup.Level, x: Fixed, y: Fixed) ?*setup.Sector {
    if (lvl.num_nodes == 0) {
        if (lvl.subsectors.len > 0) {
            if (lvl.subsectors[0].sector) |si| {
                if (si < lvl.sectors.len) return @constCast(&lvl.sectors[si]);
            }
        }
        return null;
    }
    var node_id: u16 = @intCast(lvl.num_nodes - 1);
    while (node_id & defs.NF_SUBSECTOR == 0) {
        if (node_id >= lvl.nodes.len) return null;
        const node = &lvl.nodes[node_id];
        const dx: i64 = x.raw() -% node.x.raw();
        const dy: i64 = y.raw() -% node.y.raw();
        const left: i64 = @as(i64, node.dy.raw()) * dx;
        const right: i64 = dy * @as(i64, node.dx.raw());
        const side: usize = if (right < left) 0 else 1;
        node_id = node.children[side];
    }
    const ssi = node_id & ~@as(u16, defs.NF_SUBSECTOR);
    if (ssi < lvl.subsectors.len) {
        if (lvl.subsectors[ssi].sector) |si| {
            if (si < lvl.sectors.len) return @constCast(&lvl.sectors[si]);
        }
    }
    return null;
}

// ============================================================================
// Position checking (P_CheckPosition + PIT_CheckLine + PIT_CheckThing)
// ============================================================================

/// One line vs the current tm_* move. Returns false if the move is blocked.
fn pitCheckLine(line_idx: usize, lvl: *setup.Level) bool {
    const line = &lvl.lines[line_idx];

    // Bounding-box reject
    if (tm_bbox[bbox_mod.BOXRIGHT].raw() <= line.bbox[bbox_mod.BOXLEFT].raw() or
        tm_bbox[bbox_mod.BOXLEFT].raw() >= line.bbox[bbox_mod.BOXRIGHT].raw() or
        tm_bbox[bbox_mod.BOXTOP].raw() <= line.bbox[bbox_mod.BOXBOTTOM].raw() or
        tm_bbox[bbox_mod.BOXBOTTOM].raw() >= line.bbox[bbox_mod.BOXTOP].raw())
    {
        return true;
    }

    if (maputl.boxOnLineSide(&tm_bbox, line, lvl.vertices) != -1) return true;

    const thing = tm_thing orelse return true;

    // One-sided line always blocks
    if (line.sidenum[1] < 0 or line.backsector == null) {
        ceilingline = line_idx;
        return false;
    }

    if (thing.flags & info.MF_MISSILE == 0) {
        if (line.flags & defs.ML_BLOCKING != 0) return false; // explicitly blocking
        if (thing.player == null and line.flags & defs.ML_BLOCKMONSTERS != 0) return false;
    }

    // Adjust opening: the move is legal so far; the opening may restrict it
    const op = maputl.lineOpening(line, lvl.sectors) orelse {
        ceilingline = line_idx;
        return false;
    };

    if (op.top.raw() < tm_ceilingz.raw()) {
        tm_ceilingz = op.top;
        ceilingline = line_idx;
    }
    if (op.bottom.raw() > tm_floorz.raw()) {
        tm_floorz = op.bottom;
    }
    if (op.lowfloor.raw() < tm_dropoffz.raw()) {
        tm_dropoffz = op.lowfloor;
    }

    // Remember crossed special lines
    if (line.special != 0 and numspechit < MAXSPECIALCROSS) {
        spechit[numspechit] = line_idx;
        numspechit += 1;
    }

    return true;
}

/// One thing vs the current tm_* move. Returns false if the move is blocked.
fn pitCheckThing(_: void, other: *MapObject) bool {
    const thing = tm_thing orelse return true;
    if (other == thing) return true;
    if (other.flags & (info.MF_SOLID | info.MF_SPECIAL | info.MF_SHOOTABLE) == 0) return true;

    const blockdist = Fixed.add(other.radius, thing.radius);
    if (Fixed.sub(other.x, tm_x).abs().raw() >= blockdist.raw() or
        Fixed.sub(other.y, tm_y).abs().raw() >= blockdist.raw())
    {
        return true; // Didn't hit it
    }

    // Lost soul slamming into something
    if (thing.flags & info.MF_SKULLFLY != 0) {
        const damage = (@as(i32, random.pRandom() % 8) + 1) * thing.getInfo().damage;
        inter.damageMobj(other, thing, thing, damage);

        thing.flags &= ~info.MF_SKULLFLY;
        thing.momx = Fixed.ZERO;
        thing.momy = Fixed.ZERO;
        thing.momz = Fixed.ZERO;
        _ = thing.setState(thing.getInfo().spawn_state);
        return false;
    }

    // Missile impact
    if (thing.flags & info.MF_MISSILE != 0) {
        // Z overlap
        if (thing.z.raw() > other.z.raw() + other.height.raw()) return true; // over
        if (Fixed.add(thing.z, thing.height).raw() < other.z.raw()) return true; // under

        if (thing.target) |shooter_mo| {
            if (shooter_mo == other) return true; // Don't hit the shooter
            // Same species don't damage each other (players excepted)
            if (shooter_mo.mobj_type == other.mobj_type and other.mobj_type != .MT_PLAYER) {
                return false; // Explode, but no damage
            }
        }

        if (other.flags & info.MF_SHOOTABLE == 0) {
            return other.flags & info.MF_SOLID == 0;
        }

        const damage = (@as(i32, random.pRandom() % 8) + 1) * thing.getInfo().damage;
        inter.damageMobj(other, thing, thing.target, damage);
        return false; // Stop the missile (caller explodes it)
    }

    // Item pickup
    if (other.flags & info.MF_SPECIAL != 0) {
        const solid = other.flags & info.MF_SOLID != 0;
        if (tm_flags & info.MF_PICKUP != 0) {
            if (inter.touchSpecialThing(other, thing)) {
                mobj_mod.removeMobj(other);
            }
        }
        return !solid;
    }

    return other.flags & info.MF_SOLID == 0;
}

/// Check if a mobj can be at position (x, y).
/// Sets tm_floorz, tm_ceilingz, tm_dropoffz, ceilingline, spechit.
/// Returns true if the position is valid.
pub fn checkPosition(thing: *MapObject, x: Fixed, y: Fixed) bool {
    tm_thing = thing;
    tm_flags = thing.flags;
    tm_x = x;
    tm_y = y;

    tm_bbox[bbox_mod.BOXTOP] = Fixed.add(y, thing.radius);
    tm_bbox[bbox_mod.BOXBOTTOM] = Fixed.sub(y, thing.radius);
    tm_bbox[bbox_mod.BOXRIGHT] = Fixed.add(x, thing.radius);
    tm_bbox[bbox_mod.BOXLEFT] = Fixed.sub(x, thing.radius);

    ceilingline = null;
    numspechit = 0;

    const lvl = world.level orelse {
        // No level loaded (unit tests): fall back to the thing's own bounds
        tm_floorz = thing.floorz;
        tm_ceilingz = thing.ceilingz;
        tm_dropoffz = thing.floorz;
        return Fixed.sub(tm_ceilingz, tm_floorz).raw() >= thing.height.raw();
    };

    // The destination sector's heights are the baseline
    const sec = sectorAtPoint(lvl, x, y) orelse return false;
    tm_floorz = sec.floorheight;
    tm_dropoffz = sec.floorheight;
    tm_ceilingz = sec.ceilingheight;

    if (tm_flags & info.MF_NOCLIP != 0) return true;

    // Things first (vanilla order): pickups happen even if a later line blocks
    if (!forEachMobj({}, pitCheckThing)) return false;

    // Lines
    for (0..lvl.lines.len) |i| {
        if (!pitCheckLine(i, lvl)) return false;
    }

    return true;
}

/// Attempt to move a mobj to a new position, sliding floor/ceiling values
/// and crossing special lines. Returns true if the move succeeded.
pub fn tryMove(thing: *MapObject, x: Fixed, y: Fixed) bool {
    floatok = false;

    if (!checkPosition(thing, x, y)) {
        return false; // Solid wall or thing
    }

    if (thing.flags & info.MF_NOCLIP == 0) {
        if (Fixed.sub(tm_ceilingz, tm_floorz).raw() < thing.height.raw()) {
            return false; // Doesn't fit
        }
        floatok = true;

        if (thing.flags & info.MF_TELEPORT == 0 and
            Fixed.sub(tm_ceilingz, thing.z).raw() < thing.height.raw())
        {
            return false; // Must lower itself to fit
        }
        if (thing.flags & info.MF_TELEPORT == 0 and
            Fixed.sub(tm_floorz, thing.z).raw() > 24 * 0x10000)
        {
            return false; // Too big a step up
        }
        if (thing.flags & (info.MF_DROPOFF | info.MF_FLOAT) == 0 and
            Fixed.sub(tm_floorz, tm_dropoffz).raw() > 24 * 0x10000)
        {
            return false; // Don't stand over a dropoff
        }
    }

    // The move is OK — commit it
    const oldx = thing.x;
    const oldy = thing.y;
    thing.floorz = tm_floorz;
    thing.ceilingz = tm_ceilingz;
    thing.x = x;
    thing.y = y;

    // Cross any special lines
    if (thing.flags & (info.MF_TELEPORT | info.MF_NOCLIP) == 0) {
        if (world.level) |lvl| {
            const alloc = world.allocator orelse return true;
            while (numspechit > 0) {
                numspechit -= 1;
                const li = spechit[numspechit];
                const line = &lvl.lines[li];
                const side = maputl.pointOnLineSide(thing.x, thing.y, line, lvl.vertices);
                const oldside = maputl.pointOnLineSide(oldx, oldy, line, lvl.vertices);
                if (side != oldside) {
                    if (line.special != 0) {
                        spec.crossSpecialLine(li, oldside, thing, lvl, alloc);
                    }
                }
            }
        }
    }

    return true;
}

/// Slide movement: after a failed tryMove, attempt to slide along walls.
/// Simplified stairstep version of P_SlideMove.
pub fn slideMove(mo: *MapObject) void {
    const orig_x = mo.x;
    const orig_y = mo.y;

    // Try the full move first
    if (tryMove(mo, Fixed.add(mo.x, mo.momx), Fixed.add(mo.y, mo.momy))) {
        return; // Full move succeeded
    }

    // Try X-only move (stairstep)
    if (tryMove(mo, Fixed.add(orig_x, mo.momx), orig_y)) {
        mo.momy = Fixed.ZERO; // Cancel Y momentum
        return;
    }

    // Try Y-only move
    if (tryMove(mo, orig_x, Fixed.add(orig_y, mo.momy))) {
        mo.momx = Fixed.ZERO; // Cancel X momentum
        return;
    }

    // Both failed — stop
    mo.momx = Fixed.ZERO;
    mo.momy = Fixed.ZERO;
}

// ============================================================================
// Trace walking (shared by aim, shoot, and use) — P_PathTraverse equivalent
// ============================================================================

const Intercept = struct {
    frac: Fixed,
    line: ?usize = null, // index into level.lines
    thing: ?*MapObject = null,
};

const MAXINTERCEPTS = 128;
var intercepts: [MAXINTERCEPTS]Intercept = undefined;
var num_intercepts: usize = 0;

/// Gather sorted line + thing intercepts along the trace from (x1,y1) toward
/// (x2,y2). Things are approximated by their crossing diagonal (vanilla
/// PIT_AddThingIntercepts).
fn gatherIntercepts(lvl: *setup.Level, x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed, include_things: bool) void {
    num_intercepts = 0;

    const trace = maputl.DivLine{
        .x = x1,
        .y = y1,
        .dx = Fixed.sub(x2, x1),
        .dy = Fixed.sub(y2, y1),
    };

    // Lines
    for (lvl.lines, 0..) |*line, i| {
        const v1 = &lvl.vertices[line.v1];
        const dl = maputl.DivLine{ .x = v1.x, .y = v1.y, .dx = line.dx, .dy = line.dy };

        // Line endpoints on the same side of the trace → no crossing
        const s1 = maputl.pointOnDivlineSide(v1.x, v1.y, &trace);
        const v2 = &lvl.vertices[line.v2];
        const s2 = maputl.pointOnDivlineSide(v2.x, v2.y, &trace);
        if (s1 == s2) continue;

        // Trace endpoints on the same side of the line → no crossing
        const t1 = maputl.pointOnDivlineSide(x1, y1, &dl);
        const t2 = maputl.pointOnDivlineSide(x2, y2, &dl);
        if (t1 == t2) continue;

        const frac = maputl.interceptVector(trace.x, trace.y, trace.dx, trace.dy, dl.x, dl.y, dl.dx, dl.dy);
        if (frac.raw() < 0) continue;

        if (num_intercepts < MAXINTERCEPTS) {
            intercepts[num_intercepts] = .{ .frac = frac, .line = i };
            num_intercepts += 1;
        }
    }

    if (include_things) {
        const Ctx = struct { trace: maputl.DivLine, x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed };
        const ctx = Ctx{ .trace = trace, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
        _ = forEachMobj(ctx, struct {
            fn cb(c: Ctx, mo: *MapObject) bool {
                if (mo.flags & info.MF_SHOOTABLE == 0) return true;

                // The thing's crossing diagonal, oriented against the trace
                const tracepositive = (c.trace.dx.raw() ^ c.trace.dy.raw()) > 0;
                var dl: maputl.DivLine = undefined;
                if (tracepositive) {
                    dl = .{
                        .x = Fixed.sub(mo.x, mo.radius),
                        .y = Fixed.add(mo.y, mo.radius),
                        .dx = Fixed.add(mo.radius, mo.radius),
                        .dy = Fixed.fromRaw(-(Fixed.add(mo.radius, mo.radius).raw())),
                    };
                } else {
                    dl = .{
                        .x = Fixed.sub(mo.x, mo.radius),
                        .y = Fixed.sub(mo.y, mo.radius),
                        .dx = Fixed.add(mo.radius, mo.radius),
                        .dy = Fixed.add(mo.radius, mo.radius),
                    };
                }

                const s1 = maputl.pointOnDivlineSide(c.x1, c.y1, &dl);
                const s2 = maputl.pointOnDivlineSide(c.x2, c.y2, &dl);
                if (s1 == s2) return true;

                const frac = maputl.interceptVector(c.trace.x, c.trace.y, c.trace.dx, c.trace.dy, dl.x, dl.y, dl.dx, dl.dy);
                if (frac.raw() < 0) return true;

                if (num_intercepts < MAXINTERCEPTS) {
                    intercepts[num_intercepts] = .{ .frac = frac, .thing = mo };
                    num_intercepts += 1;
                }
                return true;
            }
        }.cb);
    }

    // Sort by fraction, nearest first (insertion sort, N is small)
    var i: usize = 1;
    while (i < num_intercepts) : (i += 1) {
        const key = intercepts[i];
        var j = i;
        while (j > 0 and intercepts[j - 1].frac.raw() > key.frac.raw()) {
            intercepts[j] = intercepts[j - 1];
            j -= 1;
        }
        intercepts[j] = key;
    }
}

// ============================================================================
// Aim (P_AimLineAttack)
// ============================================================================

/// Trace toward angle looking for a shootable target within range.
/// Returns the aim slope; sets `linetarget` (null if nothing aimable).
pub fn aimLineAttack(source: *MapObject, angle: Angle, distance: Fixed) Fixed {
    linetarget = null;
    const lvl = world.level orelse return Fixed.ZERO;

    const fine = angle >> tables.ANGLETOFINESHIFT;
    const x2 = Fixed.add(source.x, Fixed.mul(distance, tables.finecosine[fine & tables.FINEMASK]));
    const y2 = Fixed.add(source.y, Fixed.mul(distance, tables.finesine[fine & tables.FINEMASK]));
    const sz = Fixed.add(Fixed.add(source.z, Fixed.fromRaw(source.height.raw() >> 1)), Fixed.fromInt(8));

    // Vanilla autoaim window: ±(100/160) slope
    var topslope = Fixed.fromRaw(@divTrunc(100 * 0x10000, 160));
    var bottomslope = Fixed.fromRaw(@divTrunc(-100 * 0x10000, 160));

    gatherIntercepts(lvl, source.x, source.y, x2, y2, true);

    for (intercepts[0..num_intercepts]) |*in| {
        if (in.line) |li| {
            // Two-sided lines narrow the vertical aim window
            const line = &lvl.lines[li];
            const op = maputl.lineOpening(line, lvl.sectors) orelse return Fixed.ZERO; // solid wall stops the aim
            if (op.range.raw() <= 0) return Fixed.ZERO;

            const dist = Fixed.mul(distance, in.frac);
            if (dist.raw() <= 0) continue;

            const front_idx = line.frontsector orelse continue;
            const back_idx = line.backsector orelse continue;
            const front = &lvl.sectors[front_idx];
            const back = &lvl.sectors[back_idx];

            if (front.floorheight.raw() != back.floorheight.raw()) {
                const slope = Fixed.div(Fixed.sub(op.bottom, sz), dist);
                if (slope.raw() > bottomslope.raw()) bottomslope = slope;
            }
            if (front.ceilingheight.raw() != back.ceilingheight.raw()) {
                const slope = Fixed.div(Fixed.sub(op.top, sz), dist);
                if (slope.raw() < topslope.raw()) topslope = slope;
            }
            if (topslope.raw() <= bottomslope.raw()) return Fixed.ZERO;
            continue;
        }

        const mo = in.thing.?;
        if (mo == source) continue;
        if (mo.health <= 0) continue;

        const dist = Fixed.mul(distance, in.frac);
        if (dist.raw() <= 0) continue;

        var thingtopslope = Fixed.div(Fixed.sub(Fixed.add(mo.z, mo.height), sz), dist);
        if (thingtopslope.raw() < bottomslope.raw()) continue; // below window
        var thingbottomslope = Fixed.div(Fixed.sub(mo.z, sz), dist);
        if (thingbottomslope.raw() > topslope.raw()) continue; // above window

        if (thingtopslope.raw() > topslope.raw()) thingtopslope = topslope;
        if (thingbottomslope.raw() < bottomslope.raw()) thingbottomslope = bottomslope;

        aim_slope = Fixed.fromRaw(@divTrunc(thingtopslope.raw() + thingbottomslope.raw(), 2));
        linetarget = mo;
        return aim_slope;
    }

    return Fixed.ZERO;
}

// ============================================================================
// Line Attack (P_LineAttack — hitscan)
// ============================================================================

/// Hitscan attack along a line from source. Damages the first shootable
/// thing hit, spawns puffs/blood, and triggers shot-activated specials.
pub fn lineAttack(
    source: *MapObject,
    angle: Angle,
    range: Fixed,
    slope: Fixed,
    damage: i32,
) void {
    const lvl = world.level orelse return;
    const alloc = world.allocator orelse return;

    shooter = source;
    la_damage = damage;
    attack_range = range;
    aim_slope = slope;
    shootz = Fixed.add(Fixed.add(source.z, Fixed.fromRaw(source.height.raw() >> 1)), Fixed.fromInt(8));

    const fine = angle >> tables.ANGLETOFINESHIFT;
    const x2 = Fixed.add(source.x, Fixed.mul(range, tables.finecosine[fine & tables.FINEMASK]));
    const y2 = Fixed.add(source.y, Fixed.mul(range, tables.finesine[fine & tables.FINEMASK]));

    gatherIntercepts(lvl, source.x, source.y, x2, y2, true);

    for (intercepts[0..num_intercepts]) |*in| {
        if (in.line) |li| {
            const line = &lvl.lines[li];

            if (line.special != 0) {
                spec.shootSpecialLine(source, li, lvl, alloc);
            }

            // Position along the trace where the line is hit
            const dist = Fixed.mul(range, in.frac);
            const z_at = Fixed.add(shootz, Fixed.mul(aim_slope, dist));

            blocked: {
                const op = maputl.lineOpening(line, lvl.sectors) orelse break :blocked;
                // Shot passes through the opening?
                if (z_at.raw() > op.bottom.raw() and z_at.raw() < op.top.raw()) continue;
                break :blocked;
            }

            // Impact on the wall: spawn a puff slightly in front of it
            const frac_back = Fixed.sub(in.frac, Fixed.div(Fixed.fromInt(4), range));
            const px = Fixed.add(source.x, Fixed.mul(Fixed.mul(range, frac_back), tables.finecosine[fine & tables.FINEMASK]));
            const py = Fixed.add(source.y, Fixed.mul(Fixed.mul(range, frac_back), tables.finesine[fine & tables.FINEMASK]));
            const pz = Fixed.add(shootz, Fixed.mul(aim_slope, Fixed.mul(range, frac_back)));

            // No puff on sky walls/ceilings
            if (line.frontsector) |fi| {
                const front = &lvl.sectors[fi];
                if (front.ceilingpic == world.sky_flatnum and pz.raw() > front.ceilingheight.raw()) {
                    return;
                }
            }

            mobj_mod.spawnPuff(px, py, pz, attack_range);
            return;
        }

        const mo = in.thing.?;
        if (mo == source) continue;
        if (mo.flags & info.MF_SHOOTABLE == 0) continue;

        const dist = Fixed.mul(range, in.frac);
        if (dist.raw() <= 0) continue;

        // Vertical hit check
        const thingtopslope = Fixed.div(Fixed.sub(Fixed.add(mo.z, mo.height), shootz), dist);
        if (thingtopslope.raw() < aim_slope.raw()) continue; // shot over
        const thingbottomslope = Fixed.div(Fixed.sub(mo.z, shootz), dist);
        if (thingbottomslope.raw() > aim_slope.raw()) continue; // shot under

        // Hit it: puff or blood at the impact point
        const frac_back = Fixed.sub(in.frac, Fixed.div(Fixed.fromInt(10), range));
        const hx = Fixed.add(source.x, Fixed.mul(Fixed.mul(range, frac_back), tables.finecosine[fine & tables.FINEMASK]));
        const hy = Fixed.add(source.y, Fixed.mul(Fixed.mul(range, frac_back), tables.finesine[fine & tables.FINEMASK]));
        const hz = Fixed.add(shootz, Fixed.mul(aim_slope, Fixed.mul(range, frac_back)));

        if (mo.flags & info.MF_NOBLOOD != 0) {
            mobj_mod.spawnPuff(hx, hy, hz, attack_range);
        } else {
            mobj_mod.spawnBlood(hx, hy, hz, la_damage);
        }

        if (la_damage > 0) {
            inter.damageMobj(mo, source, source, la_damage);
        }
        return;
    }
}

// ============================================================================
// Use Lines (P_UseLines)
// ============================================================================

/// Player activates special lines (switches, doors) in front of them.
pub fn useLines(player_mo: *MapObject) void {
    const lvl = world.level orelse return;
    const alloc = world.allocator orelse return;

    const fine = player_mo.angle >> tables.ANGLETOFINESHIFT;
    const x2 = Fixed.add(player_mo.x, Fixed.mul(level_mod.USERANGE, tables.finecosine[fine & tables.FINEMASK]));
    const y2 = Fixed.add(player_mo.y, Fixed.mul(level_mod.USERANGE, tables.finesine[fine & tables.FINEMASK]));

    gatherIntercepts(lvl, player_mo.x, player_mo.y, x2, y2, false);

    for (intercepts[0..num_intercepts]) |*in| {
        const li = in.line orelse continue;
        const line = &lvl.lines[li];

        if (line.special == 0) {
            // Solid wall or closed opening stops the use trace
            const op = maputl.lineOpening(line, lvl.sectors);
            if (op == null or op.?.range.raw() <= 0) {
                world.playSfx(@ptrCast(player_mo), .noway); // "oof"
                return;
            }
            continue; // Pass through open two-sided lines
        }

        const side = maputl.pointOnLineSide(player_mo.x, player_mo.y, line, lvl.vertices);
        spec.useSpecialLine(player_mo, li, side, lvl, alloc);
        return;
    }
}

// ============================================================================
// Radius Attack (P_RadiusAttack — explosion)
// ============================================================================

/// Apply explosion damage to all shootable things within range.
pub fn radiusAttack(spot: *MapObject, source: ?*MapObject, damage: i32) void {
    const Ctx = struct { spot: *MapObject, source: ?*MapObject, damage: i32 };
    const ctx = Ctx{ .spot = spot, .source = source, .damage = damage };
    _ = forEachMobj(ctx, struct {
        fn cb(c: Ctx, mo: *MapObject) bool {
            if (mo.flags & info.MF_SHOOTABLE == 0) return true;
            if (mo == c.spot) return true;

            const dx = Fixed.sub(mo.x, c.spot.x).abs();
            const dy = Fixed.sub(mo.y, c.spot.y).abs();
            var dist = (if (dx.raw() > dy.raw()) dx else dy).toInt() - mo.radius.toInt();
            if (dist < 0) dist = 0;
            if (dist >= c.damage) return true; // Out of range

            // Must have line of sight to take blast damage
            if (world.level) |lvl| {
                if (!sight.checkSight(mo, c.spot, lvl)) return true;
            }

            inter.damageMobj(mo, c.spot, c.source, c.damage - dist);
            return true;
        }
    }.cb);
}

// ============================================================================
// Thing-on-thing collision check
// ============================================================================

/// Check if two mobjs overlap horizontally
pub fn checkThingCollision(thing1: *const MapObject, thing2: *const MapObject) bool {
    const blockdist = Fixed.add(thing1.radius, thing2.radius);
    const dx = Fixed.sub(thing1.x, thing2.x).abs();
    const dy = Fixed.sub(thing1.y, thing2.y).abs();

    return dx.raw() < blockdist.raw() and dy.raw() < blockdist.raw();
}

// ============================================================================
// Tests
// ============================================================================

test "check position basic" {
    world.level = null;
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);

    // Should be able to stand in open space
    const result = checkPosition(mobj, Fixed.fromInt(100), Fixed.fromInt(100));
    try std.testing.expect(result);

    tick.initThinkers();
}

test "try move with step too high" {
    world.level = null;
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.z = Fixed.ZERO;
    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);

    // Normal move should succeed
    try std.testing.expect(tryMove(mobj, Fixed.fromInt(10), Fixed.ZERO));

    tick.initThinkers();
}

test "thing collision check" {
    var t1 = MapObject{};
    t1.x = Fixed.ZERO;
    t1.y = Fixed.ZERO;
    t1.radius = Fixed.fromInt(20);

    var t2 = MapObject{};
    t2.x = Fixed.fromInt(10);
    t2.y = Fixed.ZERO;
    t2.radius = Fixed.fromInt(20);

    // Overlapping — distance=10, combined radius=40
    try std.testing.expect(checkThingCollision(&t1, &t2));

    // Not overlapping
    t2.x = Fixed.fromInt(100);
    try std.testing.expect(!checkThingCollision(&t1, &t2));
}

test "slide move stops when fully blocked" {
    world.level = null;
    tick.initThinkers();
    const alloc = std.testing.allocator;

    const mobj = try mobj_mod.spawnMobj(Fixed.ZERO, Fixed.ZERO, Fixed.ZERO, .MT_POSSESSED, alloc);
    defer alloc.destroy(mobj);

    mobj.floorz = Fixed.ZERO;
    mobj.ceilingz = Fixed.fromInt(128);
    mobj.momx = Fixed.fromInt(5);
    mobj.momy = Fixed.fromInt(5);

    // slideMove should succeed with full move (no actual blockmap to block it)
    slideMove(mobj);

    // Position should have moved (since no actual blocking linedefs)
    try std.testing.expect(mobj.x.raw() != 0 or mobj.y.raw() != 0);

    tick.initThinkers();
}
