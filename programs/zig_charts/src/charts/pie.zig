//! Pie and Donut Charts
//!
//! Circular charts for showing proportions of a whole.
//! Supports donut variant with configurable inner radius.

const std = @import("std");
const canvas = @import("../canvas.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Path = canvas.Path;
const TextAnchor = canvas.TextAnchor;

/// A segment of the pie chart
pub const PieSegment = struct {
    label: []const u8,
    value: f64,
    color: ?Color = null, // Override default palette
};

/// Pie chart configuration
pub const PieChartConfig = struct {
    // Appearance
    colors: []const Color = &[_]Color{
        Color.fromHex("3B82F6").?, // blue
        Color.fromHex("EF4444").?, // red
        Color.fromHex("10B981").?, // green
        Color.fromHex("F59E0B").?, // amber
        Color.fromHex("8B5CF6").?, // violet
        Color.fromHex("EC4899").?, // pink
        Color.fromHex("06B6D4").?, // cyan
        Color.fromHex("F97316").?, // orange
    },

    // Donut settings
    inner_radius: f64 = 0, // 0 = full pie, 0.4 = donut

    // Labels
    show_labels: bool = true,
    label_position: LabelPosition = .outside,
    show_values: bool = false, // Show value/percentage
    show_percentage: bool = true,
    label_font_size: f64 = 12,
    label_color: Color = Color.gray_700,

    // Segments
    start_angle: f64 = -90, // Start from top (degrees)
    stroke_width: f64 = 1,
    stroke_color: Color = Color.white,

    // Explode segments
    explode_offset: f64 = 10, // Pixels to offset exploded segments
};

pub const LabelPosition = enum {
    inside,
    outside,
    none,
};

/// Pie chart renderer
pub const PieChart = struct {
    allocator: std.mem.Allocator,
    segments: []const PieSegment,
    exploded: []const usize, // Indices of exploded segments
    config: PieChartConfig,
    layout: Layout,

    // Computed values
    total: f64,
    center_x: f64,
    center_y: f64,
    outer_radius: f64,
    inner_radius: f64,

    const Self = @This();

    /// Create a pie chart
    pub fn init(
        allocator: std.mem.Allocator,
        segments: []const PieSegment,
        layout: Layout,
        config: PieChartConfig,
    ) Self {
        return initWithExploded(allocator, segments, &.{}, layout, config);
    }

    /// Create a pie chart with exploded segments
    pub fn initWithExploded(
        allocator: std.mem.Allocator,
        segments: []const PieSegment,
        exploded: []const usize,
        layout: Layout,
        config: PieChartConfig,
    ) Self {
        const bounds = layout.innerBounds();

        // Calculate total
        var total: f64 = 0;
        for (segments) |seg| {
            total += seg.value;
        }

        // Calculate dimensions — reserve bottom space for legend table
        const legend_reserve: f64 = if (config.show_labels and config.label_position == .outside)
            @as(f64, @floatFromInt(@min(segments.len, 8))) * 18 + 30
        else
            10;
        const avail_height = bounds.height - legend_reserve;
        const center_x = bounds.x + bounds.width / 2;
        const center_y = bounds.y + avail_height / 2;

        const margin: f64 = 10;
        const max_radius = @min(bounds.width, avail_height) / 2 - margin;
        const outer_radius = @max(10, max_radius);
        const inner_radius = outer_radius * config.inner_radius;

        return .{
            .allocator = allocator,
            .segments = segments,
            .exploded = exploded,
            .config = config,
            .layout = layout,
            .total = total,
            .center_x = center_x,
            .center_y = center_y,
            .outer_radius = outer_radius,
            .inner_radius = inner_radius,
        };
    }

    /// Render the pie chart
    pub fn render(self: *Self, c: Canvas) !void {
        if (self.total == 0) return;

        var current_angle = self.config.start_angle * std.math.pi / 180.0;

        for (self.segments, 0..) |seg, i| {
            const sweep = (seg.value / self.total) * 2 * std.math.pi;

            const is_exploded = self.isExploded(i);

            var offset_x: f64 = 0;
            var offset_y: f64 = 0;
            if (is_exploded) {
                const mid_angle = current_angle + sweep / 2;
                offset_x = @cos(mid_angle) * self.config.explode_offset;
                offset_y = @sin(mid_angle) * self.config.explode_offset;
            }

            const color = seg.color orelse self.config.colors[i % self.config.colors.len];

            try self.drawSegment(c, current_angle, sweep, color, offset_x, offset_y);

            // Only draw radial labels for .inside mode; outside uses legend table
            if (self.config.show_labels and self.config.label_position == .inside) {
                try self.drawLabel(c, seg, i, current_angle, sweep, offset_x, offset_y);
            }

            current_angle += sweep;
        }

        // Draw legend table below the pie (replaces overlapping outside labels)
        if (self.config.show_labels and self.config.label_position != .inside and self.config.label_position != .none) {
            try self.drawLegendTable(c);
        }
    }

    /// Draw a clean legend table below the pie chart with color dots + labels.
    fn drawLegendTable(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Legend starts below the pie circle
        const legend_top = self.center_y + self.outer_radius + 16;
        const row_height: f64 = 18;
        const dot_size: f64 = 8;
        const font_size = self.config.label_font_size;
        const text_color = self.config.label_color;

        // Two-column layout if many segments, single column if few
        const num_segs = self.segments.len;
        const use_two_cols = num_segs > 4;
        const col_width = if (use_two_cols) bounds.width / 2 else bounds.width;

        for (self.segments, 0..) |seg, i| {
            const col: f64 = if (use_two_cols) @floatFromInt(i % 2) else 0;
            const row: f64 = if (use_two_cols) @floatFromInt(i / 2) else @floatFromInt(i);

            const x = bounds.x + col * col_width + 10;
            const y = legend_top + row * row_height;

            const color = seg.color orelse self.config.colors[i % self.config.colors.len];

            // Color dot (small filled rect)
            c.drawRect(.{ .x = x, .y = y - dot_size + 2, .width = dot_size, .height = dot_size }, null, .{ .color = color });

            // Label + percentage
            const percentage = (seg.value / self.total) * 100;
            var label_buf: [128]u8 = undefined;
            const label = if (self.config.show_percentage)
                std.fmt.bufPrint(&label_buf, "{s}  {d:.1}%", .{ seg.label, percentage }) catch seg.label
            else if (self.config.show_values)
                std.fmt.bufPrint(&label_buf, "{s}  ({d:.0})", .{ seg.label, seg.value }) catch seg.label
            else
                seg.label;

            c.drawText(label, x + dot_size + 6, y, .{
                .color = text_color,
                .font_size = font_size,
                .anchor = .start,
            });
        }
    }

    fn isExploded(self: *Self, index: usize) bool {
        for (self.exploded) |exp_idx| {
            if (exp_idx == index) return true;
        }
        return false;
    }

    fn drawSegment(
        self: *Self,
        c: Canvas,
        start_angle: f64,
        sweep: f64,
        color: Color,
        offset_x: f64,
        offset_y: f64,
    ) !void {
        const cx = self.center_x + offset_x;
        const cy = self.center_y + offset_y;

        var path = Path.init(self.allocator);
        defer path.deinit();

        if (self.inner_radius > 0) {
            // Donut segment - draw arc with hole
            try self.buildDonutPath(&path, cx, cy, start_angle, sweep);
        } else {
            // Full pie segment
            try self.buildPiePath(&path, cx, cy, start_angle, sweep);
        }

        c.drawPath(&path, .{
            .color = self.config.stroke_color,
            .width = self.config.stroke_width,
        }, .{ .color = color });
    }

    fn buildPiePath(self: *Self, path: *Path, cx: f64, cy: f64, start_angle: f64, sweep: f64) !void {
        const end_angle = start_angle + sweep;

        // Start at center
        try path.moveTo(cx, cy);

        // Line to start of arc
        const start_x = cx + @cos(start_angle) * self.outer_radius;
        const start_y = cy + @sin(start_angle) * self.outer_radius;
        try path.lineTo(start_x, start_y);

        // Arc to end
        const end_x = cx + @cos(end_angle) * self.outer_radius;
        const end_y = cy + @sin(end_angle) * self.outer_radius;
        const large_arc = sweep > std.math.pi;
        try path.arcTo(self.outer_radius, self.outer_radius, 0, large_arc, true, end_x, end_y);

        // Close back to center
        try path.close();
    }

    fn buildDonutPath(self: *Self, path: *Path, cx: f64, cy: f64, start_angle: f64, sweep: f64) !void {
        const end_angle = start_angle + sweep;
        const large_arc = sweep > std.math.pi;

        // Outer arc start
        const outer_start_x = cx + @cos(start_angle) * self.outer_radius;
        const outer_start_y = cy + @sin(start_angle) * self.outer_radius;

        // Outer arc end
        const outer_end_x = cx + @cos(end_angle) * self.outer_radius;
        const outer_end_y = cy + @sin(end_angle) * self.outer_radius;

        // Inner arc start (at end_angle)
        const inner_end_x = cx + @cos(end_angle) * self.inner_radius;
        const inner_end_y = cy + @sin(end_angle) * self.inner_radius;

        // Inner arc end (at start_angle)
        const inner_start_x = cx + @cos(start_angle) * self.inner_radius;
        const inner_start_y = cy + @sin(start_angle) * self.inner_radius;

        // Draw donut segment
        try path.moveTo(outer_start_x, outer_start_y);
        try path.arcTo(self.outer_radius, self.outer_radius, 0, large_arc, true, outer_end_x, outer_end_y);
        try path.lineTo(inner_end_x, inner_end_y);
        try path.arcTo(self.inner_radius, self.inner_radius, 0, large_arc, false, inner_start_x, inner_start_y);
        try path.close();
    }

    fn drawLabel(
        self: *Self,
        c: Canvas,
        seg: PieSegment,
        _: usize,
        start_angle: f64,
        sweep: f64,
        offset_x: f64,
        offset_y: f64,
    ) !void {
        const mid_angle = start_angle + sweep / 2;
        const percentage = (seg.value / self.total) * 100;

        // Build label text
        var label_buf: [128]u8 = undefined;
        var label: []const u8 = undefined;

        if (self.config.show_percentage) {
            const written = std.fmt.bufPrint(&label_buf, "{s} ({d:.1}%)", .{ seg.label, percentage }) catch seg.label;
            label = written;
        } else if (self.config.show_values) {
            const written = std.fmt.bufPrint(&label_buf, "{s} ({d:.0})", .{ seg.label, seg.value }) catch seg.label;
            label = written;
        } else {
            label = seg.label;
        }

        const cx = self.center_x + offset_x;
        const cy = self.center_y + offset_y;

        if (self.config.label_position == .inside) {
            // Place label inside the segment
            const label_radius = (self.outer_radius + self.inner_radius) / 2;
            const label_x = cx + @cos(mid_angle) * label_radius;
            const label_y = cy + @sin(mid_angle) * label_radius;

            c.drawText(label, label_x, label_y, .{
                .color = Color.white,
                .font_size = self.config.label_font_size,
                .anchor = .middle,
            });
        } else {
            // Place label outside with leader line
            const label_radius = self.outer_radius + 20;
            const label_x = cx + @cos(mid_angle) * label_radius;
            const label_y = cy + @sin(mid_angle) * label_radius;

            // Determine text anchor based on position
            const anchor: TextAnchor = if (@cos(mid_angle) >= 0) .start else .end;

            c.drawText(label, label_x, label_y, .{
                .color = self.config.label_color,
                .font_size = self.config.label_font_size,
                .anchor = anchor,
            });
        }
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a simple pie chart SVG from segments
pub fn renderPie(
    allocator: std.mem.Allocator,
    c: Canvas,
    segments: []const PieSegment,
    layout: Layout,
    config: PieChartConfig,
) !void {
    var chart = PieChart.init(allocator, segments, layout, config);
    try chart.render(c);
}

// =============================================================================
// Tests
// =============================================================================

test "pie chart total calculation" {
    const allocator = std.testing.allocator;
    const segments = [_]PieSegment{
        .{ .label = "A", .value = 30 },
        .{ .label = "B", .value = 50 },
        .{ .label = "C", .value = 20 },
    };

    const layout = Layout{
        .width = 400,
        .height = 400,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    const chart = PieChart.init(allocator, &segments, layout, .{});
    try std.testing.expectEqual(@as(f64, 100), chart.total);
}

test "donut inner radius" {
    const allocator = std.testing.allocator;
    const segments = [_]PieSegment{
        .{ .label = "A", .value = 50 },
        .{ .label = "B", .value = 50 },
    };

    const layout = Layout{
        .width = 400,
        .height = 400,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 20,
        .margin_left = 20,
    };

    const chart = PieChart.init(allocator, &segments, layout, .{ .inner_radius = 0.5 });
    try std.testing.expect(chart.inner_radius > 0);
    try std.testing.expect(chart.inner_radius < chart.outer_radius);
}
