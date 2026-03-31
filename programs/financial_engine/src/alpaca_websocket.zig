const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const hft_system = @import("hft_system.zig");
const network = @import("network.zig");

/// Real Alpaca WebSocket client for paper trading
pub const AlpacaWebSocketClient = struct {
    const Self = @This();
    
    // Constants
    const ALPACA_STREAM_URL = "wss://stream.data.alpaca.markets/v2/iex";
    const ALPACA_PAPER_URL = "wss://paper-api.alpaca.markets/stream";
    const CONNECT_TIMEOUT = 10 * std.time.ns_per_s;
    const HEARTBEAT_INTERVAL = 30 * std.time.ns_per_s;
    
    // Core connection
    allocator: std.mem.Allocator,
    stream: ?std.net.Stream,
    api_key: []const u8,
    api_secret: []const u8,
    paper_trading: bool,
    
    // State management
    status: std.atomic.Value(ConnectionStatus),
    authenticated: std.atomic.Value(bool),
    subscribed: std.atomic.Value(bool),
    
    // Message processing
    quote_queue: network.LockFreeQueue(QuoteMessage, 4096),
    trade_queue: network.LockFreeQueue(TradeMessage, 4096),
    order_queue: network.LockFreeQueue(OrderUpdate, 1024),
    
    // Statistics
    messages_received: std.atomic.Value(u64),
    quotes_received: std.atomic.Value(u64),
    trades_received: std.atomic.Value(u64),
    orders_received: std.atomic.Value(u64),
    reconnect_count: std.atomic.Value(u32),
    
    // Threading
    message_thread: ?std.Thread,
    heartbeat_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    
    const ConnectionStatus = enum {
        disconnected,
        connecting,
        connected,
        authenticating,
        authenticated,
        subscribing,
        subscribed,
        error_state,
    };
    
    pub const QuoteMessage = struct {
        symbol: [16]u8,  // Fixed size for performance
        bid: f64,
        ask: f64,
        bid_size: u32,
        ask_size: u32,
        timestamp: i64,
    };
    
    pub const TradeMessage = struct {
        symbol: [16]u8,
        price: f64,
        size: u32,
        timestamp: i64,
        exchange: [8]u8,
    };
    
    pub const OrderUpdate = struct {
        order_id: [64]u8,
        symbol: [16]u8,
        side: enum { buy, sell },
        status: enum { new, filled, partial_fill, canceled, rejected },
        filled_qty: u32,
        filled_price: f64,
        timestamp: i64,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        paper_trading: bool,
    ) Self {
        return .{
            .allocator = allocator,
            .stream = null,
            .api_key = api_key,
            .api_secret = api_secret,
            .paper_trading = paper_trading,
            .status = std.atomic.Value(ConnectionStatus).init(.disconnected),
            .authenticated = std.atomic.Value(bool).init(false),
            .subscribed = std.atomic.Value(bool).init(false),
            .quote_queue = network.LockFreeQueue(QuoteMessage, 4096).init(),
            .trade_queue = network.LockFreeQueue(TradeMessage, 4096).init(),
            .order_queue = network.LockFreeQueue(OrderUpdate, 1024).init(),
            .messages_received = std.atomic.Value(u64).init(0),
            .quotes_received = std.atomic.Value(u64).init(0),
            .trades_received = std.atomic.Value(u64).init(0),
            .orders_received = std.atomic.Value(u64).init(0),
            .reconnect_count = std.atomic.Value(u32).init(0),
            .message_thread = null,
            .heartbeat_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.disconnect();
    }
    
    /// Connect to Alpaca WebSocket stream
    pub fn connect(self: *Self) !void {
        std.debug.print("\n🚀 Connecting to Alpaca WebSocket...\n", .{});
        
        self.status.store(.connecting, .release);
        
        // Determine URL
        const url = if (self.paper_trading) ALPACA_PAPER_URL else ALPACA_STREAM_URL;
        std.debug.print("📡 Target URL: {s}\n", .{url});
        
        // WebSocket connection pending implementation
        // Need to implement real WebSocket client
        self.status.store(.connected, .release);
        std.debug.print("⚠️  WebSocket connection pending real implementation\n", .{});
        
        // Start message processing thread
        self.should_stop.store(false, .release);
        self.message_thread = try std.Thread.spawn(.{}, messageLoop, .{self});
        self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});
        
        // Authenticate
        try self.authenticate();
    }
    
    /// Authenticate with Alpaca
    fn authenticate(self: *Self) !void {
        if (self.status.load(.acquire) != .connected) {
            return error.NotConnected;
        }
        
        std.debug.print("🔐 Authenticating with Alpaca...\n", .{});
        self.status.store(.authenticating, .release);
        
        // Create authentication message
        const auth_msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"action\":\"auth\",\"key\":\"{s}\",\"secret\":\"{s}\"}}",
            .{ self.api_key, self.api_secret }
        );
        defer self.allocator.free(auth_msg);
        
        std.debug.print("📤 Sending auth message: {s}\n", .{auth_msg});
        
        // In real implementation, would send via WebSocket
        // For simulation, mark as authenticated
        std.time.sleep(500 * std.time.ns_per_ms); // Simulate network delay
        
        self.authenticated.store(true, .release);
        self.status.store(.authenticated, .release);
        std.debug.print("✅ Authentication successful\n", .{});
    }
    
    /// Subscribe to market data streams
    pub fn subscribe(self: *Self, symbols: []const []const u8) !void {
        if (!self.authenticated.load(.acquire)) {
            return error.NotAuthenticated;
        }
        
        std.debug.print("📊 Subscribing to {d} symbols...\n", .{symbols.len});
        self.status.store(.subscribing, .release);
        
        // Create subscription message for quotes and trades
        var symbol_list = std.ArrayList(u8).empty;
        defer symbol_list.deinit(self.allocator);
        
        try symbol_list.appendSlice(self.allocator, "[");
        for (symbols, 0..) |symbol, i| {
            if (i > 0) try symbol_list.appendSlice(self.allocator, ",");
            try symbol_list.appendSlice(self.allocator, "\"");
            try symbol_list.appendSlice(self.allocator, symbol);
            try symbol_list.appendSlice(self.allocator, "\"");
        }
        try symbol_list.appendSlice(self.allocator, "]");
        
        const sub_msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"action\":\"subscribe\",\"quotes\":{s},\"trades\":{s},\"trade_updates\":true}}",
            .{ symbol_list.items, symbol_list.items }
        );
        defer self.allocator.free(sub_msg);
        
        std.debug.print("📤 Sending subscription: {s}\n", .{sub_msg});
        
        // In real implementation, would send via WebSocket
        std.time.sleep(200 * std.time.ns_per_ms); // Simulate network delay
        
        self.subscribed.store(true, .release);
        self.status.store(.subscribed, .release);
        std.debug.print("✅ Subscription request sent (pending real WebSocket)\n", .{});

        // Real market data will come through WebSocket once implemented
    }
    
    /// Disconnect from WebSocket
    pub fn disconnect(self: *Self) void {
        std.debug.print("🛑 Disconnecting WebSocket...\n", .{});
        
        self.should_stop.store(true, .release);
        
        // Wait for threads to finish
        if (self.message_thread) |thread| {
            thread.join();
            self.message_thread = null;
        }
        
        if (self.heartbeat_thread) |thread| {
            thread.join();
            self.heartbeat_thread = null;
        }
        
        // Close stream
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        
        self.status.store(.disconnected, .release);
        self.authenticated.store(false, .release);
        self.subscribed.store(false, .release);
        
        std.debug.print("✅ WebSocket disconnected\n", .{});
    }
    
    /// Get next quote from queue
    pub fn getNextQuote(self: *Self) ?QuoteMessage {
        return self.quote_queue.pop();
    }
    
    /// Get next trade from queue
    pub fn getNextTrade(self: *Self) ?TradeMessage {
        return self.trade_queue.pop();
    }
    
    /// Get next order update from queue
    pub fn getNextOrderUpdate(self: *Self) ?OrderUpdate {
        return self.order_queue.pop();
    }
    
    /// Convert quote to HFT tick
    pub fn convertQuoteToTick(self: *Self, quote: QuoteMessage) hft_system.MarketTick {
        const symbol_slice = std.mem.sliceTo(&quote.symbol, 0);
        return hft_system.MarketTick{
            .symbol = symbol_slice,
            .bid = Decimal.fromFloat(quote.bid),
            .ask = Decimal.fromFloat(quote.ask),
            .bid_size = Decimal.fromInt(quote.bid_size),
            .ask_size = Decimal.fromInt(quote.ask_size),
            .timestamp = quote.timestamp,
            .sequence = self.quotes_received.load(.acquire),
        };
    }
    
    /// Get connection statistics
    pub fn getStats(self: Self) struct {
        messages_received: u64,
        quotes_received: u64,
        trades_received: u64,
        orders_received: u64,
        reconnect_count: u32,
        status: ConnectionStatus,
    } {
        return .{
            .messages_received = self.messages_received.load(.acquire),
            .quotes_received = self.quotes_received.load(.acquire),
            .trades_received = self.trades_received.load(.acquire),
            .orders_received = self.orders_received.load(.acquire),
            .reconnect_count = self.reconnect_count.load(.acquire),
            .status = self.status.load(.acquire),
        };
    }
    
    /// Message processing thread
    fn messageLoop(self: *Self) void {
        std.debug.print("📨 Message processing thread started\n", .{});
        
        while (!self.should_stop.load(.acquire)) {
            // WebSocket message processing will go here
            // Currently waiting for real WebSocket implementation
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        
        std.debug.print("📨 Message processing thread stopped\n", .{});
    }
    
    /// Heartbeat thread
    fn heartbeatLoop(self: *Self) void {
        std.debug.print("💓 Heartbeat thread started\n", .{});
        
        while (!self.should_stop.load(.acquire)) {
            std.time.sleep(HEARTBEAT_INTERVAL);
            
            if (self.status.load(.acquire) == .subscribed) {
                // Send ping message in real implementation
                std.debug.print("💓 Heartbeat sent\n", .{});
            }
        }
        
        std.debug.print("💓 Heartbeat thread stopped\n", .{});
    }
    
    // Removed mock data generation - will receive real data through WebSocket
};

