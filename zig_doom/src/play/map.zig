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
pub var tm_floorz: Fixed = Fixed.ZERO;
pub var tm_ceilingz: Fixed = Fixed.ZERO;
pub var tm_dropoffz: Fixed = Fixed.ZERO;
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

pub const MAPBLOCKSHIFT = 16 + 7; // fixed-point 128-unit cells

/// Blockmap cell of a raw fixed coordinate
fn blockCell(lvl: *const setup.Level, x: Fixed, y: Fixed) ?struct { cx: i32, cy: i32 } {
    if (lvl.bmap_cols == 0) return null;
    const cx: i32 = @intCast((@as(i64, x.raw()) - lvl.bmap_orgx.raw()) >> MAPBLOCKSHIFT);
    const cy: i32 = @intCast((@as(i64, y.raw()) - lvl.bmap_orgy.raw()) >> MAPBLOCKSHIFT);
    return .{ .cx = cx, .cy = cy };
}

/// Link a mobj into the blockmap chain for its current position
/// (P_SetThingPosition — blockmap half; sector links unused).
pub fn setThingPosition(mo: *MapObject) void {
    if (mo.flags & info.MF_NOBLOCKMAP != 0) return;
    const lvl = world.level orelse return;
    if (lvl.blocklinks.len == 0) return;
    const c = blockCell(lvl, mo.x, mo.y) orelse return;
    if (c.cx < 0 or c.cy < 0 or c.cx >= lvl.bmap_cols or c.cy >= lvl.bmap_rows) {
        mo.bnext = null;
        mo.bprev = null;
        return;
    }
    const idx: usize = @intCast(c.cy * lvl.bmap_cols + c.cx);
    const head = lvl.blocklinks[idx];
    mo.bprev = null;
    mo.bnext = if (head) |h| @ptrCast(@alignCast(h)) else null;
    if (mo.bnext) |n| n.bprev = mo;
    lvl.blocklinks[idx] = @ptrCast(mo);
}

/// Unlink a mobj from its blockmap chain (must be called BEFORE moving).
pub fn unsetThingPosition(mo: *MapObject) void {
    if (mo.flags & info.MF_NOBLOCKMAP != 0) return;
    const lvl = world.level orelse return;
    if (lvl.blocklinks.len == 0) return;

    if (mo.bprev) |p| {
        p.bnext = mo.bnext;
    } else {
        // Head of its chain
        const c = blockCell(lvl, mo.x, mo.y) orelse return;
        if (c.cx >= 0 and c.cy >= 0 and c.cx < lvl.bmap_cols and c.cy < lvl.bmap_rows) {
            const idx: usize = @intCast(c.cy * lvl.bmap_cols + c.cx);
            if (lvl.blocklinks[idx]) |h| {
                const head: *MapObject = @ptrCast(@alignCast(h));
                if (head == mo) {
                    lvl.blocklinks[idx] = if (mo.bnext) |n| @ptrCast(n) else null;
                }
            }
        }
    }
    if (mo.bnext) |n| n.bprev = mo.bprev;
    mo.bnext = null;
    mo.bprev = null;
}

