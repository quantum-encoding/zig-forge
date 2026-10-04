//! zig_doom/src/agent_drive.zig
//!
//! Locomotion for agent mode: given a goal (explore, the exit, a point),
//! walk there. The agent decides WHAT to do; this decides how, every tic.
//!
//! - The route comes from agent_nav (sector graph, Dijkstra) as one
//!   crossing point per doorway or step, pulled taut by agent_funnel, and
//!   is re-planned a few times a second as doors and lifts change.
//! - DOOM sectors are not convex — a lower floor can wrap round a stair —
//!   so a straight line between two route points can cut back through
//!   other sectors. Each tic the driver heads for the FURTHEST upcoming
//!   point it can really walk to in a straight line (no wall, no step or
//!   drop over 24, enough headroom, no damaging floor) whose sectors only
//!   move FORWARD along the route, else the next one. Without the forward
//!   rule a shortcut can climb back up the stair it just came down, and a
//!   fresh plan at the top sends it down again — a loop.
//! - Inside that, a local grid A* (agent_local) plans the real walkable
//!   path to the furthest route point within reach, so a sector that wraps
//!   round a stair is walked round, not climbed back over; the route
//!   look-ahead above is the fallback when no local path exists.
//! - Steering closes half the bearing error per tic, toward that point.
//! - Speed drops while the corner is off to the side and before a sharp
//!   turn, so momentum does not carry the player off a stair or a ledge.
//! - A solid thing (barrel, pillar, lamp) on the straight line to the next
//!   corner is passed on its far side via a detour point: the sector graph
//!   cannot see things, so without this the player pushes into them.
//! - Doors on the route and the exit switch at its end get a use press.
//! - No progress for a second blocks the portal it was heading through for
//!   a few seconds, backs off, and re-plans around it.

const std = @import("std");

const user = @import("play/user.zig");
const mobj_mod = @import("play/mobj.zig");
const setup = @import("play/setup.zig");
const fixed = @import("fixed.zig");
const defs = @import("defs.zig");
const agent_nav = @import("agent_nav.zig");
const funnel = @import("agent_funnel.zig");
const agent_local = @import("agent_local.zig");

const MapObject = mobj_mod.MapObject;

const RUN: i32 = 50;
const TURN_PER_DEG: f64 = 65536.0 / 360.0;
const MAX_SPANS = 96;
const MAX_CORNERS = 98;
/// A corner this close counts as reached.
const REACH: f64 = 20;
/// How many route points ahead the straight-walk check looks.
const LOOKAHEAD: usize = 8;
/// A local grid point this close counts as passed: it only marks the way,
/// unlike a doorway that must be gone through.
const LOCAL_REACH: f64 = 32;
/// Tics a local path is followed before it is planned again.
const LOCAL_TICS: u32 = 18;
/// How many local points ahead the straight-walk check looks.
const LOCAL_LOOKAHEAD: usize = 6;
/// Route points tried as the local goal, furthest first.
const LOCAL_TRIES: usize = 3;
const MAX_STEP: f64 = 24;
const PLAYER_HEIGHT: f64 = 56;
const REPLAN_TICS: u32 = 7;
/// Progress is checked over this window…
const WATCH_TICS: u32 = 35;
/// …and less movement than this while trying to move is stuck.
const STUCK_MOVED: f64 = 12;
const BLOCK_TICS: u32 = 140;
const BACKOFF_TICS: u32 = 12;
/// DOOM's use range is 64; door midpoints sit on the door line.
const USE_REACH: f64 = 72;
const USE_EVERY: u32 = 8;

/// A solid thing as a circle the player's centre must stay out of: its
/// radius plus the player's.
pub const Obstacle = struct { x: f64, y: f64, r: f64 };

/// Clearance kept beyond an obstacle's radius when going round it.
const DETOUR_MARGIN: f64 = 10;
/// Obstacles further along the line than this are left for later.
const AVOID_AHEAD: f64 = 128;

