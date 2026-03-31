// PDF Renderer - Path Construction and Storage
//
// Implements PDF path construction operators.
// Paths consist of subpaths, each containing line and curve segments.

const std = @import("std");
const gs = @import("graphics_state.zig");
const Matrix = gs.Matrix;

/// Point in path coordinates
pub const Point = struct {
    x: f32,
    y: f32,

    pub fn transform(self: Point, m: Matrix) Point {
        const result = m.transformPoint(self.x, self.y);
        return .{ .x = result.x, .y = result.y };
    }

    pub fn lerp(a: Point, b: Point, t: f32) Point {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
        };
    }

    pub fn distance(a: Point, b: Point) f32 {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// Path segment types
pub const SegmentType = enum {
    MoveTo, // Start new subpath
    LineTo, // Straight line
    CurveTo, // Cubic bezier (2 control points + endpoint)
    ClosePath, // Close current subpath
};

/// A segment in the path
pub const Segment = struct {
    seg_type: SegmentType,
    // Points for this segment:
    // MoveTo: p1 = destination
    // LineTo: p1 = endpoint
    // CurveTo: p1 = control1, p2 = control2, p3 = endpoint
    // ClosePath: no points needed
    p1: Point = .{ .x = 0, .y = 0 },
    p2: Point = .{ .x = 0, .y = 0 },
    p3: Point = .{ .x = 0, .y = 0 },
};

/// Bounding box
pub const BoundingBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub const empty: BoundingBox = .{
        .min_x = std.math.inf(f32),
        .min_y = std.math.inf(f32),
        .max_x = -std.math.inf(f32),
        .max_y = -std.math.inf(f32),
    };

    pub fn include(self: *BoundingBox, x: f32, y: f32) void {
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, x);
        self.max_y = @max(self.max_y, y);
    }

    pub fn includePoint(self: *BoundingBox, p: Point) void {
        self.include(p.x, p.y);
    }

    pub fn width(self: BoundingBox) f32 {
        return self.max_x - self.min_x;
    }

    pub fn height(self: BoundingBox) f32 {
        return self.max_y - self.min_y;
    }

    pub fn isEmpty(self: BoundingBox) bool {
        return self.min_x > self.max_x or self.min_y > self.max_y;
    }
};

