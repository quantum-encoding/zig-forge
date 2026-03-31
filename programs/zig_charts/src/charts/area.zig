//! Area Charts
//!
//! Area charts for displaying time series with filled regions.
//! Supports stacked areas, streamgraph, and percentage modes.

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

/// Data point for area chart
pub const AreaPoint = struct {
    x: f64,
    y: f64,
};

/// A single area series
pub const AreaSeries = struct {
    name: []const u8,
    data: []const AreaPoint,
    color: Color = Color.blue_500,
    opacity: f64 = 0.7,
    show_line: bool = true,
    line_width: f64 = 2.0,
};

/// Stacking mode for multiple series
pub const StackMode = enum {
    none, // Overlapping areas (standard)
    stacked, // Areas stacked on top of each other
    percent, // Areas as percentage of total (100% stacked)
    stream, // Streamgraph (centered around baseline)
};

/// Area chart configuration
pub const AreaConfig = struct {
    // Stacking
    stack_mode: StackMode = .none,

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

    // Smoothing
    smooth: bool = false, // Use bezier curves instead of straight lines
};

pub const LegendPosition = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

/// Area chart renderer
pub const AreaChart = struct {
    allocator: std.mem.Allocator,
    series: []const AreaSeries,
    config: AreaConfig,
    layout: Layout,

    // Computed scales
    x_scale: LinearScale,
    y_scale: LinearScale,

    // Computed stacked values (for stacked/percent modes)
    stacked_data: ?[][]f64,

    const Self = @This();

    /// Create an area chart
    pub fn init(
        allocator: std.mem.Allocator,
        series: []const AreaSeries,
        layout: Layout,
        config: AreaConfig,
    ) Self {
        // Calculate data bounds
        var x_min: f64 = config.x_min orelse std.math.floatMax(f64);
        var x_max: f64 = config.x_max orelse -std.math.floatMax(f64);
        const y_min: f64 = config.y_min orelse 0; // Areas typically start from 0
        var y_max: f64 = config.y_max orelse -std.math.floatMax(f64);

        // For stacked modes, we need to compute cumulative values
        if (config.stack_mode == .stacked or config.stack_mode == .percent or config.stack_mode == .stream) {
            // Find max x points
            var max_points: usize = 0;
            for (series) |s| {
                max_points = @max(max_points, s.data.len);
                for (s.data) |p| {
                    if (config.x_min == null) x_min = @min(x_min, p.x);
                    if (config.x_max == null) x_max = @max(x_max, p.x);
                }
            }

            // Calculate stacked totals for y_max
            if (max_points > 0) {
                for (0..max_points) |i| {
                    var total: f64 = 0;
                    for (series) |s| {
                        if (i < s.data.len) {
                            total += @max(0, s.data[i].y);
                        }
                    }
                    if (config.stack_mode == .percent) {
                        y_max = 100; // Percentage mode always 0-100
                    } else {
                        if (config.y_max == null) y_max = @max(y_max, total);
                    }
                }
            }
        } else {
            // Non-stacked: find individual bounds
            for (series) |s| {
                for (s.data) |p| {
                    if (config.x_min == null) x_min = @min(x_min, p.x);
                    if (config.x_max == null) x_max = @max(x_max, p.x);
                    if (config.y_max == null) y_max = @max(y_max, p.y);
                }
            }
        }

        // Handle empty data
        if (x_min > x_max) {
            x_min = 0;
            x_max = 1;
        }
        if (y_min >= y_max) {
            y_max = 1;
        }

        // Add padding to y_max
        if (config.y_max == null and config.stack_mode != .percent) {
            y_max += (y_max - y_min) * 0.05;
        }

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
            .stacked_data = null,
        };
    }

    /// Render the area chart
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Draw grid
        if (self.config.show_grid) {
            try self.drawGrid(c);
        }

        // Set clip rect
        c.setClipRect(bounds);

        // Draw areas based on stack mode
        switch (self.config.stack_mode) {
            .none => try self.drawOverlappingAreas(c),
            .stacked => try self.drawStackedAreas(c, false),
            .percent => try self.drawStackedAreas(c, true),
            .stream => try self.drawStreamAreas(c),
        }

        c.setClipRect(null);

        // Draw axes
        if (self.config.show_y_axis) {
            const axis_config = axis.AxisConfig{
                .show_grid = false,
                .tick_count = self.config.y_tick_count,
                .title = self.config.y_label,
            };
            try axis.drawYAxis(c, self.allocator, self.layout, self.y_scale, axis_config);
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
    }

    fn drawOverlappingAreas(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();
        const base_y = bounds.y + bounds.height;

        // Draw in reverse order so first series is on top
        var i = self.series.len;
        while (i > 0) {
            i -= 1;
            const s = self.series[i];
            if (s.data.len == 0) continue;

            var area_path = Path.init(self.allocator);
            defer area_path.deinit();

            // Start at baseline
            try area_path.moveTo(self.x_scale.scale(s.data[0].x), base_y);

            // Draw top line
            for (s.data) |p| {
                try area_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(p.y));
            }

            // Return to baseline
            try area_path.lineTo(self.x_scale.scale(s.data[s.data.len - 1].x), base_y);
            try area_path.close();

            // Draw fill
            const fill_color = s.color.withAlpha(@intFromFloat(s.opacity * 255));
            c.drawPath(&area_path, null, .{ .color = fill_color });

            // Draw line on top
            if (s.show_line) {
                var line_path = Path.init(self.allocator);
                defer line_path.deinit();

                try line_path.moveTo(self.x_scale.scale(s.data[0].x), self.y_scale.scale(s.data[0].y));
                for (s.data[1..]) |p| {
                    try line_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(p.y));
                }

                c.drawPath(&line_path, .{
                    .color = s.color,
                    .width = s.line_width,
                }, null);
            }
        }
    }

    fn drawStackedAreas(self: *Self, c: Canvas, percent_mode: bool) !void {
        if (self.series.len == 0) return;

        _ = self.layout.innerBounds();

        // Find the max number of data points
        var max_points: usize = 0;
        for (self.series) |s| {
            max_points = @max(max_points, s.data.len);
        }

        if (max_points == 0) return;

        // Allocate cumulative arrays
        var cumulative_bottom = try self.allocator.alloc(f64, max_points);
        defer self.allocator.free(cumulative_bottom);
        var cumulative_top = try self.allocator.alloc(f64, max_points);
        defer self.allocator.free(cumulative_top);

        // Initialize to zero
        for (0..max_points) |i| {
            cumulative_bottom[i] = 0;
            cumulative_top[i] = 0;
        }

        // Calculate totals for percent mode
        var totals: []f64 = undefined;
        if (percent_mode) {
            totals = try self.allocator.alloc(f64, max_points);
            for (0..max_points) |i| {
                var total: f64 = 0;
                for (self.series) |s| {
                    if (i < s.data.len) {
                        total += @max(0, s.data[i].y);
                    }
                }
                totals[i] = if (total > 0) total else 1;
            }
        }
        defer if (percent_mode) self.allocator.free(totals);

        // Draw each series from bottom to top
        for (self.series) |s| {
            if (s.data.len == 0) continue;

            // Update cumulative values
            for (s.data, 0..) |p, i| {
                cumulative_bottom[i] = cumulative_top[i];
                var value = @max(0, p.y);
                if (percent_mode) {
                    value = (value / totals[i]) * 100;
                }
                cumulative_top[i] = cumulative_bottom[i] + value;
            }

            // Build area path
            var area_path = Path.init(self.allocator);
            defer area_path.deinit();

            // Start from first point on bottom
            try area_path.moveTo(self.x_scale.scale(s.data[0].x), self.y_scale.scale(cumulative_bottom[0]));

            // Draw top edge
            for (s.data, 0..) |p, i| {
                try area_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(cumulative_top[i]));
            }

            // Draw bottom edge in reverse
            var j = s.data.len;
            while (j > 0) {
                j -= 1;
                try area_path.lineTo(self.x_scale.scale(s.data[j].x), self.y_scale.scale(cumulative_bottom[j]));
            }

            try area_path.close();

            // Draw fill
            const fill_color = s.color.withAlpha(@intFromFloat(s.opacity * 255));
            c.drawPath(&area_path, null, .{ .color = fill_color });

            // Draw line on top edge
            if (s.show_line) {
                var line_path = Path.init(self.allocator);
                defer line_path.deinit();

                try line_path.moveTo(self.x_scale.scale(s.data[0].x), self.y_scale.scale(cumulative_top[0]));
                for (s.data[1..], 1..) |p, i| {
                    try line_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(cumulative_top[i]));
                }

                c.drawPath(&line_path, .{
                    .color = s.color,
                    .width = s.line_width,
                }, null);
            }
        }
    }

    fn drawStreamAreas(self: *Self, c: Canvas) !void {
        // Streamgraph: areas centered around a baseline that flows
        // This is a simplified version - just centers the stack around the middle

        if (self.series.len == 0) return;

        var max_points: usize = 0;
        for (self.series) |s| {
            max_points = @max(max_points, s.data.len);
        }

        if (max_points == 0) return;

        // Calculate totals at each point
        var totals = try self.allocator.alloc(f64, max_points);
        defer self.allocator.free(totals);

        for (0..max_points) |i| {
            var total: f64 = 0;
            for (self.series) |s| {
                if (i < s.data.len) {
                    total += @max(0, s.data[i].y);
                }
            }
            totals[i] = total;
        }

        // Calculate baseline (center the stream)
        var baseline = try self.allocator.alloc(f64, max_points);
        defer self.allocator.free(baseline);

        const y_range = self.y_scale.domain_max - self.y_scale.domain_min;
        const center = self.y_scale.domain_min + y_range / 2;

        for (0..max_points) |i| {
            baseline[i] = center - totals[i] / 2;
        }

        // Allocate cumulative array
        var cumulative = try self.allocator.alloc(f64, max_points);
        defer self.allocator.free(cumulative);

        for (0..max_points) |i| {
            cumulative[i] = baseline[i];
        }

        // Draw each series
        for (self.series) |s| {
            if (s.data.len == 0) continue;

            var area_path = Path.init(self.allocator);
            defer area_path.deinit();

            // Bottom edge (previous cumulative)
            try area_path.moveTo(self.x_scale.scale(s.data[0].x), self.y_scale.scale(cumulative[0]));

            // Top edge
            var top_values = try self.allocator.alloc(f64, s.data.len);
            defer self.allocator.free(top_values);

            for (s.data, 0..) |p, i| {
                top_values[i] = cumulative[i] + @max(0, p.y);
                try area_path.lineTo(self.x_scale.scale(p.x), self.y_scale.scale(top_values[i]));
            }

            // Bottom edge in reverse
            var j = s.data.len;
            while (j > 0) {
                j -= 1;
                try area_path.lineTo(self.x_scale.scale(s.data[j].x), self.y_scale.scale(cumulative[j]));
            }

            try area_path.close();

            // Update cumulative for next series
            for (0..s.data.len) |i| {
                cumulative[i] = top_values[i];
            }

            // Draw fill
            const fill_color = s.color.withAlpha(@intFromFloat(s.opacity * 255));
            c.drawPath(&area_path, null, .{ .color = fill_color });
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

            // Color box
            c.drawRect(
                Rect.init(legend_x + padding, entry_y + 2, 12, 12),
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
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a simple area chart
pub fn renderArea(
    allocator: std.mem.Allocator,
    c: Canvas,
    series: []const AreaSeries,
    layout: Layout,
    config: AreaConfig,
) !void {
    var chart = AreaChart.init(allocator, series, layout, config);
    try chart.render(c);
}

/// Create area data from an array of y values (x = index)
pub fn fromValues(allocator: std.mem.Allocator, values: []const f64) ![]AreaPoint {
    var points = try allocator.alloc(AreaPoint, values.len);
    for (values, 0..) |v, i| {
        points[i] = .{ .x = @floatFromInt(i), .y = v };
    }
    return points;
}

// =============================================================================
// Tests
// =============================================================================

test "area chart bounds calculation" {
    const allocator = std.testing.allocator;

    const data = [_]AreaPoint{
        .{ .x = 0, .y = 10 },
        .{ .x = 1, .y = 25 },
        .{ .x = 2, .y = 15 },
        .{ .x = 3, .y = 30 },
    };

    const series = [_]AreaSeries{
        .{ .name = "Test", .data = &data },
    };

    const layout = Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    const chart = AreaChart.init(allocator, &series, layout, .{});

    // Y should start from 0 for area charts
    try std.testing.expectEqual(@as(f64, 0), chart.y_scale.domain_min);
    try std.testing.expect(chart.y_scale.domain_max > 30);
}

test "stacked area totals" {
    const allocator = std.testing.allocator;

    const data1 = [_]AreaPoint{
        .{ .x = 0, .y = 10 },
        .{ .x = 1, .y = 20 },
    };

    const data2 = [_]AreaPoint{
        .{ .x = 0, .y = 15 },
        .{ .x = 1, .y = 25 },
    };

    const series = [_]AreaSeries{
        .{ .name = "A", .data = &data1 },
        .{ .name = "B", .data = &data2 },
    };

    const layout = Layout{ .width = 400, .height = 300 };
    const config = AreaConfig{ .stack_mode = .stacked };

    const chart = AreaChart.init(allocator, &series, layout, config);

    // Max should accommodate total (10+15=25 at x=0, 20+25=45 at x=1)
    try std.testing.expect(chart.y_scale.domain_max >= 45);
}
