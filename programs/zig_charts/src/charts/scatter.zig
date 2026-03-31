//! Scatter Plot Charts
//!
//! XY scatter plots for showing relationships between variables.
//! Supports multi-series, bubble charts (size-encoded), trend lines, and clustering.

const std = @import("std");
const canvas = @import("../canvas.zig");
const scales = @import("../scales.zig");
const axis = @import("../axis.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Path = canvas.Path;
const Rect = canvas.Rect;
const LinearScale = scales.LinearScale;

/// A single data point in a scatter plot
pub const ScatterPoint = struct {
    x: f64,
    y: f64,
    size: ?f64 = null, // For bubble charts (overrides series default)
    label: ?[]const u8 = null, // Optional point label
};

/// A series of scatter points
pub const ScatterSeries = struct {
    name: []const u8,
    points: []const ScatterPoint,
    color: Color = Color.blue_500,
    point_size: f64 = 6.0,
    point_shape: PointShape = .circle,
    show_labels: bool = false,
    opacity: f64 = 0.8,
};

/// Shape of the scatter points
pub const PointShape = enum {
    circle,
    square,
    diamond,
    triangle,
    cross,
};

/// Trend line configuration
pub const TrendLine = struct {
    enabled: bool = false,
    color: ?Color = null, // Inherits from series if null
    width: f64 = 1.5,
    dashed: bool = true,
    method: TrendMethod = .linear,
};

pub const TrendMethod = enum {
    linear, // y = mx + b
    // Future: polynomial, exponential, logarithmic
};

/// Scatter chart configuration
pub const ScatterConfig = struct {
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

    // Bounds (auto-calculated if null)
    x_min: ?f64 = null,
    x_max: ?f64 = null,
    y_min: ?f64 = null,
    y_max: ?f64 = null,

    // Legend
    show_legend: bool = true,
    legend_position: LegendPosition = .top_right,

    // Trend line
    trend_line: TrendLine = .{},

    // Bubble chart settings
    min_bubble_size: f64 = 4.0,
    max_bubble_size: f64 = 30.0,

    // Interactivity hints
    highlight_on_hover: bool = false,
};

pub const LegendPosition = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

/// Scatter plot renderer
pub const ScatterChart = struct {
    allocator: std.mem.Allocator,
    series: []const ScatterSeries,
    config: ScatterConfig,
    layout: Layout,

    // Computed scales
    x_scale: LinearScale,
    y_scale: LinearScale,
    size_scale: ?LinearScale,

    const Self = @This();

    /// Create a scatter chart
    pub fn init(
        allocator: std.mem.Allocator,
        series: []const ScatterSeries,
        layout: Layout,
        config: ScatterConfig,
    ) Self {
        // Calculate data bounds
        var x_min: f64 = config.x_min orelse std.math.floatMax(f64);
        var x_max: f64 = config.x_max orelse -std.math.floatMax(f64);
        var y_min: f64 = config.y_min orelse std.math.floatMax(f64);
        var y_max: f64 = config.y_max orelse -std.math.floatMax(f64);
        var size_min: f64 = std.math.floatMax(f64);
        var size_max: f64 = -std.math.floatMax(f64);
        var has_sizes = false;

        for (series) |s| {
            for (s.points) |p| {
                if (config.x_min == null) x_min = @min(x_min, p.x);
                if (config.x_max == null) x_max = @max(x_max, p.x);
                if (config.y_min == null) y_min = @min(y_min, p.y);
                if (config.y_max == null) y_max = @max(y_max, p.y);
                if (p.size) |sz| {
                    has_sizes = true;
                    size_min = @min(size_min, sz);
                    size_max = @max(size_max, sz);
                }
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
        const x_padding = (x_max - x_min) * 0.05;
        const y_padding = (y_max - y_min) * 0.05;
        if (config.x_min == null) x_min -= x_padding;
        if (config.x_max == null) x_max += x_padding;
        if (config.y_min == null) y_min -= y_padding;
        if (config.y_max == null) y_max += y_padding;

        const bounds = layout.innerBounds();

        const x_scale = LinearScale.init(x_min, x_max, bounds.x, bounds.x + bounds.width);
        const y_scale = LinearScale.init(y_min, y_max, bounds.y + bounds.height, bounds.y);

        const size_scale: ?LinearScale = if (has_sizes and size_max > size_min)
            LinearScale.init(size_min, size_max, config.min_bubble_size, config.max_bubble_size)
        else
            null;

        return .{
            .allocator = allocator,
            .series = series,
            .config = config,
            .layout = layout,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .size_scale = size_scale,
        };
    }

    /// Render the scatter chart
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Draw grid
        if (self.config.show_grid) {
            try self.drawGrid(c);
        }

        // Set clip rect
        c.setClipRect(bounds);

        // Draw each series
        for (self.series) |s| {
            // Draw trend line first (behind points)
            if (self.config.trend_line.enabled) {
                try self.drawTrendLine(c, s);
            }

            // Draw points
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
        if (self.config.show_legend and self.series.len > 1) {
            self.drawLegend(c);
        }
    }

    fn drawSeries(self: *Self, c: Canvas, s: ScatterSeries) !void {
        for (s.points) |p| {
            const x = self.x_scale.scale(p.x);
            const y = self.y_scale.scale(p.y);

            // Calculate point size (bubble or fixed)
            const size = if (p.size) |sz|
                if (self.size_scale) |scale| scale.scale(sz) else s.point_size
            else
                s.point_size;

            const fill_color = s.color.withAlpha(@intFromFloat(s.opacity * 255));

            // Draw point based on shape
            switch (s.point_shape) {
                .circle => {
                    c.drawCircle(x, y, size / 2, .{
                        .color = s.color,
                        .width = 1.5,
                    }, .{
                        .color = fill_color,
                    });
                },
                .square => {
                    c.drawRect(.{
                        .x = x - size / 2,
                        .y = y - size / 2,
                        .width = size,
                        .height = size,
                    }, .{
                        .color = s.color,
                        .width = 1,
                    }, .{
                        .color = fill_color,
                    });
                },
                .diamond => {
                    try self.drawDiamond(c, x, y, size, s.color, fill_color);
                },
                .triangle => {
                    try self.drawTriangle(c, x, y, size, s.color, fill_color);
                },
                .cross => {
                    self.drawCross(c, x, y, size, s.color);
                },
            }

            // Draw label if enabled
            if (s.show_labels) {
                if (p.label) |label| {
                    c.drawText(label, x, y - size / 2 - 4, .{
                        .color = Color.gray_600,
                        .font_size = 10,
                        .anchor = .middle,
                    });
                }
            }
        }
    }

    fn drawDiamond(self: *Self, c: Canvas, x: f64, y: f64, size: f64, stroke: Color, fill: Color) !void {
        var path = Path.init(self.allocator);
        defer path.deinit();

        const half = size / 2;
        try path.moveTo(x, y - half); // top
        try path.lineTo(x + half, y); // right
        try path.lineTo(x, y + half); // bottom
        try path.lineTo(x - half, y); // left
        try path.close();

        c.drawPath(&path, .{ .color = stroke, .width = 1 }, .{ .color = fill });
    }

    fn drawTriangle(self: *Self, c: Canvas, x: f64, y: f64, size: f64, stroke: Color, fill: Color) !void {
        var path = Path.init(self.allocator);
        defer path.deinit();

        const half = size / 2;
        const height = size * 0.866; // sqrt(3)/2
        try path.moveTo(x, y - height / 2); // top
        try path.lineTo(x + half, y + height / 2); // bottom right
        try path.lineTo(x - half, y + height / 2); // bottom left
        try path.close();

        c.drawPath(&path, .{ .color = stroke, .width = 1 }, .{ .color = fill });
    }

    fn drawCross(_: *Self, c: Canvas, x: f64, y: f64, size: f64, color: Color) void {
        const half = size / 2;
        c.drawLine(x - half, y, x + half, y, .{ .color = color, .width = 2 });
        c.drawLine(x, y - half, x, y + half, .{ .color = color, .width = 2 });
    }

    fn drawTrendLine(self: *Self, c: Canvas, s: ScatterSeries) !void {
        if (s.points.len < 2) return;

        // Calculate linear regression: y = mx + b
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        var sum_xy: f64 = 0;
        var sum_x2: f64 = 0;
        const n: f64 = @floatFromInt(s.points.len);

        for (s.points) |p| {
            sum_x += p.x;
            sum_y += p.y;
            sum_xy += p.x * p.y;
            sum_x2 += p.x * p.x;
        }

        const denominator = n * sum_x2 - sum_x * sum_x;
        if (@abs(denominator) < 0.0001) return; // Vertical line or no variance

        const m = (n * sum_xy - sum_x * sum_y) / denominator;
        const b = (sum_y - m * sum_x) / n;

        // Find x range from data
        var x_min = s.points[0].x;
        var x_max = s.points[0].x;
        for (s.points) |p| {
            x_min = @min(x_min, p.x);
            x_max = @max(x_max, p.x);
        }

        // Draw trend line
        const y1 = m * x_min + b;
        const y2 = m * x_max + b;

        const line_color = self.config.trend_line.color orelse s.color;

        if (self.config.trend_line.dashed) {
            c.drawLine(
                self.x_scale.scale(x_min),
                self.y_scale.scale(y1),
                self.x_scale.scale(x_max),
                self.y_scale.scale(y2),
                .{
                    .color = line_color,
                    .width = self.config.trend_line.width,
                    .dash_array = &[_]f64{ 5, 3 },
                },
            );
        } else {
            c.drawLine(
                self.x_scale.scale(x_min),
                self.y_scale.scale(y1),
                self.x_scale.scale(x_max),
                self.y_scale.scale(y2),
                .{
                    .color = line_color,
                    .width = self.config.trend_line.width,
                },
            );
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

            // Color dot
            c.drawCircle(
                legend_x + padding + 6,
                entry_y + 8,
                4,
                null,
                .{ .color = s.color },
            );

            // Label
            c.drawText(s.name, legend_x + padding + 18, entry_y + 12, .{
                .font_size = 11,
                .color = Color.gray_700,
            });
        }
    }

    /// Calculate R-squared (coefficient of determination) for a series
    pub fn calculateRSquared(self: *Self, series_idx: usize) f64 {
        if (series_idx >= self.series.len) return 0;
        const s = self.series[series_idx];
        if (s.points.len < 2) return 0;

        // Calculate means
        var sum_y: f64 = 0;
        for (s.points) |p| {
            sum_y += p.y;
        }
        const mean_y = sum_y / @as(f64, @floatFromInt(s.points.len));

        // Calculate regression coefficients
        var sum_x: f64 = 0;
        var sum_xy: f64 = 0;
        var sum_x2: f64 = 0;
        const n: f64 = @floatFromInt(s.points.len);

        for (s.points) |p| {
            sum_x += p.x;
            sum_xy += p.x * p.y;
            sum_x2 += p.x * p.x;
        }

        const denominator = n * sum_x2 - sum_x * sum_x;
        if (@abs(denominator) < 0.0001) return 0;

        const m = (n * sum_xy - sum_x * sum_y) / denominator;
        const b = (sum_y - m * sum_x) / n;

        // Calculate SS_res and SS_tot
        var ss_res: f64 = 0;
        var ss_tot: f64 = 0;

        for (s.points) |p| {
            const y_pred = m * p.x + b;
            ss_res += (p.y - y_pred) * (p.y - y_pred);
            ss_tot += (p.y - mean_y) * (p.y - mean_y);
        }

        if (ss_tot == 0) return 1.0; // Perfect fit

        return 1.0 - (ss_res / ss_tot);
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a simple scatter chart
pub fn renderScatter(
    allocator: std.mem.Allocator,
    c: Canvas,
    series: []const ScatterSeries,
    layout: Layout,
    config: ScatterConfig,
) !void {
    var chart = ScatterChart.init(allocator, series, layout, config);
    try chart.render(c);
}

/// Create scatter points from parallel x,y arrays
pub fn fromArrays(allocator: std.mem.Allocator, x_values: []const f64, y_values: []const f64) ![]ScatterPoint {
    const len = @min(x_values.len, y_values.len);
    var points = try allocator.alloc(ScatterPoint, len);
    for (0..len) |i| {
        points[i] = .{ .x = x_values[i], .y = y_values[i] };
    }
    return points;
}

// =============================================================================
// Tests
// =============================================================================

test "scatter chart bounds calculation" {
    const allocator = std.testing.allocator;
    const points = [_]ScatterPoint{
        .{ .x = 1, .y = 5 },
        .{ .x = 2, .y = 8 },
        .{ .x = 3, .y = 2 },
        .{ .x = 4, .y = 10 },
    };

    const series = [_]ScatterSeries{
        .{ .name = "Test", .points = &points },
    };

    const layout = Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    const chart = ScatterChart.init(allocator, &series, layout, .{});

    // Check that scales were computed correctly
    try std.testing.expect(chart.x_scale.domain_min < 1.0);
    try std.testing.expect(chart.x_scale.domain_max > 4.0);
    try std.testing.expect(chart.y_scale.domain_min < 2.0);
    try std.testing.expect(chart.y_scale.domain_max > 10.0);
}

test "scatter r-squared calculation" {
    const allocator = std.testing.allocator;

    // Perfect linear relationship: y = 2x + 1
    const points = [_]ScatterPoint{
        .{ .x = 1, .y = 3 },
        .{ .x = 2, .y = 5 },
        .{ .x = 3, .y = 7 },
        .{ .x = 4, .y = 9 },
    };

    const series = [_]ScatterSeries{
        .{ .name = "Linear", .points = &points },
    };

    const layout = Layout{ .width = 400, .height = 300 };

    var chart = ScatterChart.init(allocator, &series, layout, .{});
    const r_squared = chart.calculateRSquared(0);

    // Should be very close to 1.0 for perfect linear relationship
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r_squared, 0.001);
}

test "bubble chart size scaling" {
    const allocator = std.testing.allocator;
    const points = [_]ScatterPoint{
        .{ .x = 1, .y = 5, .size = 10 },
        .{ .x = 2, .y = 8, .size = 50 },
        .{ .x = 3, .y = 2, .size = 30 },
    };

    const series = [_]ScatterSeries{
        .{ .name = "Bubbles", .points = &points },
    };

    const layout = Layout{ .width = 400, .height = 300 };
    const config = ScatterConfig{
        .min_bubble_size = 5.0,
        .max_bubble_size = 25.0,
    };

    const chart = ScatterChart.init(allocator, &series, layout, config);

    // Size scale should be created
    try std.testing.expect(chart.size_scale != null);
}
