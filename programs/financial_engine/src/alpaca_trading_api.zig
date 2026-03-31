const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const HttpClient = @import("http_client.zig").HttpClient;
const http = std.http;

/// Alpaca Trading API for real order placement
pub const AlpacaTradingAPI = struct {
    const Self = @This();
    
    // Constants
    const ALPACA_API_URL = "https://api.alpaca.markets";
    const ALPACA_PAPER_API_URL = "https://paper-api.alpaca.markets";
    const MAX_RESPONSE_SIZE = 1024 * 1024; // 1MB max response
    
    // Core configuration
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    base_url: []const u8,
    paper_trading: bool,
    
    // HTTP client
    http_client: HttpClient,
    
    // Order tracking
    orders_placed: std.atomic.Value(u64),
    orders_filled: std.atomic.Value(u64),
    orders_canceled: std.atomic.Value(u64),
    last_order_id: std.atomic.Value(u64),
    
    pub const OrderSide = enum {
        buy,
        sell,
        
        pub fn toString(self: OrderSide) []const u8 {
            return switch (self) {
                .buy => "buy",
                .sell => "sell",
            };
        }
    };
    
    pub const OrderType = enum {
        market,
        limit,
        stop,
        stop_limit,
        
        pub fn toString(self: OrderType) []const u8 {
            return switch (self) {
                .market => "market",
                .limit => "limit",
                .stop => "stop",
                .stop_limit => "stop_limit",
            };
        }
    };
    
    pub const TimeInForce = enum {
        day,
        gtc, // Good Till Canceled
        ioc, // Immediate Or Cancel
        fok, // Fill Or Kill
        
        pub fn toString(self: TimeInForce) []const u8 {
            return switch (self) {
                .day => "day",
                .gtc => "gtc",
                .ioc => "ioc",
                .fok => "fok",
            };
        }
    };
    
    pub const OrderRequest = struct {
        symbol: []const u8,
        qty: u32,
        side: OrderSide,
        type: OrderType,
        time_in_force: TimeInForce = .day,
        limit_price: ?f64 = null,
        stop_price: ?f64 = null,
        client_order_id: ?[]const u8 = null,
        extended_hours: bool = false,
    };
    
    pub const OrderResponse = struct {
        id: []const u8,
        client_order_id: []const u8,
        created_at: []const u8,
        updated_at: []const u8,
        submitted_at: []const u8,
        asset_id: []const u8,
        symbol: []const u8,
        asset_class: []const u8,
        qty: []const u8,
        filled_qty: []const u8,
        order_type: []const u8,
        side: []const u8,
        time_in_force: []const u8,
        limit_price: ?[]const u8,
        stop_price: ?[]const u8,
        status: []const u8,
        extended_hours: bool,
        
        // Helper methods
        pub fn isActive(self: OrderResponse) bool {
            return std.mem.eql(u8, self.status, "new") or 
                   std.mem.eql(u8, self.status, "partially_filled") or
                   std.mem.eql(u8, self.status, "accepted") or
                   std.mem.eql(u8, self.status, "pending_new") or
                   std.mem.eql(u8, self.status, "accepted_for_bidding");
        }
        
        pub fn isFilled(self: OrderResponse) bool {
            return std.mem.eql(u8, self.status, "filled");
        }
        
        pub fn isCanceled(self: OrderResponse) bool {
            return std.mem.eql(u8, self.status, "canceled") or
                   std.mem.eql(u8, self.status, "expired") or
                   std.mem.eql(u8, self.status, "rejected");
        }
    };
    
    pub const AccountInfo = struct {
        id: []const u8,
        account_number: []const u8,
        status: []const u8,
        currency: []const u8,
        cash: []const u8,
        portfolio_value: []const u8,
        pattern_day_trader: bool,
        trading_blocked: bool,
        transfers_blocked: bool,
        account_blocked: bool,
        created_at: []const u8,
        trade_suspended_by_user: bool,
        multiplier: []const u8,
        buying_power: []const u8,
        long_market_value: []const u8,
        short_market_value: []const u8,
        equity: []const u8,
        last_equity: []const u8,
        initial_margin: []const u8,
        maintenance_margin: []const u8,
        sma: []const u8,
        daytrade_count: u32,
    };
    
    pub const Position = struct {
        asset_id: []const u8,
        symbol: []const u8,
        exchange: []const u8,
        asset_class: []const u8,
        qty: []const u8,
        side: []const u8,
        market_value: []const u8,
        cost_basis: []const u8,
        unrealized_pl: []const u8,
        unrealized_plpc: []const u8,
        unrealized_intraday_pl: []const u8,
        unrealized_intraday_plpc: []const u8,
        current_price: []const u8,
        lastday_price: []const u8,
        change_today: []const u8,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        paper_trading: bool,
    ) Self {
        const base_url = if (paper_trading) ALPACA_PAPER_API_URL else ALPACA_API_URL;
        
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_secret = api_secret,
            .base_url = base_url,
            .paper_trading = paper_trading,
            .http_client = HttpClient.init(allocator),
            .orders_placed = std.atomic.Value(u64).init(0),
            .orders_filled = std.atomic.Value(u64).init(0),
            .orders_canceled = std.atomic.Value(u64).init(0),
            .last_order_id = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }
    
    /// Place a new order
    pub fn placeOrder(self: *Self, order: OrderRequest) !OrderResponse {
        std.debug.print("📤 Placing order: {s} {} {s} @ {s}\n", .{
            order.side.toString(),
            order.qty,
            order.symbol,
            order.type.toString(),
        });
        
        // Generate client order ID if not provided
        const client_id = if (order.client_order_id) |id| id else blk: {
            const order_num = self.last_order_id.fetchAdd(1, .monotonic);
            const ts_sec = ts_blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :ts_blk ts.sec; };
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "HFT_{d}_{d}",
                .{ ts_sec, order_num }
            );
        };
        defer if (order.client_order_id == null) self.allocator.free(client_id);
        
        // Build JSON request body
        var json_body: std.ArrayListUnmanaged(u8) = .empty;
        defer json_body.deinit(self.allocator);
        
        try json_body.appendSlice(self.allocator, "{");
        try json_body.appendSlice(self.allocator, "\"symbol\":\"");
        try json_body.appendSlice(self.allocator, order.symbol);
        try json_body.appendSlice(self.allocator, "\",\"qty\":");
        try json_body.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{order.qty}));
        try json_body.appendSlice(self.allocator, ",\"side\":\"");
        try json_body.appendSlice(self.allocator, order.side.toString());
        try json_body.appendSlice(self.allocator, "\",\"type\":\"");
        try json_body.appendSlice(self.allocator, order.type.toString());
        try json_body.appendSlice(self.allocator, "\",\"time_in_force\":\"");
        try json_body.appendSlice(self.allocator, order.time_in_force.toString());
        try json_body.appendSlice(self.allocator, "\",\"client_order_id\":\"");
        try json_body.appendSlice(self.allocator, client_id);
        try json_body.appendSlice(self.allocator, "\"");
        
        // Add limit price if applicable
        if (order.limit_price) |price| {
            try json_body.appendSlice(self.allocator, ",\"limit_price\":\"");
            const price_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{price});
            defer self.allocator.free(price_str);
            try json_body.appendSlice(self.allocator, price_str);
            try json_body.appendSlice(self.allocator, "\"");
        }
        
        // Add stop price if applicable
        if (order.stop_price) |price| {
            try json_body.appendSlice(self.allocator, ",\"stop_price\":\"");
            const price_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{price});
            defer self.allocator.free(price_str);
            try json_body.appendSlice(self.allocator, price_str);
            try json_body.appendSlice(self.allocator, "\"");
        }
        
        // Add extended hours
        if (order.extended_hours) {
            try json_body.appendSlice(self.allocator, ",\"extended_hours\":true");
        }
        
        try json_body.appendSlice(self.allocator, "}");
        
        // Create request
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/orders", .{self.base_url});
        defer self.allocator.free(url);
        
        // Use our clean HTTP client module
        const headers = [_]http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(url, &headers, json_body.items);
        defer response.deinit();
        
        if (response.status == .created or response.status == .ok) {
            _ = self.orders_placed.fetchAdd(1, .monotonic);
            std.debug.print("✅ Order placed successfully\n", .{});
            
            // Parse response
            return parseOrderResponse(self.allocator, response.body);
        } else {
            std.debug.print("❌ Order placement failed: {}\n", .{response.status});
            std.debug.print("Response: {s}\n", .{response.body});
            return error.OrderPlacementFailed;
        }
    }
    
    /// Cancel an existing order
    pub fn cancelOrder(self: *Self, order_id: []const u8) !void {
        std.debug.print("🛑 Canceling order: {s}\n", .{order_id});
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/orders/{s}", .{ self.base_url, order_id });
        defer self.allocator.free(url);
        
        const headers = [_]http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
        };
        
        var response = try self.http_client.delete(url, &headers);
        defer response.deinit();
        
        if (response.status == .no_content or response.status == .ok) {
            _ = self.orders_canceled.fetchAdd(1, .monotonic);
            std.debug.print("✅ Order canceled successfully\n", .{});
        } else {
            std.debug.print("❌ Order cancellation failed: {}\n", .{response.status});
            return error.OrderCancellationFailed;
        }
    }
    
    /// Get account information
    pub fn getAccount(self: *Self) !AccountInfo {
        std.debug.print("📊 Fetching account information...\n", .{});
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/account", .{self.base_url});
        defer self.allocator.free(url);
        
        const headers = [_]http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
        };
        
        var response = try self.http_client.get(url, &headers);
        defer response.deinit();
        
        if (response.status == .ok) {
            std.debug.print("✅ Account info retrieved\n", .{});
            return parseAccountInfo(self.allocator, response.body);
        } else {
            std.debug.print("❌ Failed to get account info: {any}\n", .{response.status});
            return error.AccountInfoFailed;
        }
    }
    
    /// Get current positions
    pub fn getPositions(self: *Self) ![]Position {
        std.debug.print("📈 Fetching positions...\n", .{});
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/positions", .{self.base_url});
        defer self.allocator.free(url);
        
        const headers = [_]http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
        };
        
        var response = try self.http_client.get(url, &headers);
        defer response.deinit();
        
        if (response.status == .ok) {
            std.debug.print("✅ Positions retrieved\n", .{});
            return parsePositions(self.allocator, response.body);
        } else {
            std.debug.print("❌ Failed to get positions: {any}\n", .{response.status});
            return error.PositionsFailed;
        }
    }
    
    /// Get trading statistics
    pub fn getStats(self: Self) struct {
        orders_placed: u64,
        orders_filled: u64,
        orders_canceled: u64,
        last_order_id: u64,
    } {
        return .{
            .orders_placed = self.orders_placed.load(.acquire),
            .orders_filled = self.orders_filled.load(.acquire),
            .orders_canceled = self.orders_canceled.load(.acquire),
            .last_order_id = self.last_order_id.load(.acquire),
        };
    }
};