/// Path builder - accumulates path segments
pub const PathBuilder = struct {
    segments: std.ArrayList(Segment),
    current_point: Point,
    subpath_start: Point,
    has_current_point: bool,
    bounds: BoundingBox,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PathBuilder {
        return .{
            .segments = .empty,
            .current_point = .{ .x = 0, .y = 0 },
            .subpath_start = .{ .x = 0, .y = 0 },
            .has_current_point = false,
            .bounds = BoundingBox.empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PathBuilder) void {
        self.segments.deinit(self.allocator);
    }

    pub fn clear(self: *PathBuilder) void {
        self.segments.clearRetainingCapacity();
        self.has_current_point = false;
        self.bounds = BoundingBox.empty;
    }

    /// Move to a new point (m operator)
    pub fn moveTo(self: *PathBuilder, x: f32, y: f32) !void {
        const p = Point{ .x = x, .y = y };
        try self.segments.append(self.allocator, .{
            .seg_type = .MoveTo,
            .p1 = p,
        });
        self.current_point = p;
        self.subpath_start = p;
        self.has_current_point = true;
        self.bounds.includePoint(p);
    }

    /// Line to a point (l operator)
    pub fn lineTo(self: *PathBuilder, x: f32, y: f32) !void {
        if (!self.has_current_point) {
            return self.moveTo(x, y);
        }
        const p = Point{ .x = x, .y = y };
        try self.segments.append(self.allocator, .{
            .seg_type = .LineTo,
            .p1 = p,
        });
        self.current_point = p;
        self.bounds.includePoint(p);
    }

    /// Cubic bezier curve (c operator)
    pub fn curveTo(self: *PathBuilder, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) !void {
        if (!self.has_current_point) {
            try self.moveTo(x1, y1);
        }
        const c1 = Point{ .x = x1, .y = y1 };
        const c2 = Point{ .x = x2, .y = y2 };
        const p = Point{ .x = x3, .y = y3 };

        try self.segments.append(self.allocator, .{
            .seg_type = .CurveTo,
            .p1 = c1,
            .p2 = c2,
            .p3 = p,
        });
        self.current_point = p;

        // Include control points in bounds (approximate, but safe)
        self.bounds.includePoint(c1);
        self.bounds.includePoint(c2);
        self.bounds.includePoint(p);
    }

    /// Cubic bezier with initial point replicated (v operator)
    pub fn curveToV(self: *PathBuilder, x2: f32, y2: f32, x3: f32, y3: f32) !void {
        try self.curveTo(self.current_point.x, self.current_point.y, x2, y2, x3, y3);
    }

    /// Cubic bezier with final point replicated (y operator)
    pub fn curveToY(self: *PathBuilder, x1: f32, y1: f32, x3: f32, y3: f32) !void {
        try self.curveTo(x1, y1, x3, y3, x3, y3);
    }

    /// Close the current subpath (h operator)
    pub fn closePath(self: *PathBuilder) !void {
        if (self.has_current_point) {
            try self.segments.append(self.allocator, .{ .seg_type = .ClosePath });
            self.current_point = self.subpath_start;
        }
    }

    /// Append a rectangle (re operator)
    pub fn rectangle(self: *PathBuilder, x: f32, y: f32, w: f32, h: f32) !void {
        try self.moveTo(x, y);
        try self.lineTo(x + w, y);
        try self.lineTo(x + w, y + h);
        try self.lineTo(x, y + h);
        try self.closePath();
    }

    /// Get bounding box
    pub fn getBounds(self: *const PathBuilder) BoundingBox {
        return self.bounds;
    }

    /// Check if path is empty
    pub fn isEmpty(self: *const PathBuilder) bool {
        return self.segments.items.len == 0;
    }

    /// Transform all points in path
    pub fn transform(self: *PathBuilder, m: Matrix) void {
        self.bounds = BoundingBox.empty;

        for (self.segments.items) |*seg| {
            switch (seg.seg_type) {
                .MoveTo, .LineTo => {
                    seg.p1 = seg.p1.transform(m);
                    self.bounds.includePoint(seg.p1);
                },
                .CurveTo => {
                    seg.p1 = seg.p1.transform(m);
                    seg.p2 = seg.p2.transform(m);
                    seg.p3 = seg.p3.transform(m);
                    self.bounds.includePoint(seg.p1);
                    self.bounds.includePoint(seg.p2);
                    self.bounds.includePoint(seg.p3);
                },
                .ClosePath => {},
            }
        }

        self.current_point = self.current_point.transform(m);
        self.subpath_start = self.subpath_start.transform(m);
    }

    /// Clone the path
    pub fn clone(self: *const PathBuilder, allocator: std.mem.Allocator) !PathBuilder {
        var new_path = PathBuilder.init(allocator);
        errdefer new_path.deinit();

        try new_path.segments.appendSlice(allocator, self.segments.items);
        new_path.current_point = self.current_point;
        new_path.subpath_start = self.subpath_start;
        new_path.has_current_point = self.has_current_point;
        new_path.bounds = self.bounds;

        return new_path;
    }
};

/// Iterator for flattening curves into line segments
/// Converts bezier curves to a series of lines
pub const FlatteningIterator = struct {
    path: *const PathBuilder,
    segment_idx: usize,
    current_point: Point,
    subpath_start: Point,
    // For curve subdivision
    curve_stack: [32]CurveSegment, // Stack for subdivision
    curve_stack_len: usize,
    flatness: f32,

    const CurveSegment = struct {
        p0: Point,
        p1: Point,
        p2: Point,
        p3: Point,
    };

    pub fn init(path: *const PathBuilder, flatness: f32) FlatteningIterator {
        return .{
            .path = path,
            .segment_idx = 0,
            .current_point = .{ .x = 0, .y = 0 },
            .subpath_start = .{ .x = 0, .y = 0 },
            .curve_stack = undefined,
            .curve_stack_len = 0,
            .flatness = flatness,
        };
    }

    /// Output segment from flattening
    pub const FlatSegment = struct {
        seg_type: enum { MoveTo, LineTo, ClosePath },
        point: Point,
    };

    /// Get next flattened segment
    pub fn next(self: *FlatteningIterator) ?FlatSegment {
        // First, drain any remaining curve subdivisions
        if (self.curve_stack_len > 0) {
            return self.emitCurveLine();
        }

        // Process next path segment
        while (self.segment_idx < self.path.segments.items.len) {
            const seg = self.path.segments.items[self.segment_idx];
            self.segment_idx += 1;

            switch (seg.seg_type) {
                .MoveTo => {
                    self.current_point = seg.p1;
                    self.subpath_start = seg.p1;
                    return .{ .seg_type = .MoveTo, .point = seg.p1 };
                },
                .LineTo => {
                    self.current_point = seg.p1;
                    return .{ .seg_type = .LineTo, .point = seg.p1 };
                },
                .CurveTo => {
                    // Initialize curve subdivision
                    self.curve_stack[0] = .{
                        .p0 = self.current_point,
                        .p1 = seg.p1,
                        .p2 = seg.p2,
                        .p3 = seg.p3,
                    };
                    self.curve_stack_len = 1;
                    self.current_point = seg.p3;
                    return self.emitCurveLine();
                },
                .ClosePath => {
                    self.current_point = self.subpath_start;
                    return .{ .seg_type = .ClosePath, .point = self.subpath_start };
                },
            }
        }

        return null;
    }

    fn emitCurveLine(self: *FlatteningIterator) ?FlatSegment {
        while (self.curve_stack_len > 0) {
            const curve = self.curve_stack[self.curve_stack_len - 1];

            // Check if curve is flat enough
            if (self.isFlatEnough(curve)) {
                self.curve_stack_len -= 1;
                return .{ .seg_type = .LineTo, .point = curve.p3 };
            }

            // Subdivide curve
            if (self.curve_stack_len >= self.curve_stack.len - 1) {
                // Stack full, just output endpoint
                self.curve_stack_len -= 1;
                return .{ .seg_type = .LineTo, .point = curve.p3 };
            }

            const left, const right = subdivideCurve(curve);
            self.curve_stack[self.curve_stack_len - 1] = right;
            self.curve_stack[self.curve_stack_len] = left;
            self.curve_stack_len += 1;
        }
        return null;
    }

    fn isFlatEnough(self: *const FlatteningIterator, curve: CurveSegment) bool {
        // Check distance of control points from the line p0-p3
        const dx = curve.p3.x - curve.p0.x;
        const dy = curve.p3.y - curve.p0.y;
        const len_sq = dx * dx + dy * dy;

        if (len_sq < 0.01) return true;

        const inv_len = 1.0 / @sqrt(len_sq);

        // Distance from p1 to line
        const d1x = curve.p1.x - curve.p0.x;
        const d1y = curve.p1.y - curve.p0.y;
        const dist1 = @abs(d1x * dy - d1y * dx) * inv_len;

        // Distance from p2 to line
        const d2x = curve.p2.x - curve.p0.x;
        const d2y = curve.p2.y - curve.p0.y;
        const dist2 = @abs(d2x * dy - d2y * dx) * inv_len;

        return @max(dist1, dist2) <= self.flatness;
    }

    fn subdivideCurve(curve: CurveSegment) struct { CurveSegment, CurveSegment } {
        // De Casteljau subdivision at t=0.5
        const p01 = Point.lerp(curve.p0, curve.p1, 0.5);
        const p12 = Point.lerp(curve.p1, curve.p2, 0.5);
        const p23 = Point.lerp(curve.p2, curve.p3, 0.5);

        const p012 = Point.lerp(p01, p12, 0.5);
        const p123 = Point.lerp(p12, p23, 0.5);

        const p0123 = Point.lerp(p012, p123, 0.5);

        return .{
            // Left half
            .{
                .p0 = curve.p0,
                .p1 = p01,
                .p2 = p012,
                .p3 = p0123,
            },
            // Right half
            .{
                .p0 = p0123,
                .p1 = p123,
                .p2 = p23,
                .p3 = curve.p3,
            },
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "path builder basic" {
    var path = PathBuilder.init(std.testing.allocator);
    defer path.deinit();

    try path.moveTo(0, 0);
    try path.lineTo(100, 0);
    try path.lineTo(100, 100);
    try path.lineTo(0, 100);
    try path.closePath();

    try std.testing.expectEqual(@as(usize, 5), path.segments.items.len);
    try std.testing.expectEqual(SegmentType.MoveTo, path.segments.items[0].seg_type);
    try std.testing.expectEqual(SegmentType.ClosePath, path.segments.items[4].seg_type);
}

test "path builder rectangle" {
    var path = PathBuilder.init(std.testing.allocator);
    defer path.deinit();

    try path.rectangle(10, 20, 100, 50);

    try std.testing.expectEqual(@as(usize, 5), path.segments.items.len);

    const bounds = path.getBounds();
    try std.testing.expectEqual(@as(f32, 10), bounds.min_x);
    try std.testing.expectEqual(@as(f32, 20), bounds.min_y);
    try std.testing.expectEqual(@as(f32, 110), bounds.max_x);
    try std.testing.expectEqual(@as(f32, 70), bounds.max_y);
}

test "path transformation" {
    var path = PathBuilder.init(std.testing.allocator);
    defer path.deinit();

    try path.moveTo(0, 0);
    try path.lineTo(10, 0);

    path.transform(Matrix.scale(2, 2));

    try std.testing.expectEqual(@as(f32, 20), path.segments.items[1].p1.x);
}

test "flattening iterator" {
    var path = PathBuilder.init(std.testing.allocator);
    defer path.deinit();

    try path.moveTo(0, 0);
    try path.curveTo(10, 0, 20, 10, 20, 20);

    var iter = FlatteningIterator.init(&path, 1.0);
    var count: usize = 0;

    while (iter.next()) |_| {
        count += 1;
    }

    // Should produce multiple line segments
    try std.testing.expect(count >= 2);
}
