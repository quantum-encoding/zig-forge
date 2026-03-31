const std = @import("std");
const linux = std.os.linux;
const json = std.json;
const Decimal = @import("decimal.zig").Decimal;
const WebSocketClient = @import("websocket_client.zig").WebSocketClient;
const hft_system = @import("hft_system.zig");
const network = @import("network.zig");

/// Real Alpaca WebSocket client with production-grade connection
pub const AlpacaWebSocketReal = struct {
    const Self = @This();

    // Alpaca WebSocket endpoints
    const ALPACA_DATA_URL = "stream.data.alpaca.markets";
    const ALPACA_PAPER_TRADING_URL = "paper-api.alpaca.markets";
    const ALPACA_LIVE_TRADING_URL = "api.alpaca.markets";

    // Core components
    allocator: std.mem.Allocator,
    ws_client: WebSocketClient,
    api_key: []const u8,
    api_secret: []const u8,
    paper_trading: bool,

    // State management
    authenticated: std.atomic.Value(bool),
    subscribed_symbols: std.ArrayList([]const u8),

    // Message queues (lock-free for HFT performance)
    quote_queue: network.LockFreeQueue(QuoteMessage, 8192),
    trade_queue: network.LockFreeQueue(TradeMessage, 8192),
    bar_queue: network.LockFreeQueue(BarMessage, 4096),

    // Statistics
    messages_received: std.atomic.Value(u64),
    quotes_received: std.atomic.Value(u64),
    trades_received: std.atomic.Value(u64),
    bars_received: std.atomic.Value(u64),
    errors_received: std.atomic.Value(u64),

    pub const QuoteMessage = struct {
        symbol: [16]u8,
        bid_price: f64,
        ask_price: f64,
        bid_size: u32,
        ask_size: u32,
        bid_exchange: [4]u8,
        ask_exchange: [4]u8,
        timestamp: i64,
        conditions: [4]u8,
    };

    pub const TradeMessage = struct {
        symbol: [16]u8,
        price: f64,
        size: u32,
        timestamp: i64,
        exchange: [4]u8,
        conditions: [4]u8,
        tape: u8,
    };

    pub const BarMessage = struct {
        symbol: [16]u8,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: u64,
        timestamp: i64,
        trade_count: u32,
        vwap: f64,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        paper_trading: bool,
    ) !Self {
        return .{
            .allocator = allocator,
            .ws_client = WebSocketClient.init(allocator),
            .api_key = api_key,
            .api_secret = api_secret,
            .paper_trading = paper_trading,
            .authenticated = std.atomic.Value(bool).init(false),
            .subscribed_symbols = std.ArrayList([]const u8).empty,
            .quote_queue = network.LockFreeQueue(QuoteMessage, 8192).init(),
            .trade_queue = network.LockFreeQueue(TradeMessage, 8192).init(),
            .bar_queue = network.LockFreeQueue(BarMessage, 4096).init(),
            .messages_received = std.atomic.Value(u64).init(0),
            .quotes_received = std.atomic.Value(u64).init(0),
            .trades_received = std.atomic.Value(u64).init(0),
            .bars_received = std.atomic.Value(u64).init(0),
            .errors_received = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.subscribed_symbols.deinit(self.allocator);
        self.ws_client.deinit();
    }

    /// Connect to Alpaca WebSocket stream
    pub fn connect(self: *Self) !void {
        std.debug.print("\n🚀 Connecting to Alpaca WebSocket (REAL)...\n", .{});

        // Configure WebSocket client
        const host = ALPACA_DATA_URL;
        const port: u16 = 443;
        const path = "/v2/iex"; // IEX feed for real-time data

        self.ws_client.configure(host, port, path, true);

        // Set callbacks
        self.ws_client.setCallbacks(
            onMessage,
            onConnect,
            onDisconnect,
            onError,
        );

        // Store self reference for callbacks
        self.ws_client.user = self;

        // Connect
        try self.ws_client.connect();

        std.debug.print("✅ WebSocket client initialized and connecting...\n", .{});
    }

    /// Disconnect from Alpaca
    pub fn disconnect(self: *Self) void {
        std.debug.print("🔌 Disconnecting from Alpaca WebSocket...\n", .{});
        self.ws_client.disconnect();
        self.authenticated.store(false, .release);
    }

    /// Subscribe to market data for symbols
    pub fn subscribe(self: *Self, symbols: []const []const u8) !void {
        if (!self.authenticated.load(.acquire)) {
            return error.NotAuthenticated;
        }

        std.debug.print("📊 Subscribing to symbols: ", .{});
        for (symbols) |symbol| {
            std.debug.print("{s} ", .{symbol});
            try self.subscribed_symbols.append(self.allocator, symbol);
        }
        std.debug.print("\n", .{});

        // Build subscription message
        var buf: [4096]u8 = undefined;
        const subscribe_msg = try std.fmt.bufPrint(&buf,
            \\{{
            \\  "action": "subscribe",
            \\  "quotes": {s},
            \\  "trades": {s},
            \\  "bars": {s}
            \\}}
        , .{
            try symbolsToJsonArray(symbols, self.allocator),
            try symbolsToJsonArray(symbols, self.allocator),
            try symbolsToJsonArray(symbols, self.allocator),
        });

        try self.ws_client.send(subscribe_msg);
        std.debug.print("✅ Subscription request sent\n", .{});
    }

    /// Unsubscribe from market data
    pub fn unsubscribe(self: *Self, symbols: []const []const u8) !void {
        if (!self.authenticated.load(.acquire)) {
            return error.NotAuthenticated;
        }

        var buf: [4096]u8 = undefined;
        const unsubscribe_msg = try std.fmt.bufPrint(&buf,
            \\{{
            \\  "action": "unsubscribe",
            \\  "quotes": {s},
            \\  "trades": {s},
            \\  "bars": {s}
            \\}}
        , .{
            try symbolsToJsonArray(symbols, self.allocator),
            try symbolsToJsonArray(symbols, self.allocator),
            try symbolsToJsonArray(symbols, self.allocator),
        });

        try self.ws_client.send(unsubscribe_msg);
    }

    // Callback functions
    fn onConnect(user: ?*anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(user.?)));
        std.debug.print("🔗 WebSocket connected, authenticating...\n", .{});

        // Send authentication message
        var buf: [512]u8 = undefined;
        const auth_msg = std.fmt.bufPrint(&buf,
            \\{{
            \\  "action": "auth",
            \\  "key": "{s}",
            \\  "secret": "{s}"
            \\}}
        , .{ self.api_key, self.api_secret }) catch {
            std.debug.print("❌ Failed to create auth message\n", .{});
            return;
        };

        self.ws_client.send(auth_msg) catch {
            std.debug.print("❌ Failed to send auth message\n", .{});
            return;
        };
    }

    fn onDisconnect(user: ?*anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(user.?)));
        self.authenticated.store(false, .release);
        std.debug.print("🔌 WebSocket disconnected\n", .{});
    }

    fn onError(user: ?*anyopaque, err: []const u8) void {
        const self = @as(*Self, @ptrCast(@alignCast(user.?)));
        _ = self.errors_received.fetchAdd(1, .monotonic);
        std.debug.print("❌ WebSocket error: {s}\n", .{err});
    }

    fn onMessage(user: ?*anyopaque, data: []const u8) void {
        const self = @as(*Self, @ptrCast(@alignCast(user.?)));
        _ = self.messages_received.fetchAdd(1, .monotonic);

        // Parse the message
        self.processMessage(data) catch |err| {
            std.debug.print("⚠️ Failed to process message: {}\n", .{err});
            _ = self.errors_received.fetchAdd(1, .monotonic);
        };
    }

    /// Process incoming WebSocket message
    fn processMessage(self: *Self, data: []const u8) !void {
        const parsed = try json.parseFromSlice(json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        // Handle different message types
        switch (parsed.value) {
            .array => |messages| {
                for (messages.items) |msg| {
                    try self.processMessageItem(msg);
                }
            },
            .object => |obj| {
            // Single message
            if (obj.get("T")) |msg_type| {
                const type_str = msg_type.string;
                if (std.mem.eql(u8, type_str, "success")) {
                    // Authentication success
                    self.authenticated.store(true, .release);
                    std.debug.print("✅ Authenticated with Alpaca\n", .{});
                } else if (std.mem.eql(u8, type_str, "error")) {
                    if (obj.get("msg")) |error_msg| {
                        std.debug.print("❌ Alpaca error: {s}\n", .{error_msg.string});
                    }
                } else if (std.mem.eql(u8, type_str, "subscription")) {
                    std.debug.print("✅ Subscription confirmed\n", .{});
                } else if (std.mem.eql(u8, type_str, "q")) {
                    // Quote message
                    try self.processQuote(obj);
                } else if (std.mem.eql(u8, type_str, "t")) {
                    // Trade message
                    try self.processTrade(obj);
                } else if (std.mem.eql(u8, type_str, "b")) {
                    // Bar message
                    try self.processBar(obj);
                }
            }
            },
            else => {},
        }
    }

    fn processMessageItem(self: *Self, msg: json.Value) !void {
        switch (msg) {
            .object => |obj| {
                if (obj.get("T")) |msg_type| {
                    const type_str = msg_type.string;
                    if (std.mem.eql(u8, type_str, "success")) {
                        // Check for authentication success
                        if (obj.get("msg")) |msg_text| {
                            if (std.mem.eql(u8, msg_text.string, "authenticated")) {
                                self.authenticated.store(true, .release);
                                std.debug.print("✅ Authenticated with Alpaca\n", .{});
                            }
                        }
                    } else if (std.mem.eql(u8, type_str, "q")) {
                        try self.processQuote(obj);
                    } else if (std.mem.eql(u8, type_str, "t")) {
                        try self.processTrade(obj);
                    } else if (std.mem.eql(u8, type_str, "b")) {
                        try self.processBar(obj);
                    }
                }
            },
            else => {},
        }
    }

    fn processQuote(self: *Self, obj: json.ObjectMap) !void {
        var quote = QuoteMessage{
            .symbol = std.mem.zeroes([16]u8),
            .bid_price = 0,
            .ask_price = 0,
            .bid_size = 0,
            .ask_size = 0,
            .bid_exchange = std.mem.zeroes([4]u8),
            .ask_exchange = std.mem.zeroes([4]u8),
            .timestamp = 0,
            .conditions = std.mem.zeroes([4]u8),
        };

        if (obj.get("S")) |symbol| {
            const sym = symbol.string;
            const copy_len = @min(sym.len, 15);
            @memcpy(quote.symbol[0..copy_len], sym[0..copy_len]);
        }

        if (obj.get("bp")) |bp| quote.bid_price = bp.float;
        if (obj.get("ap")) |ap| quote.ask_price = ap.float;
        if (obj.get("bs")) |bs| quote.bid_size = @intFromFloat(bs.float);
        if (obj.get("as")) |as| quote.ask_size = @intFromFloat(as.float);
        if (obj.get("t")) |t| {
            // Parse timestamp
            const ts_str = t.string;
            quote.timestamp = std.fmt.parseInt(i64, ts_str, 10) catch blk: {var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);};
        }

        if (self.quote_queue.push(quote)) {
            _ = self.quotes_received.fetchAdd(1, .monotonic);
        }
    }

    fn processTrade(self: *Self, obj: json.ObjectMap) !void {
        var trade = TradeMessage{
            .symbol = std.mem.zeroes([16]u8),
            .price = 0,
            .size = 0,
            .timestamp = 0,
            .exchange = std.mem.zeroes([4]u8),
            .conditions = std.mem.zeroes([4]u8),
            .tape = 0,
        };

        if (obj.get("S")) |symbol| {
            const sym = symbol.string;
            const copy_len = @min(sym.len, 15);
            @memcpy(trade.symbol[0..copy_len], sym[0..copy_len]);
        }

        if (obj.get("p")) |p| trade.price = p.float;
        if (obj.get("s")) |s| trade.size = @intFromFloat(s.float);
        if (obj.get("t")) |t| {
            const ts_str = t.string;
            trade.timestamp = std.fmt.parseInt(i64, ts_str, 10) catch blk: {var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);};
        }

        if (self.trade_queue.push(trade)) {
            _ = self.trades_received.fetchAdd(1, .monotonic);
        }
    }

    fn processBar(self: *Self, obj: json.ObjectMap) !void {
        var bar = BarMessage{
            .symbol = std.mem.zeroes([16]u8),
            .open = 0,
            .high = 0,
            .low = 0,
            .close = 0,
            .volume = 0,
            .timestamp = 0,
            .trade_count = 0,
            .vwap = 0,
        };

        if (obj.get("S")) |symbol| {
            const sym = symbol.string;
            const copy_len = @min(sym.len, 15);
            @memcpy(bar.symbol[0..copy_len], sym[0..copy_len]);
        }

        if (obj.get("o")) |o| bar.open = o.float;
        if (obj.get("h")) |h| bar.high = h.float;
        if (obj.get("l")) |l| bar.low = l.float;
        if (obj.get("c")) |c| bar.close = c.float;
        if (obj.get("v")) |v| bar.volume = @intFromFloat(v.float);
        if (obj.get("n")) |n| bar.trade_count = @intFromFloat(n.float);
        if (obj.get("vw")) |vw| bar.vwap = vw.float;

        if (self.bar_queue.push(bar)) {
            _ = self.bars_received.fetchAdd(1, .monotonic);
        }
    }

    /// Get the next quote from the queue
    pub fn getNextQuote(self: *Self) ?QuoteMessage {
        return self.quote_queue.pop();
    }

    /// Get the next trade from the queue
    pub fn getNextTrade(self: *Self) ?TradeMessage {
        return self.trade_queue.pop();
    }

    /// Get the next bar from the queue
    pub fn getNextBar(self: *Self) ?BarMessage {
        return self.bar_queue.pop();
    }

    /// Get connection statistics
    pub fn getStats(self: *const Self) ConnectionStats {
        const ws_stats = self.ws_client.getStats();
        return .{
            .connected = ws_stats.connected,
            .authenticated = self.authenticated.load(.acquire),
            .messages_received = self.messages_received.load(.acquire),
            .quotes_received = self.quotes_received.load(.acquire),
            .trades_received = self.trades_received.load(.acquire),
            .bars_received = self.bars_received.load(.acquire),
            .errors_received = self.errors_received.load(.acquire),
            .bytes_received = ws_stats.bytes_received,
            .bytes_sent = ws_stats.bytes_sent,
        };
    }

    pub const ConnectionStats = struct {
        connected: bool,
        authenticated: bool,
        messages_received: u64,
        quotes_received: u64,
        trades_received: u64,
        bars_received: u64,
        errors_received: u64,
        bytes_received: u64,
        bytes_sent: u64,
    };

    /// Convert quote message to HFT tick
    pub fn convertQuoteToTick(self: *Self, quote: QuoteMessage) hft_system.MarketTick {
        const symbol_slice = std.mem.sliceTo(&quote.symbol, 0);
        return hft_system.MarketTick{
            .symbol = symbol_slice,
            .bid = Decimal.fromFloat(quote.bid_price),
            .ask = Decimal.fromFloat(quote.ask_price),
            .bid_size = Decimal.fromInt(quote.bid_size),
            .ask_size = Decimal.fromInt(quote.ask_size),
            .timestamp = quote.timestamp,
            .sequence = self.quotes_received.load(.acquire),
        };
    }
};

