//! Axis Rendering
//!
//! Draws X and Y axes with ticks, labels, and grid lines.

const std = @import("std");
const canvas = @import("canvas.zig");
const scales = @import("scales.zig");
const Color = @import("color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const StrokeStyle = canvas.StrokeStyle;
const TextStyle = canvas.TextStyle;
const LinearScale = scales.LinearScale;
const TimeScale = scales.TimeScale;
const BandScale = scales.BandScale;

/// Axis configuration
pub const AxisConfig = struct {
    // Appearance
    line_color: Color = Color.gray_400,
    line_width: f64 = 1.0,
    tick_color: Color = Color.gray_400,
    tick_length: f64 = 5.0,
    label_color: Color = Color.gray_600,
    label_font_size: f64 = 11.0,
    label_font_family: []const u8 = "sans-serif",
    label_offset: f64 = 8.0,

    // Grid
    show_grid: bool = true,
    grid_color: Color = Color.gray_200,
    grid_dash: ?[]const f64 = null,

    // Title
    title: ?[]const u8 = null,
    title_font_size: f64 = 13.0,
    title_offset: f64 = 35.0,

    // Tick formatting
    tick_count: usize = 5,
    format_fn: ?*const fn (f64, []u8) []const u8 = null,
};

/// X-axis (horizontal, typically at bottom)
pub fn drawXAxis(
    c: Canvas,
    allocator: std.mem.Allocator,
    layout: Layout,
    scale: LinearScale,
    config: AxisConfig,
) !void {
    const bounds = layout.innerBounds();
    const y = bounds.y + bounds.height;

    // Axis line
    c.drawLine(
        bounds.x,
        y,
        bounds.x + bounds.width,
        y,
        .{ .color = config.line_color, .width = config.line_width },
    );

    // Generate ticks
    const tick_values = try scale.ticks(allocator, config.tick_count);
    defer allocator.free(tick_values);

    for (tick_values) |value| {
        const x = scale.scale(value);
        if (x < bounds.x or x > bounds.x + bounds.width) continue;

        // Tick mark
        c.drawLine(
            x,
            y,
            x,
            y + config.tick_length,
            .{ .color = config.tick_color, .width = 1.0 },
        );

        // Grid line
        if (config.show_grid) {
            c.drawLine(
                x,
                bounds.y,
                x,
                y,
                .{
                    .color = config.grid_color,
                    .width = 1.0,
                    .dash_array = config.grid_dash,
                },
            );
        }

        // Label
        var label_buf: [32]u8 = undefined;
        const label = if (config.format_fn) |fmt|
            fmt(value, &label_buf)
        else
            formatNumber(value, &label_buf);

        c.drawText(
            label,
            x,
            y + config.tick_length + config.label_offset,
            .{
                .font_family = config.label_font_family,
                .font_size = config.label_font_size,
                .color = config.label_color,
                .anchor = .middle,
                .baseline = .top,
            },
        );
    }

    // Title
    if (config.title) |title| {
        c.drawText(
            title,
            bounds.x + bounds.width / 2,
            y + config.title_offset,
            .{
                .font_family = config.label_font_family,
                .font_size = config.title_font_size,
                .color = config.label_color,
                .anchor = .middle,
                .baseline = .top,
            },
        );
    }
}

/// Y-axis (vertical, typically at left)
pub fn drawYAxis(
    c: Canvas,
    allocator: std.mem.Allocator,
    layout: Layout,
    scale: LinearScale,
    config: AxisConfig,
) !void {
    const bounds = layout.innerBounds();
    const x = bounds.x;

    // Axis line
    c.drawLine(
        x,
        bounds.y,
        x,
        bounds.y + bounds.height,
        .{ .color = config.line_color, .width = config.line_width },
    );

    // Generate ticks
    const tick_values = try scale.ticks(allocator, config.tick_count);
    defer allocator.free(tick_values);

    for (tick_values) |value| {
        const y = scale.scale(value);
        if (y < bounds.y or y > bounds.y + bounds.height) continue;

        // Tick mark
        c.drawLine(
            x - config.tick_length,
            y,
            x,
            y,
            .{ .color = config.tick_color, .width = 1.0 },
        );

        // Grid line
        if (config.show_grid) {
            c.drawLine(
                x,
                y,
                bounds.x + bounds.width,
                y,
                .{
                    .color = config.grid_color,
                    .width = 1.0,
                    .dash_array = config.grid_dash,
                },
            );
        }

        // Label
        var label_buf: [32]u8 = undefined;
        const label = if (config.format_fn) |fmt|
            fmt(value, &label_buf)
        else
            formatNumber(value, &label_buf);

        c.drawText(
            label,
            x - config.tick_length - config.label_offset,
            y,
            .{
                .font_family = config.label_font_family,
                .font_size = config.label_font_size,
                .color = config.label_color,
                .anchor = .end,
                .baseline = .middle,
            },
        );
    }

    // Title (rotated)
    if (config.title) |title| {
        // For SVG, we'd need to use transform. For now, skip rotation.
        c.drawText(
            title,
            config.label_offset,
            bounds.y + bounds.height / 2,
            .{
                .font_family = config.label_font_family,
                .font_size = config.title_font_size,
                .color = config.label_color,
                .anchor = .middle,
                .baseline = .middle,
            },
        );
    }
}

/// X-axis for time data
pub fn drawTimeXAxis(
    c: Canvas,
    allocator: std.mem.Allocator,
    layout: Layout,
    scale: TimeScale,
    config: AxisConfig,
) !void {
    const bounds = layout.innerBounds();
    const y = bounds.y + bounds.height;

    // Axis line
    c.drawLine(
        bounds.x,
        y,
        bounds.x + bounds.width,
        y,
        .{ .color = config.line_color, .width = config.line_width },
    );

    // Generate ticks
    const tick_values = try scale.ticks(allocator, config.tick_count);
    defer allocator.free(tick_values);

    for (tick_values) |timestamp| {
        const x = scale.scale(timestamp);
        if (x < bounds.x or x > bounds.x + bounds.width) continue;

        // Tick mark
        c.drawLine(
            x,
            y,
            x,
            y + config.tick_length,
            .{ .color = config.tick_color, .width = 1.0 },
        );

        // Grid line
        if (config.show_grid) {
            c.drawLine(
                x,
                bounds.y,
                x,
                y,
                .{
                    .color = config.grid_color,
                    .width = 1.0,
                    .dash_array = config.grid_dash,
                },
            );
        }

        // Label
        var label_buf: [32]u8 = undefined;
        const label = formatTimestamp(timestamp, &label_buf);

        c.drawText(
            label,
            x,
            y + config.tick_length + config.label_offset,
            .{
                .font_family = config.label_font_family,
                .font_size = config.label_font_size,
                .color = config.label_color,
                .anchor = .middle,
                .baseline = .top,
            },
        );
    }
}

/// X-axis for categorical data (bar charts)
pub fn drawBandXAxis(
    c: Canvas,
    layout: Layout,
    scale: BandScale,
    config: AxisConfig,
) void {
    const bounds = layout.innerBounds();
    const y = bounds.y + bounds.height;

    // Axis line
    c.drawLine(
        bounds.x,
        y,
        bounds.x + bounds.width,
        y,
        .{ .color = config.line_color, .width = config.line_width },
    );

    // Draw category labels
    const bw = scale.bandwidth();
    for (scale.domain, 0..) |category, i| {
        const x = scale.scale(i) + bw / 2;

        c.drawText(
            category,
            x,
            y + config.tick_length + config.label_offset,
            .{
                .font_family = config.label_font_family,
                .font_size = config.label_font_size,
                .color = config.label_color,
                .anchor = .middle,
                .baseline = .top,
            },
        );
    }
}

// =============================================================================
// Formatting Helpers
// =============================================================================

fn formatNumber(value: f64, buf: []u8) []const u8 {
    const abs_val = @abs(value);

    // Use engineering notation for large/small numbers
    if (abs_val >= 1_000_000) {
        const len = std.fmt.bufPrint(buf, "{d:.1}M", .{value / 1_000_000}) catch return "?";
        return buf[0..len.len];
    } else if (abs_val >= 1_000) {
        const len = std.fmt.bufPrint(buf, "{d:.1}K", .{value / 1_000}) catch return "?";
        return buf[0..len.len];
    } else if (abs_val < 0.01 and abs_val > 0) {
        const len = std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch return "?";
        return buf[0..len.len];
    } else if (abs_val == @trunc(abs_val)) {
        const len = std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch return "?";
        return buf[0..len.len];
    } else {
        const len = std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return "?";
        return buf[0..len.len];
    }
}

fn formatTimestamp(timestamp: i64, buf: []u8) []const u8 {
    if (timestamp < 0) {
        const len = std.fmt.bufPrint(buf, "{d}", .{timestamp}) catch return "?";
        return buf[0..len.len];
    }
    const secs: u64 = @intCast(timestamp);

    // Epoch timestamps (after 2001-01-01) — show full date/time
    if (secs > 978_307_200) {
        // Convert to date components
        const days_since_epoch = secs / 86400;
        const time_of_day = secs % 86400;
        const hours = time_of_day / 3600;
        const minutes = (time_of_day % 3600) / 60;

        // Calculate year/month/day from days since 1970-01-01
        var remaining_days = days_since_epoch;
        var year: u32 = 1970;
        while (true) {
            const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }

        const days_in_months = [_]u32{ 31, if (isLeapYear(year)) @as(u32, 29) else @as(u32, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: u32 = 1;
        for (days_in_months) |dim| {
            if (remaining_days < dim) break;
            remaining_days -= dim;
            month += 1;
        }
        const day = remaining_days + 1;

        const len = std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ year, month, day, hours, minutes }) catch return "????-??-??";
        return buf[0..len.len];
    }

    // Small values — treat as time within a day
    const hours = (secs / 3600) % 24;
    const minutes = (secs % 3600) / 60;
    const seconds = secs % 60;

    if (secs < 3600) {
        // Less than an hour: show MM:SS
        const len = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch return "??:??";
        return buf[0..len.len];
    }

    // Show HH:MM:SS
    const len = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch return "??:??:??";
    return buf[0..len.len];
}

fn isLeapYear(year: u32) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    if (year % 4 == 0) return true;
    return false;
}