/// The point to head for instead of `target` when an obstacle sits on the
/// straight line to it: beside the nearest such obstacle — on the side the
/// line already leans to, unless a wall stands between the player and that
/// side (`walled` says), then the other. `target` itself when the way is clear.
pub fn detour(pos: funnel.Point, target: funnel.Point, obstacles: []const Obstacle, walled: anytype) funnel.Point {
    const dx = target[0] - pos[0];
    const dy = target[1] - pos[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-6) return target;
    const ux = dx / len;
    const uy = dy / len;
    var best: ?Obstacle = null;
    var best_along: f64 = std.math.inf(f64);
    for (obstacles) |o| {
        const ox = o.x - pos[0];
        const oy = o.y - pos[1];
        const along = ox * ux + oy * uy;
        if (along <= 0 or along > @min(len, AVOID_AHEAD) + o.r) continue;
        const across = ox * -uy + oy * ux; // + = obstacle left of the line
        if (@abs(across) >= o.r) continue;
        if (along < best_along) {
            best_along = along;
            best = o;
        }
    }
    const o = best orelse return target;
    const across = (o.x - pos[0]) * -uy + (o.y - pos[1]) * ux;
    // Obstacle left of the line → pass on its right, and vice versa.
    const side: f64 = if (across >= 0) -1 else 1;
    const off = o.r + DETOUR_MARGIN;
    const preferred: funnel.Point = .{ o.x + side * -uy * off, o.y + side * ux * off };
    if (!walled.blocked(pos, preferred)) return preferred;
    const other: funnel.Point = .{ o.x - side * -uy * off, o.y - side * ux * off };
    return if (walled.blocked(pos, other)) preferred else other;
}

/// Whether a straight walk between two points crosses a wall: a one-sided
/// line or one flagged as blocking.
pub const Walls = struct {
    level: *const setup.Level,

    pub fn blocked(self: Walls, a: funnel.Point, b: funnel.Point) bool {
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        for (self.level.lines) |*line| {
            if (line.sidenum[1] >= 0 and line.flags & defs.ML_BLOCKING == 0) continue;
            const v1 = self.level.vertices[line.v1];
            const v2 = self.level.vertices[line.v2];
            const lx = units(v1.x);
            const ly = units(v1.y);
            const fx = units(v2.x) - lx;
            const fy = units(v2.y) - ly;
            const den = ex * fy - ey * fx;
            if (@abs(den) < 1e-9) continue;
            const t = ((lx - a[0]) * fy - (ly - a[1]) * fx) / den;
            const u = ((lx - a[0]) * ey - (ly - a[1]) * ex) / den;
            if (t > 0 and t < 1 and u >= 0 and u <= 1) return true;
        }
        return false;
    }
};

/// The first place `sector` appears in the route's sector order.
fn routeIndex(order: []const u16, sector: ?usize) ?usize {
    const s = sector orelse return null;
    for (order, 0..) |o, i| if (o == s) return i;
    return null;
}

/// Whether the player can walk straight from `a` to `b`, starting on a floor
/// at height `floor`: no wall or blocking line, and at every two-sided line
/// crossed no step up or drop over 24, at least player-height headroom, and
/// no damaging floor beyond. Floors are followed line by line, so a stair
/// climbed one step at a time passes. Every sector entered must come at or
/// after the current one in the route's `order` (starting from index `at`).
pub fn walkable(level: *const setup.Level, a: funnel.Point, b: funnel.Point, floor: f64, order: []const u16, at: usize) bool {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    var hits: [64]struct { t: f64, line: *const setup.Line, front_first: bool } = undefined;
    var n: usize = 0;
    for (level.lines) |*line| {
        const v1 = level.vertices[line.v1];
        const v2 = level.vertices[line.v2];
        const lx = units(v1.x);
        const ly = units(v1.y);
        const fx = units(v2.x) - lx;
        const fy = units(v2.y) - ly;
        const den = ex * fy - ey * fx;
        if (@abs(den) < 1e-9) continue;
        const t = ((lx - a[0]) * fy - (ly - a[1]) * fx) / den;
        const u = ((lx - a[0]) * ey - (ly - a[1]) * ex) / den;
        if (t <= 0 or t >= 1 or u < 0 or u > 1) continue;
        if (line.sidenum[1] < 0 or line.flags & defs.ML_BLOCKING != 0) return false;
        if (n == hits.len) return false;
        // The front side is to the right of v1→v2.
        const right_of = fx * (a[1] - ly) - fy * (a[0] - lx) < 0;
        hits[n] = .{ .t = t, .line = line, .front_first = right_of };
        n += 1;
    }
    std.mem.sort(@TypeOf(hits[0]), hits[0..n], {}, struct {
        fn lt(_: void, x: @TypeOf(hits[0]), y: @TypeOf(hits[0])) bool {
            return x.t < y.t;
        }
    }.lt);
    var here = floor;
    var idx = at;
    for (hits[0..n]) |h| {
        const fi = h.line.frontsector orelse return false;
        const bi = h.line.backsector orelse return false;
        const to_i = if (h.front_first) bi else fi;
        // Forward along the route only: the entered sector must appear at
        // or after the current position in its order.
        var found: ?usize = null;
        for (order[idx..], idx..) |o, k| {
            if (o == to_i) {
                found = k;
                break;
            }
        }
        idx = found orelse return false;
        const to = &level.sectors[to_i];
        const other = &level.sectors[if (h.front_first) fi else bi];
        const next = units(to.floorheight);
        if (@abs(next - here) > MAX_STEP) return false;
        const top = @min(units(to.ceilingheight), units(other.ceilingheight));
        if (top - @max(next, here) < PLAYER_HEIGHT) return false;
        if (hurtsFloor(to.special)) return false;
        here = next;
    }
    return true;
}

