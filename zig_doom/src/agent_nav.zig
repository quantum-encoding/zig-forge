//! zig_doom/src/agent_nav.zig
//!
//! Route-finding for agent mode, over the level's sector graph.
//!
//! Nodes are sectors; edges are portals — two-sided linedefs the player can
//! walk through from one side to the other. Which portals exist is read
//! once per level; whether each is passable is re-checked on every plan
//! against the sectors' current heights, because doors and lifts move. A
//! closed door the player can open by pressing use counts as passable, at a
//! cost, and is flagged so the controller knows to press it.
//!
//! A plan is a Dijkstra from the player's position. Each sector remembers
//! the point it was entered at, so a path's length is the walk from portal
//! midpoint to portal midpoint rather than between sector centres. Two
//! answers come out: the nearest sector not yet stood in (exploring), and
//! the level exit (a switch to use, or a line to walk over). Each is given
//! as its FIRST hop — the portal to head for now — plus the whole distance.

const std = @import("std");

const defs = @import("defs.zig");
const fixed = @import("fixed.zig");
const setup = @import("play/setup.zig");
const mobj_mod = @import("play/mobj.zig");
const maputl = @import("play/maputl.zig");
const funnel = @import("agent_funnel.zig");

const Level = setup.Level;
const MapObject = mobj_mod.MapObject;

const PLAYER_HEIGHT: f64 = 56;
const MAX_STEP: f64 = 24;
/// Extra cost of a door: opening it takes time.
const DOOR_COST: f64 = 128;
/// Extra cost of entering a damaging floor (nukage, lava).
const HURT_COST: f64 = 512;
/// Extra cost of stepping off a ledge too high to climb back: allowed, but
/// only when nothing else gets there.
const DROP_COST: f64 = 384;
const PLAYER_RADIUS: f64 = 16;
/// How far past a doorway an explore route ends, so arriving puts the
/// player inside the new sector rather than on its threshold.
const STEP_INSIDE: f64 = 40;

const Portal = struct {
    a: u16,
    b: u16,
    line: u32,
    mx: f64,
    my: f64,
    /// The line's endpoints, so a first hop can aim anywhere along it.
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
};

const Exit = struct {
    sector: u16,
    mx: f64,
    my: f64,
    switch_: bool,
};

pub const Waypoint = struct {
    /// Where to head now: the first portal's midpoint, or the target itself.
    x: f64,
    y: f64,
    /// The first portal's span (equal to x,y when the target is in reach);
    /// the bridge picks a point along it with a clear straight line.
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    /// Walking distance along the whole route.
    dist: f64,
    /// The first hop is a door to open.
    door: bool,
    /// The target is a switch to press (the exit kind).
    switch_: bool = false,
};

/// Where a route goes.
pub const Goal = union(enum) {
    /// The nearest sector not yet visited.
    explore,
    /// The level exit.
    exit,
    /// A map point (an item, a monster's position).
    point: [2]f64,
};

pub const Route = struct {
    /// How many funnel spans the route crosses.
    spans: usize,
    end: funnel.Point,
    /// The route ends at a switch to press.
    switch_: bool,
};

pub const Plan = struct {
    explore: ?Waypoint,
    exit: ?Waypoint,
    seen: usize,
    sectors: usize,
};

