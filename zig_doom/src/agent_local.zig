//! zig_doom/src/agent_local.zig
//!
//! Local path planning for agent mode: A* on a grid of 32-unit cells in a
//! window around the player. The sector route says which doorways and steps
//! to take; this finds the actual walkable path to them through sectors of
//! any shape — DOOM's are not convex, so the straight line between two route
//! points can climb a stair it should walk round.
//!
//! A cell is usable when its centre lies in a sector with player headroom
//! and no damaging floor, at least CLEARANCE from any wall or impassable
//! edge — a centre the player's 16-unit body cannot reach would be circled
//! forever (the start cell is exempt, so a player already in nukage or
//! against a wall can plan out). Moving between neighbouring cells must be a
//! straight walk: no wall or blocking line, and no step up or drop over 24
//! at any line crossed, with headroom. Only lines near the window are
//! tested, which keeps a plan to a few milliseconds.

const std = @import("std");

const defs = @import("defs.zig");
const fixed = @import("fixed.zig");
const setup = @import("play/setup.zig");
const agent_nav = @import("agent_nav.zig");

pub const Point = [2]f64;

const CELL: f64 = 32;
const GRID: usize = 64;
const CELLS: usize = GRID * GRID;
const WINDOW: f64 = CELL * @as(f64, @floatFromInt(GRID)) / 2.0;
const MAX_STEP: f64 = 24;
/// Distance a cell centre keeps from walls: the player's radius plus room.
const CLEARANCE: f64 = 24;
const PLAYER_HEIGHT: f64 = 56;
const MAX_LINES = 1024;
pub const MAX_POINTS = 256;

/// A planned local path, start to goal.
pub const Path = struct {
    pts: [MAX_POINTS]Point = undefined,
    n: usize = 0,
};

/// Lines near the window, tested instead of the whole level.
const Nearby = struct {
    ids: [MAX_LINES]u32 = undefined,
    n: usize = 0,

    /// Lines whose bounding box meets the segment's.
    fn collectSpan(self: *Nearby, level: *const setup.Level, a: Point, b: Point) void {
        self.n = 0;
        const lo_x = @min(a[0], b[0]);
        const hi_x = @max(a[0], b[0]);
        const lo_y = @min(a[1], b[1]);
        const hi_y = @max(a[1], b[1]);
        for (level.lines, 0..) |*line, i| {
            const v1 = level.vertices[line.v1];
            const v2 = level.vertices[line.v2];
            const x1 = units(v1.x);
            const y1 = units(v1.y);
            const x2 = units(v2.x);
            const y2 = units(v2.y);
            if (@max(x1, x2) < lo_x or @min(x1, x2) > hi_x or @max(y1, y2) < lo_y or @min(y1, y2) > hi_y) continue;
            if (self.n == MAX_LINES) return;
            self.ids[self.n] = @intCast(i);
            self.n += 1;
        }
    }

    fn collect(self: *Nearby, level: *const setup.Level, cx: f64, cy: f64) void {
        self.n = 0;
        const lo_x = cx - WINDOW - CELL;
        const hi_x = cx + WINDOW + CELL;
        const lo_y = cy - WINDOW - CELL;
        const hi_y = cy + WINDOW + CELL;
        for (level.lines, 0..) |*line, i| {
            const v1 = level.vertices[line.v1];
            const v2 = level.vertices[line.v2];
            const x1 = units(v1.x);
            const y1 = units(v1.y);
            const x2 = units(v2.x);
            const y2 = units(v2.y);
            if (@max(x1, x2) < lo_x or @min(x1, x2) > hi_x or @max(y1, y2) < lo_y or @min(y1, y2) > hi_y) continue;
            if (self.n == MAX_LINES) return;
            self.ids[self.n] = @intCast(i);
            self.n += 1;
        }
    }
};

/// Whether a straight walk from `a` (standing on `floor`) to `b` is
/// possible, testing only `lines`.
pub fn straight(level: *const setup.Level, lines: []const u32, a: Point, b: Point, floor: f64) bool {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const Hit = struct { t: f64, line: *const setup.Line, front_first: bool };
    var hits: [32]Hit = undefined;
    var n: usize = 0;
    for (lines) |li| {
        const line = &level.lines[li];
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
        hits[n] = .{ .t = t, .line = line, .front_first = fx * (a[1] - ly) - fy * (a[0] - lx) < 0 };
        n += 1;
    }
    std.mem.sort(Hit, hits[0..n], {}, struct {
        fn lt(_: void, x: Hit, y: Hit) bool {
            return x.t < y.t;
        }
    }.lt);
    var here = floor;
    for (hits[0..n]) |h| {
        const fi = h.line.frontsector orelse return false;
        const bi = h.line.backsector orelse return false;
        const to = &level.sectors[if (h.front_first) bi else fi];
        const other = &level.sectors[if (h.front_first) fi else bi];
        const next = units(to.floorheight);
        if (@abs(next - here) > MAX_STEP) return false;
        const top = @min(units(to.ceilingheight), units(other.ceilingheight));
        if (top - @max(next, here) < PLAYER_HEIGHT) return false;
        here = next;
    }
    return true;
}

