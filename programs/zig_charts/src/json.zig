//! JSON Chart Specification Parser
//!
//! Enables programmatic chart generation from JSON specifications.
//! Designed for AI integration via structured output.
//!
//! Usage:
//! ```zig
//! const json = @import("json.zig");
//! const svg = try json.chartFromJson(allocator, json_string);
//! defer allocator.free(svg);
//! ```
//!
//! JSON Schema:
//! {
//!   "type": "pie|bar|line|scatter|gauge|progress|area|heatmap|candlestick|sparkline",
//!   "title": "Optional title",
//!   "width": 800,
//!   "height": 400,
//!   "data": { ... chart-specific data ... },
//!   "config": { ... optional styling ... }
//! }

const std = @import("std");
const canvas = @import("canvas.zig");
const svg_module = @import("svg.zig");
const Color = @import("color.zig").Color;

// Chart type imports
const pie = @import("charts/pie.zig");
const gauge = @import("charts/gauge.zig");
const progress = @import("charts/progress.zig");
const scatter = @import("charts/scatter.zig");
const area = @import("charts/area.zig");
const heatmap = @import("charts/heatmap.zig");
const line = @import("charts/line.zig");
const bar = @import("charts/bar.zig");
const candlestick = @import("charts/candlestick.zig");
const sparkline = @import("charts/sparkline.zig");

const Layout = canvas.Layout;
const SvgCanvas = svg_module.SvgCanvas;

/// Error types for JSON parsing
pub const JsonChartError = error{
    InvalidJson,
    MissingType,
    UnknownChartType,
    MissingData,
    InvalidData,
    InvalidConfig,
    OutOfMemory,
};

/// Supported chart types
pub const ChartType = enum {
    pie,
    gauge,
    progress,
    scatter,
    area,
    heatmap,
    line,
    bar,
    candlestick,
    sparkline,

    pub fn fromString(s: []const u8) ?ChartType {
        const map = std.StaticStringMap(ChartType).initComptime(.{
            .{ "pie", .pie },
            .{ "donut", .pie },
            .{ "gauge", .gauge },
            .{ "progress", .progress },
            .{ "scatter", .scatter },
            .{ "bubble", .scatter },
            .{ "area", .area },
            .{ "heatmap", .heatmap },
            .{ "line", .line },
            .{ "bar", .bar },
            .{ "candlestick", .candlestick },
            .{ "ohlc", .candlestick },
            .{ "sparkline", .sparkline },
        });
        return map.get(s);
    }
};

/// Parse a JSON chart specification and return SVG output
pub fn chartFromJson(allocator: std.mem.Allocator, json_string: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_string, .{}) catch {
        return JsonChartError.InvalidJson;
    };
    defer parsed.deinit();

    return chartFromValue(allocator, parsed.value);
}

/// Parse a chart from an already-parsed JSON value
pub fn chartFromValue(allocator: std.mem.Allocator, root: std.json.Value) ![]const u8 {
    if (root != .object) return JsonChartError.InvalidJson;
    const obj = root.object;

    // Extract type
    const type_val = obj.get("type") orelse return JsonChartError.MissingType;
    const type_str = if (type_val == .string) type_val.string else return JsonChartError.MissingType;
    const chart_type = ChartType.fromString(type_str) orelse return JsonChartError.UnknownChartType;

    // Extract dimensions
    const width = getFloat(obj, "width") orelse 800;
    const height = getFloat(obj, "height") orelse 400;

    // Get data and config
    const data = obj.get("data") orelse return JsonChartError.MissingData;
    const config = obj.get("config");

    // Create SVG canvas
    var svg = SvgCanvas.init(allocator, width, height);
    defer svg.deinit();

    // Set background (white by default)
    if (config) |cfg| {
        if (cfg == .object) {
            if (cfg.object.get("background")) |bg| {
                if (bg == .string) {
                    if (Color.fromHex(bg.string)) |color| {
                        svg.setBackground(color);
                    }
                }
            }
        }
    }
    if (svg.background == null) {
        svg.setBackground(Color.white);
    }

    // Create layout
    const layout = Layout{
        .width = width,
        .height = height,
        .margin_top = getFloat(obj, "margin_top") orelse 20,
        .margin_right = getFloat(obj, "margin_right") orelse 20,
        .margin_bottom = getFloat(obj, "margin_bottom") orelse 40,
        .margin_left = getFloat(obj, "margin_left") orelse 60,
    };

    // Render based on chart type
    switch (chart_type) {
        .pie => try renderPieFromJson(allocator, svg.canvas(), data, config, layout),
        .gauge => try renderGaugeFromJson(allocator, svg.canvas(), data, config, layout),
        .progress => try renderProgressFromJson(allocator, svg.canvas(), data, config, layout),
        .scatter => try renderScatterFromJson(allocator, svg.canvas(), data, config, layout),
        .area => try renderAreaFromJson(allocator, svg.canvas(), data, config, layout),
        .heatmap => try renderHeatmapFromJson(allocator, svg.canvas(), data, config, layout),
        .line => try renderLineFromJson(allocator, svg.canvas(), data, config, layout),
        .bar => try renderBarFromJson(allocator, svg.canvas(), data, config, layout),
        .candlestick => try renderCandlestickFromJson(allocator, svg.canvas(), data, config, layout),
        .sparkline => try renderSparklineFromJson(allocator, svg.canvas(), data, config, width, height),
    }

    // Get output
    const output = try svg.canvas().finish();
    const result = try allocator.dupe(u8, output);
    return result;
}