// Simplified JSON parsing functions (in production, use a proper JSON library)
fn parseOrderResponse(allocator: std.mem.Allocator, json: []const u8) !AlpacaTradingAPI.OrderResponse {
    const parsed = try std.json.parseFromSlice(
        struct {
            id: []const u8,
            client_order_id: []const u8,
            created_at: []const u8,
            updated_at: ?[]const u8,
            submitted_at: ?[]const u8,
            filled_at: ?[]const u8,
            expired_at: ?[]const u8,
            canceled_at: ?[]const u8,
            asset_id: []const u8,
            symbol: []const u8,
            asset_class: []const u8,
            qty: []const u8,
            filled_qty: []const u8,
            order_type: []const u8,
            side: []const u8,
            time_in_force: []const u8,
            limit_price: ?[]const u8,
            stop_price: ?[]const u8,
            status: []const u8,
            extended_hours: bool,
        },
        allocator,
        json,
        .{ .ignore_unknown_fields = true }
    );
    defer parsed.deinit();

    return AlpacaTradingAPI.OrderResponse{
        .id = try allocator.dupe(u8, parsed.value.id),
        .client_order_id = try allocator.dupe(u8, parsed.value.client_order_id),
        .created_at = try allocator.dupe(u8, parsed.value.created_at),
        .updated_at = if (parsed.value.updated_at) |val| try allocator.dupe(u8, val) else try allocator.dupe(u8, ""),
        .submitted_at = if (parsed.value.submitted_at) |val| try allocator.dupe(u8, val) else try allocator.dupe(u8, ""),
        .asset_id = try allocator.dupe(u8, parsed.value.asset_id),
        .symbol = try allocator.dupe(u8, parsed.value.symbol),
        .asset_class = try allocator.dupe(u8, parsed.value.asset_class),
        .qty = try allocator.dupe(u8, parsed.value.qty),
        .filled_qty = try allocator.dupe(u8, parsed.value.filled_qty),
        .order_type = try allocator.dupe(u8, parsed.value.order_type),
        .side = try allocator.dupe(u8, parsed.value.side),
        .time_in_force = try allocator.dupe(u8, parsed.value.time_in_force),
        .limit_price = if (parsed.value.limit_price) |val| try allocator.dupe(u8, val) else null,
        .stop_price = if (parsed.value.stop_price) |val| try allocator.dupe(u8, val) else null,
        .status = try allocator.dupe(u8, parsed.value.status),
        .extended_hours = parsed.value.extended_hours,
    };
}

