//! Candlestick Chart
//!
//! OHLCV (Open-High-Low-Close-Volume) candlestick chart for financial data.
//! The primary use case for this library.

const std = @import("std");
const canvas = @import("../canvas.zig");
const scales = @import("../scales.zig");
const axis = @import("../axis.zig");
const Color = @import("../color.zig").Color;

const Canvas = canvas.Canvas;
const Layout = canvas.Layout;
const Rect = canvas.Rect;
const Path = canvas.Path;
const LinearScale = scales.LinearScale;
const TimeScale = scales.TimeScale;

/// Single OHLCV candle data point
pub const Candle = struct {
    timestamp: i64, // Unix timestamp (seconds or ms)
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64 = 0,

    /// Is this a bullish (green) candle?
    pub fn isBullish(self: Candle) bool {
        return self.close >= self.open;
    }

    /// Candle body size
    pub fn bodySize(self: Candle) f64 {
        return @abs(self.close - self.open);
    }

    /// Upper wick size
    pub fn upperWick(self: Candle) f64 {
        return self.high - @max(self.open, self.close);
    }

    /// Lower wick size
    pub fn lowerWick(self: Candle) f64 {
        return @min(self.open, self.close) - self.low;
    }
};

/// Candlestick chart configuration
pub const CandlestickConfig = struct {
    // Colors
    bull_color: Color = Color.bull_green,
    bear_color: Color = Color.bear_red,
    bull_fill: Color = Color.bull_green,
    bear_fill: Color = Color.bear_red,
    wick_width: f64 = 1.0,

    // Sizing
    candle_width_ratio: f64 = 0.8, // Width relative to available space (0-1)
    min_candle_width: f64 = 3.0,
    max_candle_width: f64 = 30.0,

    // Volume
    show_volume: bool = true,
    volume_height_ratio: f64 = 0.2, // Portion of chart for volume
    volume_opacity: f64 = 0.5,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    show_grid: bool = true,
    grid_color: Color = Color.gray_200,

    // Price formatting
    price_decimals: u8 = 2,
};

/// Candlestick chart renderer
pub const CandlestickChart = struct {
    allocator: std.mem.Allocator,
    candles: []const Candle,
    config: CandlestickConfig,
    layout: Layout,

    // Computed scales
    time_scale: TimeScale,
    price_scale: LinearScale,
    volume_scale: ?LinearScale,

    const Self = @This();

    /// Create a candlestick chart
    pub fn init(
        allocator: std.mem.Allocator,
        candles: []const Candle,
        layout: Layout,
        config: CandlestickConfig,
    ) Self {
        // Compute data bounds
        var min_time: i64 = std.math.maxInt(i64);
        var max_time: i64 = std.math.minInt(i64);
        var min_price: f64 = std.math.floatMax(f64);
        var max_price: f64 = -std.math.floatMax(f64);
        var max_volume: f64 = 0;

        for (candles) |c| {
            min_time = @min(min_time, c.timestamp);
            max_time = @max(max_time, c.timestamp);
            min_price = @min(min_price, c.low);
            max_price = @max(max_price, c.high);
            max_volume = @max(max_volume, c.volume);
        }

        // Add padding to price range
        const price_padding = (max_price - min_price) * 0.05;
        min_price -= price_padding;
        max_price += price_padding;

        // Calculate plot areas
        const bounds = layout.innerBounds();
        const volume_height = if (config.show_volume) bounds.height * config.volume_height_ratio else 0;
        const price_height = bounds.height - volume_height;

        // Create scales
        const time_scale = TimeScale.init(
            min_time,
            max_time,
            bounds.x,
            bounds.x + bounds.width,
        );

        const price_scale = LinearScale.init(
            min_price,
            max_price,
            bounds.y + price_height, // Y is inverted (top = 0)
            bounds.y,
        );

        const volume_scale: ?LinearScale = if (config.show_volume)
            LinearScale.init(
                0,
                max_volume,
                bounds.y + bounds.height,
                bounds.y + price_height,
            )
        else
            null;

        return .{
            .allocator = allocator,
            .candles = candles,
            .config = config,
            .layout = layout,
            .time_scale = time_scale,
            .price_scale = price_scale,
            .volume_scale = volume_scale,
        };
    }

    /// Render the chart
    pub fn render(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Calculate candle width
        const candle_spacing = if (self.candles.len > 1)
            bounds.width / @as(f64, @floatFromInt(self.candles.len))
        else
            bounds.width;

        const candle_width = @min(
            self.config.max_candle_width,
            @max(self.config.min_candle_width, candle_spacing * self.config.candle_width_ratio),
        );

        // Draw grid first (behind candles)
        if (self.config.show_grid) {
            try self.drawGrid(c);
        }

        // Draw volume bars
        if (self.config.show_volume) {
            c.beginGroup("volume", null);
            for (self.candles, 0..) |candle, i| {
                self.drawVolumeBar(c, candle, i, candle_width);
            }
            c.endGroup();
        }

        // Draw candles
        c.beginGroup("candles", null);
        for (self.candles, 0..) |candle, i| {
            self.drawCandle(c, candle, i, candle_width);
        }
        c.endGroup();

        // Draw axes
        if (self.config.show_y_axis) {
            try axis.drawYAxis(c, self.allocator, self.layout, self.price_scale, .{
                .show_grid = false, // Already drawn
                .format_fn = formatPrice,
            });
        }

        if (self.config.show_x_axis) {
            try axis.drawTimeXAxis(c, self.allocator, self.layout, self.time_scale, .{
                .show_grid = false,
            });
        }
    }

    fn drawCandle(self: *Self, c: Canvas, candle: Candle, index: usize, width: f64) void {
        const x_center = self.getCandleX(index);
        const half_width = width / 2;

        const open_y = self.price_scale.scale(candle.open);
        const close_y = self.price_scale.scale(candle.close);
        const high_y = self.price_scale.scale(candle.high);
        const low_y = self.price_scale.scale(candle.low);

        const is_bull = candle.isBullish();
        const color = if (is_bull) self.config.bull_color else self.config.bear_color;
        const fill_color = if (is_bull) self.config.bull_fill else self.config.bear_fill;

        // Draw wick (high-low line)
        c.drawLine(
            x_center,
            high_y,
            x_center,
            low_y,
            .{ .color = color, .width = self.config.wick_width },
        );

        // Draw body
        const body_top = @min(open_y, close_y);
        const body_height = @max(1.0, @abs(close_y - open_y)); // Minimum 1px for doji

        c.drawRect(
            Rect.init(x_center - half_width, body_top, width, body_height),
            .{ .color = color, .width = 1.0 },
            .{ .color = fill_color },
        );
    }

    fn drawVolumeBar(self: *Self, c: Canvas, candle: Candle, index: usize, width: f64) void {
        const vs = self.volume_scale orelse return;

        const x_center = self.getCandleX(index);
        const half_width = width / 2;

        const bar_top = vs.scale(candle.volume);
        const bar_bottom = vs.scale(0);
        const bar_height = bar_bottom - bar_top;

        const is_bull = candle.isBullish();
        const base_color = if (is_bull) self.config.bull_color else self.config.bear_color;
        const fill_color = base_color.withAlpha(@intFromFloat(self.config.volume_opacity * 255));

        c.drawRect(
            Rect.init(x_center - half_width, bar_top, width, bar_height),
            null,
            .{ .color = fill_color },
        );
    }

    fn drawGrid(self: *Self, c: Canvas) !void {
        const bounds = self.layout.innerBounds();

        // Horizontal grid lines (price levels)
        const price_ticks = try self.price_scale.ticks(self.allocator, 5);
        defer self.allocator.free(price_ticks);

        for (price_ticks) |price| {
            const y = self.price_scale.scale(price);
            c.drawLine(
                bounds.x,
                y,
                bounds.x + bounds.width,
                y,
                .{ .color = self.config.grid_color, .width = 1.0 },
            );
        }

        // Vertical grid lines (time)
        const time_ticks = try self.time_scale.ticks(self.allocator, 5);
        defer self.allocator.free(time_ticks);

        for (time_ticks) |ts| {
            const x = self.time_scale.scale(ts);
            c.drawLine(
                x,
                bounds.y,
                x,
                bounds.y + bounds.height,
                .{ .color = self.config.grid_color, .width = 1.0 },
            );
        }
    }

    fn getCandleX(self: *Self, index: usize) f64 {
        if (self.candles.len == 0) return self.layout.innerBounds().x;
        return self.time_scale.scale(self.candles[index].timestamp);
    }
};