/// Format as currency
pub fn formatCurrency(value: f64, buf: []u8) []const u8 {
    const abs_val = @abs(value);
    if (abs_val >= 1_000_000) {
        const len = std.fmt.bufPrint(buf, "${d:.2}M", .{value / 1_000_000}) catch return "$?";
        return buf[0..len.len];
    } else if (abs_val >= 1_000) {
        const len = std.fmt.bufPrint(buf, "${d:.0}K", .{value / 1_000}) catch return "$?";
        return buf[0..len.len];
    } else {
        const len = std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch return "$?";
        return buf[0..len.len];
    }
}

/// Format as percentage
pub fn formatPercent(value: f64, buf: []u8) []const u8 {
    const len = std.fmt.bufPrint(buf, "{d:.1}%", .{value * 100}) catch return "?%";
    return buf[0..len.len];
}

// =============================================================================
// Tests
// =============================================================================

test "format number" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("1.5M", formatNumber(1_500_000, &buf));
    try std.testing.expectEqualStrings("42.5K", formatNumber(42_500, &buf));
    try std.testing.expectEqualStrings("123", formatNumber(123, &buf));
    try std.testing.expectEqualStrings("3.14", formatNumber(3.14159, &buf));
}

test "format currency" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("$1.50M", formatCurrency(1_500_000, &buf));
    try std.testing.expectEqualStrings("$42K", formatCurrency(42_000, &buf));
    try std.testing.expectEqualStrings("$99.99", formatCurrency(99.99, &buf));
}