// =============================================================================
// Helper Functions
// =============================================================================

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return if (val == .bool) val.bool else null;
}

fn parseColor(val: std.json.Value) ?Color {
    if (val == .string) {
        return Color.fromHex(val.string);
    }
    return null;
}

// =============================================================================
// Chart-Specific Parsers
// =============================================================================

fn renderPieFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    // Parse segments
    const segments_val = data_obj.get("segments") orelse return JsonChartError.InvalidData;
    if (segments_val != .array) return JsonChartError.InvalidData;

    var segments: std.ArrayListUnmanaged(pie.PieSegment) = .empty;
    defer segments.deinit(allocator);

    for (segments_val.array.items) |seg_val| {
        if (seg_val != .object) continue;
        const seg = seg_val.object;

        const label = getString(seg, "label") orelse "";
        const value = getFloat(seg, "value") orelse 0;
        const color = if (seg.get("color")) |cv| parseColor(cv) else null;

        try segments.append(allocator, .{
            .label = label,
            .value = value,
            .color = color,
        });
    }

    // Parse config
    var chart_config = pie.PieChartConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getFloat(c_obj, "inner_radius")) |ir| chart_config.inner_radius = ir;
            if (getBool(c_obj, "show_labels")) |sl| chart_config.show_labels = sl;
            if (getBool(c_obj, "show_percentage")) |sp| chart_config.show_percentage = sp;
        }
    }

    var chart = pie.PieChart.init(allocator, segments.items, layout, chart_config);
    try chart.render(c);
}

fn renderGaugeFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    const value = getFloat(data_obj, "value") orelse 0;
    const label = getString(data_obj, "label") orelse "";

    var chart_config = gauge.GaugeConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getFloat(c_obj, "min")) |m| chart_config.min = m;
            if (getFloat(c_obj, "max")) |m| chart_config.max = m;
            if (getBool(c_obj, "show_needle")) |sn| chart_config.show_needle = sn;
            if (getBool(c_obj, "show_ticks")) |st| chart_config.show_ticks = st;
        }
    }

    var chart = gauge.GaugeChart.init(allocator, value, label, layout, chart_config);
    try chart.render(c);
}

fn renderProgressFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    const bars_val = data_obj.get("bars") orelse return JsonChartError.InvalidData;
    if (bars_val != .array) return JsonChartError.InvalidData;

    var bars: std.ArrayListUnmanaged(progress.ProgressBar) = .empty;
    defer bars.deinit(allocator);

    for (bars_val.array.items) |bar_val| {
        if (bar_val != .object) continue;
        const b = bar_val.object;

        try bars.append(allocator, .{
            .label = getString(b, "label") orelse "",
            .current = getFloat(b, "current") orelse 0,
            .target = getFloat(b, "target") orelse 100,
            .color = if (b.get("color")) |cv| parseColor(cv) else null,
        });
    }

    var chart_config = progress.ProgressConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_labels")) |sl| chart_config.show_labels = sl;
            if (getBool(c_obj, "show_percentage")) |sp| chart_config.show_percentage = sp;
        }
    }

    var chart = progress.ProgressChart.init(allocator, bars.items, layout, chart_config);
    try chart.render(c);
}