fn hurtsFloor(special: i16) bool {
    return switch (special) {
        4, 5, 7, 11, 16 => true,
        else => false,
    };
}

/// For tests and callers with no level: nothing is walled.
pub const NoWalls = struct {
    pub fn blocked(_: NoWalls, _: funnel.Point, _: funnel.Point) bool {
        return false;
    }
};

pub const Drive = struct {
    goal: ?agent_nav.Goal = null,
    tic: u32 = 0,
    replan_in: u32 = 0,

    corners: [MAX_CORNERS]funnel.Point = undefined,
    n_corners: usize = 0,
    next: usize = 1,
    portals: [MAX_SPANS]u32 = undefined,
    n_portals: usize = 0,
    /// The route's sectors in order: where it starts, then each portal's far side.
    order: [MAX_SPANS + 1]u16 = undefined,

    local: agent_local.Path = .{},
    local_i: usize = 1,
    local_age: u32 = 0,
    /// The local path ends at the route's end point.
    local_final: bool = false,
    switch_end: bool = false,

    watch_x: f64 = 0,
    watch_y: f64 = 0,
    watch_left: u32 = WATCH_TICS,
    backoff: u32 = 0,
    back_side: i8 = 1,
    /// Tics since use was last pressed, so presses are separate presses.
    since_use: u32 = USE_EVERY,

    pub fn setGoal(self: *Drive, goal: ?agent_nav.Goal) void {
        const same = blk: {
            const a = self.goal orelse break :blk goal == null;
            const b = goal orelse break :blk false;
            break :blk switch (a) {
                .explore => b == .explore,
                .exit => b == .exit,
                .point => |p| b == .point and @abs(b.point[0] - p[0]) < 1 and @abs(b.point[1] - p[1]) < 1,
            };
        };
        if (same) return;
        self.goal = goal;
        self.replan_in = 0;
        self.n_corners = 0;
    }

    /// Steer this tic's command toward the goal. Leaves `cmd` alone with no
    /// goal. Fills forward, side, turn and the use button.
    pub fn steer(self: *Drive, nav: *agent_nav.Nav, level: *const setup.Level, pmo: *const MapObject, obstacles: []const Obstacle, cmd: *user.TicCmd) void {
        const goal = self.goal orelse return;
        self.tic += 1;
        self.since_use +|= 1;
        nav.now = self.tic;
        const pos: funnel.Point = .{ units(pmo.x), units(pmo.y) };

        if (self.backoff > 0) {
            self.backoff -= 1;
            cmd.forwardmove = -RUN / 2;
            cmd.sidemove = @as(i8, self.back_side) * 24;
            cmd.angleturn = 0;
            return;
        }

        if (self.replan_in == 0 or self.n_corners == 0) {
            self.replan(nav, level, pmo, goal, pos);
            self.replan_in = REPLAN_TICS;
        } else self.replan_in -= 1;
        if (self.n_corners < 2) {
            cmd.forwardmove = 0;
            cmd.angleturn = 0;
            return;
        }

        while (self.next < self.n_corners - 1 and dist(pos, self.corners[self.next]) < REACH) self.next += 1;
        const floor = units(pmo.floorz);

        // The local walkable path, refreshed every so often or when used up.
        if (self.local_age == 0 or self.local_i >= self.local.n) {
            self.planLocal(level, pos, floor);
            self.local_age = LOCAL_TICS;
        } else self.local_age -= 1;

        var target: funnel.Point = undefined;
        var after: ?funnel.Point = null;
        var final_leg = false;
        if (self.local.n >= 2) {
            while (self.local_i < self.local.n - 1 and dist(pos, self.local.pts[self.local_i]) < LOCAL_REACH) self.local_i += 1;
            var aim = self.local_i;
            var j = @min(self.local_i + LOCAL_LOOKAHEAD, self.local.n - 1);
            while (j > self.local_i) : (j -= 1) {
                if (agent_local.straightAll(level, pos, self.local.pts[j], floor)) {
                    aim = j;
                    break;
                }
            }
            self.local_i = aim;
            target = self.local.pts[aim];
            if (aim + 1 < self.local.n) after = self.local.pts[aim + 1];
            final_leg = self.local_final and aim == self.local.n - 1;
        } else {
            // Fallback: the furthest route point a straight walk reaches
            // while only moving forward along the route.
            const order = self.order[0 .. self.n_portals + 1];
            const here = routeIndex(order, agent_nav.sectorAt(level, pos[0], pos[1]));
            var aim = self.next;
            var j = @min(self.next + LOOKAHEAD, self.n_corners - 1);
            while (j > self.next) : (j -= 1) {
                if (here != null and walkable(level, pos, self.corners[j], floor, order, here.?)) {
                    aim = j;
                    break;
                }
            }
            self.next = aim;
            target = self.corners[aim];
            if (aim + 1 < self.n_corners) after = self.corners[aim + 1];
            final_leg = aim == self.n_corners - 1;
        }
        const to_target = dist(pos, target);
        const b = bearingTo(pmo, detour(pos, target, obstacles, Walls{ .level = level }));
        cmd.angleturn = @intFromFloat(std.math.clamp(b * TURN_PER_DEG * 0.5, -1280, 1280));
        cmd.sidemove = 0;

        var fwd: i32 = RUN;
        const off = @abs(b);
        if (off > 60) {
            fwd = 0;
        } else if (off > 30) {
            fwd = 15;
        } else if (off > 15) {
            fwd = 30;
        }
        // Ease off before a sharp turn at the coming corner.
        if (after) |nxt| {
            if (to_target < 96) {
                const turn = angleBetween(target[0] - pos[0], target[1] - pos[1], nxt[0] - target[0], nxt[1] - target[1]);
                if (turn > 45) fwd = @min(fwd, 25);
            }
        }
        // Arriving: do not overshoot the end point.
        if (final_leg and to_target < 64) fwd = @min(fwd, 25);
        cmd.forwardmove = @intCast(fwd);

        // Doors on the next stretch of route, and the exit switch at its end.
        var want_use = false;
        for (self.portals[0..@min(self.n_portals, 2)]) |pi| {
            if (nav.portalIsClosedDoor(level, pi) and dist(pos, nav.portalMid(pi)) < USE_REACH) want_use = true;
        }
        if (self.switch_end and dist(pos, self.corners[self.n_corners - 1]) < USE_REACH) want_use = true;
        cmd.buttons &= ~@as(u8, user.BT_USE);
        if (want_use and self.since_use >= USE_EVERY) {
            cmd.buttons |= user.BT_USE;
            self.since_use = 0;
        }

        // Stuck: no progress over the window while trying to move.
        if (self.watch_left == 0) {
            const moved = dist(pos, .{ self.watch_x, self.watch_y });
            if (moved < STUCK_MOVED and fwd > 0) {
                if (self.n_portals > 0) nav.block(self.portals[0], self.tic + BLOCK_TICS);
                self.backoff = BACKOFF_TICS;
                self.back_side = -self.back_side;
                self.replan_in = 0;
                self.local_age = 0;
            }
            self.watch_x = pos[0];
            self.watch_y = pos[1];
            self.watch_left = WATCH_TICS;
        } else self.watch_left -= 1;
    }

    fn replan(self: *Drive, nav: *agent_nav.Nav, level: *const setup.Level, pmo: *const MapObject, goal: agent_nav.Goal, pos: funnel.Point) void {
        var spans: [MAX_SPANS]funnel.Span = undefined;
        // A block may make a route longer, never impossible: with no route
        // while any portal is blocked, lift the blocks and plan again.
        const r = nav.route(level, pmo, goal, &spans, &self.portals) orelse retry: {
            if (nav.clearBlocks()) {
                if (nav.route(level, pmo, goal, &spans, &self.portals)) |again| break :retry again;
            }
            self.n_corners = 0;
            self.n_portals = 0;
            return;
        };
        self.n_portals = r.spans;
        self.switch_end = r.switch_;
        self.order[0] = @intCast(agent_nav.sectorAt(level, pos[0], pos[1]) orelse 0);
        for (self.portals[0..r.spans], 0..) |pi, i| self.order[i + 1] = nav.portalTo(pi);
        self.n_corners = funnel.crossings(pos, spans[0..r.spans], r.end, &self.corners);
        self.local_age = 0;
        self.next = 1;
    }

    /// Plan the local path toward the furthest route point in reach that
    /// has one, trying a few, furthest first.
    fn planLocal(self: *Drive, level: *const setup.Level, pos: funnel.Point, floor: f64) void {
        self.local.n = 0;
        self.local_i = 1;
        if (self.n_corners < 2) return;
        var tries: usize = 0;
        var j = self.n_corners - 1;
        while (j >= self.next and tries < LOCAL_TRIES) : (j -= 1) {
            const g = self.corners[j];
            if (@abs(g[0] - pos[0]) < 960 and @abs(g[1] - pos[1]) < 960) {
                tries += 1;
                if (agent_local.plan(level, pos, floor, g, &self.local)) {
                    self.local_final = j == self.n_corners - 1;
                    return;
                }
            }
            if (j == 0) break;
        }
        self.local.n = 0;
    }

    /// Where the driver currently heads, for the state line.
    pub fn heading(self: *const Drive) ?funnel.Point {
        if (self.goal == null or self.n_corners < 2) return null;
        if (self.local.n >= 2) return self.local.pts[@min(self.local_i, self.local.n - 1)];
        return self.corners[@min(self.next, self.n_corners - 1)];
    }
};