fn parseAccountInfo(allocator: std.mem.Allocator, json: []const u8) !AlpacaTradingAPI.AccountInfo {
    const parsed = try std.json.parseFromSlice(
        struct {
            id: []const u8,
            account_number: []const u8,
            status: []const u8,
            currency: []const u8,
            cash: []const u8,
            portfolio_value: []const u8,
            pattern_day_trader: bool,
            trading_blocked: bool,
            transfers_blocked: bool,
            account_blocked: bool,
            created_at: []const u8,
            trade_suspended_by_user: bool,
            buying_power: []const u8,
            equity: []const u8,
            last_equity: []const u8,
            long_market_value: []const u8,
            short_market_value: []const u8,
            multiplier: []const u8,
            initial_margin: []const u8,
            maintenance_margin: []const u8,
            daytrade_count: i32,
            sma: []const u8,
        },
        allocator,
        json,
        .{ .ignore_unknown_fields = true }
    );
    defer parsed.deinit();

    return AlpacaTradingAPI.AccountInfo{
        .id = try allocator.dupe(u8, parsed.value.id),
        .account_number = try allocator.dupe(u8, parsed.value.account_number),
        .status = try allocator.dupe(u8, parsed.value.status),
        .currency = try allocator.dupe(u8, parsed.value.currency),
        .cash = try allocator.dupe(u8, parsed.value.cash),
        .portfolio_value = try allocator.dupe(u8, parsed.value.portfolio_value),
        .pattern_day_trader = parsed.value.pattern_day_trader,
        .trading_blocked = parsed.value.trading_blocked,
        .transfers_blocked = parsed.value.transfers_blocked,
        .account_blocked = parsed.value.account_blocked,
        .created_at = try allocator.dupe(u8, parsed.value.created_at),
        .trade_suspended_by_user = parsed.value.trade_suspended_by_user,
        .buying_power = try allocator.dupe(u8, parsed.value.buying_power),
        .equity = try allocator.dupe(u8, parsed.value.equity),
        .last_equity = try allocator.dupe(u8, parsed.value.last_equity),
        .long_market_value = try allocator.dupe(u8, parsed.value.long_market_value),
        .short_market_value = try allocator.dupe(u8, parsed.value.short_market_value),
        .multiplier = try allocator.dupe(u8, parsed.value.multiplier),
        .initial_margin = try allocator.dupe(u8, parsed.value.initial_margin),
        .maintenance_margin = try allocator.dupe(u8, parsed.value.maintenance_margin),
        .sma = try allocator.dupe(u8, parsed.value.sma),
        .daytrade_count = @intCast(parsed.value.daytrade_count),
    };
}

