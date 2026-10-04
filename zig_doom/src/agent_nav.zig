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

const Level = setup.Level;
const MapObject = mobj_mod.MapObject;

const PLAYER_HEIGHT: f64 = 56;
const MAX_STEP: f64 = 24;
/// Extra cost of a door: opening it takes time.
const DOOR_COST: f64 = 128;
/// Extra cost of entering a damaging floor (nukage, lava).
const HURT_COST: f64 = 512;

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
            const span = .{ .x1 = units(v1.x), .y1 = units(v1.y), .x2 = units(v2.x), .y2 = units(v2.y) };
            try portals.append(self.alloc, .{ .a = f, .b = b, .line = @intCast(i), .mx = mid[0], .my = mid[1], .x1 = span.x1, .y1 = span.y1, .x2 = span.x2, .y2 = span.y2 });
            try portals.append(self.alloc, .{ .a = b, .b = f, .line = @intCast(i), .mx = mid[0], .my = mid[1], .x1 = span.x1, .y1 = span.y1, .x2 = span.x2, .y2 = span.y2 });
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
        self.goal = null;
        self.level_key = key;
    }

    /// Note the sector the player stands in. Called every tic.
    pub fn markVisited(self: *Nav, level: *const Level, pmo: *const MapObject) void {
        self.ensure(level) catch return;
        if (sectorOf(level, pmo)) |s| self.visited[s] = true;
    }

    pub fn plan(self: *Nav, level: *const Level, pmo: *const MapObject) ?Plan {
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

        var seen: usize = 0;
        var nearest: ?usize = null;
        for (0..n) |s| {
            if (self.visited[s]) {
                seen += 1;
                continue;
            }
            if (self.dist[s] == std.math.inf(f64)) continue;
            if (nearest == null or self.dist[s] < self.dist[nearest.?]) nearest = s;
        }
        // Keep the current goal while it is still unvisited and reachable;
        // switch only for one less than half as far.
        if (self.goal) |g| {
            const live = g < n and !self.visited[g] and self.dist[g] != std.math.inf(f64);
            if (!live) self.goal = null;
        }
        if (nearest) |near| {
            if (self.goal == null or self.dist[near] < 0.5 * self.dist[self.goal.?]) self.goal = near;
        }
        const explore_target = self.goal;

        var exit_wp: ?Waypoint = null;
        for (self.exits) |e| {
            if (self.dist[e.sector] == std.math.inf(f64)) continue;
            const total = self.dist[e.sector] + std.math.hypot(e.mx - self.entry_x[e.sector], e.my - self.entry_y[e.sector]);
            if (exit_wp != null and total >= exit_wp.?.dist) continue;
            var wp = self.waypoint(level, start, e.sector, e.mx, e.my, total);
            wp.switch_ = e.switch_;
            exit_wp = wp;
        }

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

/// The sector `mo` stands in, located through the BSP tree (the port does
/// not keep `subsector_id` current for moving things).
fn sectorOf(level: *const Level, mo: *const MapObject) ?usize {
    var ssi: usize = 0;
    if (level.num_nodes > 0) {
        var node_id: u16 = level.num_nodes - 1;
        while (node_id & defs.NF_SUBSECTOR == 0) {
            if (node_id >= level.nodes.len) return null;
            const node = &level.nodes[node_id];
            const dx: i64 = mo.x.raw() -% node.x.raw();
            const dy: i64 = mo.y.raw() -% node.y.raw();
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