fn symbolsToJsonArray(symbols: []const []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    try result.ensureTotalCapacity(allocator, 256);

    try result.append(allocator, '[');
    for (symbols, 0..) |symbol, i| {
        try result.append(allocator, '"');
        try result.appendSlice(allocator, symbol);
        try result.append(allocator, '"');
        if (i < symbols.len - 1) {
            try result.append(allocator, ',');
        }
    }
    try result.append(allocator, ']');

    return allocator.dupe(u8, result.items);
}

/// Bridge between Alpaca WebSocket and HFT System
pub const AlpacaHFTBridge = struct {
    const BridgeSelf = @This();

    ws_client: *AlpacaWebSocketReal,
    hft_system: *hft_system.HFTSystem,
    allocator: std.mem.Allocator,
    processing_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        ws_client: *AlpacaWebSocketReal,
        hft_system_ptr: *hft_system.HFTSystem,
    ) BridgeSelf {
        return .{
            .ws_client = ws_client,
            .hft_system = hft_system_ptr,
            .allocator = allocator,
            .processing_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *BridgeSelf) !void {
        std.debug.print("🔄 Starting Alpaca-HFT bridge...\n", .{});

        self.should_stop.store(false, .release);
        self.processing_thread = try std.Thread.spawn(.{}, processingLoop, .{self});

        std.debug.print("✅ Bridge started\n", .{});
    }

    pub fn stop(self: *BridgeSelf) void {
        std.debug.print("🛑 Stopping Alpaca-HFT bridge...\n", .{});

        self.should_stop.store(true, .release);

        if (self.processing_thread) |thread| {
            thread.join();
            self.processing_thread = null;
        }

        std.debug.print("✅ Bridge stopped\n", .{});
    }

    fn processingLoop(self: *BridgeSelf) void {
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
            var ts_us = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_us };
            _ = linux.nanosleep(&ts_us, null); // 100 microseconds
        }

        std.debug.print("🔄 Processed {d} total ticks\n", .{tick_count});
    }
};