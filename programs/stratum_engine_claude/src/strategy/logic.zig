//! Trading Strategy Logic
//! React to Bitcoin mempool events in microseconds
//!
//! Strategy: Detect large exchange deposits (whale dumps) and execute counter-trades

const std = @import("std");
const ExchangeClient = @import("../execution/exchange_client.zig").ExchangeClient;

// Zig 0.16 compatible clock helper
fn getMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Strategy configuration
pub const Config = struct {
    /// Minimum transaction value to trigger (in satoshis)
    whale_threshold_sats: u64 = 100_000_000, // 1 BTC

    /// Known exchange wallet addresses (for deposit detection)
    exchange_addresses: []const []const u8 = &.{
        // Binance hot wallets
        "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo",
        "bc1qm34lsc65zpw79lxes69zkqmk6ee3ewf0j77s3h",

        // Coinbase
        "3Nxwenay9Z8Lc9JBiywExpnEFiLp6Afp8v",

        // Kraken
        "3FHNBLobJnbCTFTVakh5TXmEneyf5PT61B",

        // Add more as discovered
    },

    /// Execution mode
    dry_run: bool = true, // Set false for live trading
};

/// Transaction output
pub const TxOutput = struct {
    address: []const u8,
    value_sats: u64,
};

/// Parsed Bitcoin transaction
pub const Transaction = struct {
    hash: [32]u8,
    total_value_sats: u64,
    outputs: []const TxOutput,

    /// Sum output values
    pub fn getTotalValue(self: Transaction) u64 {
        return self.total_value_sats;
    }

    /// Check if any output goes to known exchange
    pub fn isExchangeDeposit(self: Transaction, config: *const Config) bool {
        for (self.outputs) |output| {
            for (config.exchange_addresses) |exchange_addr| {
                if (std.mem.eql(u8, output.address, exchange_addr)) {
                    return true;
                }
            }
        }
        return false;
    }
};