fn renderScatterFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    var series_list: std.ArrayListUnmanaged(scatter.ScatterSeries) = .empty;
    defer series_list.deinit(allocator);

    // Support both "points" (single series) and "series" (multi-series)
    if (data_obj.get("points")) |points_val| {
        var points: std.ArrayListUnmanaged(scatter.ScatterPoint) = .empty;
        defer points.deinit(allocator);

        if (points_val == .array) {
            for (points_val.array.items) |pt| {
                if (pt == .object) {
                    try points.append(allocator, .{
                        .x = getFloat(pt.object, "x") orelse 0,
                        .y = getFloat(pt.object, "y") orelse 0,
                        .size = getFloat(pt.object, "size"),
                    });
                }
            }
        }

        try series_list.append(allocator, .{
            .name = "Data",
            .points = try allocator.dupe(scatter.ScatterPoint, points.items),
        });
    }

    if (data_obj.get("series")) |series_val| {
        if (series_val == .array) {
            for (series_val.array.items) |s| {
                if (s != .object) continue;
                const s_obj = s.object;

                var points: std.ArrayListUnmanaged(scatter.ScatterPoint) = .empty;
                defer points.deinit(allocator);

                if (s_obj.get("points")) |pts| {
                    if (pts == .array) {
                        for (pts.array.items) |pt| {
                            if (pt == .object) {
                                try points.append(allocator, .{
                                    .x = getFloat(pt.object, "x") orelse 0,
                                    .y = getFloat(pt.object, "y") orelse 0,
                                    .size = getFloat(pt.object, "size"),
                                });
                            }
                        }
                    }
                }

                const color = if (s_obj.get("color")) |cv| parseColor(cv) else null;

                try series_list.append(allocator, .{
                    .name = getString(s_obj, "name") orelse "Series",
                    .points = try allocator.dupe(scatter.ScatterPoint, points.items),
                    .color = color orelse Color.blue_500,
                });
            }
        }
    }

    var chart_config = scatter.ScatterConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_trend_line")) |st| chart_config.trend_line.enabled = st;
            if (getBool(c_obj, "show_grid")) |sg| chart_config.show_grid = sg;
            if (getString(c_obj, "x_label")) |xl| chart_config.x_label = xl;
            if (getString(c_obj, "y_label")) |yl| chart_config.y_label = yl;
        }
    }

    var chart = scatter.ScatterChart.init(allocator, series_list.items, layout, chart_config);
    try chart.render(c);
}

fn renderAreaFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    var series_list: std.ArrayListUnmanaged(area.AreaSeries) = .empty;
    defer series_list.deinit(allocator);

    const series_val = data_obj.get("series") orelse return JsonChartError.InvalidData;
    if (series_val != .array) return JsonChartError.InvalidData;

    for (series_val.array.items) |s| {
        if (s != .object) continue;
        const s_obj = s.object;

        var points: std.ArrayListUnmanaged(area.AreaPoint) = .empty;
        defer points.deinit(allocator);

        // Support "values" (array of y values) or "data" (array of {x, y})
        if (s_obj.get("values")) |vals| {
            if (vals == .array) {
                for (vals.array.items, 0..) |v, i| {
                    const y = switch (v) {
                        .integer => |n| @as(f64, @floatFromInt(n)),
                        .float => |f| f,
                        else => 0,
                    };
                    try points.append(allocator, .{
                        .x = @floatFromInt(i),
                        .y = y,
                    });
                }
            }
        } else if (s_obj.get("data")) |d| {
            if (d == .array) {
                for (d.array.items) |pt| {
                    if (pt == .object) {
                        try points.append(allocator, .{
                            .x = getFloat(pt.object, "x") orelse 0,
                            .y = getFloat(pt.object, "y") orelse 0,
                        });
                    }
                }
            }
        }

        const color = if (s_obj.get("color")) |cv| parseColor(cv) else null;

        try series_list.append(allocator, .{
            .name = getString(s_obj, "name") orelse "Series",
            .data = try allocator.dupe(area.AreaPoint, points.items),
            .color = color orelse Color.blue_500,
        });
    }

    var chart_config = area.AreaConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getString(c_obj, "stack_mode")) |sm| {
                if (std.mem.eql(u8, sm, "stacked")) chart_config.stack_mode = .stacked;
                if (std.mem.eql(u8, sm, "percent")) chart_config.stack_mode = .percent;
                if (std.mem.eql(u8, sm, "stream")) chart_config.stack_mode = .stream;
            }
            if (getBool(c_obj, "show_grid")) |sg| chart_config.show_grid = sg;
        }
    }

    var chart = area.AreaChart.init(allocator, series_list.items, layout, chart_config);
    try chart.render(c);
}

