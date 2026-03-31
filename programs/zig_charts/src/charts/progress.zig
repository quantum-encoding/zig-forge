//! Progress Bar Charts
//!
//! Horizontal progress bars for displaying completion status.
//! Supports multiple bars, targets, and status indicators.

const std = @import("std");
const canvas = @import("../canvas.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Rect = canvas.Rect;
const TextAnchor = canvas.TextAnchor;

/// Progress status for automatic coloring
pub const ProgressStatus = enum {
    achieved, // >= target
    on_track, // >= 75% of target
    pending, // >= 50% of target
    at_risk, // < 50% of target

    pub fn fromProgress(current: f64, target: f64) ProgressStatus {
        if (target <= 0) return .pending;
        const ratio = current / target;
        if (ratio >= 1.0) return .achieved;
        if (ratio >= 0.75) return .on_track;
        if (ratio >= 0.5) return .pending;
        return .at_risk;
    }

    pub fn toColor(self: ProgressStatus) Color {
        return switch (self) {
            .achieved => Color.fromHex("10B981").?, // green
            .on_track => Color.fromHex("3B82F6").?, // blue
            .pending => Color.fromHex("F59E0B").?, // amber
            .at_risk => Color.fromHex("EF4444").?, // red
        };
    }
};

/// A single progress bar entry
pub const ProgressBar = struct {
    label: []const u8,
    current: f64,
    target: f64,
    color: ?Color = null, // Override automatic color
    status: ?ProgressStatus = null, // Override automatic status
};

/// Progress bar chart configuration
pub const ProgressConfig = struct {
    // Layout
    bar_height: f64 = 24,
    bar_spacing: f64 = 16,
    label_width: f64 = 120,
    value_width: f64 = 80,

    // Appearance
    background_color: Color = Color.gray_200,
    border_radius: f64 = 4,
    use_gradient: bool = true,

    // Labels
    show_labels: bool = true,
    show_values: bool = true,
    show_percentage: bool = true,
    label_font_size: f64 = 14,
    value_font_size: f64 = 12,
    label_color: Color = Color.gray_700,
    value_color: Color = Color.gray_600,

    // Target marker
    show_target: bool = true,
    target_color: Color = Color.gray_500,
    target_width: f64 = 2,
};

/// Progress bar chart renderer
pub const ProgressChart = struct {
    allocator: std.mem.Allocator,
    bars: []const ProgressBar,
    config: ProgressConfig,
    layout: Layout,

    const Self = @This();

    /// Create a progress bar chart
    pub fn init(
        allocator: std.mem.Allocator,
        bars: []const ProgressBar,
        layout: Layout,
        config: ProgressConfig,
    ) Self {
        return .{
            .allocator = allocator,
            .bars = bars,
            .config = config,
            .layout = layout,
        };
    }

    /// Render the progress bars
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();
        var y = bounds.y;

        for (self.bars) |bar| {
            try self.renderBar(c, bar, bounds.x, y, bounds.width);
            y += self.config.bar_height + self.config.bar_spacing;
        }
    }

    fn renderBar(self: *Self, c: Canvas, bar: ProgressBar, x: f64, y: f64, total_width: f64) !void {
        var current_x = x;

        // Draw label
        if (self.config.show_labels) {
            c.drawText(bar.label, current_x, y + self.config.bar_height / 2, .{
                .color = self.config.label_color,
                .font_size = self.config.label_font_size,
                .anchor = .start,
                .baseline = .middle,
            });
            current_x += self.config.label_width;
        }

        // Calculate bar width
        const bar_area_width = total_width - self.config.label_width - self.config.value_width;
        const max_value = @max(bar.target, bar.current);
        const progress_ratio = if (max_value > 0) bar.current / max_value else 0;
        const fill_width = bar_area_width * @min(progress_ratio, 1.0);

        // Draw background bar
        c.drawRect(.{
            .x = current_x,
            .y = y,
            .width = bar_area_width,
            .height = self.config.bar_height,
        }, .{ .color = self.config.background_color }, null);

        // Draw progress fill
        const status = bar.status orelse ProgressStatus.fromProgress(bar.current, bar.target);
        const fill_color = bar.color orelse status.toColor();

        if (fill_width > 0) {
            if (self.config.use_gradient) {
                // Gradient effect using slightly lighter color at top
                const lighter = fill_color.lighten(0.2);
                _ = lighter;
                // For simplicity, just use solid color (gradient would need SVG linearGradient)
                c.drawRect(.{
                    .x = current_x,
                    .y = y,
                    .width = fill_width,
                    .height = self.config.bar_height,
                }, .{ .color = fill_color }, null);
            } else {
                c.drawRect(.{
                    .x = current_x,
                    .y = y,
                    .width = fill_width,
                    .height = self.config.bar_height,
                }, .{ .color = fill_color }, null);
            }
        }

        // Draw target marker
        if (self.config.show_target and bar.target > 0 and max_value > 0) {
            const target_x = current_x + (bar.target / max_value) * bar_area_width;
            c.drawLine(target_x, y - 2, target_x, y + self.config.bar_height + 2, .{
                .color = self.config.target_color,
                .width = self.config.target_width,
            });
        }

        current_x += bar_area_width + 10;

        // Draw value/percentage
        if (self.config.show_values or self.config.show_percentage) {
            var buf: [32]u8 = undefined;
            var text: []const u8 = undefined;

            if (self.config.show_percentage) {
                const pct = if (bar.target > 0) (bar.current / bar.target) * 100 else 0;
                text = std.fmt.bufPrint(&buf, "{d:.0}%", .{pct}) catch "?";
            } else {
                text = std.fmt.bufPrint(&buf, "{d:.0}/{d:.0}", .{ bar.current, bar.target }) catch "?";
            }

            c.drawText(text, current_x, y + self.config.bar_height / 2, .{
                .color = self.config.value_color,
                .font_size = self.config.value_font_size,
                .anchor = .start,
                .baseline = .middle,
            });
        }
    }

    /// Get total height needed for all bars
    pub fn getTotalHeight(self: *Self) f64 {
        if (self.bars.len == 0) return 0;
        return @as(f64, @floatFromInt(self.bars.len)) * (self.config.bar_height + self.config.bar_spacing) - self.config.bar_spacing;
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a simple progress bar chart
pub fn renderProgress(
    allocator: std.mem.Allocator,
    c: Canvas,
    bars: []const ProgressBar,
    layout: Layout,
    config: ProgressConfig,
) !void {
    var chart = ProgressChart.init(allocator, bars, layout, config);
    try chart.render(c);
}

// =============================================================================
// Tests
// =============================================================================

test "progress status calculation" {
    try std.testing.expectEqual(ProgressStatus.achieved, ProgressStatus.fromProgress(100, 100));
    try std.testing.expectEqual(ProgressStatus.achieved, ProgressStatus.fromProgress(120, 100));
    try std.testing.expectEqual(ProgressStatus.on_track, ProgressStatus.fromProgress(80, 100));
    try std.testing.expectEqual(ProgressStatus.pending, ProgressStatus.fromProgress(60, 100));
    try std.testing.expectEqual(ProgressStatus.at_risk, ProgressStatus.fromProgress(30, 100));
}

test "progress total height" {
    const allocator = std.testing.allocator;
    const bars = [_]ProgressBar{
        .{ .label = "Task 1", .current = 80, .target = 100 },
        .{ .label = "Task 2", .current = 50, .target = 100 },
        .{ .label = "Task 3", .current = 100, .target = 100 },
    };

    const layout = Layout{
        .width = 600,
        .height = 200,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    var chart = ProgressChart.init(allocator, &bars, layout, .{
        .bar_height = 24,
        .bar_spacing = 16,
    });

    // 3 bars * 24 + 2 gaps * 16 = 72 + 32 = 104
    const expected = 3 * 24 + 2 * 16;
    try std.testing.expectEqual(@as(f64, @floatFromInt(expected)), chart.getTotalHeight());
}
