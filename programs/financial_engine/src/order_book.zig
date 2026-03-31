const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Order types
pub const OrderType = enum {
    market,
    limit,
    stop,
    stop_limit,
};

/// Order side
pub const Side = enum {
    buy,
    sell,
    
    pub fn opposite(self: Side) Side {
        return switch (self) {
            .buy => .sell,
            .sell => .buy,
        };
    }
};

/// Order status
pub const OrderStatus = enum {
    pending,
    open,
    partially_filled,
    filled,
    cancelled,
    rejected,
};

/// Single order
pub const Order = struct {
    id: u64,
    symbol: []const u8,
    side: Side,
    order_type: OrderType,
    price: Decimal,
    quantity: Decimal,
    filled_quantity: Decimal,
    timestamp: i64,
    status: OrderStatus,
    client_id: u32,
    
    pub fn remainingQuantity(self: Order) Decimal {
        return self.quantity.sub(self.filled_quantity) catch Decimal.zero();
    }
    
    pub fn isFilled(self: Order) bool {
        return self.filled_quantity.equals(self.quantity);
    }
};

/// Trade execution record
pub const Trade = struct {
    id: u64,
    symbol: []const u8,
    price: Decimal,
    quantity: Decimal,
    buyer_order_id: u64,
    seller_order_id: u64,
    timestamp: i64,
};

/// Price level in the order book
pub const PriceLevel = struct {
    price: Decimal,
    total_quantity: Decimal,
    order_count: u32,
    orders: std.ArrayList(*Order),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, price: Decimal) PriceLevel {
        return .{
            .price = price,
            .total_quantity = Decimal.zero(),
            .order_count = 0,
            .orders = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PriceLevel) void {
        self.orders.deinit(self.allocator);
    }
    
    pub fn addOrder(self: *PriceLevel, order: *Order) !void {
        try self.orders.append(self.allocator, order);
        self.total_quantity = try self.total_quantity.add(order.remainingQuantity());
        self.order_count += 1;
    }
    
    pub fn removeOrder(self: *PriceLevel, order_id: u64) bool {
        for (self.orders.items, 0..) |o, i| {
            if (o.id == order_id) {
                const removed = self.orders.swapRemove(i);
                self.total_quantity = self.total_quantity.sub(removed.remainingQuantity()) catch Decimal.zero();
                self.order_count -= 1;
                return true;
            }
        }
        return false;
    }
};

