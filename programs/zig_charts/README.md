# zig_charts

High-performance SVG charting library for financial and general data visualization, written in Zig.

## Features

- **Pure Zig** - Zero external dependencies, compiles to efficient native code
- **SVG Output** - Text-based vector graphics, easy to test, diff, and embed in HTML/PDF
- **Financial Charts** - OHLCV candlestick charts with volume bars and bull/bear coloring
- **Line Charts** - Multi-series with legend, area fills, dashed lines, and markers
- **Bar Charts** - Grouped/stacked with value labels and custom colors
- **Sparklines** - Compact inline charts (line, bar, win/loss variants)
- **Flexible Scales** - Linear, logarithmic, time, and band (categorical) scales
- **Smart Axis** - Automatic "nice" tick value generation with proper formatting

## Building

```bash
# Build library and demo CLI
zig build

# Run tests
zig build test

# Run demo (generates charts to /tmp/)
zig build run

# Build optimized release
zig build -Doptimize=ReleaseFast
```

## Output

```
zig-out/
├── bin/
│   └── chart-demo      # Demo CLI
└── lib/
    └── libzigcharts.a  # Static library
```

## CLI Usage

```bash
# Generate all demo charts to /tmp/
./zig-out/bin/chart-demo

# Generate specific chart type
chart-demo candlestick
chart-demo line
chart-demo bar
chart-demo sparkline

# Output to custom directory
chart-demo --output ./my-charts

# Show help
chart-demo --help
```

## Library Usage

### Candlestick Chart

```zig
const std = @import("std");
const charts = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sample OHLCV data
    const candles = [_]charts.Candle{
        .{ .timestamp = 1704067200, .open = 100, .high = 105, .low = 98, .close = 103, .volume = 1000000 },
        .{ .timestamp = 1704153600, .open = 103, .high = 108, .low = 101, .close = 106, .volume = 1200000 },
        .{ .timestamp = 1704240000, .open = 106, .high = 110, .low = 104, .close = 108, .volume = 900000 },
    };

    // Create SVG canvas
    var svg = charts.SvgCanvas.init(allocator, 800, 400);
    defer svg.deinit();
    svg.setBackground(charts.Color.white);

    // Define layout with margins
    const layout = charts.Layout{
        .width = 800,
        .height = 400,
        .margin_top = 20,
        .margin_right = 30,
        .margin_bottom = 50,
        .margin_left = 70,
    };

    // Create and render chart
    var chart = charts.CandlestickChart.init(allocator, &candles, layout, .{
        .show_volume = true,
        .bull_color = charts.Color.bull_green,
        .bear_color = charts.Color.bear_red,
    });
    try chart.render(svg.canvas());

    // Get SVG output
    const output = try svg.canvas().finish();
    // Write to file or embed in HTML...
}
```

### Line Chart

```zig
const revenue = [_]charts.DataPoint{
    .{ .x = 1, .y = 100 }, .{ .x = 2, .y = 120 }, .{ .x = 3, .y = 115 },
    .{ .x = 4, .y = 140 }, .{ .x = 5, .y = 160 }, .{ .x = 6, .y = 180 },
};

const expenses = [_]charts.DataPoint{
    .{ .x = 1, .y = 80 }, .{ .x = 2, .y = 85 }, .{ .x = 3, .y = 90 },
    .{ .x = 4, .y = 95 }, .{ .x = 5, .y = 100 }, .{ .x = 6, .y = 110 },
};

const series = [_]charts.LineSeries{
    .{
        .name = "Revenue",
        .data = &revenue,
        .color = charts.Color.bull_green,
        .fill = true,
        .fill_opacity = 0.15,
    },
    .{
        .name = "Expenses",
        .data = &expenses,
        .color = charts.Color.bear_red,
        .dashed = true,
    },
};

var svg = charts.SvgCanvas.init(allocator, 700, 350);
defer svg.deinit();

var chart = charts.LineChart.init(allocator, &series, layout, .{
    .x_label = "Month",
    .y_label = "Value ($K)",
    .show_legend = true,
    .show_grid = true,
});
try chart.render(svg.canvas());
```