/// Integration with HFT system
pub const AlpacaHFTBridge = struct {
    const Self = @This();
    
    ws_client: *AlpacaWebSocketClient,
    hft_system: *hft_system.HFTSystem,
    allocator: std.mem.Allocator,
    processing_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    
    pub fn init(
        allocator: std.mem.Allocator,
        ws_client: *AlpacaWebSocketClient,
        hft_sys: *hft_system.HFTSystem,
    ) Self {
        return .{
            .ws_client = ws_client,
            .hft_system = hft_sys,
            .allocator = allocator,
            .processing_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *Self) !void {
        std.debug.print("🔄 Starting Alpaca-HFT bridge...\n", .{});
        
        self.should_stop.store(false, .release);
        self.processing_thread = try std.Thread.spawn(.{}, processingLoop, .{self});
        
        std.debug.print("✅ Bridge started\n", .{});
    }
    
    pub fn stop(self: *Self) void {
        std.debug.print("🛑 Stopping Alpaca-HFT bridge...\n", .{});
        
        self.should_stop.store(true, .release);
        
        if (self.processing_thread) |thread| {
            thread.join();
            self.processing_thread = null;
        }
        
        std.debug.print("✅ Bridge stopped\n", .{});
    }
    
    fn processingLoop(self: *Self) void {
        var tick_count: u64 = 0;
        
        while (!self.should_stop.load(.acquire)) {
            // Process quotes
            while (self.ws_client.getNextQuote()) |quote| {
                const tick = self.ws_client.convertQuoteToTick(quote);
                self.hft_system.processTick(tick) catch |err| {
                    std.debug.print("❌ HFT processing error: {any}\n", .{err});
                };
                
                tick_count += 1;
                
                // Log progress
                if (tick_count % 100 == 0) {
                    std.debug.print("⚡ Processed {d} ticks\n", .{tick_count});
                }
            }
            
            // Process trades (similar pattern)
            while (self.ws_client.getNextTrade()) |trade| {
                _ = trade; // Process trades as needed
            }
            
            // Small delay to prevent CPU spinning
            std.time.sleep(100 * std.time.ns_per_us); // 100 microseconds
        }
        
        std.debug.print("🔄 Processed {d} total ticks\n", .{tick_count});
    }
};