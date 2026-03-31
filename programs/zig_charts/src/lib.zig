//! Zig Charts
//!
//! High-performance charting library for financial and general data visualization.
//! Designed for integration with timeseries_db and market_data_parser.
//!
//! Features:
//! - Candlestick charts (OHLCV) for financial data
//! - Line charts with multi-series support
//! - Bar charts (grouped and stacked)
//! - Sparklines for compact inline charts
//! - SVG output (text-based, easy to test/embed)
//!
//! Usage:
//! ```zig
//! const charts = @import("zig_charts");
//!
//! // Create SVG canvas
//! var svg = charts.SvgCanvas.init(allocator, 800, 400);
//! defer svg.deinit();
//!
//! // Create candlestick chart
//! var chart = charts.CandlestickChart.init(allocator, candles, layout, .{});
//! try chart.render(svg.canvas());
//!
//! // Get SVG output
//! const output = try svg.canvas().finish();
//! ```

const std = @import("std");

// =============================================================================
// Core Modules
// =============================================================================

/// Color utilities and predefined palettes
pub const color = @import("color.zig");
pub const Color = color.Color;

/// Axis scaling (linear, log, time, band)
pub const scales = @import("scales.zig");
pub const LinearScale = scales.LinearScale;
pub const LogScale = scales.LogScale;
pub const TimeScale = scales.TimeScale;
pub const BandScale = scales.BandScale;

/// Abstract canvas interface and primitives
pub const canvas = @import("canvas.zig");
pub const Canvas = canvas.Canvas;
pub const Layout = canvas.Layout;
pub const Point = canvas.Point;
pub const Rect = canvas.Rect;
pub const Path = canvas.Path;
pub const StrokeStyle = canvas.StrokeStyle;
pub const FillStyle = canvas.FillStyle;
pub const TextStyle = canvas.TextStyle;
pub const TextAnchor = canvas.TextAnchor;

/// SVG rendering backend
pub const svg = @import("svg.zig");
pub const SvgCanvas = svg.SvgCanvas;

/// Axis rendering
pub const axis = @import("axis.zig");
pub const AxisConfig = axis.AxisConfig;
pub const drawXAxis = axis.drawXAxis;
pub const drawYAxis = axis.drawYAxis;
pub const drawTimeXAxis = axis.drawTimeXAxis;
pub const drawBandXAxis = axis.drawBandXAxis;
pub const formatCurrency = axis.formatCurrency;
pub const formatPercent = axis.formatPercent;

// =============================================================================
// Chart Types
// =============================================================================

/// Candlestick (OHLCV) charts for financial data
pub const candlestick = @import("charts/candlestick.zig");
pub const Candle = candlestick.Candle;
pub const CandlestickChart = candlestick.CandlestickChart;
pub const CandlestickConfig = candlestick.CandlestickConfig;
pub const generateSampleCandles = candlestick.generateSampleData;

/// Line charts with multi-series support
pub const line = @import("charts/line.zig");
pub const LineChart = line.LineChart;
pub const LineChartConfig = line.LineChartConfig;
pub const LineSeries = line.Series;
pub const DataPoint = line.DataPoint;
pub const fromValues = line.fromValues;

/// Bar charts (grouped and stacked)
pub const bar = @import("charts/bar.zig");
pub const BarChart = bar.BarChart;
pub const BarChartConfig = bar.BarChartConfig;
pub const BarSeries = bar.BarSeries;
pub const BarMode = bar.BarMode;

/// Sparklines for compact inline visualization
pub const sparkline = @import("charts/sparkline.zig");
pub const SparklineConfig = sparkline.SparklineConfig;
pub const renderSparkline = sparkline.render;
pub const renderSparklineBars = sparkline.renderBars;
pub const renderWinLoss = sparkline.renderWinLoss;

/// Pie and donut charts
pub const pie = @import("charts/pie.zig");
pub const PieChart = pie.PieChart;
pub const PieChartConfig = pie.PieChartConfig;
pub const PieSegment = pie.PieSegment;
pub const renderPie = pie.renderPie;

/// Gauge (arc dial) charts
pub const gauge = @import("charts/gauge.zig");
pub const GaugeChart = gauge.GaugeChart;
pub const GaugeConfig = gauge.GaugeConfig;
pub const GaugeZone = gauge.GaugeZone;
pub const renderGauge = gauge.renderGauge;

/// Progress bar charts
pub const progress = @import("charts/progress.zig");
pub const ProgressChart = progress.ProgressChart;
pub const ProgressConfig = progress.ProgressConfig;
pub const ProgressBar = progress.ProgressBar;
pub const ProgressStatus = progress.ProgressStatus;
pub const renderProgress = progress.renderProgress;

