//! Bar Chart
//!
//! Vertical and horizontal bar charts for categorical data.
//! Supports grouped and stacked variants.

const std = @import("std");
const canvas = @import("../canvas.zig");
const scales = @import("../scales.zig");
const axis = @import("../axis.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Rect = canvas.Rect;
const LinearScale = scales.LinearScale;
const BandScale = scales.BandScale;

/// Bar chart configuration
pub const BarChartConfig = struct {
    // Appearance
    bar_colors: []const Color = &[_]Color{
        Color.blue_500,
        Color.bear_red,
        Color.bull_green,
        Color.fromHex("F59E0B").?,
        Color.fromHex("8B5CF6").?,
    },
    bar_padding: f64 = 0.2, // Padding between bars (0-1)
    bar_corner_radius: f64 = 0, // Rounded corners
    show_values: bool = false,
    value_font_size: f64 = 10,
    value_color: Color = Color.gray_600,

    // Orientation
    horizontal: bool = false,

    // Grouping
    mode: BarMode = .grouped,
    group_padding: f64 = 0.1, // Padding between groups

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    show_grid: bool = true,
    grid_color: Color = Color.gray_200,

    // Baseline
    baseline: f64 = 0,
};

pub const BarMode = enum {
    grouped, // Side by side
    stacked, // On top of each other
};

/// A bar data series
pub const BarSeries = struct {
    name: []const u8,
    values: []const f64,
    color: ?Color = null, // Override default palette
};

/// Bar chart renderer
pub const BarChart = struct {
    allocator: std.mem.Allocator,
    categories: []const []const u8,
    series: []const BarSeries,
    config: BarChartConfig,
    layout: Layout,

    // Computed scales
    category_scale: BandScale,
    value_scale: LinearScale,

    const Self = @This();

    /// Create a bar chart
    pub fn init(
        allocator: std.mem.Allocator,
        categories: []const []const u8,
        series: []const BarSeries,
        layout: Layout,
        config: BarChartConfig,
    ) Self {
        const bounds = layout.innerBounds();

        // Calculate value range
        var min_val: f64 = config.baseline;
        var max_val: f64 = config.baseline;

        for (series) |s| {
            if (config.mode == .stacked) {
                // For stacked, sum up values per category
                for (0..categories.len) |i| {
                    var pos_sum: f64 = 0;
                    var neg_sum: f64 = 0;
                    for (series) |s2| {
                        if (i < s2.values.len) {
                            if (s2.values[i] >= 0) {
                                pos_sum += s2.values[i];
                            } else {
                                neg_sum += s2.values[i];
                            }
                        }
                    }
                    max_val = @max(max_val, pos_sum);
                    min_val = @min(min_val, neg_sum);
                }
                break; // Only need one pass for stacked
            } else {
                for (s.values) |v| {
                    max_val = @max(max_val, v);
                    min_val = @min(min_val, v);
                }
            }
        }

        // Add padding
        const range = max_val - min_val;
        max_val += range * 0.1;
        if (min_val < 0) min_val -= range * 0.1;

        // Create scales based on orientation
        const category_scale = if (config.horizontal)
            BandScale.init(categories, bounds.y, bounds.y + bounds.height)
        else
            BandScale.init(categories, bounds.x, bounds.x + bounds.width);

        const value_scale = if (config.horizontal)
            LinearScale.init(min_val, max_val, bounds.x, bounds.x + bounds.width)
        else
            LinearScale.init(min_val, max_val, bounds.y + bounds.height, bounds.y);

        return .{
            .allocator = allocator,
            .categories = categories,
            .series = series,
            .config = config,
            .layout = layout,
            .category_scale = category_scale,
            .value_scale = value_scale,
        };
    }

    /// Render the chart
    pub fn render(self: *Self, c: Canvas) !void {
        // Draw grid
        if (self.config.show_grid) {
            try self.drawGrid(c);
        }

        // Draw baseline
        const bounds = self.layout.innerBounds();
        const baseline_pos = self.value_scale.scale(self.config.baseline);

        if (self.config.horizontal) {
            c.drawLine(baseline_pos, bounds.y, baseline_pos, bounds.y + bounds.height, .{
                .color = Color.gray_400,
                .width = 1.0,
            });
        } else {
            c.drawLine(bounds.x, baseline_pos, bounds.x + bounds.width, baseline_pos, .{
                .color = Color.gray_400,
                .width = 1.0,
            });
        }

        // Draw bars
        if (self.config.mode == .stacked) {
            self.drawStackedBars(c);
        } else {
            self.drawGroupedBars(c);
        }

        // Draw axes
        if (self.config.horizontal) {
            if (self.config.show_x_axis) {
                try axis.drawXAxis(c, self.allocator, self.layout, self.value_scale, .{
                    .show_grid = false,
                });
            }
            if (self.config.show_y_axis) {
                axis.drawBandXAxis(c, self.layout, self.category_scale, .{});
            }
        } else {
            if (self.config.show_x_axis) {
                axis.drawBandXAxis(c, self.layout, self.category_scale, .{});
            }
            if (self.config.show_y_axis) {
                try axis.drawYAxis(c, self.allocator, self.layout, self.value_scale, .{
                    .show_grid = false,
                });
            }
        }
    }

    fn drawGroupedBars(self: *Self, c: Canvas) void {
        const num_series = self.series.len;
        if (num_series == 0) return;

        const bandwidth = self.category_scale.bandwidth();
        const bar_width = bandwidth * (1 - self.config.bar_padding) / @as(f64, @floatFromInt(num_series));
        const group_start = bandwidth * self.config.bar_padding / 2;

        for (self.categories, 0..) |_, cat_idx| {
            const cat_pos = self.category_scale.scale(cat_idx);

            for (self.series, 0..) |s, series_idx| {
                if (cat_idx >= s.values.len) continue;

                const value = s.values[cat_idx];
                const color = s.color orelse self.getSeriesColor(series_idx);

                self.drawBar(
                    c,
                    cat_pos + group_start + @as(f64, @floatFromInt(series_idx)) * bar_width,
                    bar_width,
                    value,
                    color,
                );
            }
        }
    }

    fn drawStackedBars(self: *Self, c: Canvas) void {
        const bandwidth = self.category_scale.bandwidth();
        const bar_width = bandwidth * (1 - self.config.bar_padding);
        const bar_start = bandwidth * self.config.bar_padding / 2;

        for (self.categories, 0..) |_, cat_idx| {
            const cat_pos = self.category_scale.scale(cat_idx);
            var pos_stack: f64 = self.config.baseline;
            var neg_stack: f64 = self.config.baseline;

            for (self.series, 0..) |s, series_idx| {
                if (cat_idx >= s.values.len) continue;

                const value = s.values[cat_idx];
                const color = s.color orelse self.getSeriesColor(series_idx);

                if (value >= 0) {
                    self.drawStackedBar(c, cat_pos + bar_start, bar_width, pos_stack, pos_stack + value, color);
                    pos_stack += value;
                } else {
                    self.drawStackedBar(c, cat_pos + bar_start, bar_width, neg_stack + value, neg_stack, color);
                    neg_stack += value;
                }
            }
        }
    }

    fn drawBar(self: *Self, c: Canvas, pos: f64, width: f64, value: f64, color: Color) void {
        const baseline = self.value_scale.scale(self.config.baseline);
        const value_pos = self.value_scale.scale(value);

        if (self.config.horizontal) {
            const x = @min(baseline, value_pos);
            const w = @abs(value_pos - baseline);
            c.drawRect(
                Rect.init(x, pos, w, width),
                null,
                .{ .color = color },
            );

            if (self.config.show_values) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d:.1}", .{value}) catch return;
                c.drawText(label, value_pos + 5, pos + width / 2, .{
                    .font_size = self.config.value_font_size,
                    .color = self.config.value_color,
                    .baseline = .middle,
                });
            }
        } else {
            const y = @min(baseline, value_pos);
            const h = @abs(baseline - value_pos);
            c.drawRect(
                Rect.init(pos, y, width, h),
                null,
                .{ .color = color },
            );

            if (self.config.show_values) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d:.1}", .{value}) catch return;
                const text_y = if (value >= 0) value_pos - 5 else value_pos + 12;
                c.drawText(label, pos + width / 2, text_y, .{
                    .font_size = self.config.value_font_size,
                    .color = self.config.value_color,
                    .anchor = .middle,
                });
            }
        }
    }

    fn drawStackedBar(self: *Self, c: Canvas, pos: f64, width: f64, from: f64, to: f64, color: Color) void {
        const from_pos = self.value_scale.scale(from);
        const to_pos = self.value_scale.scale(to);

        if (self.config.horizontal) {
            const x = @min(from_pos, to_pos);
            const w = @abs(to_pos - from_pos);
            c.drawRect(Rect.init(x, pos, w, width), null, .{ .color = color });
        } else {
            const y = @min(from_pos, to_pos);
            const h = @abs(from_pos - to_pos);
            c.drawRect(Rect.init(pos, y, width, h), null, .{ .color = color });
        }
    }

    fn drawGrid(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();
        const ticks = try self.value_scale.ticks(self.allocator, 5);
        defer self.allocator.free(ticks);

        for (ticks) |v| {
            const pos = self.value_scale.scale(v);
            if (self.config.horizontal) {
                c.drawLine(pos, bounds.y, pos, bounds.y + bounds.height, .{
                    .color = self.config.grid_color,
                    .width = 1.0,
                });
            } else {
                c.drawLine(bounds.x, pos, bounds.x + bounds.width, pos, .{
                    .color = self.config.grid_color,
                    .width = 1.0,
                });
            }
        }
    }

    fn getSeriesColor(self: *Self, index: usize) Color {
        return self.config.bar_colors[index % self.config.bar_colors.len];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "bar chart render" {
    const allocator = std.testing.allocator;
    const svg = @import("../svg.zig");

    var svg_canvas = svg.SvgCanvas.init(allocator, 400, 300);
    defer svg_canvas.deinit();

    const categories = [_][]const u8{ "Q1", "Q2", "Q3", "Q4" };
    const series = [_]BarSeries{
        .{ .name = "Revenue", .values = &[_]f64{ 100, 120, 90, 150 } },
        .{ .name = "Expenses", .values = &[_]f64{ 80, 95, 85, 110 } },
    };

    const layout = Layout{ .width = 400, .height = 300 };
    var chart = BarChart.init(allocator, &categories, &series, layout, .{});

    const c = svg_canvas.canvas();
    try chart.render(c);

    const output = try c.finish();
    try std.testing.expect(std.mem.indexOf(u8, output, "<rect") != null);
}
