//! Sparkline Charts
//!
//! Compact inline charts for embedding in text, tables, or dashboards.
//! Minimal, no axes, just the data.

const std = @import("std");
const canvas = @import("../canvas.zig");
const scales = @import("../scales.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Path = canvas.Path;
const Rect = canvas.Rect;
const LinearScale = scales.LinearScale;

/// Sparkline configuration
pub const SparklineConfig = struct {
    // Appearance
    line_color: Color = Color.blue_500,
    line_width: f64 = 1.5,
    fill: bool = false,
    fill_color: ?Color = null, // Default: line_color with transparency
    fill_opacity: f64 = 0.2,

    // Markers
    show_first: bool = false,
    show_last: bool = true,
    show_min: bool = false,
    show_max: bool = false,
    marker_radius: f64 = 2.5,
    first_color: Color = Color.gray_500,
    last_color: Color = Color.blue_600,
    min_color: Color = Color.bear_red,
    max_color: Color = Color.bull_green,

    // Reference line
    show_reference: bool = false,
    reference_value: f64 = 0,
    reference_color: Color = Color.gray_300,
    reference_dash: []const f64 = &[_]f64{ 2, 2 },

    // Bounds
    min_value: ?f64 = null, // Force minimum (for consistent scales)
    max_value: ?f64 = null, // Force maximum
};

/// Render a sparkline
pub fn render(
    allocator: std.mem.Allocator,
    c: Canvas,
    data: []const f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    config: SparklineConfig,
) !void {
    if (data.len == 0) return;

    // Calculate data bounds
    var min_val: f64 = config.min_value orelse std.math.floatMax(f64);
    var max_val: f64 = config.max_value orelse -std.math.floatMax(f64);
    var min_idx: usize = 0;
    var max_idx: usize = 0;

    for (data, 0..) |v, i| {
        if (config.min_value == null and v < min_val) {
            min_val = v;
            min_idx = i;
        }
        if (config.max_value == null and v > max_val) {
            max_val = v;
            max_idx = i;
        }
    }

    // Handle flat data
    if (max_val == min_val) {
        max_val = min_val + 1;
    }

    // Add small padding
    const padding = (max_val - min_val) * 0.05;
    if (config.min_value == null) min_val -= padding;
    if (config.max_value == null) max_val += padding;

    // Create scales
    const x_scale = LinearScale.init(0, @as(f64, @floatFromInt(data.len - 1)), x, x + width);
    const y_scale = LinearScale.init(min_val, max_val, y + height, y);

    // Draw reference line
    if (config.show_reference) {
        const ref_y = y_scale.scale(config.reference_value);
        if (ref_y >= y and ref_y <= y + height) {
            c.drawLine(x, ref_y, x + width, ref_y, .{
                .color = config.reference_color,
                .width = 1.0,
                .dash_array = config.reference_dash,
            });
        }
    }

    // Build path
    var path = Path.init(allocator);
    defer path.deinit();

    const first_x = x_scale.scale(0);
    const first_y = y_scale.scale(data[0]);
    try path.moveTo(first_x, first_y);

    for (data[1..], 1..) |v, i| {
        const px = x_scale.scale(@floatFromInt(i));
        const py = y_scale.scale(v);
        try path.lineTo(px, py);
    }

    // Draw fill area
    if (config.fill) {
        var fill_path = Path.init(allocator);
        defer fill_path.deinit();

        try fill_path.moveTo(first_x, y + height);
        try fill_path.lineTo(first_x, first_y);

        for (data[1..], 1..) |v, i| {
            const px = x_scale.scale(@floatFromInt(i));
            const py = y_scale.scale(v);
            try fill_path.lineTo(px, py);
        }

        try fill_path.lineTo(x_scale.scale(@floatFromInt(data.len - 1)), y + height);
        try fill_path.close();

        const fill_color = config.fill_color orelse config.line_color;
        c.drawPath(&fill_path, null, .{
            .color = fill_color.withAlpha(@intFromFloat(config.fill_opacity * 255)),
        });
    }

    // Draw line
    c.drawPath(&path, .{
        .color = config.line_color,
        .width = config.line_width,
        .line_cap = .round,
        .line_join = .round,
    }, null);

    // Draw markers
    if (config.show_first) {
        c.drawCircle(first_x, first_y, config.marker_radius, null, .{ .color = config.first_color });
    }

    if (config.show_last) {
        const last_x = x_scale.scale(@floatFromInt(data.len - 1));
        const last_y = y_scale.scale(data[data.len - 1]);
        c.drawCircle(last_x, last_y, config.marker_radius, null, .{ .color = config.last_color });
    }

    if (config.show_min) {
        const mx = x_scale.scale(@floatFromInt(min_idx));
        const my = y_scale.scale(data[min_idx]);
        c.drawCircle(mx, my, config.marker_radius, null, .{ .color = config.min_color });
    }

    if (config.show_max) {
        const mx = x_scale.scale(@floatFromInt(max_idx));
        const my = y_scale.scale(data[max_idx]);
        c.drawCircle(mx, my, config.marker_radius, null, .{ .color = config.max_color });
    }
}

/// Sparkline variant types
pub const SparklineType = enum {
    line,
    bar,
    area,
    win_loss,
};

/// Bar sparkline (for discrete values)
pub fn renderBars(
    c: Canvas,
    data: []const f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    positive_color: Color,
    negative_color: Color,
) void {
    if (data.len == 0) return;

    // Calculate bounds
    var min_val: f64 = std.math.floatMax(f64);
    var max_val: f64 = -std.math.floatMax(f64);

    for (data) |v| {
        min_val = @min(min_val, v);
        max_val = @max(max_val, v);
    }

    // Include zero in range for proper bar direction
    min_val = @min(min_val, 0);
    max_val = @max(max_val, 0);

    if (max_val == min_val) max_val = min_val + 1;

    const y_scale = LinearScale.init(min_val, max_val, y + height, y);
    const bar_width = width / @as(f64, @floatFromInt(data.len));
    const zero_y = y_scale.scale(0);

    for (data, 0..) |v, i| {
        const bx = x + @as(f64, @floatFromInt(i)) * bar_width;
        const by = y_scale.scale(v);

        const bar_top = @min(by, zero_y);
        const bar_height = @abs(by - zero_y);
        const color = if (v >= 0) positive_color else negative_color;

        c.drawRect(
            Rect.init(bx + 1, bar_top, bar_width - 2, @max(1, bar_height)),
            null,
            .{ .color = color },
        );
    }
}

/// Win/Loss sparkline (binary up/down indicators)
pub fn renderWinLoss(
    c: Canvas,
    data: []const bool,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    win_color: Color,
    loss_color: Color,
) void {
    if (data.len == 0) return;

    const bar_width = width / @as(f64, @floatFromInt(data.len));
    const half_height = height / 2;

    for (data, 0..) |is_win, i| {
        const bx = x + @as(f64, @floatFromInt(i)) * bar_width;

        const bar_y = if (is_win) y else y + half_height;
        const color = if (is_win) win_color else loss_color;

        c.drawRect(
            Rect.init(bx + 1, bar_y, bar_width - 2, half_height - 1),
            null,
            .{ .color = color },
        );
    }
}

// =============================================================================
// Tests
// =============================================================================

test "sparkline basic render" {
    const allocator = std.testing.allocator;
    const svg = @import("../svg.zig");

    var canvas_impl = svg.SvgCanvas.init(allocator, 100, 30);
    defer canvas_impl.deinit();

    const c = canvas_impl.canvas();

    const data = [_]f64{ 10, 15, 8, 22, 18, 25, 20 };
    try render(allocator, c, &data, 0, 0, 100, 30, .{});

    const output = try c.finish();
    try std.testing.expect(std.mem.indexOf(u8, output, "<path") != null);
}
