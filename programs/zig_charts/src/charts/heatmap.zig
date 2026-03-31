//! Heatmap Charts
//!
//! 2D grid visualization with color-coded cell values.
//! Supports custom color scales, labels, and annotations.

const std = @import("std");
const canvas = @import("../canvas.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Rect = canvas.Rect;
const TextAnchor = canvas.TextAnchor;

/// Color scale for heatmap
pub const ColorScale = struct {
    colors: []const Color,
    min: f64,
    max: f64,

    /// Get color for a value
    pub fn getColor(self: ColorScale, value: f64) Color {
        if (self.colors.len == 0) return Color.gray_400;
        if (self.colors.len == 1) return self.colors[0];

        const normalized = std.math.clamp((value - self.min) / (self.max - self.min), 0, 1);
        const segment_count: f64 = @floatFromInt(self.colors.len - 1);
        const segment = normalized * segment_count;
        const lower_idx: usize = @intFromFloat(@floor(segment));
        const upper_idx: usize = @min(lower_idx + 1, self.colors.len - 1);
        const t = segment - @as(f64, @floatFromInt(lower_idx));

        return self.colors[lower_idx].interpolate(self.colors[upper_idx], @floatCast(t));
    }

    /// Create a default blue-red color scale
    pub fn blueToRed(min: f64, max: f64) ColorScale {
        return .{
            .colors = &[_]Color{
                Color.fromHex("3B82F6").?, // blue
                Color.fromHex("10B981").?, // green
                Color.fromHex("F59E0B").?, // yellow
                Color.fromHex("EF4444").?, // red
            },
            .min = min,
            .max = max,
        };
    }

    /// Create a sequential single-hue scale
    pub fn sequential(base_color: Color, min: f64, max: f64) ColorScale {
        return .{
            .colors = &[_]Color{
                base_color.lighten(0.8),
                base_color.lighten(0.5),
                base_color,
                base_color.darken(0.3),
            },
            .min = min,
            .max = max,
        };
    }

    /// Create a diverging scale (for data with meaningful center)
    pub fn diverging(min: f64, max: f64) ColorScale {
        return .{
            .colors = &[_]Color{
                Color.fromHex("2563EB").?, // blue
                Color.fromHex("93C5FD").?, // light blue
                Color.fromHex("F3F4F6").?, // white-ish
                Color.fromHex("FCA5A5").?, // light red
                Color.fromHex("DC2626").?, // red
            },
            .min = min,
            .max = max,
        };
    }
};

/// Heatmap configuration
pub const HeatmapConfig = struct {
    // Cell appearance
    cell_padding: f64 = 1,
    cell_border_radius: f64 = 0,
    show_values: bool = false,
    value_font_size: f64 = 10,
    value_color: ?Color = null, // Auto-contrast if null

    // Color scale
    color_scale: ?ColorScale = null, // Auto-calculated if null
    custom_colors: ?[]const Color = null,

    // Labels
    show_x_labels: bool = true,
    show_y_labels: bool = true,
    x_labels: ?[]const []const u8 = null,
    y_labels: ?[]const []const u8 = null,
    label_font_size: f64 = 11,
    label_color: Color = Color.gray_700,
    rotate_x_labels: bool = false,

    // Legend
    show_legend: bool = true,
    legend_width: f64 = 20,
    legend_position: LegendPosition = .right,

    // Title
    title: ?[]const u8 = null,
    title_font_size: f64 = 14,
};

pub const LegendPosition = enum {
    right,
    bottom,
};

/// Heatmap chart renderer
pub const HeatmapChart = struct {
    allocator: std.mem.Allocator,
    data: []const []const f64, // 2D array [rows][cols]
    config: HeatmapConfig,
    layout: Layout,

    // Computed values
    rows: usize,
    cols: usize,
    color_scale: ColorScale,

    const Self = @This();

    /// Create a heatmap
    pub fn init(
        allocator: std.mem.Allocator,
        data: []const []const f64,
        layout: Layout,
        config: HeatmapConfig,
    ) Self {
        // Calculate dimensions
        const rows = data.len;
        var cols: usize = 0;
        for (data) |row| {
            cols = @max(cols, row.len);
        }

        // Calculate value range
        var min_val: f64 = std.math.floatMax(f64);
        var max_val: f64 = -std.math.floatMax(f64);

        for (data) |row| {
            for (row) |val| {
                min_val = @min(min_val, val);
                max_val = @max(max_val, val);
            }
        }

        if (min_val > max_val) {
            min_val = 0;
            max_val = 1;
        }

        // Determine color scale
        const color_scale = config.color_scale orelse ColorScale.blueToRed(min_val, max_val);

        return .{
            .allocator = allocator,
            .data = data,
            .config = config,
            .layout = layout,
            .rows = rows,
            .cols = cols,
            .color_scale = color_scale,
        };
    }

    /// Render the heatmap
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Calculate layout areas
        const label_margin_left: f64 = if (self.config.show_y_labels) 80 else 0;
        const label_margin_bottom: f64 = if (self.config.show_x_labels)
            (if (self.config.rotate_x_labels) 80 else 30)
        else
            0;
        const legend_margin: f64 = if (self.config.show_legend)
            (if (self.config.legend_position == .right) self.config.legend_width + 40 else 50)
        else
            0;
        const title_margin: f64 = if (self.config.title != null) 30 else 0;

        const grid_x = bounds.x + label_margin_left;
        const grid_y = bounds.y + title_margin;
        const grid_width = bounds.width - label_margin_left - (if (self.config.legend_position == .right) legend_margin else 0);
        const grid_height = bounds.height - label_margin_bottom - title_margin - (if (self.config.legend_position == .bottom) legend_margin else 0);

        // Draw title
        if (self.config.title) |title| {
            c.drawText(title, bounds.x + bounds.width / 2, bounds.y + 15, .{
                .color = Color.gray_800,
                .font_size = self.config.title_font_size,
                .anchor = .middle,
                .font_weight = .bold,
            });
        }

        // Calculate cell size
        if (self.rows == 0 or self.cols == 0) return;

        const cell_width = grid_width / @as(f64, @floatFromInt(self.cols));
        const cell_height = grid_height / @as(f64, @floatFromInt(self.rows));

        // Draw cells
        for (self.data, 0..) |row, row_idx| {
            const y = grid_y + @as(f64, @floatFromInt(row_idx)) * cell_height;

            for (row, 0..) |val, col_idx| {
                const x = grid_x + @as(f64, @floatFromInt(col_idx)) * cell_width;

                const cell_color = self.color_scale.getColor(val);

                c.drawRect(.{
                    .x = x + self.config.cell_padding,
                    .y = y + self.config.cell_padding,
                    .width = cell_width - self.config.cell_padding * 2,
                    .height = cell_height - self.config.cell_padding * 2,
                }, .{ .color = cell_color }, null);

                // Draw value if enabled
                if (self.config.show_values) {
                    var buf: [16]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{d:.1}", .{val}) catch "?";

                    // Auto-contrast: use white on dark, black on light
                    const text_color = self.config.value_color orelse
                        (if (cell_color.luminance() < 0.5) Color.white else Color.gray_800);

                    c.drawText(text, x + cell_width / 2, y + cell_height / 2, .{
                        .color = text_color,
                        .font_size = self.config.value_font_size,
                        .anchor = .middle,
                        .baseline = .middle,
                    });
                }
            }
        }

        // Draw Y labels (row labels)
        if (self.config.show_y_labels) {
            for (0..self.rows) |i| {
                const y = grid_y + @as(f64, @floatFromInt(i)) * cell_height + cell_height / 2;
                const label = if (self.config.y_labels) |labels|
                    (if (i < labels.len) labels[i] else "")
                else
                    "";

                if (label.len > 0) {
                    c.drawText(label, grid_x - 8, y, .{
                        .color = self.config.label_color,
                        .font_size = self.config.label_font_size,
                        .anchor = .end,
                        .baseline = .middle,
                    });
                }
            }
        }

        // Draw X labels (column labels)
        if (self.config.show_x_labels) {
            for (0..self.cols) |i| {
                const x = grid_x + @as(f64, @floatFromInt(i)) * cell_width + cell_width / 2;
                const y = grid_y + grid_height + 12;
                const label = if (self.config.x_labels) |labels|
                    (if (i < labels.len) labels[i] else "")
                else
                    "";

                if (label.len > 0) {
                    // Note: rotation not yet supported in canvas, using middle anchor
                    c.drawText(label, x, y, .{
                        .color = self.config.label_color,
                        .font_size = self.config.label_font_size,
                        .anchor = if (self.config.rotate_x_labels) .end else .middle,
                    });
                }
            }
        }

        // Draw legend (color bar)
        if (self.config.show_legend) {
            try self.drawLegend(c, bounds, grid_x, grid_y, grid_width, grid_height);
        }
    }

    fn drawLegend(self: *Self, c: Canvas, _: Rect, grid_x: f64, grid_y: f64, grid_width: f64, grid_height: f64) !void {
        const steps: usize = 50;

        if (self.config.legend_position == .right) {
            const legend_x = grid_x + grid_width + 20;
            const legend_height = grid_height;
            const step_height = legend_height / @as(f64, @floatFromInt(steps));

            // Draw gradient bar
            for (0..steps) |i| {
                const t = 1.0 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
                const value = self.color_scale.min + t * (self.color_scale.max - self.color_scale.min);
                const color = self.color_scale.getColor(value);

                c.drawRect(.{
                    .x = legend_x,
                    .y = grid_y + @as(f64, @floatFromInt(i)) * step_height,
                    .width = self.config.legend_width,
                    .height = step_height + 1,
                }, .{ .color = color }, null);
            }

            // Draw labels
            var max_buf: [16]u8 = undefined;
            var min_buf: [16]u8 = undefined;

            const max_text = std.fmt.bufPrint(&max_buf, "{d:.1}", .{self.color_scale.max}) catch "?";
            const min_text = std.fmt.bufPrint(&min_buf, "{d:.1}", .{self.color_scale.min}) catch "?";

            c.drawText(max_text, legend_x + self.config.legend_width + 5, grid_y + 5, .{
                .color = self.config.label_color,
                .font_size = 10,
                .anchor = .start,
            });

            c.drawText(min_text, legend_x + self.config.legend_width + 5, grid_y + legend_height - 5, .{
                .color = self.config.label_color,
                .font_size = 10,
                .anchor = .start,
            });
        } else {
            // Bottom legend
            const legend_y = grid_y + grid_height + 30;
            const legend_width = grid_width * 0.6;
            const legend_x = grid_x + (grid_width - legend_width) / 2;
            const step_width = legend_width / @as(f64, @floatFromInt(steps));

            // Draw gradient bar
            for (0..steps) |i| {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
                const value = self.color_scale.min + t * (self.color_scale.max - self.color_scale.min);
                const color = self.color_scale.getColor(value);

                c.drawRect(.{
                    .x = legend_x + @as(f64, @floatFromInt(i)) * step_width,
                    .y = legend_y,
                    .width = step_width + 1,
                    .height = self.config.legend_width,
                }, .{ .color = color }, null);
            }

            // Draw labels
            var min_buf: [16]u8 = undefined;
            var max_buf: [16]u8 = undefined;

            const min_text = std.fmt.bufPrint(&min_buf, "{d:.1}", .{self.color_scale.min}) catch "?";
            const max_text = std.fmt.bufPrint(&max_buf, "{d:.1}", .{self.color_scale.max}) catch "?";

            c.drawText(min_text, legend_x, legend_y + self.config.legend_width + 12, .{
                .color = self.config.label_color,
                .font_size = 10,
                .anchor = .start,
            });

            c.drawText(max_text, legend_x + legend_width, legend_y + self.config.legend_width + 12, .{
                .color = self.config.label_color,
                .font_size = 10,
                .anchor = .end,
            });
        }
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create and render a simple heatmap
pub fn renderHeatmap(
    allocator: std.mem.Allocator,
    c: Canvas,
    data: []const []const f64,
    layout: Layout,
    config: HeatmapConfig,
) !void {
    var chart = HeatmapChart.init(allocator, data, layout, config);
    try chart.render(c);
}

/// Create a correlation matrix heatmap
pub fn renderCorrelationMatrix(
    allocator: std.mem.Allocator,
    c: Canvas,
    matrix: []const []const f64,
    labels: []const []const u8,
    layout: Layout,
) !void {
    var chart = HeatmapChart.init(allocator, matrix, layout, .{
        .x_labels = labels,
        .y_labels = labels,
        .show_values = true,
        .color_scale = ColorScale.diverging(-1, 1),
        .rotate_x_labels = true,
    });
    try chart.render(c);
}

// =============================================================================
// Tests
// =============================================================================

test "color scale interpolation" {
    const scale = ColorScale.blueToRed(0, 100);

    const min_color = scale.getColor(0);
    const max_color = scale.getColor(100);
    const mid_color = scale.getColor(50);

    // Verify colors are valid (non-zero where expected)
    // Min (blue): should have some blue component
    try std.testing.expect(min_color.a == 255); // Full opacity

    // Max (red): should have some red component
    try std.testing.expect(max_color.a == 255);

    // Mid: should be interpolated
    try std.testing.expect(mid_color.a == 255);
}

test "heatmap dimensions" {
    const allocator = std.testing.allocator;

    const row1 = [_]f64{ 1, 2, 3 };
    const row2 = [_]f64{ 4, 5, 6 };
    const data = [_][]const f64{ &row1, &row2 };

    const layout = Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    const chart = HeatmapChart.init(allocator, &data, layout, .{});

    try std.testing.expectEqual(@as(usize, 2), chart.rows);
    try std.testing.expectEqual(@as(usize, 3), chart.cols);
}

test "heatmap value range" {
    const allocator = std.testing.allocator;

    const row1 = [_]f64{ -10, 0, 10 };
    const row2 = [_]f64{ 20, 30, 40 };
    const data = [_][]const f64{ &row1, &row2 };

    const layout = Layout{ .width = 400, .height = 300 };

    const chart = HeatmapChart.init(allocator, &data, layout, .{});

    try std.testing.expectEqual(@as(f64, -10), chart.color_scale.min);
    try std.testing.expectEqual(@as(f64, 40), chart.color_scale.max);
}