/// Format price with 2 decimal places
fn formatPrice(value: f64, buf: []u8) []const u8 {
    const len = std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return "?";
    return buf[0..len.len];
}

// =============================================================================
// Convenience Functions
// =============================================================================

/// Generate sample OHLCV data for testing
pub fn generateSampleData(allocator: std.mem.Allocator, count: usize, start_price: f64) ![]Candle {
    var candles = try allocator.alloc(Candle, count);
    // Use fixed seed for deterministic demo output
    var rng = std.Random.DefaultPrng.init(0x853c49e6748fea9b);
    var price = start_price;

    for (0..count) |i| {
        const change = (rng.random().float(f64) - 0.5) * 5;
        const open = price;
        price += change;
        const close = price;

        const volatility = rng.random().float(f64) * 3 + 1;
        const high = @max(open, close) + volatility;
        const low = @min(open, close) - volatility;

        candles[i] = .{
            .timestamp = @as(i64, @intCast(1704067200 + i * 86400)), // Daily candles starting Jan 1, 2024
            .open = open,
            .high = high,
            .low = low,
            .close = close,
            .volume = rng.random().float(f64) * 1_000_000 + 100_000,
        };
    }

    return candles;
}

// =============================================================================
// Tests
// =============================================================================

test "candle calculations" {
    const candle = Candle{
        .timestamp = 1704067200,
        .open = 100,
        .high = 110,
        .low = 95,
        .close = 105,
        .volume = 1000,
    };

    try std.testing.expect(candle.isBullish());
    try std.testing.expectEqual(@as(f64, 5), candle.bodySize());
    try std.testing.expectEqual(@as(f64, 5), candle.upperWick()); // 110 - 105
    try std.testing.expectEqual(@as(f64, 5), candle.lowerWick()); // 100 - 95
}

test "bearish candle" {
    const candle = Candle{
        .timestamp = 1704067200,
        .open = 105,
        .high = 110,
        .low = 95,
        .close = 100,
        .volume = 1000,
    };

    try std.testing.expect(!candle.isBullish());
    try std.testing.expectEqual(@as(f64, 5), candle.bodySize());
}