### Bar Chart

```zig
const categories = [_][]const u8{ "Q1", "Q2", "Q3", "Q4" };
const series = [_]charts.BarSeries{
    .{ .name = "2024", .values = &[_]f64{ 150, 180, 165, 200 } },
    .{ .name = "2025", .values = &[_]f64{ 170, 195, 185, 220 } },
};

var svg = charts.SvgCanvas.init(allocator, 500, 300);
defer svg.deinit();

var chart = charts.BarChart.init(allocator, &categories, &series, layout, .{
    .show_values = true,
    .bar_padding = 0.1,
});
try chart.render(svg.canvas());
```

### Sparklines

```zig
const data = [_]f64{ 10, 15, 8, 22, 18, 25, 20, 28, 24, 30 };

var svg = charts.SvgCanvas.init(allocator, 200, 50);
defer svg.deinit();

// Line sparkline with markers
try charts.renderSparkline(allocator, svg.canvas(), &data, 10, 5, 180, 40, .{
    .line_color = charts.Color.bull_green,
    .fill = true,
    .show_first = true,
    .show_last = true,
    .show_min = true,
    .show_max = true,
});

// Bar sparkline (positive/negative)
const bar_data = [_]f64{ 5, -3, 8, -2, 6, -5, 9, -1, 4, -4 };
charts.renderSparklineBars(svg.canvas(), &bar_data, 10, 5, 180, 40,
    charts.Color.bull_green, charts.Color.bear_red);

// Win/Loss sparkline
const results = [_]bool{ true, true, false, true, false, false, true, true, true, false };
charts.renderWinLoss(svg.canvas(), &results, 10, 5, 180, 40,
    charts.Color.bull_green, charts.Color.bear_red);
```

## Chart Types

| Type | Use Case | Key Features |
|------|----------|--------------|
| **Candlestick** | Financial OHLCV data | Volume bars, wick lines, bull/bear colors |
| **Line** | Time series, trends | Multi-series, area fill, legend, markers |
| **Bar** | Categorical comparison | Grouped, value labels, custom colors |
| **Sparkline** | Inline mini-charts | Line, bar, win/loss variants |

## Architecture

```
src/
├── lib.zig              # Main library entry point
├── color.zig            # RGBA color with financial palette
├── scales.zig           # LinearScale, LogScale, TimeScale, BandScale
├── canvas.zig           # Abstract Canvas interface (vtable pattern)
├── svg.zig              # SVG rendering backend
├── axis.zig             # Axis rendering with tick generation
├── charts/
│   ├── candlestick.zig  # OHLCV candlestick charts
│   ├── line.zig         # Multi-series line charts
│   ├── bar.zig          # Grouped/stacked bar charts
│   └── sparkline.zig    # Compact inline charts
├── main.zig             # Demo CLI
└── build.zig            # Build configuration
```

## API Reference

### Color

```zig
const Color = struct {
    r: u8, g: u8, b: u8, a: u8 = 255,

    // Constructors
    pub fn rgb(r: u8, g: u8, b: u8) Color;
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color;
    pub fn fromHex(hex: []const u8) ?Color;

    // Operations
    pub fn toHex(self: Color, buf: *[6]u8) []const u8;
    pub fn withAlpha(self: Color, a: u8) Color;
    pub fn blend(self: Color, other: Color, t: f32) Color;
    pub fn lighten(self: Color, amount: f32) Color;
    pub fn darken(self: Color, amount: f32) Color;

    // Predefined colors
    pub const black, white, transparent;
    pub const bull_green, bear_red;           // Financial
    pub const gray_100 ... gray_900;          // Grayscale
    pub const blue_500, red_500, green_500;   // Palette
};
```