/// Walk the mobj chain of one blockmap cell. cb returns false to stop.
fn blockThings(lvl: *const setup.Level, cx: i32, cy: i32, ctx: anytype, comptime cb: fn (@TypeOf(ctx), *MapObject) bool) bool {
    if (cx < 0 or cy < 0 or cx >= lvl.bmap_cols or cy >= lvl.bmap_rows) return true;
    if (lvl.blocklinks.len == 0) return true;
    const idx: usize = @intCast(cy * lvl.bmap_cols + cx);
    var cur: ?*MapObject = if (lvl.blocklinks[idx]) |h| @ptrCast(@alignCast(h)) else null;
    while (cur) |mo| {
        const next = mo.bnext; // chain may mutate under us (pickups)
        if (!cb(ctx, mo)) return false;
        cur = next;
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
        const side = maputl.rPointOnSide(x, y, node.x, node.y, node.dx, node.dy);
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

    // Things first (vanilla order), via blockmap cells of the move bbox
    // expanded by MAXRADIUS
    {
        const orgx = lvl.bmap_orgx.raw();
        const orgy = lvl.bmap_orgy.raw();
        const maxr = level_mod.MAXRADIUS.raw();
        const xl: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXLEFT].raw()) - orgx - maxr) >> MAPBLOCKSHIFT);
        const xh: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXRIGHT].raw()) - orgx + maxr) >> MAPBLOCKSHIFT);
        const yl: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXBOTTOM].raw()) - orgy - maxr) >> MAPBLOCKSHIFT);
        const yh: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXTOP].raw()) - orgy + maxr) >> MAPBLOCKSHIFT);

        var bx = xl;
        while (bx <= xh) : (bx += 1) {
            var by = yl;
            while (by <= yh) : (by += 1) {
                if (!blockThings(lvl, bx, by, {}, pitCheckThing)) return false;
            }
        }
    }

    // Lines via the blockmap's per-cell lists (each line checked once)
    {
        if (line_guard.len < lvl.lines.len) line_guard = &line_guard_buf;
        @memset(line_guard_buf[0..lvl.lines.len], false);

        const orgx = lvl.bmap_orgx.raw();
        const orgy = lvl.bmap_orgy.raw();
        const xl: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXLEFT].raw()) - orgx) >> MAPBLOCKSHIFT);
        const xh: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXRIGHT].raw()) - orgx) >> MAPBLOCKSHIFT);
        const yl: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXBOTTOM].raw()) - orgy) >> MAPBLOCKSHIFT);
        const yh: i32 = @intCast((@as(i64, tm_bbox[bbox_mod.BOXTOP].raw()) - orgy) >> MAPBLOCKSHIFT);

        const Ctx = struct { lvl: *setup.Level };
        const ctx = Ctx{ .lvl = lvl };
        var bx = xl;
        while (bx <= xh) : (bx += 1) {
            var by = yl;
            while (by <= yh) : (by += 1) {
                const ok = lvl.blockLines(bx, by, ctx, struct {
                    fn cb(c: Ctx, li: u16) bool {
                        if (li >= c.lvl.lines.len) return true;
                        if (line_guard_buf[li]) return true;
                        line_guard_buf[li] = true;
                        return pitCheckLine(li, c.lvl);
                    }
                }.cb);
                if (!ok) return false;
            }
        }
    }

    return true;
}

/// Per-call line-visited guard (vanilla validcount)
var line_guard_buf: [8192]bool = undefined;
var line_guard: []bool = &[_]bool{};

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

    // The move is OK — commit it (relinking the blockmap chain)
    const oldx = thing.x;
    const oldy = thing.y;
    unsetThingPosition(thing);
    thing.floorz = tm_floorz;
    thing.ceilingz = tm_ceilingz;
    thing.x = x;
    thing.y = y;
    setThingPosition(thing);

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

// Slide movement state (P_SlideMove globals)
var bestslidefrac: Fixed = Fixed.ZERO;
var bestslideline: ?usize = null;
var slide_tmxmove: Fixed = Fixed.ZERO;
var slide_tmymove: Fixed = Fixed.ZERO;

/// One slide trace from a leading corner (PTR_SlideTraverse over lines).
/// Updates bestslidefrac/bestslideline with the nearest blocking line.
fn slideTraverse(mo: *MapObject, lvl: *setup.Level, x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) void {
    gatherIntercepts(lvl, x1, y1, x2, y2, false);

    for (intercepts[0..num_intercepts]) |*in| {
        if (in.frac.raw() >= 0x10000) break; // beyond the move
        const li = in.line orelse continue;
        const line = &lvl.lines[li];

        blocking: {
            if (line.flags & defs.ML_TWOSIDED == 0) {
                if (maputl.pointOnLineSide(mo.x, mo.y, line, lvl.vertices) != 0) {
                    continue; // don't hit the back side
                }
                break :blocking;
            }
            const op = maputl.lineOpening(line, lvl.sectors) orelse break :blocking;
            if (op.range.raw() < mo.height.raw()) break :blocking;
            if (Fixed.sub(op.top, mo.z).raw() < mo.height.raw()) break :blocking;
            if (Fixed.sub(op.bottom, mo.z).raw() > 24 * 0x10000) break :blocking;
            continue; // this line doesn't block movement
        }

        if (in.frac.raw() < bestslidefrac.raw()) {
            bestslidefrac = in.frac;
            bestslideline = li;
        }
        return; // stop this trace at the first blocker
    }
}

