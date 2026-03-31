//! Canvas Abstraction
//!
//! Abstract rendering surface for chart output. Backends implement
//! the Canvas interface to render to different formats (SVG, PNG, ASCII).

const std = @import("std");
const Color = @import("color.zig").Color;

/// Text anchor alignment
pub const TextAnchor = enum {
    start,
    middle,
    end,
};

/// Text baseline alignment
pub const TextBaseline = enum {
    top,
    middle,
    bottom,
    alphabetic,
};

/// Font weight
pub const FontWeight = enum {
    normal,
    bold,
};

/// Line cap style
pub const LineCap = enum {
    butt,
    round,
    square,
};

/// Line join style
pub const LineJoin = enum {
    miter,
    round,
    bevel,
};

/// Stroke style configuration
pub const StrokeStyle = struct {
    color: Color = Color.black,
    width: f64 = 1.0,
    dash_array: ?[]const f64 = null,
    line_cap: LineCap = .butt,
    line_join: LineJoin = .miter,
};

/// Fill style configuration
pub const FillStyle = struct {
    color: Color = Color.black,
};

/// Text style configuration
pub const TextStyle = struct {
    font_family: []const u8 = "sans-serif",
    font_size: f64 = 12.0,
    font_weight: FontWeight = .normal,
    color: Color = Color.black,
    anchor: TextAnchor = .start,
    baseline: TextBaseline = .alphabetic,
};

/// Point in 2D space
pub const Point = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }
};

/// Rectangle
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x <= self.x + self.width and
            p.y >= self.y and p.y <= self.y + self.height;
    }
};

/// Path commands for complex shapes
pub const PathCommand = union(enum) {
    move_to: Point,
    line_to: Point,
    quad_to: struct { control: Point, end: Point },
    cubic_to: struct { control1: Point, control2: Point, end: Point },
    arc_to: struct { rx: f64, ry: f64, rotation: f64, large_arc: bool, sweep: bool, end: Point },
    close,
};

/// Path builder for complex shapes
pub const Path = struct {
    commands: std.ArrayListUnmanaged(PathCommand),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{ .commands = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Path) void {
        self.commands.deinit(self.allocator);
    }

    pub fn moveTo(self: *Path, x: f64, y: f64) !void {
        try self.commands.append(self.allocator, .{ .move_to = Point.init(x, y) });
    }

    pub fn lineTo(self: *Path, x: f64, y: f64) !void {
        try self.commands.append(self.allocator, .{ .line_to = Point.init(x, y) });
    }

    pub fn quadTo(self: *Path, cx: f64, cy: f64, x: f64, y: f64) !void {
        try self.commands.append(self.allocator, .{ .quad_to = .{
            .control = Point.init(cx, cy),
            .end = Point.init(x, y),
        } });
    }

    pub fn cubicTo(self: *Path, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) !void {
        try self.commands.append(self.allocator, .{ .cubic_to = .{
            .control1 = Point.init(c1x, c1y),
            .control2 = Point.init(c2x, c2y),
            .end = Point.init(x, y),
        } });
    }

    pub fn arcTo(self: *Path, rx: f64, ry: f64, rotation: f64, large_arc: bool, sweep: bool, x: f64, y: f64) !void {
        try self.commands.append(self.allocator, .{ .arc_to = .{
            .rx = rx,
            .ry = ry,
            .rotation = rotation,
            .large_arc = large_arc,
            .sweep = sweep,
            .end = Point.init(x, y),
        } });
    }

    pub fn close(self: *Path) !void {
        try self.commands.append(self.allocator, .close);
    }

    pub fn clear(self: *Path) void {
        self.commands.clearRetainingCapacity();
    }
};