pub const Nav = struct {
    alloc: std.mem.Allocator,
    level_key: usize = 0,
    portals: []Portal = &.{},
    exits: []Exit = &.{},
    visited: []bool = &.{},
    dist: []f64 = &.{},
    entry_x: []f64 = &.{},
    entry_y: []f64 = &.{},
    /// The portal a sector was reached through; -1 for none.
    via: []i32 = &.{},
    /// The unvisited sector exploring is heading for. Held until reached or
    /// cut off, so two similar targets cannot swap places every plan and
    /// turn the player back and forth between them.
    goal: ?usize = null,
    /// Per portal: the tic until which a route may not use it (set when
    /// the player got stuck there).
    blocked_until: []u32 = &.{},
    /// The current tic, for `blocked_until`.
    now: u32 = 0,
    done: []bool = &.{},

    pub fn init(alloc: std.mem.Allocator) Nav {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Nav) void {
        self.release();
    }

    fn release(self: *Nav) void {
        if (self.level_key == 0) return;
        self.alloc.free(self.portals);
        self.alloc.free(self.exits);
        self.alloc.free(self.visited);
        self.alloc.free(self.dist);
        self.alloc.free(self.entry_x);
        self.alloc.free(self.entry_y);
        self.alloc.free(self.via);
        self.alloc.free(self.done);
        self.alloc.free(self.blocked_until);
        self.level_key = 0;
    }

    /// Rebuild the topology when the level changes.
    fn ensure(self: *Nav, level: *const Level) !void {
        const key = @intFromPtr(level.lines.ptr) ^ level.lines.len;
        if (key == self.level_key) return;
        self.release();
        const n = level.sectors.len;
        var portals: std.ArrayList(Portal) = .empty;
        defer portals.deinit(self.alloc);
        var exits: std.ArrayList(Exit) = .empty;
        defer exits.deinit(self.alloc);
        for (level.lines, 0..) |*line, i| {
            const mid = midpoint(level, line);
            const front = line.frontsector;
            const back = line.backsector;
            if (isExit(line.special)) |is_switch| {
                if (front) |f| {
                    try exits.append(self.alloc, .{ .sector = f, .mx = mid[0], .my = mid[1], .switch_ = is_switch });
                }
                // A walk-over exit works from either side.
                if (!is_switch) {
                    if (back) |b| try exits.append(self.alloc, .{ .sector = b, .mx = mid[0], .my = mid[1], .switch_ = false });
                }
            }
            if (line.sidenum[1] < 0) continue;
            const f = front orelse continue;
            const b = back orelse continue;
            if (f == b) continue;
            const v1 = level.vertices[line.v1];
            const v2 = level.vertices[line.v2];
            const ends = .{ .x1 = units(v1.x), .y1 = units(v1.y), .x2 = units(v2.x), .y2 = units(v2.y) };
            try portals.append(self.alloc, .{ .a = f, .b = b, .line = @intCast(i), .mx = mid[0], .my = mid[1], .x1 = ends.x1, .y1 = ends.y1, .x2 = ends.x2, .y2 = ends.y2 });
            try portals.append(self.alloc, .{ .a = b, .b = f, .line = @intCast(i), .mx = mid[0], .my = mid[1], .x1 = ends.x1, .y1 = ends.y1, .x2 = ends.x2, .y2 = ends.y2 });
        }
        self.portals = try portals.toOwnedSlice(self.alloc);
        self.exits = try exits.toOwnedSlice(self.alloc);
        self.visited = try self.alloc.alloc(bool, n);
        @memset(self.visited, false);
        self.dist = try self.alloc.alloc(f64, n);
        self.entry_x = try self.alloc.alloc(f64, n);
        self.entry_y = try self.alloc.alloc(f64, n);
        self.via = try self.alloc.alloc(i32, n);
        self.done = try self.alloc.alloc(bool, n);
        self.blocked_until = try self.alloc.alloc(u32, self.portals.len);
        @memset(self.blocked_until, 0);
        self.goal = null;
        self.level_key = key;
    }

    /// Note the sector the player stands in. Called every tic.
    pub fn markVisited(self: *Nav, level: *const Level, pmo: *const MapObject) void {
        self.ensure(level) catch return;
        if (sectorOf(level, pmo)) |s| self.visited[s] = true;
    }

    /// Dijkstra over the portal graph from where `pmo` stands. Returns the
    /// start sector; distances and `via` chains are left in place.
    fn search(self: *Nav, level: *const Level, pmo: *const MapObject) ?usize {
        self.ensure(level) catch return null;
        const start = sectorOf(level, pmo) orelse return null;
        self.visited[start] = true;
        const n = level.sectors.len;
        @memset(self.dist, std.math.inf(f64));
        @memset(self.via, -1);
        @memset(self.done, false);
        const px = units(pmo.x);
        const py = units(pmo.y);
        self.dist[start] = 0;
        self.entry_x[start] = px;
        self.entry_y[start] = py;

        // Dense Dijkstra: a few hundred sectors, re-planned a few times a second.
        while (true) {
            var u: ?usize = null;
            for (0..n) |s| {
                if (!self.done[s] and self.dist[s] != std.math.inf(f64) and (u == null or self.dist[s] < self.dist[u.?])) u = s;
            }
            const cur = u orelse break;
            self.done[cur] = true;
            for (self.portals, 0..) |p, pi| {
                if (p.a != cur or self.done[p.b]) continue;
                if (self.blocked_until[pi] > self.now) continue;
                const step = passCost(level, p) orelse continue;
                const d = self.dist[cur] + std.math.hypot(p.mx - self.entry_x[cur], p.my - self.entry_y[cur]) + step;
                if (d < self.dist[p.b]) {
                    self.dist[p.b] = d;
                    self.entry_x[p.b] = p.mx;
                    self.entry_y[p.b] = p.my;
                    self.via[p.b] = @intCast(pi);
                }
            }
        }
        return start;
    }

    pub fn plan(self: *Nav, level: *const Level, pmo: *const MapObject) ?Plan {
        const start = self.search(level, pmo) orelse return null;
        const n = level.sectors.len;
        const explore_target = self.exploreGoal(n);

        var exit_wp: ?Waypoint = null;
        for (self.exits) |e| {
            if (self.dist[e.sector] == std.math.inf(f64)) continue;
            const total = self.dist[e.sector] + std.math.hypot(e.mx - self.entry_x[e.sector], e.my - self.entry_y[e.sector]);
            if (exit_wp != null and total >= exit_wp.?.dist) continue;
            var wp = self.waypoint(level, start, e.sector, e.mx, e.my, total);
            wp.switch_ = e.switch_;
            exit_wp = wp;
        }

        var seen: usize = 0;
        for (self.visited) |v| seen += @intFromBool(v);
        return .{
            .explore = if (explore_target) |t|
                self.waypoint(level, start, t, self.entry_x[t], self.entry_y[t], self.dist[t])
            else
                null,
            .exit = exit_wp,
            .seen = seen,
            .sectors = n,
        };
    }

    /// The sticky explore goal after a `search`: the nearest unvisited
    /// reachable sector, kept until reached or cut off unless a new one is
    /// under half as far.
    fn exploreGoal(self: *Nav, n: usize) ?usize {
        var nearest: ?usize = null;
        for (0..n) |s| {
            if (self.visited[s] or self.dist[s] == std.math.inf(f64)) continue;
            if (nearest == null or self.dist[s] < self.dist[nearest.?]) nearest = s;
        }
        if (self.goal) |g| {
            const live = g < n and !self.visited[g] and self.dist[g] != std.math.inf(f64);
            if (!live) self.goal = null;
        }
        if (nearest) |near| {
            if (self.goal == null or self.dist[near] < 0.5 * self.dist[self.goal.?]) self.goal = near;
        }
        return self.goal;
    }

    /// A whole route for the driver: the portal chain from where `pmo`
    /// stands to the goal, as funnel spans narrowed by the player's radius,
    /// plus the end point. `portals` receives the chain's portal indices.
    pub fn route(
        self: *Nav,
        level: *const Level,
        pmo: *const MapObject,
        goal: Goal,
        spans: []funnel.Span,
        portals: []u32,
    ) ?Route {
        const start = self.search(level, pmo) orelse return null;
        const n = level.sectors.len;
        var target: usize = undefined;
        var end: funnel.Point = undefined;
        var switch_ = false;
        var step_in = false;
        switch (goal) {
            .explore => {
                target = self.exploreGoal(n) orelse return null;
                end = .{ self.entry_x[target], self.entry_y[target] };
                step_in = true;
            },
            .exit => {
                var best: ?Exit = null;
                var best_d = std.math.inf(f64);
                for (self.exits) |e| {
                    if (self.dist[e.sector] == std.math.inf(f64)) continue;
                    const d = self.dist[e.sector] + std.math.hypot(e.mx - self.entry_x[e.sector], e.my - self.entry_y[e.sector]);
                    if (d < best_d) {
                        best_d = d;
                        best = e;
                    }
                }
                const e = best orelse return null;
                target = e.sector;
                end = .{ e.mx, e.my };
                switch_ = e.switch_;
            },
            .point => |pt| {
                target = sectorAt(level, pt[0], pt[1]) orelse return null;
                if (self.dist[target] == std.math.inf(f64)) return null;
                end = pt;
            },
        }

        // The chain, target back to start, then reversed.
        var count: usize = 0;
        var s = target;
        while (s != start and self.via[s] >= 0 and count < portals.len) {
            const pi: u32 = @intCast(self.via[s]);
            portals[count] = pi;
            count += 1;
            s = self.portals[pi].a;
        }
        if (s != start) return null;
        std.mem.reverse(u32, portals[0..count]);
        const n_spans = @min(count, spans.len);
        for (portals[0..n_spans], 0..) |pi, i| spans[i] = self.span(level, pi);

        if (step_in and count > 0) {
            // Past the last doorway, into the target sector.
            const last = self.span(level, portals[count - 1]);
            const dx = last.right[0] - last.left[0];
            const dy = last.right[1] - last.left[1];
            const len = @max(std.math.hypot(dx, dy), 1e-6);
            // Walking through, left→right points to the walker's right, so
            // the way in is that turned 90° left.
            end = .{ end[0] - dy / len * STEP_INSIDE, end[1] + dx / len * STEP_INSIDE };
        }
        return .{ .spans = n_spans, .end = end, .switch_ = switch_ };
    }

    /// A portal as a funnel span, oriented for walking from `a` to `b` and
    /// narrowed by the player's radius at each end.
    fn span(self: *Nav, level: *const Level, pi: u32) funnel.Span {
        const p = self.portals[pi];
        // The front side lies to the right of v1→v2; walking front→back,
        // v1 is on the walker's left.
        const from_front = level.lines[p.line].frontsector == p.a;
        var left: funnel.Point = if (from_front) .{ p.x1, p.y1 } else .{ p.x2, p.y2 };
        var right: funnel.Point = if (from_front) .{ p.x2, p.y2 } else .{ p.x1, p.y1 };
        const dx = right[0] - left[0];
        const dy = right[1] - left[1];
        const len = std.math.hypot(dx, dy);
        if (len <= 2 * PLAYER_RADIUS) {
            const mid: funnel.Point = .{ p.mx, p.my };
            return .{ .left = mid, .right = mid };
        }
        const ux = dx / len * PLAYER_RADIUS;
        const uy = dy / len * PLAYER_RADIUS;
        left = .{ left[0] + ux, left[1] + uy };
        right = .{ right[0] - ux, right[1] - uy };
        return .{ .left = left, .right = right };
    }

    /// Whether the door at portal `pi` is at rest: no mover on either side.
    /// A DOOM door that is moving reverses when used again, so a press while
    /// one is opening would shut it.
    pub fn portalDoorIdle(self: *Nav, level: *const Level, pi: u32) bool {
        const p = self.portals[pi];
        return level.sectors[p.a].ceilingdata == null and level.sectors[p.b].ceilingdata == null;
    }

    /// Whether crossing portal `pi` means opening a closed door first.
    pub fn portalIsClosedDoor(self: *Nav, level: *const Level, pi: u32) bool {
        return isClosedDoor(level, self.portals[pi]);
    }

    /// The sector a portal leads into.
    pub fn portalTo(self: *Nav, pi: u32) u16 {
        return self.portals[pi].b;
    }

    pub fn portalMid(self: *Nav, pi: u32) funnel.Point {
        return .{ self.portals[pi].mx, self.portals[pi].my };
    }

    /// Keep routes off portal `pi` until tic `until` (it could not be crossed).
    pub fn block(self: *Nav, pi: u32, until: u32) void {
        if (pi < self.blocked_until.len) self.blocked_until[pi] = until;
    }

    /// Lift every block; true when any was in force.
    pub fn clearBlocks(self: *Nav) bool {
        var any = false;
        for (self.blocked_until) |*b| {
            if (b.* > self.now) any = true;
            b.* = 0;
        }
        return any;
    }

    /// The first hop toward `target`: walk the `via` chain back to the
    /// portal that leaves the start sector.
    fn waypoint(self: *Nav, level: *const Level, start: usize, target: usize, tx: f64, ty: f64, total: f64) Waypoint {
        const here = Waypoint{ .x = tx, .y = ty, .x1 = tx, .y1 = ty, .x2 = tx, .y2 = ty, .dist = total, .door = false };
        if (target == start) return here;
        var s = target;
        var first: ?Portal = null;
        while (self.via[s] >= 0) {
            const p = self.portals[@intCast(self.via[s])];
            first = p;
            if (p.a == start) break;
            s = p.a;
        }
        const p = first orelse return here;
        return .{ .x = p.mx, .y = p.my, .x1 = p.x1, .y1 = p.y1, .x2 = p.x2, .y2 = p.y2, .dist = total, .door = isClosedDoor(level, p) };
    }
};