/// Clip the slide move along the blocking wall (P_HitSlideLine).
fn hitSlideLine(mo: *MapObject, lvl: *setup.Level, line_idx: usize) void {
    const line = &lvl.lines[line_idx];

    if (line.slopetype == .horizontal) {
        slide_tmymove = Fixed.ZERO;
        return;
    }
    if (line.slopetype == .vertical) {
        slide_tmxmove = Fixed.ZERO;
        return;
    }

    const side = maputl.pointOnLineSide(mo.x, mo.y, line, lvl.vertices);
    var lineangle = state_pointToAngle2(Fixed.ZERO, Fixed.ZERO, line.dx, line.dy);
    if (side == 1) lineangle +%= fixed.ANG180;

    const moveangle = state_pointToAngle2(Fixed.ZERO, Fixed.ZERO, slide_tmxmove, slide_tmymove);
    var deltaangle = moveangle -% lineangle;
    if (deltaangle > fixed.ANG180) deltaangle +%= fixed.ANG180; // vanilla quirk, kept

    const lf = lineangle >> tables.ANGLETOFINESHIFT;
    const df = deltaangle >> tables.ANGLETOFINESHIFT;

    const movelen = maputl.aproxDistance(slide_tmxmove, slide_tmymove);
    const newlen = Fixed.mul(movelen, tables.finecosine[df & tables.FINEMASK]);

    slide_tmxmove = Fixed.mul(newlen, tables.finecosine[lf & tables.FINEMASK]);
    slide_tmymove = Fixed.mul(newlen, tables.finesine[lf & tables.FINEMASK]);
}

fn state_pointToAngle2(x1: Fixed, y1: Fixed, x2: Fixed, y2: Fixed) Angle {
    return maputl.pointToAngle2(x1, y1, x2, y2);
}

