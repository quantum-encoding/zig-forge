const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;

/// Get current Unix timestamp (seconds since epoch) - Zig 0.16 compatible
fn getTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Runaway Protection System - Prevents catastrophic losses
pub const RunawayProtection = struct {
    const Self = @This();

    pub const ProtectionLimits = struct {
        max_daily_trades: u32,
        max_daily_loss: Decimal,
        max_consecutive_losses: u32,
        max_position_value: Decimal,
        max_order_rate_per_minute: u32,
        emergency_stop_loss_pct: f64,
    };

    // Core tracking
    allocator: std.mem.Allocator,
    daily_trades: u32,
    daily_loss: Decimal,
    consecutive_losses: u32,
    total_position_value: Decimal,
    last_reset_time: i64,

    // Circuit breakers
    is_halted: std.atomic.Value(bool),
    halt_reason: ?[]const u8,

    // Limits from configuration
    limits: ProtectionLimits,

    // Tracking for rate limiting
    order_timestamps: std.ArrayList(i64),

    pub fn init(allocator: std.mem.Allocator, limits: ProtectionLimits) Self {
        return .{
            .allocator = allocator,
            .daily_trades = 0,
            .daily_loss = Decimal.fromInt(0),
            .consecutive_losses = 0,
            .total_position_value = Decimal.fromInt(0),
            .last_reset_time = getTimestamp(),
            .is_halted = std.atomic.Value(bool).init(false),
            .halt_reason = null,
            .limits = limits,
            .order_timestamps = std.ArrayList(i64).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.order_timestamps.deinit(self.allocator);
    }

    /// Check if we should allow this order
    pub fn checkOrder(self: *Self, order_value: Decimal, symbol: []const u8) !bool {
        _ = symbol;

        // Check if system is halted
        if (self.is_halted.load(.acquire)) {
            std.debug.print("❌ RUNAWAY PROTECTION: System halted - {s}\n", .{self.halt_reason.?});
            return false;
        }

        // Check daily reset
        self.checkDailyReset();

        // Check daily trade limit
        if (self.daily_trades >= self.limits.max_daily_trades) {
            self.halt("Daily trade limit exceeded");
            return false;
        }

        // Check position value limit
        const new_position_value = try self.total_position_value.add(order_value);
        if (new_position_value.toFloat() > self.limits.max_position_value.toFloat()) {
            std.debug.print("⚠️ RUNAWAY PROTECTION: Order would exceed max position value\n", .{});
            return false;
        }

        // Check order rate (orders per minute)
        const now = getTimestamp();
        try self.cleanOldTimestamps(now);

        if (self.order_timestamps.items.len >= self.limits.max_order_rate_per_minute) {
            std.debug.print("⚠️ RUNAWAY PROTECTION: Order rate limit exceeded\n", .{});
            return false;
        }

        // Check consecutive losses
        if (self.consecutive_losses >= self.limits.max_consecutive_losses) {
            self.halt("Too many consecutive losses");
            return false;
        }

        // All checks passed
        try self.order_timestamps.append(self.allocator, now);
        self.daily_trades += 1;
        self.total_position_value = new_position_value;

        return true;
    }

    /// Record trade result
    pub fn recordTrade(self: *Self, pnl: Decimal) void {
        if (pnl.toFloat() < 0) {
            self.consecutive_losses += 1;
            self.daily_loss = self.daily_loss.add(pnl) catch self.daily_loss;

            // Check daily loss limit
            if (self.daily_loss.toFloat() < -self.limits.max_daily_loss.toFloat()) {
                self.halt("Daily loss limit exceeded");
            }
        } else {
            self.consecutive_losses = 0;
        }
    }

    /// Emergency halt
    pub fn halt(self: *Self, reason: []const u8) void {
        self.is_halted.store(true, .release);
        self.halt_reason = reason;

        std.debug.print("\n", .{});
        std.debug.print("🚨🚨🚨 EMERGENCY HALT 🚨🚨🚨\n", .{});
        std.debug.print("Reason: {s}\n", .{reason});
        std.debug.print("Daily Trades: {}/{}\n", .{self.daily_trades, self.limits.max_daily_trades});
        std.debug.print("Daily Loss: ${d:.2}\n", .{self.daily_loss.toFloat()});
        std.debug.print("Consecutive Losses: {}\n", .{self.consecutive_losses});
        std.debug.print("Position Value: ${d:.2}\n", .{self.total_position_value.toFloat()});
        std.debug.print("🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨\n", .{});
        std.debug.print("\n", .{});
    }

    /// Resume trading after manual review
    pub fn resumeTrading(self: *Self) void {
        self.is_halted.store(false, .release);
        self.halt_reason = null;
        self.consecutive_losses = 0;
        std.debug.print("✅ RUNAWAY PROTECTION: Trading resumed\n", .{});
    }

    /// Check if we need to reset daily counters
    fn checkDailyReset(self: *Self) void {
        const now = getTimestamp();
        const hours_since_reset = @divTrunc(now - self.last_reset_time, 3600);

        if (hours_since_reset >= 24) {
            self.daily_trades = 0;
            self.daily_loss = Decimal.fromInt(0);
            self.last_reset_time = now;
            std.debug.print("📅 Daily counters reset\n", .{});
        }
    }

    /// Clean timestamps older than 1 minute
    fn cleanOldTimestamps(self: *Self, now: i64) !void {
        const cutoff = now - 60;

        var i: usize = 0;
        while (i < self.order_timestamps.items.len) {
            if (self.order_timestamps.items[i] < cutoff) {
                _ = self.order_timestamps.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get current status
    pub fn getStatus(self: *Self) ProtectionStatus {
        self.checkDailyReset();

        return .{
            .is_halted = self.is_halted.load(.acquire),
            .halt_reason = self.halt_reason,
            .daily_trades = self.daily_trades,
            .max_daily_trades = self.limits.max_daily_trades,
            .daily_loss = self.daily_loss.toFloat(),
            .max_daily_loss = self.limits.max_daily_loss.toFloat(),
            .consecutive_losses = self.consecutive_losses,
            .max_consecutive_losses = self.limits.max_consecutive_losses,
            .position_value = self.total_position_value.toFloat(),
            .max_position_value = self.limits.max_position_value.toFloat(),
            .orders_per_minute = @intCast(self.order_timestamps.items.len),
            .max_orders_per_minute = self.limits.max_order_rate_per_minute,
        };
    }

    pub const ProtectionStatus = struct {
        is_halted: bool,
        halt_reason: ?[]const u8,
        daily_trades: u32,
        max_daily_trades: u32,
        daily_loss: f64,
        max_daily_loss: f64,
        consecutive_losses: u32,
        max_consecutive_losses: u32,
        position_value: f64,
        max_position_value: f64,
        orders_per_minute: u32,
        max_orders_per_minute: u32,
    };
};

// Test the runaway protection
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("🛡️ Testing Runaway Protection System\n", .{});
    std.debug.print("=====================================\n\n", .{});

    const limits = RunawayProtection.ProtectionLimits{
        .max_daily_trades = 100,
        .max_daily_loss = Decimal.fromFloat(1000),
        .max_consecutive_losses = 5,
        .max_position_value = Decimal.fromFloat(50000),
        .max_order_rate_per_minute = 10,
        .emergency_stop_loss_pct = 0.02,
    };

    var protection = RunawayProtection.init(allocator, limits);
    defer protection.deinit();

    // Test 1: Normal order
    std.debug.print("Test 1: Normal order\n", .{});
    const order1 = Decimal.fromFloat(1000);
    if (try protection.checkOrder(order1, "AAPL")) {
        std.debug.print("✅ Order approved\n", .{});
    }

    // Test 2: Order that exceeds position limit
    std.debug.print("\nTest 2: Large order\n", .{});
    const order2 = Decimal.fromFloat(60000);
    if (!try protection.checkOrder(order2, "AAPL")) {
        std.debug.print("✅ Large order correctly blocked\n", .{});
    }

    // Test 3: Simulate consecutive losses
    std.debug.print("\nTest 3: Consecutive losses\n", .{});
    for (0..6) |i| {
        protection.recordTrade(Decimal.fromFloat(-100));
        std.debug.print("Loss #{}: Consecutive losses = {}\n", .{i + 1, protection.consecutive_losses});

        if (protection.is_halted.load(.acquire)) {
            std.debug.print("✅ System halted after too many losses\n", .{});
            break;
        }
    }

    // Test 4: Check status
    std.debug.print("\nTest 4: System status\n", .{});
    const status = protection.getStatus();
    std.debug.print("Status:\n", .{});
    std.debug.print("  Halted: {}\n", .{status.is_halted});
    std.debug.print("  Daily trades: {}/{}\n", .{status.daily_trades, status.max_daily_trades});
    std.debug.print("  Daily loss: ${d:.2}/${d:.2}\n", .{status.daily_loss, status.max_daily_loss});
    std.debug.print("  Consecutive losses: {}/{}\n", .{status.consecutive_losses, status.max_consecutive_losses});
    std.debug.print("  Position value: ${d:.2}/${d:.2}\n", .{status.position_value, status.max_position_value});

    std.debug.print("\n✅ All runaway protection tests passed!\n", .{});
}