fn units(v: fixed.Fixed) f64 {
    return @as(f64, @floatFromInt(v.raw())) / 65536.0;
}

fn dist(a: funnel.Point, b: funnel.Point) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

/// Degrees from where `from` faces to `p`, positive = left.
fn bearingTo(from: *const MapObject, p: funnel.Point) f64 {
    const facing = @as(f64, @floatFromInt(from.angle)) / 4294967296.0 * 360.0;
    var d = std.math.atan2(p[1] - units(from.y), p[0] - units(from.x)) * 180.0 / std.math.pi - facing;
    while (d > 180) d -= 360;
    while (d < -180) d += 360;
    return d;
}

/// The unsigned angle in degrees between two direction vectors.
fn angleBetween(ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const la = std.math.hypot(ax, ay);
    const lb = std.math.hypot(bx, by);
    if (la < 1e-6 or lb < 1e-6) return 0;
    const c = std.math.clamp((ax * bx + ay * by) / (la * lb), -1.0, 1.0);
    return std.math.acos(c) * 180.0 / std.math.pi;
}

test "goal changes reset the route; repeating a goal does not" {
    var d = Drive{};
    d.setGoal(.explore);
    d.n_corners = 5;
    d.setGoal(.explore);
    try std.testing.expectEqual(@as(usize, 5), d.n_corners);
    d.setGoal(.exit);
    try std.testing.expectEqual(@as(usize, 0), d.n_corners);
    d.n_corners = 3;
    d.setGoal(.{ .point = .{ 10, 20 } });
    try std.testing.expectEqual(@as(usize, 0), d.n_corners);
    d.n_corners = 3;
    d.setGoal(.{ .point = .{ 10.2, 20 } });
    try std.testing.expectEqual(@as(usize, 3), d.n_corners);
    d.setGoal(null);
    try std.testing.expect(d.goal == null);
}