/// Scatter and bubble charts
pub const scatter = @import("charts/scatter.zig");
pub const ScatterChart = scatter.ScatterChart;
pub const ScatterConfig = scatter.ScatterConfig;
pub const ScatterSeries = scatter.ScatterSeries;
pub const ScatterPoint = scatter.ScatterPoint;
pub const renderScatter = scatter.renderScatter;

/// Area charts (stacked, percent, stream)
pub const area = @import("charts/area.zig");
pub const AreaChart = area.AreaChart;
pub const AreaConfig = area.AreaConfig;
pub const AreaSeries = area.AreaSeries;
pub const AreaPoint = area.AreaPoint;
pub const StackMode = area.StackMode;
pub const renderArea = area.renderArea;

/// Heatmap charts
pub const heatmap = @import("charts/heatmap.zig");
pub const HeatmapChart = heatmap.HeatmapChart;
pub const HeatmapConfig = heatmap.HeatmapConfig;
pub const ColorScale = heatmap.ColorScale;
pub const renderHeatmap = heatmap.renderHeatmap;
pub const renderCorrelationMatrix = heatmap.renderCorrelationMatrix;

/// JSON chart specification parser
pub const json = @import("json.zig");
pub const chartFromJson = json.chartFromJson;
pub const ChartType = json.ChartType;
pub const JsonChartError = json.JsonChartError;

// =============================================================================
// Convenience Functions
// =============================================================================

/// Quick candlestick chart to SVG
pub fn candlestickToSvg(
    allocator: std.mem.Allocator,
    candles: []const Candle,
    width: f64,
    height: f64,
) ![]const u8 {
    var svg_canvas = SvgCanvas.init(allocator, width, height);
    defer svg_canvas.deinit();

    const layout = Layout{
        .width = width,
        .height = height,
        .margin_top = 20,
        .margin_right = 20,
        .margin_bottom = 40,
        .margin_left = 60,
    };

    var chart = CandlestickChart.init(allocator, candles, layout, .{});
    try chart.render(svg_canvas.canvas());

    const output = try svg_canvas.canvas().finish();

    // Copy to owned memory
    const result = try allocator.dupe(u8, output);
    return result;
}

/// Quick line chart to SVG
pub fn lineChartToSvg(
    allocator: std.mem.Allocator,
    series: []const LineSeries,
    width: f64,
    height: f64,
) ![]const u8 {
    var svg_canvas = SvgCanvas.init(allocator, width, height);
    defer svg_canvas.deinit();

    const layout = Layout{
        .width = width,
        .height = height,
    };

    var chart = LineChart.init(allocator, series, layout, .{});
    try chart.render(svg_canvas.canvas());

    const output = try svg_canvas.canvas().finish();
    const result = try allocator.dupe(u8, output);
    return result;
}

/// Quick sparkline to SVG
pub fn sparklineToSvg(
    allocator: std.mem.Allocator,
    data: []const f64,
    width: f64,
    height: f64,
) ![]const u8 {
    var svg_canvas = SvgCanvas.init(allocator, width, height);
    defer svg_canvas.deinit();

    try renderSparkline(allocator, svg_canvas.canvas(), data, 0, 0, width, height, .{});

    const output = try svg_canvas.canvas().finish();
    const result = try allocator.dupe(u8, output);
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "all imports" {
    _ = color;
    _ = scales;
    _ = canvas;
    _ = svg;
    _ = axis;
    _ = candlestick;
    _ = line;
    _ = bar;
    _ = sparkline;
    _ = pie;
    _ = gauge;
    _ = progress;
    _ = scatter;
    _ = area;
    _ = heatmap;
    _ = json;
}

test "quick candlestick" {
    const allocator = std.testing.allocator;

    const candles = [_]Candle{
        .{ .timestamp = 1704067200, .open = 100, .high = 110, .low = 95, .close = 105, .volume = 1000 },
        .{ .timestamp = 1704153600, .open = 105, .high = 115, .low = 100, .close = 112, .volume = 1200 },
        .{ .timestamp = 1704240000, .open = 112, .high = 120, .low = 108, .close = 115, .volume = 900 },
    };

    const svg_output = try candlestickToSvg(allocator, &candles, 400, 200);
    defer allocator.free(svg_output);

    try std.testing.expect(svg_output.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, svg_output, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg_output, "</svg>") != null);
}

test "quick sparkline" {
    const allocator = std.testing.allocator;

    const data = [_]f64{ 10, 25, 15, 30, 22, 35, 28 };
    const svg_output = try sparklineToSvg(allocator, &data, 100, 30);
    defer allocator.free(svg_output);

    try std.testing.expect(svg_output.len > 50);
    try std.testing.expect(std.mem.indexOf(u8, svg_output, "<path") != null);
}
