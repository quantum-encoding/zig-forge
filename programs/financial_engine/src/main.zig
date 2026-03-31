const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const order_book = @import("order_book.zig");
const risk = @import("risk_manager.zig");

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

const OrderBook = order_book.OrderBook;
const OrderType = order_book.OrderType;
const Side = order_book.Side;
const RiskManager = risk.RiskManager;
const RiskLimits = risk.RiskLimits;

/// Trading Engine - High-performance financial trading system
pub const TradingEngine = struct {
    const Self = @This();
    
    order_books: std.StringHashMap(*OrderBook),
    risk_manager: RiskManager,
    allocator: std.mem.Allocator,
    message_count: u64,
    last_update: i64,
    
    pub fn init(allocator: std.mem.Allocator, initial_balance: Decimal) !Self {
        const limits = RiskLimits{
            .max_position_size = Decimal.fromInt(10000),
            .max_leverage = Decimal.fromInt(10),
            .max_drawdown = Decimal.fromFloat(0.2), // 20%
            .daily_loss_limit = Decimal.fromInt(5000),
            .position_limit_per_symbol = Decimal.fromInt(5000),
            .total_exposure_limit = Decimal.fromInt(100000),
            .margin_call_level = Decimal.fromFloat(1.5),
            .liquidation_level = Decimal.fromFloat(1.1),
        };
        
        return Self{
            .order_books = std.StringHashMap(*OrderBook).init(allocator),
            .risk_manager = RiskManager.init(allocator, initial_balance, limits),
            .allocator = allocator,
            .message_count = 0,
            .last_update = getCurrentTimestamp(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iter = self.order_books.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.order_books.deinit();
        self.risk_manager.deinit();
    }
    
    /// Create or get order book for symbol
    fn getOrCreateOrderBook(self: *Self, symbol: []const u8) !*OrderBook {
        if (self.order_books.get(symbol)) |book| {
            return book;
        }
        
        const book = try self.allocator.create(OrderBook);
        book.* = OrderBook.init(self.allocator, symbol);
        try self.order_books.put(symbol, book);
        return book;
    }
    
    /// Submit a new order
    pub fn submitOrder(
        self: *Self,
        symbol: []const u8,
        side: Side,
        order_type: OrderType,
        price: Decimal,
        quantity: Decimal,
        client_id: u32,
    ) !u64 {
        // Risk checks
        if (!self.risk_manager.canOpenPosition(symbol, quantity, price)) {
            return error.RiskLimitExceeded;
        }
        
        // Get order book
        const book = try self.getOrCreateOrderBook(symbol);
        
        // Add order to book
        const order = try book.addOrder(side, order_type, price, quantity, client_id);
        
        // Track position if filled
        if (order.status == .filled or order.status == .partially_filled) {
            const fill_qty = order.filled_quantity;
            const fill_price = book.last_trade_price orelse price;
            
            const position_side = switch (side) {
                .buy => @as(@TypeOf(@as(risk.Position, undefined).side), .long),
                .sell => @as(@TypeOf(@as(risk.Position, undefined).side), .short),
            };
            
            try self.risk_manager.openPosition(symbol, position_side, fill_qty, fill_price);
        }
        
        self.message_count += 1;
        self.last_update = getCurrentTimestamp();
        
        return order.id;
    }
    
    /// Cancel an order
    pub fn cancelOrder(self: *Self, symbol: []const u8, order_id: u64) bool {
        const book = self.order_books.get(symbol) orelse return false;
        
        self.message_count += 1;
        self.last_update = getCurrentTimestamp();
        
        return book.cancelOrder(order_id);
    }
    
    /// Get market data
    pub fn getMarketData(self: Self, symbol: []const u8) ?MarketData {
        const book = self.order_books.get(symbol) orelse return null;
        
        return MarketData{
            .symbol = symbol,
            .bid = book.getBestBid(),
            .ask = book.getBestAsk(),
            .last = book.last_trade_price,
            .mid = book.getMidPrice(),
            .spread = book.getSpread(),
            .bid_size = if (book.bids.items.len > 0) book.bids.items[0].total_quantity else null,
            .ask_size = if (book.asks.items.len > 0) book.asks.items[0].total_quantity else null,
        };
    }
    
    /// Get order book depth
    pub fn getDepth(self: Self, symbol: []const u8, levels: usize) ?@TypeOf(@as(order_book.OrderBook, undefined).getDepth(0)) {
        const book = self.order_books.get(symbol) orelse return null;
        return book.getDepth(levels);
    }
    
    /// Get engine statistics
    pub fn getStats(self: Self) EngineStats {
        var total_orders: u64 = 0;
        var total_trades: u64 = 0;
        var active_orders: u64 = 0;
        
        var iter = self.order_books.iterator();
        while (iter.next()) |entry| {
            const book = entry.value_ptr.*;
            total_orders += book.next_order_id - 1;
            total_trades += book.next_trade_id - 1;
            
            for (book.bids.items) |level| {
                active_orders += level.order_count;
            }
            for (book.asks.items) |level| {
                active_orders += level.order_count;
            }
        }
        
        const risk_report = self.risk_manager.getRiskReport();
        
        return EngineStats{
            .message_count = self.message_count,
            .total_orders = total_orders,
            .total_trades = total_trades,
            .active_orders = active_orders,
            .symbols_count = self.order_books.count(),
            .messages_per_second = self.calculateMPS(),
            .risk_metrics = risk_report,
        };
    }
    
    fn calculateMPS(self: Self) f64 {
        const now = @as(i64, getCurrentTimestamp());
        const elapsed = now - self.last_update;
        if (elapsed <= 0) return 0;
        
        return @as(f64, @floatFromInt(self.message_count)) / @as(f64, @floatFromInt(elapsed));
    }
};

/// Market data snapshot
pub const MarketData = struct {
    symbol: []const u8,
    bid: ?Decimal,
    ask: ?Decimal,
    last: ?Decimal,
    mid: ?Decimal,
    spread: ?Decimal,
    bid_size: ?Decimal,
    ask_size: ?Decimal,
};

/// Engine statistics
pub const EngineStats = struct {
    message_count: u64,
    total_orders: u64,
    total_trades: u64,
    active_orders: u64,
    symbols_count: u32,
    messages_per_second: f64,
    risk_metrics: risk.RiskMetrics,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("\n=== High-Performance Financial Trading Engine ===\n\n", .{});
    
    // Initialize engine with $100,000 balance
    var engine = try TradingEngine.init(allocator, Decimal.fromInt(100000));
    defer engine.deinit();
    
    // Simulate trading session
    try simulateTradingSession(&engine);
    
    // Print final statistics
    const stats = engine.getStats();
    std.debug.print("\n=== Trading Session Statistics ===\n", .{});
    std.debug.print("Total Orders: {d}\n", .{stats.total_orders});
    std.debug.print("Total Trades: {d}\n", .{stats.total_trades});
    std.debug.print("Active Orders: {d}\n", .{stats.active_orders});
    std.debug.print("Symbols Traded: {d}\n", .{stats.symbols_count});
    std.debug.print("\n=== Risk Metrics ===\n", .{});
    std.debug.print("Unrealized PnL: {any}\n", .{stats.risk_metrics.unrealized_pnl});
    std.debug.print("Realized PnL: {any}\n", .{stats.risk_metrics.realized_pnl});
    std.debug.print("Leverage: {any}\n", .{stats.risk_metrics.leverage});
    std.debug.print("Sharpe Ratio: {d:.2}\n", .{stats.risk_metrics.sharpe_ratio});
}

fn simulateTradingSession(engine: *TradingEngine) !void {
    std.debug.print("Starting trading session simulation...\n\n", .{});
    
    // Add some initial orders to create a market
    const symbol = "AAPL";
    
    std.debug.print("Creating order book for {s}...\n", .{symbol});
    
    // Add buy orders (bids)
    _ = try engine.submitOrder(symbol, .buy, .limit, Decimal.fromFloat(149.90), Decimal.fromInt(100), 1);
    _ = try engine.submitOrder(symbol, .buy, .limit, Decimal.fromFloat(149.85), Decimal.fromInt(200), 2);
    _ = try engine.submitOrder(symbol, .buy, .limit, Decimal.fromFloat(149.80), Decimal.fromInt(150), 3);
    
    // Add sell orders (asks)
    _ = try engine.submitOrder(symbol, .sell, .limit, Decimal.fromFloat(150.10), Decimal.fromInt(100), 4);
    _ = try engine.submitOrder(symbol, .sell, .limit, Decimal.fromFloat(150.15), Decimal.fromInt(200), 5);
    _ = try engine.submitOrder(symbol, .sell, .limit, Decimal.fromFloat(150.20), Decimal.fromInt(150), 6);
    
    // Show initial market
    if (engine.getMarketData(symbol)) |market| {
        std.debug.print("\nInitial Market for {s}:\n", .{symbol});
        if (market.bid) |bid| std.debug.print("  Best Bid: {any}\n", .{bid});
        if (market.ask) |ask| std.debug.print("  Best Ask: {any}\n", .{ask});
        if (market.spread) |spread| std.debug.print("  Spread: {any}\n", .{spread});
    }
    
    // Execute some market orders
    std.debug.print("\nExecuting market orders...\n", .{});
    
    // Buy 50 shares at market
    const buy_order = try engine.submitOrder(symbol, .buy, .market, Decimal.zero(), Decimal.fromInt(50), 7);
    std.debug.print("Market buy order {d} submitted\n", .{buy_order});
    
    // Sell 30 shares at market
    const sell_order = try engine.submitOrder(symbol, .sell, .market, Decimal.zero(), Decimal.fromInt(30), 8);
    std.debug.print("Market sell order {d} submitted\n", .{sell_order});
    
    // Show updated market
    if (engine.getMarketData(symbol)) |market| {
        std.debug.print("\nUpdated Market for {s}:\n", .{symbol});
        if (market.bid) |bid| std.debug.print("  Best Bid: {any}\n", .{bid});
        if (market.ask) |ask| std.debug.print("  Best Ask: {any}\n", .{ask});
        if (market.last) |last| std.debug.print("  Last Trade: {any}\n", .{last});
    }
    
    // Show order book depth
    if (engine.getDepth(symbol, 3)) |depth| {
        std.debug.print("\nOrder Book Depth (3 levels):\n", .{});
        std.debug.print("BIDS:\n", .{});
        for (depth.bids) |level| {
            std.debug.print("  {any} x {any}\n", .{ level.price, level.total_quantity });
        }
        std.debug.print("ASKS:\n", .{});
        for (depth.asks) |level| {
            std.debug.print("  {any} x {any}\n", .{ level.price, level.total_quantity });
        }
    }
    
    // Simulate aggressive order that crosses the spread
    std.debug.print("\nSubmitting aggressive limit order...\n", .{});
    _ = try engine.submitOrder(symbol, .buy, .limit, Decimal.fromFloat(150.15), Decimal.fromInt(150), 9);
    
    if (engine.getMarketData(symbol)) |market| {
        std.debug.print("\nFinal Market State:\n", .{});
        if (market.bid) |bid| std.debug.print("  Best Bid: {any}\n", .{bid});
        if (market.ask) |ask| std.debug.print("  Best Ask: {any}\n", .{ask});
        if (market.last) |last| std.debug.print("  Last Trade: {any}\n", .{last});
    }
}