const std = @import("std");

pub const TradingConfig = struct {
    api_credentials: ApiCredentials,
    trading_params: TradingParams,
    strategy_params: StrategyParams,
    risk_management: RiskManagement,
    operational_settings: OperationalSettings,
    symbols: []const []const u8,

    pub const ApiCredentials = struct {
        api_key: []const u8 = "",
        api_secret: []const u8 = "",
        paper_trading: bool = true,
    };

    pub const TradingParams = struct {
        max_order_rate: u32 = 10000,
        max_message_rate: u32 = 100000,
        latency_threshold_us: u32 = 100,
        tick_buffer_size: u32 = 10000,
        enable_logging: bool = true,
        enable_live_trading: bool = false,
    };

    pub const StrategyParams = struct {
        max_position: i64 = 1000,
        max_spread: f64 = 0.50,
        min_edge: f64 = 0.05,
        tick_window: u32 = 100,
        min_profit_threshold: f64 = 0.001,
        position_sizing_pct: f64 = 0.1,
    };

    pub const RiskManagement = struct {
        stop_loss_percentage: f64 = 0.02,
        max_position_value: f64 = 50000,
        max_daily_trades: u32 = 100,
        max_orders_per_minute: u32 = 60,
        min_order_size: u32 = 1,
        max_order_size: u32 = 100,
        enable_short_selling: bool = false,
        use_market_orders: bool = false,
    };

    pub const OperationalSettings = struct {
        enable_pre_market: bool = false,
        enable_after_hours: bool = false,
        risk_check_interval_ms: u32 = 1000,
        order_timeout_ms: u32 = 30000,
        run_duration_seconds: ?u32 = null,
        startup_mode: StartupMode = .live_trading,
    };

    pub const StartupMode = enum {
        live_trading,
        simulation,
        monitor_only,
    };
};

pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config: TradingConfig,
    config_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) ConfigManager {
        return .{
            .allocator = allocator,
            .config = TradingConfig{
                .api_credentials = .{},
                .trading_params = .{},
                .strategy_params = .{},
                .risk_management = .{},
                .operational_settings = .{},
                .symbols = &[_][]const u8{},
            },
            .config_path = null,
        };
    }

    pub fn loadFromFile(self: *ConfigManager, path: []const u8) !void {
        // Read file contents using posix APIs
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.c.close(fd);

        // Read file in chunks
        var contents_list: std.ArrayListUnmanaged(u8) = .empty;
        defer contents_list.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            try contents_list.appendSlice(self.allocator, buf[0..@intCast(n)]);
            if (contents_list.items.len > 10 * 1024 * 1024) return error.FileTooLarge;
        }

        const contents = contents_list.items;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, contents, .{});
        defer parsed.deinit();

        const root = parsed.value;

        if (root.object.get("api_key")) |key| {
            self.config.api_credentials.api_key = try self.allocator.dupe(u8, key.string);
        }

        if (root.object.get("api_secret")) |secret| {
            self.config.api_credentials.api_secret = try self.allocator.dupe(u8, secret.string);
        }

        if (root.object.get("paper_trading")) |paper| {
            self.config.api_credentials.paper_trading = paper.bool;
        }

        if (root.object.get("max_order_rate")) |val| {
            self.config.trading_params.max_order_rate = @intCast(val.integer);
        }

        if (root.object.get("max_message_rate")) |val| {
            self.config.trading_params.max_message_rate = @intCast(val.integer);
        }

        if (root.object.get("latency_threshold_us")) |val| {
            self.config.trading_params.latency_threshold_us = @intCast(val.integer);
        }

        if (root.object.get("tick_buffer_size")) |val| {
            self.config.trading_params.tick_buffer_size = @intCast(val.integer);
        }

        if (root.object.get("enable_logging")) |val| {
            self.config.trading_params.enable_logging = val.bool;
        }

        if (root.object.get("enable_live_trading")) |val| {
            self.config.trading_params.enable_live_trading = val.bool;
        }

        if (root.object.get("max_position")) |val| {
            self.config.strategy_params.max_position = val.integer;
        }

        if (root.object.get("max_spread")) |val| {
            self.config.strategy_params.max_spread = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.strategy_params.max_spread,
            };
        }

        if (root.object.get("min_edge")) |val| {
            self.config.strategy_params.min_edge = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.strategy_params.min_edge,
            };
        }

        if (root.object.get("min_profit_threshold")) |val| {
            self.config.strategy_params.min_profit_threshold = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.strategy_params.min_profit_threshold,
            };
        }

        if (root.object.get("tick_window")) |val| {
            self.config.strategy_params.tick_window = @intCast(val.integer);
        }

        if (root.object.get("position_sizing_pct")) |val| {
            self.config.strategy_params.position_sizing_pct = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.strategy_params.position_sizing_pct,
            };
        }

        if (root.object.get("stop_loss_percentage")) |val| {
            self.config.risk_management.stop_loss_percentage = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.risk_management.stop_loss_percentage,
            };
        }

        if (root.object.get("max_position_value")) |val| {
            self.config.risk_management.max_position_value = switch (val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => self.config.risk_management.max_position_value,
            };
        }

        if (root.object.get("max_daily_trades")) |val| {
            self.config.risk_management.max_daily_trades = @intCast(val.integer);
        }

        if (root.object.get("max_orders_per_minute")) |val| {
            self.config.risk_management.max_orders_per_minute = @intCast(val.integer);
        }

        if (root.object.get("min_order_size")) |val| {
            self.config.risk_management.min_order_size = @intCast(val.integer);
        }

        if (root.object.get("max_order_size")) |val| {
            self.config.risk_management.max_order_size = @intCast(val.integer);
        }

        if (root.object.get("enable_short_selling")) |val| {
            self.config.risk_management.enable_short_selling = val.bool;
        }

        if (root.object.get("use_market_orders")) |val| {
            self.config.risk_management.use_market_orders = val.bool;
        }

        if (root.object.get("enable_pre_market")) |val| {
            self.config.operational_settings.enable_pre_market = val.bool;
        }

        if (root.object.get("enable_after_hours")) |val| {
            self.config.operational_settings.enable_after_hours = val.bool;
        }

        if (root.object.get("risk_check_interval_ms")) |val| {
            self.config.operational_settings.risk_check_interval_ms = @intCast(val.integer);
        }

        if (root.object.get("order_timeout_ms")) |val| {
            self.config.operational_settings.order_timeout_ms = @intCast(val.integer);
        }

        if (root.object.get("run_duration_seconds")) |val| {
            self.config.operational_settings.run_duration_seconds = switch (val) {
                .integer => |i| @intCast(i),
                .null => null,
                else => self.config.operational_settings.run_duration_seconds,
            };
        }

        if (root.object.get("startup_mode")) |val| {
            if (std.mem.eql(u8, val.string, "live_trading")) {
                self.config.operational_settings.startup_mode = .live_trading;
            } else if (std.mem.eql(u8, val.string, "simulation")) {
                self.config.operational_settings.startup_mode = .simulation;
            } else {
                self.config.operational_settings.startup_mode = .monitor_only;
            }
        }

        if (root.object.get("symbols")) |symbols_val| {
            const symbols_array = symbols_val.array;
            var symbols = try self.allocator.alloc([]const u8, symbols_array.items.len);
            for (symbols_array.items, 0..) |symbol, i| {
                symbols[i] = try self.allocator.dupe(u8, symbol.string);
            }
            self.config.symbols = symbols;
        }

        self.config_path = try self.allocator.dupe(u8, path);
    }

    pub fn loadFromEnvironment(self: *ConfigManager) !void {
        if (std.c.getenv("ALPACA_API_KEY")) |key_ptr| {
            const key = std.mem.span(key_ptr);
            self.config.api_credentials.api_key = try self.allocator.dupe(u8, key);
        }

        if (std.c.getenv("ALPACA_API_SECRET")) |secret_ptr| {
            const secret = std.mem.span(secret_ptr);
            self.config.api_credentials.api_secret = try self.allocator.dupe(u8, secret);
        }

        if (std.c.getenv("ALPACA_PAPER_TRADING")) |paper_ptr| {
            const paper = std.mem.span(paper_ptr);
            self.config.api_credentials.paper_trading = std.mem.eql(u8, paper, "true");
        }
    }

    pub fn validate(self: *const ConfigManager) !void {
        if (self.config.api_credentials.api_key.len == 0) {
            std.debug.print("❌ Error: API key is required\n", .{});
            return error.MissingApiKey;
        }

        if (self.config.api_credentials.api_secret.len == 0) {
            std.debug.print("❌ Error: API secret is required\n", .{});
            return error.MissingApiSecret;
        }

        if (self.config.symbols.len == 0) {
            std.debug.print("❌ Error: At least one trading symbol is required\n", .{});
            return error.NoSymbols;
        }

        if (self.config.risk_management.max_position_value <= 0) {
            std.debug.print("❌ Error: Invalid max position value\n", .{});
            return error.InvalidRiskParameters;
        }

        if (self.config.strategy_params.max_position <= 0) {
            std.debug.print("❌ Error: Invalid max position\n", .{});
            return error.InvalidStrategyParameters;
        }
    }

    pub fn printConfiguration(self: *const ConfigManager) void {
        std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║            TRADING CONFIGURATION               ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════════╝\n", .{});

        if (self.config_path) |path| {
            std.debug.print("📁 Config File: {s}\n", .{path});
        }

        std.debug.print("\n🔑 API Configuration:\n", .{});
        std.debug.print("  • API Key: {s}...\n", .{self.config.api_credentials.api_key[0..@min(10, self.config.api_credentials.api_key.len)]});
        std.debug.print("  • Mode: {s}\n", .{if (self.config.api_credentials.paper_trading) "Paper Trading" else "Live Trading"});

        std.debug.print("\n📊 Trading Symbols ({} total):\n", .{self.config.symbols.len});
        for (self.config.symbols) |symbol| {
            std.debug.print("  • {s}\n", .{symbol});
        }

        std.debug.print("\n⚙️ Strategy Parameters:\n", .{});
        std.debug.print("  • Max Position: {}\n", .{self.config.strategy_params.max_position});
        std.debug.print("  • Max Spread: {d:.2}\n", .{self.config.strategy_params.max_spread});
        std.debug.print("  • Min Edge: {d:.3}\n", .{self.config.strategy_params.min_edge});
        std.debug.print("  • Min Profit Threshold: {d:.3}\n", .{self.config.strategy_params.min_profit_threshold});

        std.debug.print("\n🛡️ Risk Management:\n", .{});
        std.debug.print("  • Stop Loss: {d:.1}%\n", .{self.config.risk_management.stop_loss_percentage * 100});
        std.debug.print("  • Max Position Value: ${d:.0}\n", .{self.config.risk_management.max_position_value});
        std.debug.print("  • Max Daily Trades: {}\n", .{self.config.risk_management.max_daily_trades});
        std.debug.print("  • Short Selling: {s}\n", .{if (self.config.risk_management.enable_short_selling) "Enabled" else "Disabled"});

        std.debug.print("\n⏰ Operational Settings:\n", .{});
        std.debug.print("  • Pre-Market: {s}\n", .{if (self.config.operational_settings.enable_pre_market) "Enabled" else "Disabled"});
        std.debug.print("  • After-Hours: {s}\n", .{if (self.config.operational_settings.enable_after_hours) "Enabled" else "Disabled"});
        std.debug.print("  • Startup Mode: {s}\n", .{@tagName(self.config.operational_settings.startup_mode)});
        if (self.config.operational_settings.run_duration_seconds) |duration| {
            std.debug.print("  • Run Duration: {} seconds\n", .{duration});
        } else {
            std.debug.print("  • Run Duration: Indefinite\n", .{});
        }

        std.debug.print("────────────────────────────────────────────\n", .{});
    }

    pub fn deinit(self: *ConfigManager) void {
        if (self.config_path) |path| {
            self.allocator.free(path);
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, raw_args: std.process.Args) !?[]const u8 {
    var args = std.process.Args.Iterator.init(raw_args);

    // Skip program name
    _ = args.next();

    var config_file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (args.next()) |file| {
                config_file = try allocator.dupe(u8, file);
            } else {
                std.debug.print("❌ Error: --config requires a file path\n", .{});
                return error.MissingConfigPath;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        }
    }

    return config_file;
}

pub fn printHelp() void {
    std.debug.print("\n🚀 HFT Trading Engine - Configuration-Driven Architecture\n", .{});
    std.debug.print("\nUsage: ./hft_alpaca_real [OPTIONS]\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -c, --config <file>  Load configuration from JSON file\n", .{});
    std.debug.print("  -h, --help          Show this help message\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("  ./hft_alpaca_real --config config/european_premarket.json\n", .{});
    std.debug.print("  ./hft_alpaca_real --config config/us_tech_regular.json\n", .{});
    std.debug.print("  ./hft_alpaca_real --config config/crypto_24h.json\n", .{});
    std.debug.print("\nEnvironment Variables:\n", .{});
    std.debug.print("  ALPACA_API_KEY       Your Alpaca API key\n", .{});
    std.debug.print("  ALPACA_API_SECRET    Your Alpaca API secret\n", .{});
    std.debug.print("  ALPACA_PAPER_TRADING Set to 'true' for paper trading\n", .{});
    std.debug.print("\n", .{});
}