/// Canvas interface for rendering
/// Backends implement this via function pointers
pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Primitives
        drawLine: *const fn (ptr: *anyopaque, x1: f64, y1: f64, x2: f64, y2: f64, style: StrokeStyle) void,
        drawRect: *const fn (ptr: *anyopaque, rect: Rect, stroke: ?StrokeStyle, fill: ?FillStyle) void,
        drawCircle: *const fn (ptr: *anyopaque, cx: f64, cy: f64, r: f64, stroke: ?StrokeStyle, fill: ?FillStyle) void,
        drawPath: *const fn (ptr: *anyopaque, path: *const Path, stroke: ?StrokeStyle, fill: ?FillStyle) void,
        drawText: *const fn (ptr: *anyopaque, text: []const u8, x: f64, y: f64, style: TextStyle) void,

        // Grouping (for SVG <g> elements, etc.)
        beginGroup: *const fn (ptr: *anyopaque, id: ?[]const u8, class: ?[]const u8) void,
        endGroup: *const fn (ptr: *anyopaque) void,

        // Clipping
        setClipRect: *const fn (ptr: *anyopaque, rect: ?Rect) void,

        // Transform
        translate: *const fn (ptr: *anyopaque, x: f64, y: f64) void,
        rotate: *const fn (ptr: *anyopaque, angle: f64) void,
        scale: *const fn (ptr: *anyopaque, sx: f64, sy: f64) void,
        resetTransform: *const fn (ptr: *anyopaque) void,

        // Output
        finish: *const fn (ptr: *anyopaque) anyerror![]const u8,
    };

    // Convenience wrappers
    pub fn drawLine(self: Canvas, x1: f64, y1: f64, x2: f64, y2: f64, style: StrokeStyle) void {
        self.vtable.drawLine(self.ptr, x1, y1, x2, y2, style);
    }

    pub fn drawRect(self: Canvas, rect: Rect, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        self.vtable.drawRect(self.ptr, rect, stroke, fill);
    }

    pub fn drawCircle(self: Canvas, cx: f64, cy: f64, r: f64, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        self.vtable.drawCircle(self.ptr, cx, cy, r, stroke, fill);
    }

    pub fn drawPath(self: Canvas, path: *const Path, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        self.vtable.drawPath(self.ptr, path, stroke, fill);
    }

    pub fn drawText(self: Canvas, text: []const u8, x: f64, y: f64, style: TextStyle) void {
        self.vtable.drawText(self.ptr, text, x, y, style);
    }

    pub fn beginGroup(self: Canvas, id: ?[]const u8, class: ?[]const u8) void {
        self.vtable.beginGroup(self.ptr, id, class);
    }

    pub fn endGroup(self: Canvas) void {
        self.vtable.endGroup(self.ptr);
    }

    pub fn setClipRect(self: Canvas, rect: ?Rect) void {
        self.vtable.setClipRect(self.ptr, rect);
    }

    pub fn translate(self: Canvas, x: f64, y: f64) void {
        self.vtable.translate(self.ptr, x, y);
    }

    pub fn rotate(self: Canvas, angle: f64) void {
        self.vtable.rotate(self.ptr, angle);
    }

    pub fn scale(self: Canvas, sx: f64, sy: f64) void {
        self.vtable.scale(self.ptr, sx, sy);
    }

    pub fn resetTransform(self: Canvas) void {
        self.vtable.resetTransform(self.ptr);
    }

    pub fn finish(self: Canvas) ![]const u8 {
        return self.vtable.finish(self.ptr);
    }

    // Helper methods
    pub fn drawPolyline(self: Canvas, points: []const Point, style: StrokeStyle) void {
        if (points.len < 2) return;
        for (0..points.len - 1) |i| {
            self.drawLine(points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, style);
        }
    }

    pub fn drawPolygon(self: Canvas, allocator: std.mem.Allocator, points: []const Point, stroke: ?StrokeStyle, fill: ?FillStyle) !void {
        if (points.len < 3) return;

        var path = Path.init(allocator);
        defer path.deinit();

        try path.moveTo(points[0].x, points[0].y);
        for (points[1..]) |p| {
            try path.lineTo(p.x, p.y);
        }
        try path.close();

        self.drawPath(&path, stroke, fill);
    }
};

/// Chart dimensions and margins
pub const Layout = struct {
    width: f64,
    height: f64,
    margin_top: f64 = 20,
    margin_right: f64 = 20,
    margin_bottom: f64 = 40,
    margin_left: f64 = 60,

    /// Inner plot area width
    pub fn innerWidth(self: Layout) f64 {
        return self.width - self.margin_left - self.margin_right;
    }

    /// Inner plot area height
    pub fn innerHeight(self: Layout) f64 {
        return self.height - self.margin_top - self.margin_bottom;
    }

    /// Inner plot area bounds
    pub fn innerBounds(self: Layout) Rect {
        return Rect.init(
            self.margin_left,
            self.margin_top,
            self.innerWidth(),
            self.innerHeight(),
        );
    }
};