/// Strategy state
pub const Strategy = struct {
    config: Config,
    exchange: *ExchangeClient,
    allocator: std.mem.Allocator,

    // Statistics
    whales_detected: std.atomic.Value(u64),
    trades_executed: std.atomic.Value(u64),
    total_volume_btc: std.atomic.Value(u64), // In satoshis

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config, exchange: *ExchangeClient) Self {
        return .{
            .config = config,
            .exchange = exchange,
            .allocator = allocator,
            .whales_detected = std.atomic.Value(u64).init(0),
            .trades_executed = std.atomic.Value(u64).init(0),
            .total_volume_btc = std.atomic.Value(u64).init(0),
        };
    }

    /// Main entry point: Called when mempool sniffer detects new transaction
    pub fn onWhaleAlert(self: *Self, tx: Transaction) void {
        const start_ns = getMonotonicNs();

        // Filter 1: Size check
        if (tx.getTotalValue() < self.config.whale_threshold_sats) {
            return; // Too small, ignore
        }

        _ = self.whales_detected.fetchAdd(1, .monotonic);

        const btc_value = @as(f64, @floatFromInt(tx.getTotalValue())) / 100_000_000.0;
        std.debug.print("\n🐋 WHALE DETECTED: {d:.8} BTC\n", .{btc_value});

        // Filter 2: Exchange deposit check
        if (tx.isExchangeDeposit(&self.config)) {
            std.debug.print("⚠️  EXCHANGE DEPOSIT DETECTED - Likely SELL pressure incoming!\n", .{});

            // EXECUTE: Counter-trade (short/sell)
            self.executeCounterTrade(.sell, tx) catch |err| {
                std.debug.print("❌ Execution failed: {}\n", .{err});
                return;
            };
        } else {
            std.debug.print("ℹ️  Wallet-to-wallet transfer (monitoring)\n", .{});
        }

        const end_ns = getMonotonicNs();
        const processing_us = (end_ns - start_ns) / 1000;

        std.debug.print("⏱️  Total processing time: {}µs\n", .{processing_us});
    }

    /// Execute counter-trade based on whale movement
    fn executeCounterTrade(self: *Self, side: enum { buy, sell }, tx: Transaction) !void {
        if (!self.exchange.isReady()) {
            return error.ExchangeNotReady;
        }

        if (self.config.dry_run) {
            std.debug.print("🧪 DRY RUN: Would execute {s} order\n", .{@tagName(side)});
            return;
        }

        switch (side) {
            .sell => {
                std.debug.print("🚀 Executing SELL order...\n", .{});
                try self.exchange.executeSell();
            },
            .buy => {
                std.debug.print("🚀 Executing BUY order...\n", .{});
                try self.exchange.executeBuy();
            },
        }

        _ = self.trades_executed.fetchAdd(1, .monotonic);
        _ = self.total_volume_btc.fetchAdd(tx.getTotalValue(), .monotonic);

        std.debug.print("✅ Trade executed!\n", .{});
    }

    /// Print strategy statistics
    pub fn printStats(self: *Self) void {
        const whales = self.whales_detected.load(.monotonic);
        const trades = self.trades_executed.load(.monotonic);
        const volume_sats = self.total_volume_btc.load(.monotonic);
        const volume_btc = @as(f64, @floatFromInt(volume_sats)) / 100_000_000.0;

        std.debug.print("\n╔═══════════════════════════════════════╗\n", .{});
        std.debug.print("║   STRATEGY STATISTICS                 ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════╝\n", .{});
        std.debug.print("  Whales Detected:  {}\n", .{whales});
        std.debug.print("  Trades Executed:  {}\n", .{trades});
        std.debug.print("  Total Volume:     {d:.8} BTC\n", .{volume_btc});
        std.debug.print("  Execution Rate:   {d:.1}%\n", .{
            if (whales > 0) @as(f64, @floatFromInt(trades)) / @as(f64, @floatFromInt(whales)) * 100.0 else 0.0
        });

        if (self.exchange.getAvgRtt() > 0) {
            std.debug.print("  Exchange RTT:     {}µs\n", .{self.exchange.getAvgRtt()});
        }
        std.debug.print("  Mode:             {s}\n", .{if (self.config.dry_run) "DRY RUN" else "LIVE"});
        std.debug.print("\n", .{});
    }
};

test "whale detection threshold" {
    const allocator = std.testing.allocator;
    var dummy_exchange: ExchangeClient = undefined; // Not used in test

    const config = Config{
        .whale_threshold_sats = 100_000_000, // 1 BTC
        .dry_run = true,
    };

    _ = Strategy.init(allocator, config, &dummy_exchange);

    // Test: Small transaction (should be ignored)
    const small_tx = Transaction{
        .hash = [_]u8{0} ** 32,
        .total_value_sats = 50_000_000, // 0.5 BTC
        .outputs = &.{},
    };

    try std.testing.expect(small_tx.getTotalValue() < config.whale_threshold_sats);

    // Test: Large transaction (should trigger)
    const large_tx = Transaction{
        .hash = [_]u8{0} ** 32,
        .total_value_sats = 200_000_000, // 2 BTC
        .outputs = &.{},
    };

    try std.testing.expect(large_tx.getTotalValue() >= config.whale_threshold_sats);
}

test "exchange deposit detection" {
    const config = Config{
        .exchange_addresses = &.{
            "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo", // Binance
        },
    };

    const outputs = [_]TxOutput{
        .{ .address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", .value_sats = 50_000_000 },
        .{ .address = "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo", .value_sats = 100_000_000 }, // To exchange!
    };

    const tx = Transaction{
        .hash = [_]u8{0} ** 32,
        .total_value_sats = 150_000_000,
        .outputs = &outputs,
    };

    try std.testing.expect(tx.isExchangeDeposit(&config));
}