fn parsePositions(allocator: std.mem.Allocator, json: []const u8) ![]AlpacaTradingAPI.Position {
    const parsed = try std.json.parseFromSlice(
        []struct {
            asset_id: []const u8,
            symbol: []const u8,
            exchange: []const u8,
            asset_class: []const u8,
            avg_entry_price: []const u8,
            qty: []const u8,
            qty_available: []const u8,
            side: []const u8,
            market_value: []const u8,
            cost_basis: []const u8,
            unrealized_pl: []const u8,
            unrealized_plpc: []const u8,
            unrealized_intraday_pl: []const u8,
            unrealized_intraday_plpc: []const u8,
            current_price: []const u8,
            lastday_price: []const u8,
            change_today: []const u8,
        },
        allocator,
        json,
        .{ .ignore_unknown_fields = true }
    );
    defer parsed.deinit();

    const positions = try allocator.alloc(AlpacaTradingAPI.Position, parsed.value.len);
    for (parsed.value, 0..) |pos, i| {
        positions[i] = AlpacaTradingAPI.Position{
            .asset_id = try allocator.dupe(u8, pos.asset_id),
            .symbol = try allocator.dupe(u8, pos.symbol),
            .exchange = try allocator.dupe(u8, pos.exchange),
            .asset_class = try allocator.dupe(u8, pos.asset_class),
            .avg_entry_price = try allocator.dupe(u8, pos.avg_entry_price),
            .qty = try allocator.dupe(u8, pos.qty),
            .qty_available = try allocator.dupe(u8, pos.qty_available),
            .side = try allocator.dupe(u8, pos.side),
            .market_value = try allocator.dupe(u8, pos.market_value),
            .cost_basis = try allocator.dupe(u8, pos.cost_basis),
            .unrealized_pl = try allocator.dupe(u8, pos.unrealized_pl),
            .unrealized_plpc = try allocator.dupe(u8, pos.unrealized_plpc),
            .unrealized_intraday_pl = try allocator.dupe(u8, pos.unrealized_intraday_pl),
            .unrealized_intraday_plpc = try allocator.dupe(u8, pos.unrealized_intraday_plpc),
            .current_price = try allocator.dupe(u8, pos.current_price),
            .lastday_price = try allocator.dupe(u8, pos.lastday_price),
            .change_today = try allocator.dupe(u8, pos.change_today),
        };
    }

    return positions;
}

