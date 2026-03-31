//! Gauge Charts
//!
//! Circular arc gauges for displaying single values within a range.
//! Supports zones (colors for different ranges), needle, and labels.

const std = @import("std");
const canvas = @import("../canvas.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Path = canvas.Path;
const TextAnchor = canvas.TextAnchor;

/// A zone in the gauge (colored range)
pub const GaugeZone = struct {
    max: f64, // Upper bound of this zone
    color: Color,
};

/// Gauge chart configuration
pub const GaugeConfig = struct {
    // Range
    min: f64 = 0,
    max: f64 = 100,

    // Arc settings
    start_angle: f64 = -135, // Degrees from 3 o'clock position
    end_angle: f64 = 135, // Degrees
    arc_width: f64 = 30, // Width of the gauge arc

    // Zones (colored ranges)
    zones: []const GaugeZone = &[_]GaugeZone{
        .{ .max = 33, .color = Color.fromHex("10B981").? }, // green
        .{ .max = 66, .color = Color.fromHex("F59E0B").? }, // yellow
        .{ .max = 100, .color = Color.fromHex("EF4444").? }, // red
    },
    background_color: Color = Color.gray_200,

    // Needle
    show_needle: bool = true,
    needle_color: Color = Color.gray_800,
    needle_width: f64 = 4,
    center_circle_radius: f64 = 10,
    center_circle_color: Color = Color.gray_700,

    // Labels
    show_value: bool = true,
    value_font_size: f64 = 32,
    value_color: Color = Color.gray_800,
    show_label: bool = true,
    label_font_size: f64 = 14,
    label_color: Color = Color.gray_600,
    show_min_max: bool = true,
    min_max_font_size: f64 = 12,

    // Ticks
    show_ticks: bool = true,
    major_tick_count: usize = 5,
    minor_tick_count: usize = 4, // Between each major tick
    major_tick_length: f64 = 15,
    minor_tick_length: f64 = 8,
    tick_color: Color = Color.gray_500,
};

/// Gauge chart renderer
pub const GaugeChart = struct {
    allocator: std.mem.Allocator,
    value: f64,
    label: []const u8,
    config: GaugeConfig,
    layout: Layout,

    // Computed values
    center_x: f64,
    center_y: f64,
    outer_radius: f64,
    inner_radius: f64,
    angle_range: f64,

    const Self = @This();

    /// Create a gauge chart
    pub fn init(
        allocator: std.mem.Allocator,
        value: f64,
        label: []const u8,
        layout: Layout,
        config: GaugeConfig,
    ) Self {
        const bounds = layout.innerBounds();

        const center_x = bounds.x + bounds.width / 2;
        // Offset center down for semi-circle gauges
        const center_y = bounds.y + bounds.height * 0.55;

        const margin: f64 = 30;
        const max_radius = @min(bounds.width / 2, bounds.height * 0.8) - margin;
        const outer_radius = @max(20, max_radius);
        const inner_radius = outer_radius - config.arc_width;

        const start_rad = config.start_angle * std.math.pi / 180.0;
        const end_rad = config.end_angle * std.math.pi / 180.0;
        const angle_range = end_rad - start_rad;

        return .{
            .allocator = allocator,
            .value = std.math.clamp(value, config.min, config.max),
            .label = label,
            .config = config,
            .layout = layout,
            .center_x = center_x,
            .center_y = center_y,
            .outer_radius = outer_radius,
            .inner_radius = inner_radius,
            .angle_range = angle_range,
        };
    }

    /// Render the gauge chart
    pub fn render(self: *Self, c: Canvas) !void {
        // Draw background arc
        try self.drawArc(c, self.config.min, self.config.max, self.config.background_color);

        // Draw zone arcs
        var prev_max = self.config.min;
        for (self.config.zones) |zone| {
            const zone_max = @min(zone.max, self.config.max);
            if (zone_max > prev_max) {
                try self.drawArc(c, prev_max, zone_max, zone.color);
                prev_max = zone_max;
            }
        }

        // Draw ticks
        if (self.config.show_ticks) {
            try self.drawTicks(c);
        }

        // Draw needle
        if (self.config.show_needle) {
            try self.drawNeedle(c);
        }

        // Draw center circle
        c.drawCircle(self.center_x, self.center_y, self.config.center_circle_radius, .{
            .color = self.config.center_circle_color,
        }, null);

        // Draw value text
        if (self.config.show_value) {
            var buf: [32]u8 = undefined;
            const value_text = std.fmt.bufPrint(&buf, "{d:.0}", .{self.value}) catch "?";
            c.drawText(value_text, self.center_x, self.center_y + self.outer_radius * 0.3, .{
                .color = self.config.value_color,
                .font_size = self.config.value_font_size,
                .anchor = .middle,
                .font_weight = .bold,
            });
        }

        // Draw label
        if (self.config.show_label and self.label.len > 0) {
            c.drawText(self.label, self.center_x, self.center_y + self.outer_radius * 0.55, .{
                .color = self.config.label_color,
                .font_size = self.config.label_font_size,
                .anchor = .middle,
            });
        }

        // Draw min/max labels
        if (self.config.show_min_max) {
            try self.drawMinMaxLabels(c);
        }
    }

    fn valueToAngle(self: *Self, value: f64) f64 {
        const normalized = (value - self.config.min) / (self.config.max - self.config.min);
        const start_rad = self.config.start_angle * std.math.pi / 180.0;
        return start_rad + normalized * self.angle_range;
    }

    fn drawArc(self: *Self, c: Canvas, from_value: f64, to_value: f64, color: Color) !void {
        const start_angle = self.valueToAngle(from_value);
        const end_angle = self.valueToAngle(to_value);

        var path = Path.init(self.allocator);
        defer path.deinit();

        // Outer arc start
        const outer_start_x = self.center_x + @cos(start_angle) * self.outer_radius;
        const outer_start_y = self.center_y + @sin(start_angle) * self.outer_radius;

        // Outer arc end
        const outer_end_x = self.center_x + @cos(end_angle) * self.outer_radius;
        const outer_end_y = self.center_y + @sin(end_angle) * self.outer_radius;

        // Inner arc
        const inner_end_x = self.center_x + @cos(end_angle) * self.inner_radius;
        const inner_end_y = self.center_y + @sin(end_angle) * self.inner_radius;
        const inner_start_x = self.center_x + @cos(start_angle) * self.inner_radius;
        const inner_start_y = self.center_y + @sin(start_angle) * self.inner_radius;

        const sweep = end_angle - start_angle;
        const large_arc = sweep > std.math.pi;

        try path.moveTo(outer_start_x, outer_start_y);
        try path.arcTo(self.outer_radius, self.outer_radius, 0, large_arc, true, outer_end_x, outer_end_y);
        try path.lineTo(inner_end_x, inner_end_y);
        try path.arcTo(self.inner_radius, self.inner_radius, 0, large_arc, false, inner_start_x, inner_start_y);
        try path.close();

        c.drawPath(&path, null, .{ .color = color });
    }

    fn drawNeedle(self: *Self, c: Canvas) !void {
        const angle = self.valueToAngle(self.value);

        // Needle tip at outer radius
        const tip_x = self.center_x + @cos(angle) * (self.outer_radius - 5);
        const tip_y = self.center_y + @sin(angle) * (self.outer_radius - 5);

        // Needle base (perpendicular to angle, at center)
        const base_offset = self.config.needle_width / 2;
        const perp_angle = angle + std.math.pi / 2.0;
        const base1_x = self.center_x + @cos(perp_angle) * base_offset;
        const base1_y = self.center_y + @sin(perp_angle) * base_offset;
        const base2_x = self.center_x - @cos(perp_angle) * base_offset;
        const base2_y = self.center_y - @sin(perp_angle) * base_offset;

        var path = Path.init(self.allocator);
        defer path.deinit();

        try path.moveTo(base1_x, base1_y);
        try path.lineTo(tip_x, tip_y);
        try path.lineTo(base2_x, base2_y);
        try path.close();

        c.drawPath(&path, null, .{ .color = self.config.needle_color });
    }

    fn drawTicks(self: *Self, c: Canvas) !void {
        const total_major = self.config.major_tick_count;
        const minor_per_major = self.config.minor_tick_count;

        for (0..total_major + 1) |i| {
            // Major tick
            const major_value = self.config.min + @as(f64, @floatFromInt(i)) * (self.config.max - self.config.min) / @as(f64, @floatFromInt(total_major));
            try self.drawTick(c, major_value, self.config.major_tick_length);

            // Minor ticks between major ticks
            if (i < total_major) {
                for (1..minor_per_major + 1) |j| {
                    const minor_offset = @as(f64, @floatFromInt(j)) * (self.config.max - self.config.min) / @as(f64, @floatFromInt(total_major)) / @as(f64, @floatFromInt(minor_per_major + 1));
                    const minor_value = major_value + minor_offset;
                    try self.drawTick(c, minor_value, self.config.minor_tick_length);
                }
            }
        }
    }

    fn drawTick(self: *Self, c: Canvas, value: f64, length: f64) !void {
        const angle = self.valueToAngle(value);
        const outer_x = self.center_x + @cos(angle) * self.outer_radius;
        const outer_y = self.center_y + @sin(angle) * self.outer_radius;
        const inner_x = self.center_x + @cos(angle) * (self.outer_radius - length);
        const inner_y = self.center_y + @sin(angle) * (self.outer_radius - length);

        c.drawLine(outer_x, outer_y, inner_x, inner_y, .{
            .color = self.config.tick_color,
            .width = 2,
        });
    }

    fn drawMinMaxLabels(self: *Self, c: Canvas) !void {
        var min_buf: [16]u8 = undefined;
        var max_buf: [16]u8 = undefined;

        const min_text = std.fmt.bufPrint(&min_buf, "{d:.0}", .{self.config.min}) catch "?";
        const max_text = std.fmt.bufPrint(&max_buf, "{d:.0}", .{self.config.max}) catch "?";

        const min_angle = self.valueToAngle(self.config.min);
        const max_angle = self.valueToAngle(self.config.max);

        const label_radius = self.outer_radius + 15;

        const min_x = self.center_x + @cos(min_angle) * label_radius;
        const min_y = self.center_y + @sin(min_angle) * label_radius;

        const max_x = self.center_x + @cos(max_angle) * label_radius;
        const max_y = self.center_y + @sin(max_angle) * label_radius;

        c.drawText(min_text, min_x, min_y, .{
            .color = self.config.label_color,
            .font_size = self.config.min_max_font_size,
            .anchor = .middle,
        });

        c.drawText(max_text, max_x, max_y, .{
            .color = self.config.label_color,
            .font_size = self.config.min_max_font_size,
            .anchor = .middle,
        });
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a simple gauge chart
pub fn renderGauge(
    allocator: std.mem.Allocator,
    c: Canvas,
    value: f64,
    label: []const u8,
    layout: Layout,
    config: GaugeConfig,
) !void {
    var chart = GaugeChart.init(allocator, value, label, layout, config);
    try chart.render(c);
}

// =============================================================================
// Tests
// =============================================================================

test "gauge value clamping" {
    const allocator = std.testing.allocator;
    const layout = Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    // Value above max
    const gauge1 = GaugeChart.init(allocator, 150, "Test", layout, .{ .max = 100 });
    try std.testing.expectEqual(@as(f64, 100), gauge1.value);

    // Value below min
    const gauge2 = GaugeChart.init(allocator, -10, "Test", layout, .{ .min = 0 });
    try std.testing.expectEqual(@as(f64, 0), gauge2.value);
}

test "gauge angle calculation" {
    const allocator = std.testing.allocator;
    const layout = Layout{
        .width = 400,
        .height = 300,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    var gauge = GaugeChart.init(allocator, 50, "Test", layout, .{
        .min = 0,
        .max = 100,
        .start_angle = -90,
        .end_angle = 90,
    });

    // 50% should be at 0 degrees (horizontal right)
    const angle = gauge.valueToAngle(50);
    try std.testing.expectApproxEqAbs(@as(f64, 0), angle, 0.001);
}