fn renderHeatmapFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    const matrix_val = data_obj.get("matrix") orelse return JsonChartError.InvalidData;
    if (matrix_val != .array) return JsonChartError.InvalidData;

    var matrix: std.ArrayListUnmanaged([]const f64) = .empty;
    defer matrix.deinit(allocator);

    for (matrix_val.array.items) |row_val| {
        if (row_val != .array) continue;

        var row: std.ArrayListUnmanaged(f64) = .empty;
        defer row.deinit(allocator);

        for (row_val.array.items) |cell| {
            const v = switch (cell) {
                .integer => |n| @as(f64, @floatFromInt(n)),
                .float => |f| f,
                else => 0,
            };
            try row.append(allocator, v);
        }

        try matrix.append(allocator, try allocator.dupe(f64, row.items));
    }

    var chart_config = heatmap.HeatmapConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_values")) |sv| chart_config.show_values = sv;
            if (getString(c_obj, "title")) |t| chart_config.title = t;
        }
    }

    var chart = heatmap.HeatmapChart.init(allocator, matrix.items, layout, chart_config);
    try chart.render(c);
}

fn renderLineFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    var series_list: std.ArrayListUnmanaged(line.Series) = .empty;
    defer series_list.deinit(allocator);

    const series_val = data_obj.get("series") orelse return JsonChartError.InvalidData;
    if (series_val != .array) return JsonChartError.InvalidData;

    for (series_val.array.items) |s| {
        if (s != .object) continue;
        const s_obj = s.object;

        var points: std.ArrayListUnmanaged(line.DataPoint) = .empty;
        defer points.deinit(allocator);

        // Support "values" or "data"
        if (s_obj.get("values")) |vals| {
            if (vals == .array) {
                for (vals.array.items, 0..) |v, i| {
                    const y = switch (v) {
                        .integer => |n| @as(f64, @floatFromInt(n)),
                        .float => |f| f,
                        else => 0,
                    };
                    try points.append(allocator, .{ .x = @floatFromInt(i), .y = y });
                }
            }
        } else if (s_obj.get("data")) |d| {
            if (d == .array) {
                for (d.array.items) |pt| {
                    if (pt == .object) {
                        try points.append(allocator, .{
                            .x = getFloat(pt.object, "x") orelse 0,
                            .y = getFloat(pt.object, "y") orelse 0,
                        });
                    }
                }
            }
        }

        const color = if (s_obj.get("color")) |cv| parseColor(cv) else null;

        try series_list.append(allocator, .{
            .name = getString(s_obj, "name") orelse "Series",
            .data = try allocator.dupe(line.DataPoint, points.items),
            .color = color orelse Color.blue_500,
            .fill = getBool(s_obj, "fill") orelse false,
            .dashed = getBool(s_obj, "dashed") orelse false,
            .show_markers = getBool(s_obj, "show_markers") orelse false,
        });
    }

    var chart_config = line.LineChartConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_grid")) |sg| chart_config.show_grid = sg;
            if (getBool(c_obj, "show_legend")) |sl| chart_config.show_legend = sl;
            if (getString(c_obj, "x_label")) |xl| chart_config.x_label = xl;
            if (getString(c_obj, "y_label")) |yl| chart_config.y_label = yl;
        }
    }

    var chart = line.LineChart.init(allocator, series_list.items, layout, chart_config);
    try chart.render(c);
}

fn renderBarFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    // Parse categories
    var categories: std.ArrayListUnmanaged([]const u8) = .empty;
    defer categories.deinit(allocator);

    if (data_obj.get("categories")) |cats| {
        if (cats == .array) {
            for (cats.array.items) |cat| {
                if (cat == .string) {
                    try categories.append(allocator, cat.string);
                }
            }
        }
    }

    // Parse series
    var series_list: std.ArrayListUnmanaged(bar.BarSeries) = .empty;
    defer series_list.deinit(allocator);

    const series_val = data_obj.get("series") orelse return JsonChartError.InvalidData;
    if (series_val != .array) return JsonChartError.InvalidData;

    for (series_val.array.items) |s| {
        if (s != .object) continue;
        const s_obj = s.object;

        var values: std.ArrayListUnmanaged(f64) = .empty;
        defer values.deinit(allocator);

        if (s_obj.get("values")) |vals| {
            if (vals == .array) {
                for (vals.array.items) |v| {
                    const val = switch (v) {
                        .integer => |n| @as(f64, @floatFromInt(n)),
                        .float => |f| f,
                        else => 0,
                    };
                    try values.append(allocator, val);
                }
            }
        }

        try series_list.append(allocator, .{
            .name = getString(s_obj, "name") orelse "Series",
            .values = try allocator.dupe(f64, values.items),
        });
    }

    var chart_config = bar.BarChartConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_values")) |sv| chart_config.show_values = sv;
            if (getString(c_obj, "mode")) |m| {
                if (std.mem.eql(u8, m, "stacked")) chart_config.mode = .stacked;
                if (std.mem.eql(u8, m, "grouped")) chart_config.mode = .grouped;
            }
        }
    }

    var chart = bar.BarChart.init(allocator, categories.items, series_list.items, layout, chart_config);
    try chart.render(c);
}

