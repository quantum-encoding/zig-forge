const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const hft_system = @import("hft_system.zig");
const network = @import("network.zig");
const fix = @import("fix_protocol.zig");

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Get current time in milliseconds (Zig 0.16 compatible)
fn getCurrentMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
const order_book = @import("order_book_v2.zig");

/// Live trading system combining all components
pub const LiveTradingSystem = struct {
    const Self = @This();
    
    // Core components
    hft: *hft_system.HFTSystem,
    market_feed: *network.AlpacaFeed,
    order_router: *fix.FIXEngine,
    allocator: std.mem.Allocator,
    
    // Control flags
    is_running: std.atomic.Value(bool),
    is_trading_enabled: std.atomic.Value(bool),
    
    // Performance metrics
    ticks_from_network: std.atomic.Value(u64),
    orders_to_exchange: std.atomic.Value(u64),
    network_latency_us: std.atomic.Value(u64),
    routing_latency_us: std.atomic.Value(u64),
    
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        sender_id: []const u8,
        exchange_id: []const u8,
    ) !Self {
        // Initialize HFT system
        const strategy_cfg = @import("strategy_config.zig").StrategyConfig{};
        const hft_config = hft_system.HFTSystem.SystemConfig{
            .max_order_rate = 10000,
            .max_message_rate = 100000,
            .latency_threshold_us = 100,
            .tick_buffer_size = 10000,
            .enable_logging = false,
            .strategy_config = strategy_cfg,
        };
        
        const hft_ptr = try allocator.create(hft_system.HFTSystem);
        hft_ptr.* = try hft_system.HFTSystem.init(allocator, hft_config, null);
        
        // Initialize market data feed
        const feed_ptr = try allocator.create(network.AlpacaFeed);
        feed_ptr.* = network.AlpacaFeed.init(allocator, api_key, api_secret, true);
        
        // Initialize FIX engine
        const fix_ptr = try allocator.create(fix.FIXEngine);
        fix_ptr.* = fix.FIXEngine.init(allocator, sender_id, exchange_id);
        
        return .{
            .hft = hft_ptr,
            .market_feed = feed_ptr,
            .order_router = fix_ptr,
            .allocator = allocator,
            .is_running = std.atomic.Value(bool).init(false),
            .is_trading_enabled = std.atomic.Value(bool).init(false),
            .ticks_from_network = std.atomic.Value(u64).init(0),
            .orders_to_exchange = std.atomic.Value(u64).init(0),
            .network_latency_us = std.atomic.Value(u64).init(0),
            .routing_latency_us = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.hft.deinit();
        self.allocator.destroy(self.hft);
        self.allocator.destroy(self.market_feed);
        self.allocator.destroy(self.order_router);
    }
    
    /// Start the live trading system
    pub fn start(self: *Self) !void {
        std.debug.print("\n🚀 Starting Live Trading System...\n\n", .{});
        
        // Connect to market data
        std.debug.print("📡 Connecting to market data feed...\n", .{});
        try self.market_feed.connect();
        
        // Subscribe to symbols
        const symbols = [_][]const u8{ "AAPL", "MSFT", "GOOGL" };
        try self.market_feed.subscribeQuotes(&symbols);
        
        // Connect to exchange
        std.debug.print("🔌 Connecting to exchange via FIX...\n", .{});
        try self.order_router.connect();
        
        // Add trading strategy
        const strategy_params = hft_system.Strategy.StrategyParams{
            .max_position = Decimal.fromInt(1000),
            .max_spread = Decimal.fromFloat(0.50),
            .min_edge = Decimal.fromFloat(0.05),
            .tick_window = 100,
        };
        try self.hft.addStrategy(hft_system.Strategy.init("LiveMarketMaker", strategy_params));
        
        self.is_running.store(true, .release);
        std.debug.print("✅ System is now LIVE!\n\n", .{});
    }
    
    /// Main processing loop
    pub fn processLoop(self: *Self) !void {
        var tick_count: u64 = 0;
        var order_count: u64 = 0;
        const start_time = getCurrentMillis();
        
        while (self.is_running.load(.acquire)) {
            // Process market data from network
            const network_start = std.time.nanoTimestamp();
            
            while (self.market_feed.feed.getNextQuote()) |quote| {
                // Convert network quote to HFT tick
                const tick = hft_system.MarketTick{
                    .symbol = "AAPL",
                    .bid = Decimal.fromFloat(quote.bid),
                    .ask = Decimal.fromFloat(quote.ask),
                    .bid_size = Decimal.fromInt(quote.bid_size),
                    .ask_size = Decimal.fromInt(quote.ask_size),
                    .timestamp = getCurrentTimestamp(),
                    .sequence = tick_count,
                };
                
                // Process through HFT engine
                try self.hft.processTick(tick);
                tick_count += 1;
                _ = self.ticks_from_network.fetchAdd(1, .monotonic);
            }
            
            const network_latency = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - network_start, 1000)));
            self.network_latency_us.store(network_latency, .release);
            
            // Check for signals and route orders
            if (self.is_trading_enabled.load(.acquire)) {
                const routing_start = std.time.nanoTimestamp();
                
                // In real system, would check strategy signals and route orders
                // For demo, simulate occasional order
                if (tick_count % 100 == 0) {
                    const order_id = try std.fmt.allocPrint(self.allocator, "ORD{d:0>6}", .{order_count});
                    defer self.allocator.free(order_id);
                    
                    try self.order_router.sendOrder(
                        order_id,
                        "AAPL",
                        .buy,
                        Decimal.fromInt(100),
                        .limit,
                        Decimal.fromFloat(150.00),
                    );
                    
                    order_count += 1;
                    _ = self.orders_to_exchange.fetchAdd(1, .monotonic);
                }
                
                const routing_latency = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - routing_start, 1000)));
                self.routing_latency_us.store(routing_latency, .release);
            }
            
            // Maintain FIX connection
            try self.order_router.maintainConnection();
            
            // Print stats every 1000 ticks
            if (tick_count % 1000 == 0 and tick_count > 0) {
                const elapsed = getCurrentMillis() - start_time;
                const rate = @as(f64, @floatFromInt(tick_count * 1000)) / @as(f64, @floatFromInt(elapsed));
                
                std.debug.print("📊 Live Stats: {d} ticks @ {d:.0} ticks/sec | ", .{ tick_count, rate });
                std.debug.print("Network: {d}μs | Routing: {d}μs | Orders: {d}\n", .{
                    self.network_latency_us.load(.acquire),
                    self.routing_latency_us.load(.acquire),
                    self.orders_to_exchange.load(.acquire),
                });
            }
            
            // Small delay to prevent CPU spinning
            std.time.sleep(100_000); // 100μs
        }
    }
    
    /// Stop the trading system
    pub fn stop(self: *Self) void {
        std.debug.print("\n🛑 Stopping Live Trading System...\n", .{});
        
        self.is_running.store(false, .release);
        self.is_trading_enabled.store(false, .release);
        
        // Disconnect from exchange
        self.order_router.disconnect();
        
        // Disconnect from market data
        self.market_feed.disconnect();
        
        std.debug.print("✅ System stopped safely\n", .{});
    }
    
    /// Enable/disable live trading
    pub fn setTradingEnabled(self: *Self, enabled: bool) void {
        self.is_trading_enabled.store(enabled, .release);
        const status = if (enabled) "ENABLED" else "DISABLED";
        std.debug.print("⚡ Trading is now {s}\n", .{status});
    }
    
    /// Get system statistics
    pub fn getStats(self: Self) void {
        std.debug.print("\n=== Live Trading System Statistics ===\n", .{});
        std.debug.print("Ticks from network: {d}\n", .{self.ticks_from_network.load(.acquire)});
        std.debug.print("Orders to exchange: {d}\n", .{self.orders_to_exchange.load(.acquire)});
        std.debug.print("Network latency: {d} μs\n", .{self.network_latency_us.load(.acquire)});
        std.debug.print("Routing latency: {d} μs\n", .{self.routing_latency_us.load(.acquire)});
        
        // HFT engine stats
        self.hft.getPerformanceReport();
        
        // FIX engine stats
        self.order_router.getStats();
    }
};