/// `straight` against every line in the level.
pub fn straightAll(level: *const setup.Level, a: Point, b: Point, floor: f64) bool {
    var near = Nearby{};
    near.collectSpan(level, a, b);
    return straight(level, near.ids[0..near.n], a, b, floor);
}

/// Whether `p` (on a floor at `floor`) is at least CLEARANCE from every
/// line the player could not cross there: one-sided or blocking lines, and
/// two-sided ones with a step over 24 or too little headroom.
fn clearOfWalls(level: *const setup.Level, lines: []const u32, p: Point, floor: f64) bool {
    for (lines) |li| {
        const line = &level.lines[li];
        const v1 = level.vertices[line.v1];
        const v2 = level.vertices[line.v2];
        const a: Point = .{ units(v1.x), units(v1.y) };
        const b: Point = .{ units(v2.x), units(v2.y) };
        if (segDist(p, a, b) >= CLEARANCE) continue;
        if (line.sidenum[1] < 0 or line.flags & defs.ML_BLOCKING != 0) return false;
        const f = &level.sectors[line.frontsector orelse return false];
        const k = &level.sectors[line.backsector orelse return false];
        const lo = @min(units(f.floorheight), units(k.floorheight));
        const hi = @max(units(f.floorheight), units(k.floorheight));
        if (hi - lo > MAX_STEP) return false;
        if (@min(units(f.ceilingheight), units(k.ceilingheight)) - @max(hi, floor) < PLAYER_HEIGHT) return false;
    }
    return true;
}

fn segDist(p: Point, a: Point, b: Point) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 < 1e-9) 0 else std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0.0, 1.0);
    return std.math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

fn hurts(special: i16) bool {
    return switch (special) {
        4, 5, 7, 11, 16 => true,
        else => false,
    };
}