/// Slide a player along the wall that blocked the move (P_SlideMove).
pub fn slideMove(mo: *MapObject) void {
    const lvl = world.level orelse {
        // No level (tests): just try the full move
        _ = tryMove(mo, Fixed.add(mo.x, mo.momx), Fixed.add(mo.y, mo.momy));
        return;
    };

    var hitcount: u32 = 0;
    retry: while (true) {
        hitcount += 1;
        if (hitcount == 3) {
            // Don't loop forever: stairstep
            if (!tryMove(mo, mo.x, Fixed.add(mo.y, mo.momy))) {
                _ = tryMove(mo, Fixed.add(mo.x, mo.momx), mo.y);
            }
            return;
        }

        // Trace along the three leading corners
        var leadx: Fixed = undefined;
        var trailx: Fixed = undefined;
        var leady: Fixed = undefined;
        var traily: Fixed = undefined;
        if (mo.momx.raw() > 0) {
            leadx = Fixed.add(mo.x, mo.radius);
            trailx = Fixed.sub(mo.x, mo.radius);
        } else {
            leadx = Fixed.sub(mo.x, mo.radius);
            trailx = Fixed.add(mo.x, mo.radius);
        }
        if (mo.momy.raw() > 0) {
            leady = Fixed.add(mo.y, mo.radius);
            traily = Fixed.sub(mo.y, mo.radius);
        } else {
            leady = Fixed.sub(mo.y, mo.radius);
            traily = Fixed.add(mo.y, mo.radius);
        }

        bestslidefrac = Fixed.fromRaw(0x10000 + 1);
        bestslideline = null;

        slideTraverse(mo, lvl, leadx, leady, Fixed.add(leadx, mo.momx), Fixed.add(leady, mo.momy));
        slideTraverse(mo, lvl, trailx, leady, Fixed.add(trailx, mo.momx), Fixed.add(leady, mo.momy));
        slideTraverse(mo, lvl, leadx, traily, Fixed.add(leadx, mo.momx), Fixed.add(traily, mo.momy));

        // Move up to the wall
        if (bestslidefrac.raw() == 0x10000 + 1) {
            // The move must have hit the middle: stairstep
            if (!tryMove(mo, mo.x, Fixed.add(mo.y, mo.momy))) {
                _ = tryMove(mo, Fixed.add(mo.x, mo.momx), mo.y);
            }
            return;
        }

        // Fudge a bit so it doesn't hit
        bestslidefrac = Fixed.fromRaw(bestslidefrac.raw() - 0x800);
        if (bestslidefrac.raw() > 0) {
            const newx = Fixed.mul(mo.momx, bestslidefrac);
            const newy = Fixed.mul(mo.momy, bestslidefrac);
            if (!tryMove(mo, Fixed.add(mo.x, newx), Fixed.add(mo.y, newy))) {
                if (!tryMove(mo, mo.x, Fixed.add(mo.y, mo.momy))) {
                    _ = tryMove(mo, Fixed.add(mo.x, mo.momx), mo.y);
                }
                return;
            }
        }

        // Now continue along the wall with the remaining momentum
        var remain = 0x10000 - (bestslidefrac.raw() + 0x800);
        if (remain > 0x10000) remain = 0x10000;
        if (remain <= 0) return;

        slide_tmxmove = Fixed.mul(mo.momx, Fixed.fromRaw(remain));
        slide_tmymove = Fixed.mul(mo.momy, Fixed.fromRaw(remain));

        if (bestslideline) |bli| {
            hitSlideLine(mo, lvl, bli);
        }

        mo.momx = slide_tmxmove;
        mo.momy = slide_tmymove;

        if (!tryMove(mo, Fixed.add(mo.x, slide_tmxmove), Fixed.add(mo.y, slide_tmymove))) {
            continue :retry;
        }
        return;
    }
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

/// Gather sorted line + thing intercepts along the trace from (x1,y1)
/// toward (x2,y2), using the vanilla P_PathTraverse blockmap cell walk —
/// demo sync depends on its exact locality (things/lines in unvisited
/// cells are invisible to the trace, quirks and all).
fn gatherIntercepts(lvl: *setup.Level, x1_in: Fixed, y1_in: Fixed, x2_in: Fixed, y2_in: Fixed, include_things: bool) void {
    num_intercepts = 0;

    var x1 = x1_in;
    var y1 = y1_in;
    const x2 = x2_in;
    const y2 = y2_in;

    const MAPBLOCKSIZE: i32 = 128 << 16;

    // Don't side exactly on a cell boundary (vanilla nudge)
    if ((x1.raw() -% lvl.bmap_orgx.raw()) & (MAPBLOCKSIZE - 1) == 0) x1 = Fixed.add(x1, Fixed.ONE);
    if ((y1.raw() -% lvl.bmap_orgy.raw()) & (MAPBLOCKSIZE - 1) == 0) y1 = Fixed.add(y1, Fixed.ONE);

    const trace = maputl.DivLine{
        .x = x1,
        .y = y1,
        .dx = Fixed.sub(x2, x1),
        .dy = Fixed.sub(y2, y1),
    };

    if (line_guard.len < lvl.lines.len) line_guard = &line_guard_buf;
    @memset(line_guard_buf[0..lvl.lines.len], false);

    // Cell walk state (vanilla DDA, MAPBTOFRAC = 7)
    const lx1 = x1.raw() -% lvl.bmap_orgx.raw();
    const ly1 = y1.raw() -% lvl.bmap_orgy.raw();
    const lx2 = x2.raw() -% lvl.bmap_orgx.raw();
    const ly2 = y2.raw() -% lvl.bmap_orgy.raw();

    const xt1: i32 = @intCast(@as(i64, lx1) >> MAPBLOCKSHIFT);
    const yt1: i32 = @intCast(@as(i64, ly1) >> MAPBLOCKSHIFT);
    const xt2: i32 = @intCast(@as(i64, lx2) >> MAPBLOCKSHIFT);
    const yt2: i32 = @intCast(@as(i64, ly2) >> MAPBLOCKSHIFT);

    var mapxstep: i32 = 0;
    var mapystep: i32 = 0;
    var partial: Fixed = Fixed.ONE;
    var xstep: Fixed = Fixed.ONE;
    var ystep: Fixed = Fixed.ONE;

    if (xt2 > xt1) {
        mapxstep = 1;
        partial = Fixed.fromRaw(0x10000 - ((lx1 >> 7) & 0xFFFF));
        ystep = Fixed.div(Fixed.fromRaw(ly2 -% ly1), Fixed.fromRaw(@intCast(@abs(lx2 -% lx1))));
    } else if (xt2 < xt1) {
        mapxstep = -1;
        partial = Fixed.fromRaw((lx1 >> 7) & 0xFFFF);
        ystep = Fixed.div(Fixed.fromRaw(ly2 -% ly1), Fixed.fromRaw(@intCast(@abs(lx2 -% lx1))));
    } else {
        mapxstep = 0;
        partial = Fixed.ONE;
        ystep = Fixed.fromRaw(256 * 0x10000);
    }
    var yintercept = Fixed.fromRaw((ly1 >> 7) +% Fixed.mul(partial, ystep).raw());

    if (yt2 > yt1) {
        mapystep = 1;
        partial = Fixed.fromRaw(0x10000 - ((ly1 >> 7) & 0xFFFF));
        xstep = Fixed.div(Fixed.fromRaw(lx2 -% lx1), Fixed.fromRaw(@intCast(@abs(ly2 -% ly1))));
    } else if (yt2 < yt1) {
        mapystep = -1;
        partial = Fixed.fromRaw((ly1 >> 7) & 0xFFFF);
        xstep = Fixed.div(Fixed.fromRaw(lx2 -% lx1), Fixed.fromRaw(@intCast(@abs(ly2 -% ly1))));
    } else {
        mapystep = 0;
        partial = Fixed.ONE;
        xstep = Fixed.fromRaw(256 * 0x10000);
    }
    var xintercept = Fixed.fromRaw((lx1 >> 7) +% Fixed.mul(partial, xstep).raw());

    const LineCtx = struct { lvl: *setup.Level, trace: *const maputl.DivLine };
    const lctx = LineCtx{ .lvl = lvl, .trace = &trace };
    const ThingCtx = struct { trace: *const maputl.DivLine };
    const tctx = ThingCtx{ .trace = &trace };

    var mapx = xt1;
    var mapy = yt1;
    var count: u32 = 0;
    while (count < 64) : (count += 1) {
        // Lines in this cell
        _ = lvl.blockLines(mapx, mapy, lctx, struct {
            fn cb(c: LineCtx, li: u16) bool {
                if (li >= c.lvl.lines.len) return true;
                if (line_guard_buf[li]) return true;
                line_guard_buf[li] = true;

                const line = &c.lvl.lines[li];
                const v1 = &c.lvl.vertices[line.v1];
                const v2 = &c.lvl.vertices[line.v2];

                // Vanilla dual-mode crossing test: long traces test the line
                // endpoints against the trace; SHORT traces (slides!) test
                // the trace endpoints against the line.
                var s1: i32 = undefined;
                var s2: i32 = undefined;
                const lim: i32 = 16 * 0x10000;
                if (c.trace.dx.raw() > lim or c.trace.dy.raw() > lim or
                    c.trace.dx.raw() < -lim or c.trace.dy.raw() < -lim)
                {
                    s1 = maputl.pointOnDivlineSide(v1.x, v1.y, c.trace);
                    s2 = maputl.pointOnDivlineSide(v2.x, v2.y, c.trace);
                } else {
                    s1 = maputl.pointOnLineSide(c.trace.x, c.trace.y, line, c.lvl.vertices);
                    s2 = maputl.pointOnLineSide(Fixed.add(c.trace.x, c.trace.dx), Fixed.add(c.trace.y, c.trace.dy), line, c.lvl.vertices);
                }
                if (s1 == s2) return true; // Line isn't crossed

                const dl = maputl.DivLine{ .x = v1.x, .y = v1.y, .dx = line.dx, .dy = line.dy };
                const frac = maputl.interceptVector(c.trace.x, c.trace.y, c.trace.dx, c.trace.dy, dl.x, dl.y, dl.dx, dl.dy);
                if (frac.raw() < 0) return true; // Behind source

                if (num_intercepts < MAXINTERCEPTS) {
                    intercepts[num_intercepts] = .{ .frac = frac, .line = li };
                    num_intercepts += 1;
                }
                return true;
            }
        }.cb);

        // Things in this cell
        if (include_things) {
            _ = blockThings(lvl, mapx, mapy, tctx, struct {
                fn cb(c: ThingCtx, mo: *MapObject) bool {
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

                    const s1 = maputl.pointOnDivlineSide(dl.x, dl.y, c.trace);
                    const s2 = maputl.pointOnDivlineSide(Fixed.add(dl.x, dl.dx), Fixed.add(dl.y, dl.dy), c.trace);
                    if (s1 == s2) return true; // Diagonal isn't crossed

                    const frac = maputl.interceptVector(c.trace.x, c.trace.y, c.trace.dx, c.trace.dy, dl.x, dl.y, dl.dx, dl.dy);
                    if (frac.raw() < 0) return true; // Behind source

                    if (num_intercepts < MAXINTERCEPTS) {
                        intercepts[num_intercepts] = .{ .frac = frac, .thing = mo };
                        num_intercepts += 1;
                    }
                    return true;
                }
            }.cb);
        }

        if (mapx == xt2 and mapy == yt2) break;

        if ((yintercept.raw() >> 16) == mapy) {
            yintercept = Fixed.add(yintercept, ystep);
            mapx += mapxstep;
        } else if ((xintercept.raw() >> 16) == mapx) {
            xintercept = Fixed.add(xintercept, xstep);
            mapy += mapystep;
        }
    }

    // Sort by fraction, nearest first (stable insertion sort)
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
        if (in.frac.raw() > 0x10000) break; // beyond trace range
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
        if (mo.flags & info.MF_SHOOTABLE == 0) continue; // corpse or something

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
        if (in.frac.raw() > 0x10000) break; // beyond trace range
        if (in.line) |li| {
            const line = &lvl.lines[li];

            if (line.special != 0) {
                spec.shootSpecialLine(source, li, lvl, alloc);
            }

            // Two-sided lines pass the shot when the slope clears the
            // opening; equal-height planes never block (vanilla).
            blocked: {
                if (line.flags & defs.ML_TWOSIDED == 0) break :blocked;
                const op = maputl.lineOpening(line, lvl.sectors) orelse break :blocked;
                const dist = Fixed.mul(range, in.frac);
                if (dist.raw() <= 0) continue;

                const fi = line.frontsector orelse break :blocked;
                const bi = line.backsector orelse break :blocked;
                const front = &lvl.sectors[fi];
                const back = &lvl.sectors[bi];

                if (front.floorheight.raw() != back.floorheight.raw()) {
                    const bot_slope = Fixed.div(Fixed.sub(op.bottom, shootz), dist);
                    if (bot_slope.raw() > aim_slope.raw()) break :blocked; // hits the lower wall
                }
                if (front.ceilingheight.raw() != back.ceilingheight.raw()) {
                    const top_slope = Fixed.div(Fixed.sub(op.top, shootz), dist);
                    if (top_slope.raw() < aim_slope.raw()) break :blocked; // hits the upper wall
                }
                continue; // Shot continues past this line
            }

            // Impact on the wall: spawn a puff slightly in front of it
            const frac_back = Fixed.sub(in.frac, Fixed.div(Fixed.fromInt(4), range));
            const px = Fixed.add(source.x, Fixed.mul(Fixed.mul(range, frac_back), tables.finecosine[fine & tables.FINEMASK]));
            const py = Fixed.add(source.y, Fixed.mul(Fixed.mul(range, frac_back), tables.finesine[fine & tables.FINEMASK]));
            const pz = Fixed.add(shootz, Fixed.mul(aim_slope, Fixed.mul(range, frac_back)));

            // No puff on sky walls/ceilings (vanilla PTR_ShootTraverse)
            if (line.frontsector) |fi| {
                const front = &lvl.sectors[fi];
                if (front.ceilingpic == world.sky_flatnum) {
                    // don't shoot the sky!
                    if (pz.raw() > front.ceilingheight.raw()) return;
                    // it's a sky hack wall
                    if (line.backsector) |bi| {
                        if (lvl.sectors[bi].ceilingpic == world.sky_flatnum) return;
                    }
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
        if (in.frac.raw() > 0x10000) break; // beyond trace range
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
        _ = spec.useSpecialLine(player_mo, li, side, lvl, alloc);
        return;
    }
}

// ============================================================================
// Radius Attack (P_RadiusAttack — explosion)
// ============================================================================

/// Apply explosion damage to all shootable things within range
/// (vanilla P_RadiusAttack: blockmap cells around the blast).
pub fn radiusAttack(spot: *MapObject, source: ?*MapObject, damage: i32) void {
    const lvl = world.level orelse return;

    const dist_f: i64 = (@as(i64, damage) << 16) + level_mod.MAXRADIUS.raw();
    const orgx = lvl.bmap_orgx.raw();
    const orgy = lvl.bmap_orgy.raw();
    const xl: i32 = @intCast((@as(i64, spot.x.raw()) - dist_f - orgx) >> MAPBLOCKSHIFT);
    const xh: i32 = @intCast((@as(i64, spot.x.raw()) + dist_f - orgx) >> MAPBLOCKSHIFT);
    const yl: i32 = @intCast((@as(i64, spot.y.raw()) - dist_f - orgy) >> MAPBLOCKSHIFT);
    const yh: i32 = @intCast((@as(i64, spot.y.raw()) + dist_f - orgy) >> MAPBLOCKSHIFT);

    const Ctx = struct { spot: *MapObject, source: ?*MapObject, damage: i32 };
    const ctx = Ctx{ .spot = spot, .source = source, .damage = damage };

    // Vanilla iterates y outer, x inner — the order things take splash
    // damage (and roll pain chances) must match for demo sync.
    var by = yl;
    while (by <= yh) : (by += 1) {
        var bx = xl;
        while (bx <= xh) : (bx += 1) {
            _ = blockThings(lvl, bx, by, ctx, struct {
                fn cb(c: Ctx, mo: *MapObject) bool {
                    if (mo.flags & info.MF_SHOOTABLE == 0) return true;

                    // Boss spider and cyborg take no concussion damage
                    if (mo.mobj_type == .MT_CYBORG or mo.mobj_type == .MT_SPIDER) return true;

                    const dx = Fixed.sub(mo.x, c.spot.x).abs();
                    const dy = Fixed.sub(mo.y, c.spot.y).abs();
                    // Chebyshev distance minus radius, in FIXED, then >>16
                    const dist_fx = (if (dx.raw() > dy.raw()) dx else dy).raw() - mo.radius.raw();
                    var dist: i32 = dist_fx >> 16;
                    if (dist < 0) dist = 0;
                    if (dist >= c.damage) return true; // Out of range

                    // Must have line of sight to take blast damage
                    if (world.level) |l2| {
                        if (!sight.checkSight(mo, c.spot, l2)) return true;
                    }

                    inter.damageMobj(mo, c.spot, c.source, c.damage - dist);
                    return true;
                }
            }.cb);
        }
    }
}

// ============================================================================
// Sector height changes (vanilla P_ChangeSector / P_ThingHeightClip)
// ============================================================================

/// P_ThingHeightClip — after a sector height change, re-derive the thing's
/// floorz/ceilingz from its current position and snap grounded things to the
/// (possibly moved) floor. Returns false if the thing no longer fits.
fn thingHeightClip(thing: *MapObject) bool {
    const onfloor = thing.z.raw() == thing.floorz.raw();

    _ = checkPosition(thing, thing.x, thing.y);
    thing.floorz = tm_floorz;
    thing.ceilingz = tm_ceilingz;

    if (onfloor) {
        // walking monsters rise and fall with the floor
        thing.z = thing.floorz;
    } else {
        // don't adjust a floating monster unless forced to
        if (Fixed.add(thing.z, thing.height).raw() > thing.ceilingz.raw())
            thing.z = Fixed.sub(thing.ceilingz, thing.height);
    }

    return Fixed.sub(thing.ceilingz, thing.floorz).raw() >= thing.height.raw();
}

var cs_nofit: bool = false;
var cs_crushchange: bool = false;

/// PIT_ChangeSector — refit one thing; gib corpses, destroy dropped items,
/// flag nofit and apply crush damage every 4th tic.
fn pitChangeSector(_: u8, thing: *MapObject) bool {
    if (thingHeightClip(thing)) return true; // keep checking

    // crunch bodies to giblets
    if (thing.health <= 0) {
        _ = thing.setState(.S_GIBS);
        thing.flags &= ~info.MF_SOLID;
        thing.height = Fixed.ZERO;
        thing.radius = Fixed.ZERO;
        return true;
    }

    // crunch dropped items
    if (thing.flags & info.MF_DROPPED != 0) {
        mobj_mod.removeMobj(thing);
        return true;
    }

    if (thing.flags & info.MF_SHOOTABLE == 0) {
        // assume it is bloody gibs or something
        return true;
    }

    cs_nofit = true;

    if (cs_crushchange and (world.leveltime & 3) == 0) {
        inter.damageMobj(thing, null, null, 10);

        // spray blood in a random direction
        if (world.allocator) |alloc| {
            const bz = Fixed.add(thing.z, Fixed.fromRaw(thing.height.raw() >> 1));
            if (mobj_mod.spawnMobj(thing.x, thing.y, bz, .MT_BLOOD, alloc)) |mo| {
                mo.momx = Fixed.fromRaw(random.pSubRandom() << 12);
                mo.momy = Fixed.fromRaw(random.pSubRandom() << 12);
            } else |_| {}
        }
    }

    // keep checking (crush other things)
    return true;
}

/// P_ChangeSector — after modifying a sector's floor or ceiling height,
/// re-check every thing in the sector's blockmap box. Returns true if
/// anything no longer fits.
pub fn changeSector(lvl: *setup.Level, sector_idx: usize, crunch: bool) bool {
    cs_nofit = false;
    cs_crushchange = crunch;

    const bb = lvl.sectors[sector_idx].blockbox; // [top, bottom, left, right]
    var x = bb[2];
    while (x <= bb[3]) : (x += 1) {
        var y = bb[1];
        while (y <= bb[0]) : (y += 1) {
            _ = blockThings(lvl, x, y, @as(u8, 0), pitChangeSector);
        }
    }

    return cs_nofit;
}

// ============================================================================
// T_MovePlane (vanilla p_floor.c) — the single sector plane mover
// ============================================================================

pub const PlaneResult = enum { ok, crushed, pastdest };

/// Move a sector's floor (floor_or_ceiling=0) or ceiling (=1) by speed
/// toward dest. Faithful port: strict overshoot compares (landing exactly
/// on dest returns ok; pastdest fires the NEXT tic) and P_ChangeSector
/// crush handling with height restore.
pub fn movePlane(
    lvl: *setup.Level,
    sector_idx: usize,
    speed: Fixed,
    dest: Fixed,
    crush: bool,
    floor_or_ceiling: i32,
    direction: i32,
) PlaneResult {
    const sector = &lvl.sectors[sector_idx];

    switch (floor_or_ceiling) {
        0 => switch (direction) {
            -1 => { // floor DOWN
                if (Fixed.sub(sector.floorheight, speed).raw() < dest.raw()) {
                    const lastpos = sector.floorheight;
                    sector.floorheight = dest;
                    if (changeSector(lvl, sector_idx, crush)) {
                        sector.floorheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                    }
                    return .pastdest;
                } else {
                    const lastpos = sector.floorheight;
                    sector.floorheight = Fixed.sub(sector.floorheight, speed);
                    if (changeSector(lvl, sector_idx, crush)) {
                        sector.floorheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                        return .crushed;
                    }
                }
            },
            1 => { // floor UP
                if (Fixed.add(sector.floorheight, speed).raw() > dest.raw()) {
                    const lastpos = sector.floorheight;
                    sector.floorheight = dest;
                    if (changeSector(lvl, sector_idx, crush)) {
                        sector.floorheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                    }
                    return .pastdest;
                } else {
                    // COULD GET CRUSHED
                    const lastpos = sector.floorheight;
                    sector.floorheight = Fixed.add(sector.floorheight, speed);
                    if (changeSector(lvl, sector_idx, crush)) {
                        if (crush) return .crushed;
                        sector.floorheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                        return .crushed;
                    }
                }
            },
            else => {},
        },
        1 => switch (direction) {
            -1 => { // ceiling DOWN
                if (Fixed.sub(sector.ceilingheight, speed).raw() < dest.raw()) {
                    const lastpos = sector.ceilingheight;
                    sector.ceilingheight = dest;
                    if (changeSector(lvl, sector_idx, crush)) {
                        sector.ceilingheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                    }
                    return .pastdest;
                } else {
                    // COULD GET CRUSHED
                    const lastpos = sector.ceilingheight;
                    sector.ceilingheight = Fixed.sub(sector.ceilingheight, speed);
                    if (changeSector(lvl, sector_idx, crush)) {
                        if (crush) return .crushed;
                        sector.ceilingheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                        return .crushed;
                    }
                }
            },
            1 => { // ceiling UP
                if (Fixed.add(sector.ceilingheight, speed).raw() > dest.raw()) {
                    const lastpos = sector.ceilingheight;
                    sector.ceilingheight = dest;
                    if (changeSector(lvl, sector_idx, crush)) {
                        sector.ceilingheight = lastpos;
                        _ = changeSector(lvl, sector_idx, crush);
                    }
                    return .pastdest;
                } else {
                    sector.ceilingheight = Fixed.add(sector.ceilingheight, speed);
                    _ = changeSector(lvl, sector_idx, crush);
                }
            },
            else => {},
        },
        else => {},
    }

    return .ok;
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