/// Walk cost added for crossing `p`, or null when it cannot be crossed now.
fn passCost(level: *const Level, p: Portal) ?f64 {
    const line = &level.lines[p.line];
    if (line.flags & defs.ML_BLOCKING != 0) return null;
    const from = &level.sectors[p.a];
    const to = &level.sectors[p.b];
    const step = units(to.floorheight) - units(from.floorheight);
    if (step > MAX_STEP) return null;
    var cost: f64 = 0;
    if (step < -MAX_STEP) cost += DROP_COST;
    if (hurts(to.special)) cost += HURT_COST;
    const top = @min(units(from.ceilingheight), units(to.ceilingheight));
    const bottom = @max(units(from.floorheight), units(to.floorheight));
    if (top - bottom >= PLAYER_HEIGHT) return cost;
    // Too low to pass: only a door the player can open is a way through.
    return if (isManualDoor(line.special)) cost + DOOR_COST else null;
}

fn isClosedDoor(level: *const Level, p: Portal) bool {
    const line = &level.lines[p.line];
    if (!isManualDoor(line.special)) return false;
    const from = &level.sectors[p.a];
    const to = &level.sectors[p.b];
    const top = @min(units(from.ceilingheight), units(to.ceilingheight));
    const bottom = @max(units(from.floorheight), units(to.floorheight));
    return top - bottom < PLAYER_HEIGHT;
}

