const std = @import("std");
const linux = std.os.linux;
const Decimal = @import("decimal.zig").Decimal;
const hft_system = @import("hft_system.zig");
const alpaca_ws = @import("alpaca_websocket_real.zig");
const order_book = @import("order_book_v2.zig");
const pool_lib = @import("simple_pool.zig");
const StrategyConfig = @import("strategy_config.zig").StrategyConfig;
const config_manager = @import("config_manager.zig");
const RunawayProtection = @import("runaway_protection.zig").RunawayProtection;

/// Real HFT System with Alpaca Paper Trading Integration
pub const RealHFTSystem = struct {
    const Self = @This();
    
    // Core components
    hft: hft_system.HFTSystem,
    alpaca_client: alpaca_ws.AlpacaWebSocketReal,
    bridge: alpaca_ws.AlpacaHFTBridge,
    allocator: std.mem.Allocator,
    
    // Configuration
    config: SystemConfig,
    
    // Control
    is_running: std.atomic.Value(bool),
    is_live_trading: std.atomic.Value(bool),
    
    pub const SystemConfig = struct {
        // Alpaca credentials
        api_key: []const u8,
        api_secret: []const u8,
        paper_trading: bool = true,

        // Trading symbols
        symbols: []const []const u8,

        // HFT parameters
        max_order_rate: u32 = 10000,
        max_message_rate: u32 = 100000,
        latency_threshold_us: u32 = 100,
        tick_buffer_size: u32 = 10000,
        enable_logging: bool = true,

        // Strategy parameters
        max_position: i64 = 1000,
        max_spread: f64 = 0.50,
        min_edge: f64 = 0.05,
        tick_window: u32 = 100,

        // Risk management parameters
        max_daily_trades: u32 = 1000,
        max_position_value: f64 = 100000.0,
        max_orders_per_minute: u32 = 60,
        stop_loss_percentage: f64 = 0.02,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: SystemConfig) !Self {
        // Validate configuration
        if (config.api_key.len == 0 or config.api_secret.len == 0) {
            std.debug.print("❌ Error: API key and secret are required\n", .{});
            return error.InvalidConfiguration;
        }
        
        // Initialize HFT system with strategy config
        const strategy_config = StrategyConfig{
            .max_position = @floatFromInt(config.max_position),
            .max_spread = config.max_spread,
            .min_edge = config.min_edge,
            .tick_window = config.tick_window,
        };

        const hft_config = hft_system.HFTSystem.SystemConfig{
            .max_order_rate = config.max_order_rate,
            .max_message_rate = config.max_message_rate,
            .latency_threshold_us = config.latency_threshold_us,
            .tick_buffer_size = config.tick_buffer_size,
            .enable_logging = config.enable_logging,
            .strategy_config = strategy_config,
        };
        
        var hft = try hft_system.HFTSystem.init(allocator, hft_config, null);

        // Initialize runaway protection from config
        const protection_limits = RunawayProtection.ProtectionLimits{
            .max_daily_trades = config.max_daily_trades,
            .max_daily_loss = Decimal.fromFloat(config.max_position_value * config.stop_loss_percentage),
            .max_consecutive_losses = 5,
            .max_position_value = Decimal.fromFloat(config.max_position_value),
            .max_order_rate_per_minute = config.max_orders_per_minute,
            .emergency_stop_loss_pct = config.stop_loss_percentage,
        };
        hft.runaway_protection = RunawayProtection.init(allocator, protection_limits);
        std.debug.print("🛡️ Runaway protection initialized:\n", .{});
        std.debug.print("  • Max daily trades: {}\n", .{protection_limits.max_daily_trades});
        std.debug.print("  • Max daily loss: ${d:.0}\n", .{protection_limits.max_daily_loss.toFloat()});
        std.debug.print("  • Max position value: ${d:.0}\n", .{protection_limits.max_position_value.toFloat()});
        std.debug.print("  • Max orders/minute: {}\n", .{protection_limits.max_order_rate_per_minute});

        // Add trading strategy
        const strategy_params = hft_system.Strategy.StrategyParams{
            .max_position = Decimal.fromInt(config.max_position),
            .max_spread = Decimal.fromFloat(config.max_spread),
            .min_edge = Decimal.fromFloat(config.min_edge),
            .tick_window = config.tick_window,
        };
        
        try hft.addStrategy(hft_system.Strategy.init("RealAlpacaStrategy", strategy_params));
        
        // Initialize Alpaca WebSocket client
        var alpaca_client = try alpaca_ws.AlpacaWebSocketReal.init(
            allocator,
            config.api_key,
            config.api_secret,
            config.paper_trading,
        );

        // Initialize bridge
        const bridge = alpaca_ws.AlpacaHFTBridge.init(allocator, &alpaca_client, &hft);
        
        return .{
            .hft = hft,
            .alpaca_client = alpaca_client,
            .bridge = bridge,
            .allocator = allocator,
            .config = config,
            .is_running = std.atomic.Value(bool).init(false),
            .is_live_trading = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.alpaca_client.deinit();
        self.hft.deinit();
    }
    
    /// Start the real HFT system
    pub fn start(self: *Self) !void {
        std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║      REAL HFT SYSTEM WITH ALPACA PAPER        ║\n", .{});
        std.debug.print("║             TRADING INTEGRATION               ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════════╝\n\n", .{});
        
        std.debug.print("🚀 Starting Real HFT System...\n", .{});
        std.debug.print("📊 Mode: {s}\n", .{if (self.config.paper_trading) "Paper Trading" else "Live Trading"});
        std.debug.print("🔑 API Key: {s}...\n", .{self.config.api_key[0..@min(10, self.config.api_key.len)]});
        
        // Connect to Alpaca
        std.debug.print("\n📡 Connecting to Alpaca WebSocket...\n", .{});
        try self.alpaca_client.connect();

        // Wait for authentication to complete with proper state checking
        std.debug.print("⏳ Waiting for authentication...\n", .{});
        const max_wait_ms: u64 = 10000; // 10 seconds max wait
        const check_interval_ms: u64 = 100;
        var waited_ms: u64 = 0;

        while (!self.alpaca_client.authenticated.load(.acquire)) {
            if (waited_ms >= max_wait_ms) {
                std.debug.print("❌ Authentication timeout after {}ms\n", .{max_wait_ms});
                return error.AuthenticationTimeout;
            }
            var ts_wait = linux.timespec{ .sec = 0, .nsec = @intCast(check_interval_ms * std.time.ns_per_ms) };
            _ = linux.nanosleep(&ts_wait, null);
            waited_ms += check_interval_ms;
        }

        std.debug.print("✅ Authenticated successfully in {}ms\n", .{waited_ms});

        // Subscribe to symbols
        std.debug.print("📊 Subscribing to symbols: ", .{});
        for (self.config.symbols) |symbol| {
            std.debug.print("{s} ", .{symbol});
        }
        std.debug.print("\n", .{});

        try self.alpaca_client.subscribe(self.config.symbols);
        
        // Start the bridge
        try self.bridge.start();
        
        self.is_running.store(true, .release);
        std.debug.print("\n✅ Real HFT System is now LIVE!\n\n", .{});
    }
    
    /// Enable live trading (vs. just data monitoring)
    pub fn enableLiveTrading(self: *Self) void {
        self.is_live_trading.store(true, .release);
        std.debug.print("⚡ LIVE TRADING ENABLED - System will execute real orders!\n", .{});
    }
    
    /// Disable live trading
    pub fn disableLiveTrading(self: *Self) void {
        self.is_live_trading.store(false, .release);
        std.debug.print("🛡️ Live trading disabled - System in monitor-only mode\n", .{});
    }
    
    /// Run the system for a specified duration or until stopped
    pub fn run(self: *Self, duration_seconds: ?u32) !void {
        if (!self.is_running.load(.acquire)) {
            std.debug.print("❌ System is not started. Call start() first.\n", .{});
            return;
        }

        const start_time = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :blk ts.sec; };
        const end_time = if (duration_seconds) |duration|
            start_time + duration
        else
            std.math.maxInt(i64);

        std.debug.print("🔄 Running system", .{});
        if (duration_seconds) |duration| {
            std.debug.print(" for {d} seconds", .{duration});
        }
        std.debug.print("...\n", .{});

        var last_stats_time = start_time;

        while (self.is_running.load(.acquire) and (ts_blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :ts_blk ts.sec; }) < end_time) {
            // Print stats every 10 seconds
            const current_time = ct_blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :ct_blk ts.sec; };
            if (current_time - last_stats_time >= 10) {
                self.printLiveStats();
                last_stats_time = current_time;
            }
            
            // Small sleep to prevent CPU spinning
            var ts_sleep = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts_sleep, null); // 100ms
        }
        
        std.debug.print("🏁 System run completed\n", .{});
    }
    
    /// Stop the system
    pub fn stop(self: *Self) void {
        if (!self.is_running.load(.acquire)) return;
        
        std.debug.print("\n🛑 Stopping Real HFT System...\n", .{});
        
        self.is_running.store(false, .release);
        self.is_live_trading.store(false, .release);
        
        // Stop components in reverse order
        self.bridge.stop();
        self.alpaca_client.disconnect();
        
        std.debug.print("✅ Real HFT System stopped safely\n", .{});
    }
    
    /// Print live system statistics
    pub fn printLiveStats(self: *Self) void {
        const alpaca_stats = self.alpaca_client.getStats();
        
        std.debug.print("\n📊 === LIVE SYSTEM STATISTICS ===\n", .{});
        std.debug.print("🔗 Connection Active: {}\n", .{alpaca_stats.connected});
        std.debug.print("📨 Messages Received: {d}\n", .{alpaca_stats.messages_received});
        std.debug.print("📈 Quotes Received: {d}\n", .{alpaca_stats.quotes_received});
        std.debug.print("🔄 Trades Received: {d}\n", .{alpaca_stats.trades_received});
        std.debug.print("🎉 Bars Received: {d}\n", .{alpaca_stats.bars_received});
        std.debug.print("❌ Errors: {d}\n", .{alpaca_stats.errors_received});
        std.debug.print("⚡ Live Trading: {s}\n", .{if (self.is_live_trading.load(.acquire)) "ENABLED" else "DISABLED"});
        
        // HFT engine stats
        std.debug.print("\n🚀 === HFT ENGINE STATISTICS ===\n", .{});
        self.hft.getPerformanceReport();
        
        std.debug.print("────────────────────────────────────────\n", .{});
    }
    
    /// Get comprehensive system report
    pub fn getSystemReport(self: Self) SystemReport {
        const alpaca_stats = self.alpaca_client.getStats();
        
        return SystemReport{
            .is_running = self.is_running.load(.acquire),
            .is_live_trading = self.is_live_trading.load(.acquire),
            .is_connected = alpaca_stats.connected,
            .messages_received = alpaca_stats.messages_received,
            .quotes_received = alpaca_stats.quotes_received,
            .trades_received = alpaca_stats.trades_received,
            .orders_received = 0, // Not tracked in new implementation
            .reconnect_count = 0, // Not tracked in new implementation
            .hft_ticks_processed = self.hft.metrics.ticks_processed,
            .hft_signals_generated = self.hft.metrics.signals_generated,
            .hft_orders_sent = self.hft.metrics.orders_sent,
            .hft_trades_executed = self.hft.metrics.trades_executed,
        };
    }
    
    pub const SystemReport = struct {
        is_running: bool,
        is_live_trading: bool,
        is_connected: bool,
        messages_received: u64,
        quotes_received: u64,
        trades_received: u64,
        orders_received: u64,
        reconnect_count: u32,
        hft_ticks_processed: u64,
        hft_signals_generated: u64,
        hft_orders_sent: u64,
        hft_trades_executed: u64,
    };
};

