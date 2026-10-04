//! zig_doom/src/agent_funnel.zig
//!
//! String pulling over a chain of portals: the shortest path from a start
//! point to an end point that passes through every portal span in order.
//! It turns a route of doorway and step midpoints — which zig-zags — into
//! the few corners a person would actually walk, hugging each bend.
//!
//! Method: one crossing point per span, relaxed toward the taut string —
//! each point moves to where the line between its neighbours crosses its
//! span, clamped to the span's ends — then collinear points are dropped.
//! Every point stays on its own span, so no portal can be skipped, and a
//! route that doubles back keeps its turn. (The classic funnel algorithm
//! loses exactly that case when a wall edge is collinear with the walker,
//! which DOOM's axis-aligned walls make common.)
//!
//! Coordinates are DOOM map units, y up. `left` and `right` are as seen
//! walking through the portal in the direction of travel.

const std = @import("std");

pub const Point = [2]f64;

pub const Span = struct {
    left: Point,
    right: Point,
};

const MAX_POINTS = 128;
const RELAX_ROUNDS = 40;
/// A point this close to the segment between its neighbours is dropped.
const COLLINEAR: f64 = 1.0;

/// Where the line through `a` and `b` crosses the span, clamped to it; the
/// span's nearer end when they are parallel.
fn crossing(a: Point, b: Point, sp: Span, current: Point) Point {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const sx = sp.right[0] - sp.left[0];
    const sy = sp.right[1] - sp.left[1];
    const den = dx * sy - dy * sx;
    if (@abs(den) < 1e-9) return current;
    // a + t·d = left + u·s  →  u
    const u = std.math.clamp(((sp.left[0] - a[0]) * dy - (sp.left[1] - a[1]) * dx) / den, 0.0, 1.0);
    return .{ sp.left[0] + u * sx, sp.left[1] + u * sy };
}

/// Whether `p` lies on the segment a→b (within COLLINEAR), so dropping it
/// leaves the path unchanged. A point on the line but outside the segment is
/// a turn back and must stay.
fn onSegment(p: Point, a: Point, b: Point) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-9) return std.math.hypot(p[0] - a[0], p[1] - a[1]) < COLLINEAR;
    const t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
    if (t < 0 or t > 1) return false;
    return @abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / @sqrt(len2) < COLLINEAR;
}

/// Writes the path's corners into `out`, start first and end last; returns
/// how many. `spans` excludes the start and end, which are added here.
pub fn pull(start: Point, spans: []const Span, end: Point, out: []Point) usize {
    return relax(start, spans, end, out, true);
}

/// Like `pull`, but keeps one point per span even where the path runs
/// straight: a caller walking a non-convex space checks each stretch
/// itself and needs every crossing to fall back on.
pub fn crossings(start: Point, spans: []const Span, end: Point, out: []Point) usize {
    return relax(start, spans, end, out, false);
}

fn relax(start: Point, spans: []const Span, end: Point, out: []Point, drop_straight: bool) usize {
    if (out.len < 2) return 0;
    const n = @min(spans.len, MAX_POINTS - 2);
    var pts: [MAX_POINTS]Point = undefined;
    pts[0] = start;
    for (spans[0..n], 0..) |sp, i| pts[i + 1] = .{ (sp.left[0] + sp.right[0]) / 2, (sp.left[1] + sp.right[1]) / 2 };
    pts[n + 1] = end;

    var round: usize = 0;
    while (round < RELAX_ROUNDS) : (round += 1) {
        var moved: f64 = 0;
        for (spans[0..n], 0..) |sp, i| {
            const next = crossing(pts[i], pts[i + 2], sp, pts[i + 1]);
            moved = @max(moved, std.math.hypot(next[0] - pts[i + 1][0], next[1] - pts[i + 1][1]));
            pts[i + 1] = next;
        }
        if (moved < 0.01) break;
    }

    var count: usize = 0;
    out[count] = start;
    count += 1;
    for (1..n + 1) |i| {
        if (drop_straight and onSegment(pts[i], out[count - 1], pts[i + 1])) continue;
        if (count >= out.len - 1) break;
        out[count] = pts[i];
        count += 1;
    }
    out[count] = end;
    return count + 1;
}

const expect = std.testing.expect;

fn near(a: Point, b: Point) bool {
    return @abs(a[0] - b[0]) < 0.5 and @abs(a[1] - b[1]) < 0.5;
}

test "a straight corridor needs no corners" {
    var out: [8]Point = undefined;
    const spans = [_]Span{
        .{ .left = .{ 100, 50 }, .right = .{ 100, -50 } },
        .{ .left = .{ 200, 50 }, .right = .{ 200, -50 } },
    };
    const n = pull(.{ 0, 0 }, &spans, .{ 300, 0 }, &out);
    try expect(n == 2);
    try expect(near(out[1], .{ 300, 0 }));
}

test "a left bend hugs its inside corner" {
    // East through x=100 (y -50..50), then north through y=200 (x 150..250).
    var out: [8]Point = undefined;
    const spans = [_]Span{
        .{ .left = .{ 100, 50 }, .right = .{ 100, -50 } },
        .{ .left = .{ 150, 200 }, .right = .{ 250, 200 } },
    };
    const n = pull(.{ 0, 0 }, &spans, .{ 200, 300 }, &out);
    try expect(n == 3);
    try expect(near(out[1], .{ 100, 50 }));
    try expect(near(out[2], .{ 200, 300 }));
}

test "a right bend hugs its inside corner" {
    // East through x=100 (y -50..50), then south through y=-200 (x 150..250).
    var out: [8]Point = undefined;
    const spans = [_]Span{
        .{ .left = .{ 100, 50 }, .right = .{ 100, -50 } },
        .{ .left = .{ 250, -200 }, .right = .{ 150, -200 } },
    };
    const n = pull(.{ 0, 0 }, &spans, .{ 200, -300 }, &out);
    try expect(n == 3);
    try expect(near(out[1], .{ 100, -50 }));
}

test "a zig-zag of doorways becomes one corner per real turn" {
    // A staircase of offset doorways the straight line already passes.
    var out: [8]Point = undefined;
    const spans = [_]Span{
        .{ .left = .{ 100, 40 }, .right = .{ 100, -10 } },
        .{ .left = .{ 200, 60 }, .right = .{ 200, 10 } },
        .{ .left = .{ 300, 80 }, .right = .{ 300, 30 } },
    };
    const n = pull(.{ 0, 0 }, &spans, .{ 400, 100 }, &out);
    try expect(n == 2); // 0,0 → 400,100 is y = x/4: 25, 50, 75 — inside all three
}

test "a route that doubles back keeps its turn (E1M1 stairs)" {
    // Down three steps westward, then back east across the floor below:
    // spans captured from a live route (left/right already narrowed).
    var out: [8]Point = undefined;
    const spans = [_]Span{
        .{ .left = .{ 2208, -2544 }, .right = .{ 2208, -2320 } },
        .{ .left = .{ 2176, -2544 }, .right = .{ 2176, -2320 } },
        .{ .left = .{ 2144, -2544 }, .right = .{ 2144, -2320 } },
        .{ .left = .{ 2496, -2576 }, .right = .{ 2496, -2672 } },
    };
    const n = pull(.{ 2272, -2544 }, &spans, .{ 2536, -2624 }, &out);
    // It must reach x <= 2144 before heading east again.
    var westmost: f64 = 1e9;
    for (out[0..n]) |p| westmost = @min(westmost, p[0]);
    try expect(westmost <= 2144.5);
}