/// Doors opened by pressing use on the door line itself (DR/D1, any key).
fn isManualDoor(special: i16) bool {
    return switch (special) {
        1, 26, 27, 28, 31, 32, 33, 34, 117, 118 => true,
        else => false,
    };
}

/// Exit lines: `true` for a switch (11 exit, 51 secret exit), `false` for a
/// line crossed on foot (52 exit, 124 secret exit), null otherwise.
fn isExit(special: i16) ?bool {
    return switch (special) {
        11, 51 => true,
        52, 124 => false,
        else => null,
    };
}

/// Floors that damage: nukage, slime, lava and their blinking variants.
fn hurts(special: i16) bool {
    return switch (special) {
        4, 5, 7, 11, 16 => true,
        else => false,
    };
}

/// The sector `mo` stands in.
fn sectorOf(level: *const Level, mo: *const MapObject) ?usize {
    return sectorAt(level, units(mo.x), units(mo.y));
}

/// The sector containing a map point, located through the BSP tree (the
/// port does not keep `subsector_id` current for moving things).
pub fn sectorAt(level: *const Level, x: f64, y: f64) ?usize {
    const fx: i64 = @intFromFloat(x * 65536.0);
    const fy: i64 = @intFromFloat(y * 65536.0);
    var ssi: usize = 0;
    if (level.num_nodes > 0) {
        var node_id: u16 = level.num_nodes - 1;
        while (node_id & defs.NF_SUBSECTOR == 0) {
            if (node_id >= level.nodes.len) return null;
            const node = &level.nodes[node_id];
            const dx: i64 = fx - node.x.raw();
            const dy: i64 = fy - node.y.raw();
            const left: i64 = @as(i64, node.dy.raw()) * dx;
            const right: i64 = dy * @as(i64, node.dx.raw());
            node_id = node.children[if (right < left) 0 else 1];
        }
        ssi = node_id & ~defs.NF_SUBSECTOR;
    }
    if (ssi >= level.subsectors.len) return null;
    const s = level.subsectors[ssi].sector orelse return null;
    return if (s < level.sectors.len) s else null;
}

fn midpoint(level: *const Level, line: *const setup.Line) [2]f64 {
    const v1 = level.vertices[line.v1];
    const v2 = level.vertices[line.v2];
    return .{ (units(v1.x) + units(v2.x)) / 2, (units(v1.y) + units(v2.y)) / 2 };
}

fn units(v: fixed.Fixed) f64 {
    return @as(f64, @floatFromInt(v.raw())) / 65536.0;
}

test "exit and door specials" {
    try std.testing.expectEqual(@as(?bool, true), isExit(11));
    try std.testing.expectEqual(@as(?bool, false), isExit(52));
    try std.testing.expectEqual(@as(?bool, null), isExit(1));
    try std.testing.expect(isManualDoor(1) and isManualDoor(26) and !isManualDoor(11));
}
