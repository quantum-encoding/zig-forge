/// Cache-line aligned order book for market data.
/// Compatible with market_data_parser's OrderBook format.
///
/// Design:
///   - Fixed-size price level arrays (no heap allocation after init)
///   - Sorted insertion for fast best-bid/best-ask access
///   - Cache-line aligned bid/ask arrays to prevent false sharing
///   - Update from parsed JSON price/quantity pairs (zero-copy from mbuf)

const std = @import("std");
const decimal_mod = @import("decimal.zig");

const Decimal = decimal_mod.Decimal;
const parseDecimal = decimal_mod.parseDecimal;

pub const MAX_LEVELS: usize = 100;

/// Single price level.
pub const PriceLevel = struct {
    price: Decimal = Decimal.ZERO,
    quantity: Decimal = Decimal.ZERO,
};

/// Order book with bids and asks.
pub const OrderBook = struct {
    symbol: [16]u8 = [_]u8{0} ** 16,
    bids: [MAX_LEVELS]PriceLevel align(64) = [_]PriceLevel{.{}} ** MAX_LEVELS,
    asks: [MAX_LEVELS]PriceLevel align(64) = [_]PriceLevel{.{}} ** MAX_LEVELS,
    bid_count: u32 = 0,
    ask_count: u32 = 0,
    sequence: u64 = 0,
    last_update_ns: u64 = 0,

    pub fn init(symbol: []const u8) OrderBook {
        var book = OrderBook{};
        const len = @min(symbol.len, 16);
        @memcpy(book.symbol[0..len], symbol[0..len]);
        return book;
    }

    /// Update a bid level. If quantity is zero, remove the level.
    /// Bids are sorted descending (best bid = highest price at index 0).
    pub fn updateBid(self: *OrderBook, price: Decimal, qty: Decimal) void {
        if (qty.value == 0) {
            self.removeLevel(&self.bids, &self.bid_count, price);
        } else {
            self.upsertLevel(&self.bids, &self.bid_count, price, qty, .descending);
        }
    }

    /// Update an ask level. If quantity is zero, remove the level.
    /// Asks are sorted ascending (best ask = lowest price at index 0).
    pub fn updateAsk(self: *OrderBook, price: Decimal, qty: Decimal) void {
        if (qty.value == 0) {
            self.removeLevel(&self.asks, &self.ask_count, price);
        } else {
            self.upsertLevel(&self.asks, &self.ask_count, price, qty, .ascending);
        }
    }

    /// Update from string price/quantity (directly from JSON parse result).
    pub fn updateBidStr(self: *OrderBook, price_str: []const u8, qty_str: []const u8) void {
        const price = parseDecimal(price_str) orelse return;
        const qty = parseDecimal(qty_str) orelse return;
        self.updateBid(price, qty);
    }

    pub fn updateAskStr(self: *OrderBook, price_str: []const u8, qty_str: []const u8) void {
        const price = parseDecimal(price_str) orelse return;
        const qty = parseDecimal(qty_str) orelse return;
        self.updateAsk(price, qty);
    }

    pub fn bestBid(self: *const OrderBook) ?PriceLevel {
        if (self.bid_count == 0) return null;
        return self.bids[0];
    }

    pub fn bestAsk(self: *const OrderBook) ?PriceLevel {
        if (self.ask_count == 0) return null;
        return self.asks[0];
    }

    /// Mid price = (best bid + best ask) / 2.
    pub fn midPrice(self: *const OrderBook) ?Decimal {
        const bid = self.bestBid() orelse return null;
        const ask = self.bestAsk() orelse return null;
        return bid.price.add(ask.price).div(Decimal.fromInt(2));
    }

    /// Spread in basis points = (ask - bid) / mid * 10000.
    pub fn spreadBps(self: *const OrderBook) ?Decimal {
        const bid = self.bestBid() orelse return null;
        const ask = self.bestAsk() orelse return null;
        const mid = self.midPrice() orelse return null;
        if (mid.value == 0) return null;
        const spread = ask.price.sub(bid.price);
        return spread.mul(Decimal.fromInt(10000)).div(mid);
    }

    // ── Internal ──

    const SortOrder = enum { ascending, descending };

    fn upsertLevel(
        self: *OrderBook,
        levels: *[MAX_LEVELS]PriceLevel,
        count: *u32,
        price: Decimal,
        qty: Decimal,
        order: SortOrder,
    ) void {
        _ = self;
        // Check if price already exists — update in place
        for (levels[0..count.*]) |*lvl| {
            if (lvl.price.eql(price)) {
                lvl.quantity = qty;
                return;
            }
        }

        // Insert new level at sorted position
        if (count.* >= MAX_LEVELS) return; // book full

        // Find insertion point
        var insert_idx: u32 = count.*;
        for (levels[0..count.*], 0..) |lvl, idx| {
            const should_insert = switch (order) {
                .descending => price.greaterThan(lvl.price),
                .ascending => price.lessThan(lvl.price),
            };
            if (should_insert) {
                insert_idx = @intCast(idx);
                break;
            }
        }

        // Shift elements right to make room
        if (insert_idx < count.*) {
            var i: u32 = count.*;
            while (i > insert_idx) : (i -= 1) {
                levels[i] = levels[i - 1];
            }
        }

        levels[insert_idx] = .{ .price = price, .quantity = qty };
        count.* += 1;
    }

    fn removeLevel(self: *OrderBook, levels: *[MAX_LEVELS]PriceLevel, count: *u32, price: Decimal) void {
        _ = self;
        for (0..count.*) |idx| {
            if (levels[idx].price.eql(price)) {
                // Shift elements left
                var i: usize = idx;
                while (i + 1 < count.*) : (i += 1) {
                    levels[i] = levels[i + 1];
                }
                count.* -= 1;
                return;
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "order_book: basic bid/ask" {
    var book = OrderBook.init("BTCUSDT");

    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(1.5));
    book.updateBid(Decimal.fromFloat(49999.0), Decimal.fromFloat(2.0));
    book.updateAsk(Decimal.fromFloat(50001.0), Decimal.fromFloat(0.5));
    book.updateAsk(Decimal.fromFloat(50002.0), Decimal.fromFloat(1.0));

    try testing.expectEqual(@as(u32, 2), book.bid_count);
    try testing.expectEqual(@as(u32, 2), book.ask_count);

    // Best bid = highest price
    const bb = book.bestBid().?;
    try testing.expect(@abs(bb.price.toFloat() - 50000.0) < 0.01);

    // Best ask = lowest price
    const ba = book.bestAsk().?;
    try testing.expect(@abs(ba.price.toFloat() - 50001.0) < 0.01);
}

test "order_book: sorted insertion" {
    var book = OrderBook.init("ETHUSDT");

    // Insert bids out of order
    book.updateBid(Decimal.fromFloat(3000.0), Decimal.fromFloat(5.0));
    book.updateBid(Decimal.fromFloat(3010.0), Decimal.fromFloat(3.0));
    book.updateBid(Decimal.fromFloat(2990.0), Decimal.fromFloat(8.0));

    // Best bid should be 3010 (highest)
    try testing.expect(@abs(book.bestBid().?.price.toFloat() - 3010.0) < 0.01);
    try testing.expectEqual(@as(u32, 3), book.bid_count);

    // Insert asks out of order
    book.updateAsk(Decimal.fromFloat(3020.0), Decimal.fromFloat(1.0));
    book.updateAsk(Decimal.fromFloat(3015.0), Decimal.fromFloat(2.0));

    // Best ask should be 3015 (lowest)
    try testing.expect(@abs(book.bestAsk().?.price.toFloat() - 3015.0) < 0.01);
}

test "order_book: update existing level" {
    var book = OrderBook.init("BTCUSDT");

    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(1.0));
    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(2.5)); // update

    try testing.expectEqual(@as(u32, 1), book.bid_count);
    try testing.expect(@abs(book.bestBid().?.quantity.toFloat() - 2.5) < 0.01);
}

test "order_book: remove level with zero quantity" {
    var book = OrderBook.init("BTCUSDT");

    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(1.0));
    book.updateBid(Decimal.fromFloat(49999.0), Decimal.fromFloat(2.0));
    try testing.expectEqual(@as(u32, 2), book.bid_count);

    book.updateBid(Decimal.fromFloat(50000.0), Decimal.ZERO); // remove
    try testing.expectEqual(@as(u32, 1), book.bid_count);
    try testing.expect(@abs(book.bestBid().?.price.toFloat() - 49999.0) < 0.01);
}

test "order_book: string update" {
    var book = OrderBook.init("BTCUSDT");

    book.updateBidStr("50000.50", "1.25");
    book.updateAskStr("50001.75", "0.50");

    try testing.expect(@abs(book.bestBid().?.price.toFloat() - 50000.50) < 0.01);
    try testing.expect(@abs(book.bestAsk().?.quantity.toFloat() - 0.50) < 0.01);
}

test "order_book: mid price and spread" {
    var book = OrderBook.init("BTCUSDT");

    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(1.0));
    book.updateAsk(Decimal.fromFloat(50010.0), Decimal.fromFloat(1.0));

    const mid = book.midPrice().?;
    try testing.expect(@abs(mid.toFloat() - 50005.0) < 0.01);

    const spread = book.spreadBps().?;
    // spread = (50010-50000)/50005 * 10000 ≈ 2.0 bps
    try testing.expect(@abs(spread.toFloat() - 2.0) < 0.1);
}

test "order_book: empty book" {
    const book = OrderBook.init("EMPTY");
    try testing.expect(book.bestBid() == null);
    try testing.expect(book.bestAsk() == null);
    try testing.expect(book.midPrice() == null);
    try testing.expect(book.spreadBps() == null);
}
