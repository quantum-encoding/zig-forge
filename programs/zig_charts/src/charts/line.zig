//! Line Chart
//!
//! Multi-series line chart with optional area fills, markers, and legends.

const std = @import("std");
const canvas = @import("../canvas.zig");
const scales = @import("../scales.zig");
const axis = @import("../axis.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Path = canvas.Path;
const Point = canvas.Point;
const Rect = canvas.Rect;
const LinearScale = scales.LinearScale;
const TimeScale = scales.TimeScale;

/// Data point for line chart
pub const DataPoint = struct {
    x: f64, // Can be index, timestamp, or arbitrary X value
    y: f64,
};

/// A single data series
pub const Series = struct {
    name: []const u8,
    data: []const DataPoint,
    color: Color = Color.blue_500,
    line_width: f64 = 2.0,
    fill: bool = false,
    fill_opacity: f64 = 0.2,
    show_markers: bool = false,
    marker_radius: f64 = 3.0,
    dashed: bool = false,
    dash_pattern: []const f64 = &[_]f64{ 5, 3 },
};

/// Line chart configuration
pub const LineChartConfig = struct {
    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    show_grid: bool = true,
    grid_color: Color = Color.gray_200,

    // Axis labels
    x_label: ?[]const u8 = null,
    y_label: ?[]const u8 = null,
    x_tick_count: usize = 5,
    y_tick_count: usize = 5,

    // Legend
    show_legend: bool = true,
    legend_position: LegendPosition = .top_right,

    // Interaction markers
    show_crosshair: bool = false,
    crosshair_x: ?f64 = null,

    // Bounds (auto-calculated if null)
    x_min: ?f64 = null,
    x_max: ?f64 = null,
    y_min: ?f64 = null,
    y_max: ?f64 = null,

    // Zero line
    show_zero_line: bool = false,
    zero_line_color: Color = Color.gray_400,
};

pub const LegendPosition = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

/// Line chart renderer
pub const LineChart = struct {
    allocator: std.mem.Allocator,
    series: []const Series,
    config: LineChartConfig,
    layout: Layout,

    // Computed scales
    x_scale: LinearScale,
    y_scale: LinearScale,

    const Self = @This();

    /// Create a line chart
    pub fn init(
        allocator: std.mem.Allocator,
        series: []const Series,
        layout: Layout,
        config: LineChartConfig,
    ) Self {
        // Calculate data bounds
        var x_min: f64 = config.x_min orelse std.math.floatMax(f64);
        var x_max: f64 = config.x_max orelse -std.math.floatMax(f64);
        var y_min: f64 = config.y_min orelse std.math.floatMax(f64);
        var y_max: f64 = config.y_max orelse -std.math.floatMax(f64);

        for (series) |s| {
            for (s.data) |p| {
                if (config.x_min == null) x_min = @min(x_min, p.x);
                if (config.x_max == null) x_max = @max(x_max, p.x);
                if (config.y_min == null) y_min = @min(y_min, p.y);
                if (config.y_max == null) y_max = @max(y_max, p.y);
            }
        }

        // Handle empty data
        if (x_min > x_max) {
            x_min = 0;
            x_max = 1;
        }
        if (y_min > y_max) {
            y_min = 0;
            y_max = 1;
        }

        // Add padding
        const y_padding = (y_max - y_min) * 0.05;
        if (config.y_min == null) y_min -= y_padding;
        if (config.y_max == null) y_max += y_padding;

        const bounds = layout.innerBounds();

        const x_scale = LinearScale.init(x_min, x_max, bounds.x, bounds.x + bounds.width);
        const y_scale = LinearScale.init(y_min, y_max, bounds.y + bounds.height, bounds.y);

        return .{
            .allocator = allocator,
            .series = series,
            .config = config,
            .layout = layout,
            .x_scale = x_scale,
            .y_scale = y_scale,
        };
    }

    /// Render the chart
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Draw grid
        if (self.config.show_grid) {
            try self.drawGrid(c);
        }

        // Draw zero line
        if (self.config.show_zero_line) {
            const zero_y = self.y_scale.scale(0);
            if (zero_y >= bounds.y and zero_y <= bounds.y + bounds.height) {
                c.drawLine(bounds.x, zero_y, bounds.x + bounds.width, zero_y, .{
                    .color = self.config.zero_line_color,
                    .width = 1.0,
                });
            }
        }

        // Set clip rect to prevent drawing outside bounds
        c.setClipRect(bounds);

        // Draw each series
        for (self.series) |s| {
            try self.drawSeries(c, s);
        }

        c.setClipRect(null);

        // Draw axes
        if (self.config.show_y_axis) {
            try axis.drawYAxis(c, self.allocator, self.layout, self.y_scale, .{
                .show_grid = false,
                .tick_count = self.config.y_tick_count,
                .title = self.config.y_label,
            });
        }

        if (self.config.show_x_axis) {
            try axis.drawXAxis(c, self.allocator, self.layout, self.x_scale, .{
                .show_grid = false,
                .tick_count = self.config.x_tick_count,
                .title = self.config.x_label,
            });
        }

        // Draw legend
        if (self.config.show_legend and self.series.len > 0) {
            self.drawLegend(c);
        }

        // Draw crosshair
        if (self.config.show_crosshair) {
            if (self.config.crosshair_x) |cx| {
                const x = self.x_scale.scale(cx);
                c.drawLine(x, bounds.y, x, bounds.y + bounds.height, .{
                    .color = Color.gray_400,
                    .width = 1.0,
                    .dash_array = &[_]f64{ 3, 3 },
                });
            }
        }
    }

    fn drawSeries(self: *Self, c: Canvas, s: Series) !void {
        if (s.data.len == 0) return;

        // Build path
        var path = Path.init(self.allocator);
        defer path.deinit();

        const first = s.data[0];
        try path.moveTo(self.x_scale.scale(first.x), self.y_scale.scale(first.y));

        for (s.data[1..]) |p| {
            try path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(p.y));
        }

        // Draw fill area
        if (s.fill) {
            var fill_path = Path.init(self.allocator);
            defer fill_path.deinit();

            const bounds = self.layout.innerBounds();
            const base_y = bounds.y + bounds.height;

            try fill_path.moveTo(self.x_scale.scale(s.data[0].x), base_y);

            for (s.data) |p| {
                try fill_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(p.y));
            }

            try fill_path.lineTo(self.x_scale.scale(s.data[s.data.len - 1].x), base_y);
            try fill_path.close();

            c.drawPath(&fill_path, null, .{
                .color = s.color.withAlpha(@intFromFloat(s.fill_opacity * 255)),
            });
        }

        // Draw line
        const stroke_style = canvas.StrokeStyle{
            .color = s.color,
            .width = s.line_width,
            .line_cap = .round,
            .line_join = .round,
            .dash_array = if (s.dashed) s.dash_pattern else null,
        };
        c.drawPath(&path, stroke_style, null);

        // Draw markers
        if (s.show_markers) {
            for (s.data) |p| {
                c.drawCircle(
                    self.x_scale.scale(p.x),
                    self.y_scale.scale(p.y),
                    s.marker_radius,
                    .{ .color = s.color, .width = 1.5 },
                    .{ .color = Color.white },
                );
            }
        }
    }

    fn drawGrid(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Horizontal lines
        const y_ticks = try self.y_scale.ticks(self.allocator, self.config.y_tick_count);
        defer self.allocator.free(y_ticks);

        for (y_ticks) |v| {
            const y = self.y_scale.scale(v);
            c.drawLine(bounds.x, y, bounds.x + bounds.width, y, .{
                .color = self.config.grid_color,
                .width = 1.0,
            });
        }

        // Vertical lines
        const x_ticks = try self.x_scale.ticks(self.allocator, self.config.x_tick_count);
        defer self.allocator.free(x_ticks);

        for (x_ticks) |v| {
            const x = self.x_scale.scale(v);
            c.drawLine(x, bounds.y, x, bounds.y + bounds.height, .{
                .color = self.config.grid_color,
                .width = 1.0,
            });
        }
    }

    fn drawLegend(self: *Self, c: Canvas) void {
        const bounds = self.layout.innerBounds();
        const padding: f64 = 10;
        const line_height: f64 = 18;
        const legend_width: f64 = 120;
        const legend_height = @as(f64, @floatFromInt(self.series.len)) * line_height + padding * 2;

        // Calculate position
        const legend_x = switch (self.config.legend_position) {
            .top_left, .bottom_left => bounds.x + padding,
            .top_right, .bottom_right => bounds.x + bounds.width - legend_width - padding,
        };
        const legend_y = switch (self.config.legend_position) {
            .top_left, .top_right => bounds.y + padding,
            .bottom_left, .bottom_right => bounds.y + bounds.height - legend_height - padding,
        };

        // Background
        c.drawRect(
            Rect.init(legend_x, legend_y, legend_width, legend_height),
            .{ .color = Color.gray_300, .width = 1.0 },
            .{ .color = Color.white.withAlpha(230) },
        );

        // Entries
        for (self.series, 0..) |s, i| {
            const entry_y = legend_y + padding + @as(f64, @floatFromInt(i)) * line_height;

            // Color line
            c.drawLine(
                legend_x + padding,
                entry_y + 8,
                legend_x + padding + 20,
                entry_y + 8,
                .{ .color = s.color, .width = 2.0 },
            );

            // Label
            c.drawText(s.name, legend_x + padding + 28, entry_y + 12, .{
                .font_size = 11,
                .color = Color.gray_700,
            });
        }
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create data points from a simple array (indices as X)
pub fn fromValues(allocator: std.mem.Allocator, values: []const f64) ![]DataPoint {
    var points = try allocator.alloc(DataPoint, values.len);
    for (values, 0..) |v, i| {
        points[i] = .{ .x = @floatFromInt(i), .y = v };
    }
    return points;
}

// =============================================================================
// Tests
// =============================================================================

test "line chart render" {
    const allocator = std.testing.allocator;
    const svg = @import("../svg.zig");

    var svg_canvas = svg.SvgCanvas.init(allocator, 400, 300);
    defer svg_canvas.deinit();

    const data1 = [_]DataPoint{
        .{ .x = 0, .y = 10 },
        .{ .x = 1, .y = 25 },
        .{ .x = 2, .y = 18 },
        .{ .x = 3, .y = 32 },
    };

    const data2 = [_]DataPoint{
        .{ .x = 0, .y = 15 },
        .{ .x = 1, .y = 12 },
        .{ .x = 2, .y = 28 },
        .{ .x = 3, .y = 22 },
    };

    const series = [_]Series{
        .{ .name = "Series A", .data = &data1, .color = Color.blue_500 },
        .{ .name = "Series B", .data = &data2, .color = Color.bear_red, .dashed = true },
    };

    const layout = Layout{ .width = 400, .height = 300 };
    var chart = LineChart.init(allocator, &series, layout, .{});

    const c = svg_canvas.canvas();
    try chart.render(c);

    const output = try c.finish();
    try std.testing.expect(std.mem.indexOf(u8, output, "<path") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Series A") != null);
}