/// Order book for a single symbol
pub const OrderBook = struct {
    const Self = @This();
    
    symbol: []const u8,
    bids: std.ArrayList(PriceLevel),  // Buy orders (sorted descending)
    asks: std.ArrayList(PriceLevel),  // Sell orders (sorted ascending)
    trades: std.ArrayList(Trade),
    orders: std.AutoHashMap(u64, *Order),
    allocator: std.mem.Allocator,
    next_order_id: u64,
    next_trade_id: u64,
    last_trade_price: ?Decimal,
    
    pub fn init(allocator: std.mem.Allocator, symbol: []const u8) Self {
        return .{
            .symbol = symbol,
            .bids = .{ .items = &.{}, .capacity = 0 },
            .asks = .{ .items = &.{}, .capacity = 0 },
            .trades = .{ .items = &.{}, .capacity = 0 },
            .orders = std.AutoHashMap(u64, *Order).init(allocator),
            .allocator = allocator,
            .next_order_id = 1,
            .next_trade_id = 1,
            .last_trade_price = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.bids.items) |*level| {
            level.deinit();
        }
        self.bids.deinit(self.allocator);

        for (self.asks.items) |*level| {
            level.deinit();
        }
        self.asks.deinit(self.allocator);

        self.trades.deinit(self.allocator);

        var iter = self.orders.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.orders.deinit();
    }
    
    /// Add a new order to the book
    pub fn addOrder(self: *Self, side: Side, order_type: OrderType, price: Decimal, quantity: Decimal, client_id: u32) !*Order {
        const order = try self.allocator.create(Order);
        order.* = .{
            .id = self.next_order_id,
            .symbol = self.symbol,
            .side = side,
            .order_type = order_type,
            .price = price,
            .quantity = quantity,
            .filled_quantity = Decimal.zero(),
            .timestamp = getCurrentTimestamp(),
            .status = .pending,
            .client_id = client_id,
        };
        
        self.next_order_id += 1;
        try self.orders.put(order.id, order);
        
        // Process the order
        try self.processOrder(order);
        
        return order;
    }
    
    /// Process an order (match and place in book)
    fn processOrder(self: *Self, order: *Order) !void {
        if (order.order_type == .market) {
            try self.executeMarketOrder(order);
        } else if (order.order_type == .limit) {
            try self.executeLimitOrder(order);
        }
    }
    
    /// Execute a market order
    fn executeMarketOrder(self: *Self, order: *Order) !void {
        const opposite_book = if (order.side == .buy) &self.asks else &self.bids;
        
        while (!order.isFilled() and opposite_book.items.len > 0) {
            var level = &opposite_book.items[0];
            
            for (level.orders.items) |counter_order| {
                if (order.isFilled()) break;
                
                const match_qty = blk: {
                    const remaining = order.remainingQuantity();
                    const counter_remaining = counter_order.remainingQuantity();
                    
                    if (remaining.lessThan(counter_remaining)) {
                        break :blk remaining;
                    } else {
                        break :blk counter_remaining;
                    }
                };
                
                // Execute trade
                try self.executeTrade(order, counter_order, level.price, match_qty);
            }
            
            // Remove filled orders from level
            var i: usize = 0;
            while (i < level.orders.items.len) {
                if (level.orders.items[i].isFilled()) {
                    _ = level.orders.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            
            // Remove empty level
            if (level.orders.items.len == 0) {
                level.deinit();
                _ = opposite_book.orderedRemove(0);
            }
        }
        
        if (order.isFilled()) {
            order.status = .filled;
        } else {
            order.status = .cancelled; // Market orders don't rest in book
        }
    }
    
    /// Execute a limit order
    fn executeLimitOrder(self: *Self, order: *Order) !void {
        const opposite_book = if (order.side == .buy) &self.asks else &self.bids;
        const same_book = if (order.side == .buy) &self.bids else &self.asks;
        
        // Try to match with opposite side
        while (!order.isFilled() and opposite_book.items.len > 0) {
            const best_level = &opposite_book.items[0];
            
            // Check if price crosses
            const crosses = if (order.side == .buy)
                !order.price.lessThan(best_level.price)
            else
                !best_level.price.lessThan(order.price);
            
            if (!crosses) break;
            
            for (best_level.orders.items) |counter_order| {
                if (order.isFilled()) break;
                
                const match_qty = blk: {
                    const remaining = order.remainingQuantity();
                    const counter_remaining = counter_order.remainingQuantity();
                    
                    if (remaining.lessThan(counter_remaining)) {
                        break :blk remaining;
                    } else {
                        break :blk counter_remaining;
                    }
                };
                
                // Execute trade at passive order price
                try self.executeTrade(order, counter_order, counter_order.price, match_qty);
            }
            
            // Clean up filled orders
            var i: usize = 0;
            while (i < best_level.orders.items.len) {
                if (best_level.orders.items[i].isFilled()) {
                    _ = best_level.orders.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            
            if (best_level.orders.items.len == 0) {
                best_level.deinit();
                _ = opposite_book.orderedRemove(0);
            }
        }
        
        // Add remaining quantity to book
        if (!order.isFilled()) {
            try self.addToBook(order, same_book);
            order.status = if (order.filled_quantity.isZero()) .open else .partially_filled;
        } else {
            order.status = .filled;
        }
    }
    
    /// Add order to the appropriate side of the book
    fn addToBook(self: *Self, order: *Order, book: *std.ArrayList(PriceLevel)) !void {
        // Find or create price level
        var level_index: ?usize = null;
        
        for (book.items, 0..) |*level, i| {
            if (level.price.equals(order.price)) {
                level_index = i;
                break;
            }
            
            // Find insertion point for new level
            const should_insert = if (order.side == .buy)
                order.price.greaterThan(level.price)  // Bids sorted descending
            else
                order.price.lessThan(level.price);     // Asks sorted ascending
                
            if (should_insert) {
                level_index = i;
                break;
            }
        }
        
        if (level_index) |idx| {
            // Check if level exists at this index
            if (idx < book.items.len and book.items[idx].price.equals(order.price)) {
                // Add to existing level
                try book.items[idx].addOrder(order);
            } else {
                // Insert new level
                var new_level = PriceLevel.init(self.allocator, order.price);
                try new_level.addOrder(order);
                try book.insert(self.allocator, idx, new_level);
            }
        } else {
            // Append new level at end
            var new_level = PriceLevel.init(self.allocator, order.price);
            try new_level.addOrder(order);
            try book.append(self.allocator, new_level);
        }
    }
    
    /// Execute a trade between two orders
    fn executeTrade(self: *Self, aggressive: *Order, passive: *Order, price: Decimal, quantity: Decimal) !void {
        aggressive.filled_quantity = try aggressive.filled_quantity.add(quantity);
        passive.filled_quantity = try passive.filled_quantity.add(quantity);
        
        const trade = Trade{
            .id = self.next_trade_id,
            .symbol = self.symbol,
            .price = price,
            .quantity = quantity,
            .buyer_order_id = if (aggressive.side == .buy) aggressive.id else passive.id,
            .seller_order_id = if (aggressive.side == .sell) aggressive.id else passive.id,
            .timestamp = getCurrentTimestamp(),
        };
        
        self.next_trade_id += 1;
        try self.trades.append(self.allocator, trade);
        self.last_trade_price = price;
    }
    
    /// Cancel an order
    pub fn cancelOrder(self: *Self, order_id: u64) bool {
        const order = self.orders.get(order_id) orelse return false;
        
        if (order.status == .filled or order.status == .cancelled) {
            return false;
        }
        
        // Remove from book
        const book = if (order.side == .buy) &self.bids else &self.asks;
        
        for (book.items) |*level| {
            if (level.removeOrder(order_id)) {
                if (level.orders.items.len == 0) {
                    // Remove empty level
                    for (book.items, 0..) |*l, i| {
                        if (l == level) {
                            l.deinit();
                            _ = book.orderedRemove(i);
                            break;
                        }
                    }
                }
                break;
            }
        }
        
        order.status = .cancelled;
        return true;
    }
    
    /// Get best bid price
    pub fn getBestBid(self: Self) ?Decimal {
        if (self.bids.items.len > 0) {
            return self.bids.items[0].price;
        }
        return null;
    }
    
    /// Get best ask price
    pub fn getBestAsk(self: Self) ?Decimal {
        if (self.asks.items.len > 0) {
            return self.asks.items[0].price;
        }
        return null;
    }
    
    /// Get mid price
    pub fn getMidPrice(self: Self) ?Decimal {
        const bid = self.getBestBid() orelse return null;
        const ask = self.getBestAsk() orelse return null;
        
        const sum = bid.add(ask) catch return null;
        const two = Decimal.fromInt(2);
        return sum.div(two) catch null;
    }
    
    /// Get spread
    pub fn getSpread(self: Self) ?Decimal {
        const bid = self.getBestBid() orelse return null;
        const ask = self.getBestAsk() orelse return null;
        return ask.sub(bid) catch null;
    }
    
    /// Get order book depth
    pub fn getDepth(self: Self, levels: usize) struct { bids: []PriceLevel, asks: []PriceLevel } {
        const bid_count = @min(levels, self.bids.items.len);
        const ask_count = @min(levels, self.asks.items.len);
        
        return .{
            .bids = self.bids.items[0..bid_count],
            .asks = self.asks.items[0..ask_count],
        };
    }
};