test "a barrel on the line is passed on the side the line leans to" {
    const barrel = [_]Obstacle{.{ .x = 50, .y = 5, .r = 26 }};
    // Barrel slightly left of the line → go right of it (negative y).
    const d = detour(.{ 0, 0 }, .{ 200, 0 }, &barrel, NoWalls{});
    try std.testing.expect(d[1] < -20 and @abs(d[0] - 50) < 1e-9);
    // Clear when it is off the line, behind, or beyond the look-ahead.
    const aside = [_]Obstacle{.{ .x = 50, .y = 40, .r = 26 }};
    try std.testing.expectEqual(funnel.Point{ 200, 0 }, detour(.{ 0, 0 }, .{ 200, 0 }, &aside, NoWalls{}));
    const behind = [_]Obstacle{.{ .x = -50, .y = 0, .r = 26 }};
    try std.testing.expectEqual(funnel.Point{ 200, 0 }, detour(.{ 0, 0 }, .{ 200, 0 }, &behind, NoWalls{}));
    const far = [_]Obstacle{.{ .x = 400, .y = 0, .r = 26 }};
    try std.testing.expectEqual(funnel.Point{ 600, 0 }, detour(.{ 0, 0 }, .{ 600, 0 }, &far, NoWalls{}));
}

test "a walled side is avoided" {
    const barrel = [_]Obstacle{.{ .x = 50, .y = 5, .r = 26 }};
    const RightWalled = struct {
        pub fn blocked(_: @This(), _: funnel.Point, p: funnel.Point) bool {
            return p[1] < 0;
        }
    };
    const d = detour(.{ 0, 0 }, .{ 200, 0 }, &barrel, RightWalled{});
    try std.testing.expect(d[1] > 20);
}

test "corner sharpness" {
    try std.testing.expect(@abs(angleBetween(1, 0, 0, 1) - 90) < 1e-9);
    try std.testing.expect(angleBetween(1, 0, 1, 0) < 1e-9);
}
