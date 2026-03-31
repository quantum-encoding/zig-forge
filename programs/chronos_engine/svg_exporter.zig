// SPDX-License-Identifier: Dual License - MIT (Non-Commercial) / Commercial License
//
// svg_exporter.zig - SVG Cognitive Graph Exporter
//
// Purpose: Export cognitive metrics as beautiful SVG graphs (Criterion style)
// Architecture: Template-based SVG generation with color gradients
//
// THE CHRONICLER - Preserving Cognitive History in Graphical Form

const std = @import("std");
const posix = std.posix;
const cognitive_metrics = @import("cognitive_metrics.zig");
const cognitive_states = @import("cognitive_states.zig");

pub const SVGExporter = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator) SVGExporter {
        return SVGExporter{
            .allocator = allocator,
            .width = 1200,
            .height = 800,
        };
    }

    /// Export cognitive metrics as SVG graph
    pub fn exportGraph(
        self: *SVGExporter,
        metrics: cognitive_metrics.CognitiveMetrics,
        state_history: []const cognitive_metrics.StateEvent,
        _: []const cognitive_metrics.ToolEvent,
        output_path: []const u8,
    ) !void {
        var svg = std.ArrayList(u8).empty;
        defer svg.deinit(self.allocator);

        // SVG header
        try svg.print(self.allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<svg width="{d}" height="{d}" xmlns="http://www.w3.org/2000/svg">
            \\  <defs>
            \\    <style>
            \\      .title {{ font-family: 'Courier New', monospace; font-size: 24px; font-weight: bold; }}
            \\      .subtitle {{ font-family: 'Courier New', monospace; font-size: 14px; fill: #666; }}
            \\      .label {{ font-family: 'Courier New', monospace; font-size: 12px; }}
            \\      .grid {{ stroke: #e0e0e0; stroke-width: 1; }}
            \\      .confidence-line {{ fill: none; stroke: white; stroke-width: 3; stroke-opacity: 0.9; }}
            \\      .state-band {{ opacity: 0.75; }}
            \\      .tool-marker {{ stroke: white; stroke-width: 2; }}
            \\    </style>
            \\  </defs>
            \\
            \\
        , .{ self.width, self.height });

        // Title and metadata
        try svg.print(self.allocator,
            \\  <text x="20" y="30" class="title">🔮 Cognitive Oracle Graph</text>
            \\  <text x="20" y="50" class="subtitle">Window: {d}s | State: {s} | Confidence: {d:.0}% | Tool Rate: {d:.1}/min</text>
            \\
            \\
        , .{
            (metrics.window_end_ns - metrics.window_start_ns) / std.time.ns_per_s,
            metrics.current_state,
            metrics.confidence * 100.0,
            metrics.tool_rate,
        });

        // Draw state timeline graph
        try self.drawStateTimeline(&svg, state_history, 20, 80, self.width - 40, 250);

        // Draw tool activity bars
        try self.drawToolActivity(&svg, metrics, 20, 360, self.width - 40, 180);

        // Draw metrics panel
        try self.drawMetrics(&svg, metrics, 20, 570, self.width - 40, 200);

        // SVG footer
        try svg.appendSlice(self.allocator, "</svg>\n");

        // Write to file - need null-terminated path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..output_path.len], output_path);
        path_buf[output_path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..output_path.len :0];

        const fd = try posix.openatZ(std.c.AT.FDCWD, path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        defer _ = std.c.close(fd);

        // Write all content
        var written: usize = 0;
        while (written < svg.items.len) {
            const result = std.c.write(fd, svg.items.ptr + written, svg.items.len - written);
            if (result <= 0) return error.WriteError;
            written += @intCast(result);
        }
    }

    fn drawStateTimeline(
        self: *SVGExporter,
        svg: *std.ArrayList(u8),
        state_history: []const cognitive_metrics.StateEvent,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) !void {

        // Section title
        try svg.print(self.allocator, 
            \\  <text x="{d}" y="{d}" class="label">COGNITIVE STATE TIMELINE</text>
            \\
        , .{ x, y - 5 });

        // Draw background and grid
        try svg.print(self.allocator, 
            \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" fill="#f9f9f9" stroke="#ccc" stroke-width="1"/>
            \\
        , .{ x, y, w, h });

        // Draw time grid lines (every 10 seconds)
        const window_ns = if (state_history.len > 0)
            state_history[state_history.len - 1].timestamp_ns - state_history[0].timestamp_ns
        else
            60 * std.time.ns_per_s;

        var grid_time: u64 = 0;
        while (grid_time <= window_ns) : (grid_time += 10 * std.time.ns_per_s) {
            const grid_x = x + @as(u32, @intCast((@as(u64, w) * grid_time) / window_ns));
            try svg.print(self.allocator, 
                \\  <line x1="{d}" y1="{d}" x2="{d}" y2="{d}" class="grid"/>
                \\  <text x="{d}" y="{d}" class="label" font-size="10" fill="#999">{d}s</text>
                \\
            , .{ grid_x, y, grid_x, y + h, grid_x - 10, y + h + 12, grid_time / std.time.ns_per_s });
        }

        if (state_history.len == 0) return;

        // Draw state bands
        const start_ns = state_history[0].timestamp_ns;
        for (state_history, 0..) |event, i| {
            if (i == 0) continue;
            const prev = state_history[i - 1];

            const x1 = x + @as(u32, @intCast((@as(u64, w) * (prev.timestamp_ns - start_ns)) / window_ns));
            const x2 = x + @as(u32, @intCast((@as(u64, w) * (event.timestamp_ns - start_ns)) / window_ns));

            const color = getStateColorHex(prev.state);

            try svg.print(self.allocator, 
                \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" fill="{s}" class="state-band"/>
                \\
            , .{ x1, y, x2 - x1, h, color });
        }

        // Draw confidence line overlay
        try svg.print(self.allocator, "  <path d=\"M", .{});
        for (state_history) |event| {
            const px = x + @as(u32, @intCast((@as(u64, w) * (event.timestamp_ns - start_ns)) / window_ns));
            const py = y + @as(u32, @intFromFloat(@as(f32, @floatFromInt(h)) * (1.0 - event.confidence)));
            try svg.print(self.allocator, " {d},{d}", .{ px, py });
        }
        try svg.appendSlice(self.allocator, "\" class=\"confidence-line\"/>\n");

        // Confidence axis labels (positioned to the left of the graph)
        const label_x = if (x >= 35) x - 35 else 5;
        try svg.print(self.allocator,
            \\  <text x="{d}" y="{d}" class="label" font-size="10" fill="#666">100%</text>
            \\  <text x="{d}" y="{d}" class="label" font-size="10" fill="#666">50%</text>
            \\  <text x="{d}" y="{d}" class="label" font-size="10" fill="#666">0%</text>
            \\
        , .{ label_x, y + 10, label_x, y + h / 2, label_x, y + h });
    }

    fn drawToolActivity(
        self: *SVGExporter,
        svg: *std.ArrayList(u8),
        metrics: cognitive_metrics.CognitiveMetrics,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) !void {

        // Section title
        try svg.print(self.allocator, 
            \\  <text x="{d}" y="{d}" class="label">TOOL ACTIVITY BREAKDOWN</text>
            \\
        , .{ x, y - 5 });

        // Find max count for scaling
        var max_count: u32 = 1;
        for (metrics.tool_counts) |count| {
            if (count > max_count) max_count = count;
        }

        // Tool names
        const tool_names = [_][]const u8{
            "executing-command",
            "planning-tasks",
            "reading-file",
            "writing-file",
            "editing-file",
            "searching-files",
            "searching-code",
            "fetching-web",
            "searching-web",
            "running-agent",
            "awaiting-input",
            "editing-notebook",
            "unknown",
        };

        const bar_height = h / tool_names.len;

        for (tool_names, 0..) |name, i| {
            const count = metrics.tool_counts[i];
            if (count == 0) continue;

            const bar_width = (@as(u32, w) * count) / max_count;
            const bar_y = y + @as(u32, @intCast(i * bar_height));

            const color = getToolColorHex(@as(cognitive_states.ToolActivity, @enumFromInt(i)));

            try svg.print(self.allocator, 
                \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" fill="{s}" opacity="0.8"/>
                \\  <text x="{d}" y="{d}" class="label" font-size="11">{s}: {d} events ({d:.0}%)</text>
                \\
            , .{
                x,
                bar_y + 5,
                bar_width,
                bar_height - 10,
                color,
                x + 10,
                bar_y + bar_height / 2 + 4,
                name,
                count,
                (@as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(metrics.total_events))) * 100.0,
            });
        }
    }

    fn drawMetrics(
        self: *SVGExporter,
        svg: *std.ArrayList(u8),
        metrics: cognitive_metrics.CognitiveMetrics,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) !void {

        // Section title
        try svg.print(self.allocator, 
            \\  <text x="{d}" y="{d}" class="label">COGNITIVE HEALTH METRICS</text>
            \\
        , .{ x, y - 5 });

        // Metrics grid - allocate strings for numeric values
        const completion_str = try std.fmt.allocPrint(self.allocator, "{d:.0}%", .{metrics.completion_rate * 100.0});
        defer self.allocator.free(completion_str);
        const duration_str = try std.fmt.allocPrint(self.allocator, "{d:.2}s", .{@as(f64, @floatFromInt(metrics.avg_state_duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))});
        defer self.allocator.free(duration_str);
        const retry_str = try std.fmt.allocPrint(self.allocator, "{d:.0}%", .{metrics.retry_rate * 100.0});
        defer self.allocator.free(retry_str);
        const uncertainty_str = try std.fmt.allocPrint(self.allocator, "{d}", .{metrics.uncertainty_events});
        defer self.allocator.free(uncertainty_str);
        const total_str = try std.fmt.allocPrint(self.allocator, "{d}", .{metrics.total_events});
        defer self.allocator.free(total_str);

        const metrics_data = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = "Completion Rate", .value = completion_str },
            .{ .name = "Avg State Duration", .value = duration_str },
            .{ .name = "Retry Rate", .value = retry_str },
            .{ .name = "Uncertainty Events", .value = uncertainty_str },
            .{ .name = "Total Events", .value = total_str },
            .{ .name = "Current Activity", .value = @tagName(metrics.current_activity) },
        };

        var row_y = y + 10;
        for (metrics_data) |metric| {
            try svg.print(self.allocator,
                \\  <text x="{d}" y="{d}" class="label">{s}: <tspan font-weight="bold">{s}</tspan></text>
                \\
            , .{ x + 10, row_y, metric.name, metric.value });
            row_y += 25;
        }

        // Health indicator
        const health_color = if (metrics.confidence > 0.8)
            "#4CAF50"
        else if (metrics.confidence > 0.5)
            "#FFC107"
        else
            "#F44336";

        try svg.print(self.allocator, 
            \\  <circle cx="{d}" cy="{d}" r="15" fill="{s}"/>
            \\  <text x="{d}" y="{d}" class="label" fill="white" font-weight="bold" text-anchor="middle" dominant-baseline="middle">{d:.0}%</text>
            \\
        , .{ x + w - 50, y + h / 2, health_color, x + w - 50, y + h / 2, metrics.confidence * 100.0 });
    }
};

fn getStateColorHex(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "Channelling")) return "#66CC66";
    if (std.mem.eql(u8, state, "Synthesizing")) return "#9966FF";
    if (std.mem.eql(u8, state, "Thinking")) return "#6699FF";
    if (std.mem.eql(u8, state, "Pondering")) return "#66CCFF";
    if (std.mem.eql(u8, state, "Finagling")) return "#FFCC66";
    if (std.mem.eql(u8, state, "Combobulating")) return "#FF9966";
    if (std.mem.eql(u8, state, "Puzzling")) return "#FF6666";
    if (std.mem.eql(u8, state, "Discombobulating")) return "#CC3333";
    if (std.mem.eql(u8, state, "Creating")) return "#66FF66";
    if (std.mem.eql(u8, state, "Crafting")) return "#66FF99";
    if (std.mem.eql(u8, state, "Actualizing")) return "#99FF66";
    return "#CCCCCC";
}

fn getToolColorHex(activity: cognitive_metrics.ToolActivity) []const u8 {
    return switch (activity) {
        .executing_command => "#FF6B6B",
        .planning_tasks => "#4ECDC4",
        .writing_file => "#45B7D1",
        .editing_file => "#FFA07A",
        .reading_file => "#98D8C8",
        .searching_files => "#F7DC6F",
        .searching_code => "#BB8FCE",
        else => "#95A5A6",
    };
}