/// Demo function to test the trading API
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        ALPACA TRADING API DEMO                ║\n", .{});
    std.debug.print("║         REAL ORDER PLACEMENT!                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n\n", .{});
    
    // Initialize trading API
    const api_key = std.mem.span(std.c.getenv("ALPACA_API_KEY") orelse "");
    const api_secret = std.mem.span(std.c.getenv("ALPACA_API_SECRET") orelse "");
    if (api_key.len == 0 or api_secret.len == 0) {
        std.debug.print("❌ ALPACA_API_KEY and ALPACA_API_SECRET environment variables must be set\n", .{});
        return;
    }
    var api = AlpacaTradingAPI.init(
        allocator,
        api_key,
        api_secret,
        true, // Paper trading
    );
    defer api.deinit();
    
    // Test account info
    std.debug.print("🧪 Testing account info...\n", .{});
    const account = api.getAccount() catch |err| {
        std.debug.print("❌ Account test failed: {any}\n", .{err});
        std.debug.print("💡 Make sure your API credentials are correct!\n", .{});
        return;
    };
    
    std.debug.print("✅ Account: {s} (Status: {s})\n", .{ account.account_number, account.status });
    std.debug.print("💰 Buying Power: ${s}\n", .{account.buying_power});
    
    // Test order placement
    std.debug.print("\n🧪 Testing order placement...\n", .{});
    const test_order = AlpacaTradingAPI.OrderRequest{
        .symbol = "AAPL",
        .qty = 10,
        .side = .buy,
        .type = .limit,
        .limit_price = 150.00,
        .time_in_force = .day,
    };
    
    const placed_order = api.placeOrder(test_order) catch |err| {
        std.debug.print("❌ Order test failed: {any}\n", .{err});
        return;
    };
    
    std.debug.print("✅ Order placed: {s} (Status: {s})\n", .{ placed_order.id, placed_order.status });
    
    // Test order cancellation
    std.debug.print("\n🛑 Testing order cancellation...\n", .{});
    api.cancelOrder(placed_order.id) catch |err| {
        std.debug.print("❌ Cancellation test failed: {any}\n", .{err});
        return;
    };
    
    // Show stats
    const stats = api.getStats();
    std.debug.print("\n📊 Trading Statistics:\n", .{});
    std.debug.print("📤 Orders Placed: {d}\n", .{stats.orders_placed});
    std.debug.print("✅ Orders Filled: {d}\n", .{stats.orders_filled});
    std.debug.print("🛑 Orders Canceled: {d}\n", .{stats.orders_canceled});
    
    std.debug.print("\n🚀 Trading API is ready for integration!\n", .{});
}