/// A* from `start` to `goal` within the window around `start`. Writes the
/// path (start first, goal last, collinear points dropped) and returns
/// whether one was found.
pub fn plan(level: *const setup.Level, start: Point, floor: f64, goal: Point, out: *Path) bool {
    out.n = 0;
    if (@abs(goal[0] - start[0]) >= WINDOW - CELL or @abs(goal[1] - start[1]) >= WINDOW - CELL) return false;
    var near = Nearby{};
    near.collect(level, start[0], start[1]);
    const lines = near.ids[0..near.n];

    const ox = @floor((start[0] - WINDOW) / CELL) * CELL;
    const oy = @floor((start[1] - WINDOW) / CELL) * CELL;
    const S = struct {
        // 0 unknown, 1 usable, 2 not.
        state: [CELLS]u8 = [_]u8{0} ** CELLS,
        floor: [CELLS]f64 = undefined,
        g: [CELLS]f64 = undefined,
        parent: [CELLS]i32 = undefined,
        closed: [CELLS]bool = [_]bool{false} ** CELLS,
    };
    var st: S = .{};
    @memset(&st.g, std.math.inf(f64));
    @memset(&st.parent, -1);

    const cellOf = struct {
        fn f(x: f64, y: f64, ox_: f64, oy_: f64) ?usize {
            const cx = @floor((x - ox_) / CELL);
            const cy = @floor((y - oy_) / CELL);
            if (cx < 0 or cy < 0 or cx >= @as(f64, GRID) or cy >= @as(f64, GRID)) return null;
            return @as(usize, @intFromFloat(cy)) * GRID + @as(usize, @intFromFloat(cx));
        }
    }.f;
    const s_cell = cellOf(start[0], start[1], ox, oy) orelse return false;
    const g_cell = cellOf(goal[0], goal[1], ox, oy) orelse return false;
    const centre = struct {
        fn f(c: usize, ox_: f64, oy_: f64) Point {
            return .{ ox_ + (@as(f64, @floatFromInt(c % GRID)) + 0.5) * CELL, oy_ + (@as(f64, @floatFromInt(c / GRID)) + 0.5) * CELL };
        }
    }.f;
    const pointOf = struct {
        fn f(c: usize, s: usize, gc: usize, st_: Point, gl: Point, ox_: f64, oy_: f64) Point {
            if (c == s) return st_;
            if (c == gc) return gl;
            return centre(c, ox_, oy_);
        }
    }.f;

    st.state[s_cell] = 1;
    st.floor[s_cell] = floor;
    st.g[s_cell] = 0;

    var heap = Heap{};
    heap.push(.{ .f = dist(start, goal), .c = @intCast(s_cell) });
    var expansions: usize = 0;
    while (heap.pop()) |top| {
        const c: usize = top.c;
        if (st.closed[c]) continue;
        st.closed[c] = true;
        if (c == g_cell) break;
        expansions += 1;
        if (expansions > CELLS) break;
        const cx: i32 = @intCast(c % GRID);
        const cy: i32 = @intCast(c / GRID);
        const here = pointOf(c, s_cell, g_cell, start, goal, ox, oy);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = cx + dx;
                const ny = cy + dy;
                if (nx < 0 or ny < 0 or nx >= GRID or ny >= GRID) continue;
                const nc: usize = @intCast(ny * @as(i32, GRID) + nx);
                if (st.closed[nc]) continue;
                const there = pointOf(nc, s_cell, g_cell, start, goal, ox, oy);
                if (st.state[nc] == 0) {
                    st.state[nc] = 2;
                    if (agent_nav.sectorAt(level, there[0], there[1])) |si| {
                        const sec = &level.sectors[si];
                        if (units(sec.ceilingheight) - units(sec.floorheight) >= PLAYER_HEIGHT and !hurts(sec.special) and clearOfWalls(level, lines, there, units(sec.floorheight))) {
                            st.state[nc] = 1;
                            st.floor[nc] = units(sec.floorheight);
                        }
                    }
                }
                if (st.state[nc] != 1) continue;
                const step = dist(here, there);
                const ng = st.g[c] + step;
                if (ng >= st.g[nc]) continue;
                if (!straight(level, lines, here, there, st.floor[c])) continue;
                st.g[nc] = ng;
                st.parent[nc] = @intCast(c);
                heap.push(.{ .f = ng + dist(there, goal), .c = @intCast(nc) });
            }
        }
    }
    if (!st.closed[g_cell]) return false;

    // Walk back from the goal, then reverse.
    var rev: [MAX_POINTS]Point = undefined;
    var m: usize = 0;
    var c: i32 = @intCast(g_cell);
    while (c >= 0 and m < MAX_POINTS) {
        rev[m] = pointOf(@intCast(c), s_cell, g_cell, start, goal, ox, oy);
        m += 1;
        c = st.parent[@intCast(c)];
    }
    if (c >= 0) return false; // longer than the buffer
    var k: usize = 0;
    while (k < m) : (k += 1) {
        const p = rev[m - 1 - k];
        if (out.n >= 2 and collinear(out.pts[out.n - 2], out.pts[out.n - 1], p)) {
            out.pts[out.n - 1] = p;
            continue;
        }
        out.pts[out.n] = p;
        out.n += 1;
    }
    return out.n >= 2;
}

fn collinear(a: Point, b: Point, c: Point) bool {
    const cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    const dot = (b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1]);
    return @abs(cross) < 1e-6 and dot > 0;
}

const Node = struct { f: f64, c: u16 };

/// A binary min-heap on `f`, sized for every cell pushed up to 8 times.
const Heap = struct {
    items: [CELLS * 2]Node = undefined,
    n: usize = 0,

    fn push(self: *Heap, x: Node) void {
        if (self.n == self.items.len) return;
        var i = self.n;
        self.items[i] = x;
        self.n += 1;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (self.items[p].f <= self.items[i].f) break;
            std.mem.swap(Node, &self.items[p], &self.items[i]);
            i = p;
        }
    }

    fn pop(self: *Heap) ?Node {
        if (self.n == 0) return null;
        const top = self.items[0];
        self.n -= 1;
        self.items[0] = self.items[self.n];
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            const r = l + 1;
            var m = i;
            if (l < self.n and self.items[l].f < self.items[m].f) m = l;
            if (r < self.n and self.items[r].f < self.items[m].f) m = r;
            if (m == i) break;
            std.mem.swap(Node, &self.items[m], &self.items[i]);
            i = m;
        }
        return top;
    }
};

fn units(v: fixed.Fixed) f64 {
    return @as(f64, @floatFromInt(v.raw())) / 65536.0;
}

fn dist(a: Point, b: Point) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

test "heap pops in order" {
    var h = Heap{};
    for ([_]f64{ 5, 1, 4, 2, 3 }, 0..) |f, i| h.push(.{ .f = f, .c = @intCast(i) });
    var last: f64 = -1;
    while (h.pop()) |x| {
        try std.testing.expect(x.f >= last);
        last = x.f;
    }
}

test "collinear merge keeps turns" {
    try std.testing.expect(collinear(.{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }));
    try std.testing.expect(!collinear(.{ 0, 0 }, .{ 1, 0 }, .{ 0, 0 })); // a reversal is a turn
    try std.testing.expect(!collinear(.{ 0, 0 }, .{ 1, 0 }, .{ 2, 1 }));
}