### Scales

```zig
// Linear scale: maps [domain_min, domain_max] to [range_min, range_max]
const LinearScale = struct {
    pub fn init(domain_min: f64, domain_max: f64, range_min: f64, range_max: f64) Self;
    pub fn scale(self: Self, value: f64) f64;      // Domain -> Range
    pub fn invert(self: Self, value: f64) f64;     // Range -> Domain
    pub fn ticks(self: Self, allocator: Allocator, approx_count: usize) ![]f64;
    pub fn nice(self: *Self) void;                 // Extend to nice round numbers
};

// Logarithmic scale (base 10)
const LogScale = struct { ... };

// Time scale for Unix timestamps
const TimeScale = struct { ... };

// Band scale for categorical data
const BandScale = struct {
    pub fn bandwidth(self: Self) f64;
    pub fn scale(self: Self, index: usize) f64;
    pub fn indexOf(self: Self, name: []const u8) ?usize;
};
```

### Layout

```zig
const Layout = struct {
    width: f64,
    height: f64,
    margin_top: f64 = 20,
    margin_right: f64 = 20,
    margin_bottom: f64 = 40,
    margin_left: f64 = 60,

    pub fn innerWidth(self: Layout) f64;
    pub fn innerHeight(self: Layout) f64;
    pub fn innerBounds(self: Layout) Rect;
};
```

### Canvas

```zig
const Canvas = struct {
    // Drawing primitives
    pub fn drawLine(self: Canvas, x1: f64, y1: f64, x2: f64, y2: f64, style: StrokeStyle) void;
    pub fn drawRect(self: Canvas, rect: Rect, stroke: ?StrokeStyle, fill: ?FillStyle) void;
    pub fn drawCircle(self: Canvas, cx: f64, cy: f64, r: f64, stroke: ?StrokeStyle, fill: ?FillStyle) void;
    pub fn drawPath(self: Canvas, path: *const Path, stroke: ?StrokeStyle, fill: ?FillStyle) void;
    pub fn drawText(self: Canvas, text: []const u8, x: f64, y: f64, style: TextStyle) void;

    // Grouping and transforms
    pub fn beginGroup(self: Canvas, id: ?[]const u8, class: ?[]const u8) void;
    pub fn endGroup(self: Canvas) void;
    pub fn translate(self: Canvas, x: f64, y: f64) void;
    pub fn rotate(self: Canvas, angle: f64) void;
    pub fn scale(self: Canvas, sx: f64, sy: f64) void;
    pub fn resetTransform(self: Canvas) void;

    // Output
    pub fn finish(self: Canvas) ![]const u8;
};
```

## Generated Demo Charts

| File | Size | Description |
|------|------|-------------|
| `chart-candlestick.svg` | ~12 KB | 30-day OHLCV with volume bars |
| `chart-line.svg` | ~5 KB | Revenue vs Expenses (12 months) |
| `chart-bar.svg` | ~4 KB | Quarterly comparison (2024 vs 2025) |
| `chart-sparklines.svg` | ~3 KB | Line, bar, and win/loss sparklines |

## Performance

- **Zero allocations** in hot path (scales, color operations)
- **Single-pass rendering** - no intermediate data structures
- **Efficient SVG output** - minimal string allocations via fixed buffers
- **~10-50KB** typical chart output size

## Requirements

- **Zig:** 0.16.0+
- **OS:** Linux, macOS, Windows (SVG output is platform-independent)

## Future Enhancements

- [ ] PNG rasterization backend
- [ ] Interactive SVG with JavaScript hooks
- [ ] Pie/donut charts
- [ ] Scatter plots
- [ ] Heatmaps
- [ ] Annotations and tooltips
- [ ] Responsive sizing
- [ ] Animation support

## License

MIT License - See [LICENSE](LICENSE) for details.

```
Copyright 2025 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
```
