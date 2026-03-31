// Strategy Configuration Management
// Replaces hardcoded parameters with configurable values

const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;

pub const StrategyConfig = struct {
    // Pool sizes
    tick_pool_size: usize = 200000,
    signal_pool_size: usize = 10000,

    // Rate limits
    max_order_rate: u32 = 10000,
    max_message_rate: u32 = 100000,

    // Latency monitoring
    latency_threshold_us: u64 = 500,
    latency_warning_us: u64 = 1000,

    // Buffer sizes
    tick_buffer_size: usize = 10000,
    order_book_depth: usize = 100,

    // Risk parameters
    max_position: f64 = 1000.0,
    max_position_per_symbol: f64 = 500.0,
    max_spread: f64 = 0.50,
    min_edge: f64 = 0.10,

    // Strategy parameters
    tick_window: u32 = 100,
    moving_average_period: u32 = 20,
    rsi_period: u32 = 14,

    // Order sizing
    default_order_size: u32 = 100,
    min_order_size: u32 = 1,
    max_order_size: u32 = 1000,

    // Market making parameters
    quote_width: f64 = 0.02,  // 2 cents default spread
    quote_size_min: u32 = 100,
    quote_size_max: u32 = 1000,

    // Momentum parameters
    momentum_threshold: f64 = 0.02,  // 2% move triggers signal
    momentum_lookback: u32 = 60,     // 60 second lookback

    // Mean reversion parameters
    reversion_threshold: f64 = 2.0,  // 2 standard deviations
    reversion_period: u32 = 300,     // 5 minute period

    // Stop loss / take profit
    stop_loss_percent: f64 = 0.02,   // 2% stop loss
    take_profit_percent: f64 = 0.05, // 5% take profit
    trailing_stop_percent: f64 = 0.01, // 1% trailing stop

    // Volume filters
    min_volume_filter: u32 = 10000,  // Min volume to trade
    volume_participation: f64 = 0.01, // Max 1% of volume

    // Time filters
    enable_premarket: bool = false,
    enable_afterhours: bool = false,
    max_holding_period_seconds: u32 = 3600, // 1 hour max hold

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !StrategyConfig {
        // Read file contents using posix APIs
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.c.close(fd);

        // Read file in chunks
        var contents: std.ArrayListUnmanaged(u8) = .empty;
        defer contents.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try contents.appendSlice(allocator, buf[0..@intCast(n)]);
            if (contents.items.len > 1024 * 1024) return error.FileTooLarge;
        }

        const parsed = try std.json.parseFromSlice(
            StrategyConfig,
            allocator,
            contents.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return parsed.value;
    }

    pub fn saveToFile(self: *const StrategyConfig, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_str = try std.json.stringifyAlloc(allocator, self, .{ .whitespace = .indent_2 });
        defer allocator.free(json_str);

        // Write file using posix APIs
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        defer _ = std.c.close(fd);

        var written: usize = 0;
        while (written < json_str.len) {
            const remaining = json_str[written..];
            const n = std.c.write(fd, remaining.ptr, remaining.len);
            if (n <= 0) return error.WriteError;
            written += @intCast(n);
        }
    }

    pub fn validate(self: *const StrategyConfig) !void {
        if (self.min_order_size > self.max_order_size) {
            return error.InvalidOrderSizeRange;
        }

        if (self.stop_loss_percent >= 1.0 or self.stop_loss_percent <= 0) {
            return error.InvalidStopLossPercent;
        }

        if (self.take_profit_percent <= 0) {
            return error.InvalidTakeProfitPercent;
        }

        if (self.volume_participation > 0.1) { // Max 10% of volume
            return error.ExcessiveVolumeParticipation;
        }

        if (self.tick_pool_size < 1000) {
            return error.InsufficientTickPoolSize;
        }
    }

    pub fn getDecimal(self: *const StrategyConfig, field: enum {
        max_position,
        max_spread,
        min_edge,
        quote_width,
        momentum_threshold,
        stop_loss_percent,
        take_profit_percent,
    }) Decimal {
        return switch (field) {
            .max_position => Decimal.fromFloat(self.max_position),
            .max_spread => Decimal.fromFloat(self.max_spread),
            .min_edge => Decimal.fromFloat(self.min_edge),
            .quote_width => Decimal.fromFloat(self.quote_width),
            .momentum_threshold => Decimal.fromFloat(self.momentum_threshold),
            .stop_loss_percent => Decimal.fromFloat(self.stop_loss_percent),
            .take_profit_percent => Decimal.fromFloat(self.take_profit_percent),
        };
    }
};

// Default configurations for different strategy types
pub const DEFAULT_CONFIGS = struct {
    pub const market_maker = StrategyConfig{
        .tick_window = 50,
        .quote_width = 0.02,
        .max_position = 500.0,
        .min_edge = 0.01,
    };

    pub const momentum = StrategyConfig{
        .tick_window = 200,
        .momentum_threshold = 0.03,
        .max_position = 1000.0,
        .stop_loss_percent = 0.02,
    };

    pub const mean_reversion = StrategyConfig{
        .tick_window = 300,
        .reversion_threshold = 2.5,
        .max_position = 750.0,
        .take_profit_percent = 0.03,
    };

    pub const scalper = StrategyConfig{
        .tick_window = 20,
        .min_edge = 0.005,
        .max_position = 200.0,
        .max_holding_period_seconds = 60,
    };
};

test "StrategyConfig validation" {
    var config = StrategyConfig{};
    try config.validate();

    // Test invalid config
    config.min_order_size = 1000;
    config.max_order_size = 100;
    try std.testing.expectError(error.InvalidOrderSizeRange, config.validate());
}

test "StrategyConfig JSON serialization" {
    const allocator = std.testing.allocator;

    const config = StrategyConfig{
        .tick_window = 150,
        .max_position = 2000.0,
        .min_edge = 0.15,
    };

    const json = try std.json.stringifyAlloc(allocator, config, .{});
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(StrategyConfig, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(config.tick_window, parsed.value.tick_window);
    try std.testing.expectEqual(config.max_position, parsed.value.max_position);
}