fn renderCandlestickFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    layout: Layout,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    var candles: std.ArrayListUnmanaged(candlestick.Candle) = .empty;
    defer candles.deinit(allocator);

    const candles_val = data_obj.get("candles") orelse return JsonChartError.InvalidData;
    if (candles_val != .array) return JsonChartError.InvalidData;

    for (candles_val.array.items) |candle_val| {
        if (candle_val != .object) continue;
        const cd = candle_val.object;

        // Support timestamp as int or array index
        const ts = if (cd.get("timestamp")) |t| switch (t) {
            .integer => |n| @as(i64, n),
            else => 0,
        } else 0;

        try candles.append(allocator, .{
            .timestamp = ts,
            .open = getFloat(cd, "open") orelse getFloat(cd, "o") orelse 0,
            .high = getFloat(cd, "high") orelse getFloat(cd, "h") orelse 0,
            .low = getFloat(cd, "low") orelse getFloat(cd, "l") orelse 0,
            .close = getFloat(cd, "close") orelse getFloat(cd, "c") orelse 0,
            .volume = getFloat(cd, "volume") orelse getFloat(cd, "v") orelse 0,
        });
    }

    var chart_config = candlestick.CandlestickConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "show_volume")) |sv| chart_config.show_volume = sv;
            if (getBool(c_obj, "show_grid")) |sg| chart_config.show_grid = sg;
        }
    }

    var chart = candlestick.CandlestickChart.init(allocator, candles.items, layout, chart_config);
    try chart.render(c);
}

fn renderSparklineFromJson(
    allocator: std.mem.Allocator,
    c: canvas.Canvas,
    data: std.json.Value,
    config_val: ?std.json.Value,
    width: f64,
    height: f64,
) !void {
    if (data != .object) return JsonChartError.InvalidData;
    const data_obj = data.object;

    var values: std.ArrayListUnmanaged(f64) = .empty;
    defer values.deinit(allocator);

    const values_val = data_obj.get("values") orelse return JsonChartError.InvalidData;
    if (values_val != .array) return JsonChartError.InvalidData;

    for (values_val.array.items) |v| {
        const val = switch (v) {
            .integer => |n| @as(f64, @floatFromInt(n)),
            .float => |f| f,
            else => 0,
        };
        try values.append(allocator, val);
    }

    var spark_config = sparkline.SparklineConfig{};
    if (config_val) |cfg| {
        if (cfg == .object) {
            const c_obj = cfg.object;
            if (getBool(c_obj, "fill")) |f| spark_config.fill = f;
            if (getBool(c_obj, "show_min")) |sm| spark_config.show_min = sm;
            if (getBool(c_obj, "show_max")) |sm| spark_config.show_max = sm;
            if (c_obj.get("line_color")) |lc| {
                if (parseColor(lc)) |color| spark_config.line_color = color;
            }
        }
    }

    try sparkline.render(allocator, c, values.items, 0, 0, width, height, spark_config);
}

// =============================================================================
// Tests
// =============================================================================

test "parse pie chart json" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "pie",
        \\  "width": 400,
        \\  "height": 300,
        \\  "data": {
        \\    "segments": [
        \\      {"label": "A", "value": 30},
        \\      {"label": "B", "value": 50},
        \\      {"label": "C", "value": 20}
        \\    ]
        \\  }
        \\}
    ;

    const svg = try chartFromJson(allocator, json_str);
    defer allocator.free(svg);

    try std.testing.expect(svg.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "parse gauge chart json" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "gauge",
        \\  "data": {
        \\    "value": 75,
        \\    "label": "CPU Usage"
        \\  },
        \\  "config": {
        \\    "min": 0,
        \\    "max": 100
        \\  }
        \\}
    ;

    const svg = try chartFromJson(allocator, json_str);
    defer allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "parse bar chart json" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "bar",
        \\  "data": {
        \\    "categories": ["Q1", "Q2", "Q3", "Q4"],
        \\    "series": [
        \\      {"name": "2024", "values": [100, 120, 110, 140]},
        \\      {"name": "2025", "values": [110, 130, 125, 155]}
        \\    ]
        \\  },
        \\  "config": {
        \\    "show_values": true
        \\  }
        \\}
    ;

    const svg = try chartFromJson(allocator, json_str);
    defer allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "unknown chart type" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "unknown_chart",
        \\  "data": {}
        \\}
    ;

    const result = chartFromJson(allocator, json_str);
    try std.testing.expectError(JsonChartError.UnknownChartType, result);
}