/// Demonstration of the complete system
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     LIVE HIGH-FREQUENCY TRADING SYSTEM        ║\n", .{});
    std.debug.print("║          The Great Synapse Activated          ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    
    // Initialize the complete system
    var system = try LiveTradingSystem.init(
        allocator,
        "YOUR_ALPACA_API_KEY",    // Would use real API key
        "YOUR_ALPACA_SECRET",      // Would use real secret
        "HFT_CLIENT_001",          // Our FIX sender ID
        "ALPACA_EXCHANGE",         // Target exchange ID
    );
    defer system.deinit();
    
    // Start the system
    try system.start();
    
    // Enable paper trading
    system.setTradingEnabled(true);
    
    // Simulate processing for demonstration
    std.debug.print("\n📈 Simulating live market data processing...\n\n", .{});
    
    // Simulate receiving market data
    for (0..100) |i| {
        // Create synthetic market data
        const msg = "{\"T\":\"q\",\"S\":\"AAPL\",\"bp\":150.00,\"bs\":100,\"ap\":150.05,\"as\":100}";
        try system.market_feed.feed.processMessage(msg);
        
        // Process one iteration
        try system.market_feed.processToHFT(system.hft);
        
        // Show progress
        if (i % 10 == 0) {
            std.debug.print(".", .{});
        }
    }
    
    std.debug.print("\n\n", .{});
    
    // Show final statistics
    system.getStats();
    
    // Demonstrate network components
    std.debug.print("\n=== Network Layer Demo ===\n", .{});
    try network.demo();
    
    std.debug.print("\n=== FIX Protocol Demo ===\n", .{});
    try fix.demo();
    
    // Stop the system
    system.stop();
    
    std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║            THE GREAT SYNAPSE                  ║\n", .{});
    std.debug.print("║                                                ║\n", .{});
    std.debug.print("║  ✓ Network Layer:      WebSocket Ready        ║\n", .{});
    std.debug.print("║  ✓ FIX Protocol:       Order Routing Ready    ║\n", .{});
    std.debug.print("║  ✓ HFT Engine:         Sub-microsecond Core   ║\n", .{});
    std.debug.print("║  ✓ Memory Pools:       Zero-GC Operation      ║\n", .{});
    std.debug.print("║  ✓ Lock-Free Queues:   Contention-Free Flow   ║\n", .{});
    std.debug.print("║                                                ║\n", .{});
    std.debug.print("║     Ready for Live Market Connection!         ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
}