/// Main entry point for the real HFT system
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     ALPACA HFT SYSTEM - MISSION CONTROL       ║\n", .{});
    std.debug.print("║        CONFIGURATION-DRIVEN ARCHITECTURE      ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});

    // Parse command-line arguments
    const config_file = try config_manager.parseArgs(allocator, init.minimal.args);
    if (config_file == null) {
        // Help was printed or error occurred
        return;
    }
    defer if (config_file) |file| allocator.free(file);

    // Initialize configuration manager
    var cfg_manager = config_manager.ConfigManager.init(allocator);
    defer cfg_manager.deinit();

    // Load configuration from file if provided
    if (config_file) |file| {
        std.debug.print("\n📁 Loading configuration from: {s}\n", .{file});
        cfg_manager.loadFromFile(file) catch |err| {
            std.debug.print("❌ Failed to load config file: {any}\n", .{err});
            std.debug.print("💡 Check that the file exists and is valid JSON\n", .{});
            return;
        };
    } else {
        std.debug.print("❌ No configuration file specified\n", .{});
        std.debug.print("💡 Use --config <file> to specify a configuration\n", .{});
        std.debug.print("\nExample configurations:\n", .{});
        std.debug.print("  ./hft_alpaca_real --config config/european_premarket.json\n", .{});
        std.debug.print("  ./hft_alpaca_real --config config/us_tech_regular.json\n", .{});
        return;
    }

    // Load API credentials from environment (overrides config file)
    try cfg_manager.loadFromEnvironment();

    // Validate configuration
    cfg_manager.validate() catch |err| {
        std.debug.print("\n❌ Configuration validation failed: {any}\n", .{err});
        return;
    };

    // Print the loaded configuration
    cfg_manager.printConfiguration();

    // Convert to legacy SystemConfig format for compatibility
    const config = RealHFTSystem.SystemConfig{
        .api_key = cfg_manager.config.api_credentials.api_key,
        .api_secret = cfg_manager.config.api_credentials.api_secret,
        .paper_trading = cfg_manager.config.api_credentials.paper_trading,
        .symbols = cfg_manager.config.symbols,
        .max_order_rate = cfg_manager.config.trading_params.max_order_rate,
        .max_message_rate = cfg_manager.config.trading_params.max_message_rate,
        .latency_threshold_us = cfg_manager.config.trading_params.latency_threshold_us,
        .tick_buffer_size = cfg_manager.config.trading_params.tick_buffer_size,
        .enable_logging = cfg_manager.config.trading_params.enable_logging,
        .max_position = cfg_manager.config.strategy_params.max_position,
        .max_spread = cfg_manager.config.strategy_params.max_spread,
        .min_edge = cfg_manager.config.strategy_params.min_edge,
        .tick_window = cfg_manager.config.strategy_params.tick_window,
        .max_daily_trades = cfg_manager.config.risk_management.max_daily_trades,
        .max_position_value = cfg_manager.config.risk_management.max_position_value,
        .max_orders_per_minute = cfg_manager.config.risk_management.max_orders_per_minute,
        .stop_loss_percentage = cfg_manager.config.risk_management.stop_loss_percentage,
    };

    // Initialize the system
    var system = RealHFTSystem.init(allocator, config) catch |err| {
        std.debug.print("❌ Failed to initialize system: {any}\n", .{err});
        return;
    };
    defer system.deinit();

    // Start the system
    try system.start();

    // Set trading mode based on configuration
    switch (cfg_manager.config.operational_settings.startup_mode) {
        .live_trading => {
            std.debug.print("\n⚡ LIVE TRADING ACTIVE - Executing real paper trades\n", .{});
            system.enableLiveTrading();
        },
        .simulation => {
            std.debug.print("\n🎮 SIMULATION mode - Local order simulation\n", .{});
        },
        .monitor_only => {
            std.debug.print("\n👁️ MONITOR ONLY - No order execution\n", .{});
        },
    }

    // Check market hours settings
    if (cfg_manager.config.operational_settings.enable_pre_market) {
        std.debug.print("⏰ Pre-market trading: ENABLED\n", .{});
    }
    if (cfg_manager.config.operational_settings.enable_after_hours) {
        std.debug.print("🌙 After-hours trading: ENABLED\n", .{});
    }

    // Run the system
    std.debug.print("\n🎯 Starting system operation...\n", .{});
    const duration = cfg_manager.config.operational_settings.run_duration_seconds;
    try system.run(duration);

    // Show final report
    std.debug.print("\n📋 === FINAL SYSTEM REPORT ===\n", .{});
    const report = system.getSystemReport();
    std.debug.print("✅ System ran successfully\n", .{});
    std.debug.print("📊 Total messages processed: {d}\n", .{report.messages_received});
    std.debug.print("📈 Quotes processed: {d}\n", .{report.quotes_received});
    std.debug.print("🚀 HFT ticks processed: {d}\n", .{report.hft_ticks_processed});
    std.debug.print("⚡ Signals generated: {d}\n", .{report.hft_signals_generated});

    // Final summary
    std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           MISSION CONTROL SUMMARY              ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Configuration: {s:<31} ║\n", .{config_file.?});
    std.debug.print("║ Symbols Traded: {d:<30} ║\n", .{cfg_manager.config.symbols.len});
    std.debug.print("║ Mode: {s:<40} ║\n", .{@tagName(cfg_manager.config.operational_settings.startup_mode)});
    std.debug.print("║                                                ║\n", .{});
    std.debug.print("║        🚀 MISSION COMPLETE 🚀                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
}