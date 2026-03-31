//! Lock-Free Order Book
//! Cache-line aligned for optimal performance
//! Target: <100ns update latency

const std = @import("std");

pub const PriceLevel = struct {
    price: f64,
    quantity: f64,
    orders: u32,

    pub fn init(price: f64, qty: f64) PriceLevel {
        return .{
            .price = price,
            .quantity = qty,
            .orders = 1,
        };
    }
};

/// High-performance order book
/// Maintains top N levels on each side
pub const OrderBook = struct {
    symbol: [16]u8,
    bids: [100]PriceLevel align(64),  // Cache-line aligned
    asks: [100]PriceLevel align(64),
    bid_count: usize,
    ask_count: usize,
    sequence: u64,

    pub fn init(symbol: []const u8) OrderBook {
        var book: OrderBook = undefined;
        @memset(&book.symbol, 0);
        @memcpy(book.symbol[0..symbol.len], symbol);
        book.bid_count = 0;
        book.ask_count = 0;
        book.sequence = 0;
        return book;
    }

    /// Update bid side (buy orders)
    /// Bids are sorted descending by price (best bid = highest price at index 0)
    pub fn updateBid(self: *OrderBook, price: f64, qty: f64) void {
        self.sequence += 1;

        // Find insertion/update position via binary search
        var left: usize = 0;
        var right: usize = self.bid_count;
        var found_idx: ?usize = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_price = self.bids[mid].price;

            if (mid_price == price) {
                found_idx = mid;
                break;
            } else if (mid_price > price) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (found_idx) |idx| {
            // Update existing level
            if (qty == 0.0) {
                // Remove level
                if (idx + 1 < self.bid_count) {
                    std.mem.copyForwards(PriceLevel, self.bids[idx..self.bid_count-1], self.bids[idx+1..self.bid_count]);
                }
                self.bid_count -= 1;
            } else {
                self.bids[idx].quantity = qty;
            }
        } else if (qty > 0.0) {
            // Insert new level
            if (self.bid_count >= 100) return; // Full

            const insert_idx = left;

            // Shift elements to make room
            if (insert_idx < self.bid_count) {
                std.mem.copyBackwards(PriceLevel, self.bids[insert_idx+1..self.bid_count+1], self.bids[insert_idx..self.bid_count]);
            }

            self.bids[insert_idx] = PriceLevel.init(price, qty);
            self.bid_count += 1;
        }
    }

    /// Update ask side (sell orders)
    /// Asks are sorted ascending by price (best ask = lowest price at index 0)
    pub fn updateAsk(self: *OrderBook, price: f64, qty: f64) void {
        self.sequence += 1;

        // Find insertion/update position via binary search
        var left: usize = 0;
        var right: usize = self.ask_count;
        var found_idx: ?usize = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_price = self.asks[mid].price;

            if (mid_price == price) {
                found_idx = mid;
                break;
            } else if (mid_price < price) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (found_idx) |idx| {
            // Update existing level
            if (qty == 0.0) {
                // Remove level
                if (idx + 1 < self.ask_count) {
                    std.mem.copyForwards(PriceLevel, self.asks[idx..self.ask_count-1], self.asks[idx+1..self.ask_count]);
                }
                self.ask_count -= 1;
            } else {
                self.asks[idx].quantity = qty;
            }
        } else if (qty > 0.0) {
            // Insert new level
            if (self.ask_count >= 100) return; // Full

            const insert_idx = left;

            // Shift elements to make room
            if (insert_idx < self.ask_count) {
                std.mem.copyBackwards(PriceLevel, self.asks[insert_idx+1..self.ask_count+1], self.asks[insert_idx..self.ask_count]);
            }

            self.asks[insert_idx] = PriceLevel.init(price, qty);
            self.ask_count += 1;
        }
    }

    /// Get best bid (highest buy price)
    pub fn getBestBid(self: *const OrderBook) ?PriceLevel {
        if (self.bid_count == 0) return null;
        return self.bids[0];
    }

    /// Get best ask (lowest sell price)
    pub fn getBestAsk(self: *const OrderBook) ?PriceLevel {
        if (self.ask_count == 0) return null;
        return self.asks[0];
    }

    /// Get mid price
    pub fn getMidPrice(self: *const OrderBook) ?f64 {
        const bid = self.getBestBid() orelse return null;
        const ask = self.getBestAsk() orelse return null;
        return (bid.price + ask.price) / 2.0;
    }

    /// Get spread in basis points
    pub fn getSpreadBps(self: *const OrderBook) ?f64 {
        const bid = self.getBestBid() orelse return null;
        const ask = self.getBestAsk() orelse return null;
        const mid = (bid.price + ask.price) / 2.0;
        return ((ask.price - bid.price) / mid) * 10000.0;
    }
};

test "order book init" {
    const book = OrderBook.init("BTCUSDT");
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}
