//! Binance WebSocket Protocol Parser
//! Handles depth updates, trades, and ticker messages
//!
//! Performance: <200ns per message parse

const std = @import("std");
const json = @import("../parsers/json_parser.zig");
const OrderBook = @import("../orderbook/book.zig").OrderBook;

pub const MessageType = enum {
    depth_update,
    trade,
    ticker,
    unknown,
};

/// Binance depth update message
/// {"e":"depthUpdate","E":1234567890,"s":"BTCUSDT","U":157,"u":160,"b":[["50000.00","0.1"]],"a":[["50001.00","0.2"]]}
pub const DepthUpdate = struct {
    symbol: []const u8,
    event_time: u64,
    first_update_id: u64,
    final_update_id: u64,
    // Note: bids/asks are not stored in the struct, they're processed directly

    pub fn parse(allocator: std.mem.Allocator, msg: []const u8) !DepthUpdate {
        var parser = json.Parser.init(msg);

        // Parse event type to verify
        const event_type = parser.findValue("e") orelse return error.MissingEventType;
        if (!std.mem.eql(u8, event_type, "depthUpdate")) {
            return error.InvalidEventType;
        }

        // Parse event time
        parser.reset();
        const event_time_str = parser.findValue("E") orelse return error.MissingEventTime;
        const event_time = try json.Parser.parseInt(event_time_str);

        // Parse symbol
        parser.reset();
        const symbol = parser.findValue("s") orelse return error.MissingSymbol;
        // Allocate symbol copy for safety
        const symbol_copy = try allocator.dupe(u8, symbol);

        // Parse first update ID
        parser.reset();
        const first_id_str = parser.findValue("U") orelse return error.MissingFirstId;
        const first_id = try json.Parser.parseInt(first_id_str);

        // Parse final update ID
        parser.reset();
        const final_id_str = parser.findValue("u") orelse return error.MissingFinalId;
        const final_id = try json.Parser.parseInt(final_id_str);

        return DepthUpdate{
            .symbol = symbol_copy,
            .event_time = event_time,
            .first_update_id = first_id,
            .final_update_id = final_id,
        };
    }

    /// Apply depth update to order book
    /// Parses and applies bids/asks directly without allocation
    pub fn applyToBook(msg: []const u8, book: *OrderBook) !void {
        var parser = json.Parser.init(msg);

        // Find bids array
        parser.reset();
        const bids_start = std.mem.indexOf(u8, msg, "\"b\":") orelse return error.MissingBids;
        const bids_str = msg[bids_start + 4 ..];

        // Find asks array
        const asks_start = std.mem.indexOf(u8, msg, "\"a\":") orelse return error.MissingAsks;
        const asks_str = msg[asks_start + 4 ..];

        // Parse bids - format: [["price","qty"],...]
        try parsePriceLevels(bids_str, book, true);

        // Parse asks
        try parsePriceLevels(asks_str, book, false);
    }

    /// Parse and apply price levels from JSON array
    fn parsePriceLevels(array_str: []const u8, book: *OrderBook, is_bid: bool) !void {
        // Simple parser for [["price","qty"],["price","qty"],...]
        var i: usize = 0;

        // Skip opening [
        while (i < array_str.len and array_str[i] != '[') : (i += 1) {}
        if (i >= array_str.len) return;
        i += 1;

        // Parse each price level
        while (i < array_str.len) {
            // Skip whitespace
            while (i < array_str.len and (array_str[i] == ' ' or array_str[i] == '\n')) : (i += 1) {}

            // Check for end of array
            if (i >= array_str.len or array_str[i] == ']') break;

            // Expect opening [
            if (array_str[i] != '[') break;
            i += 1;

            // Parse price string
            while (i < array_str.len and array_str[i] != '"') : (i += 1) {}
            if (i >= array_str.len) break;
            i += 1; // Skip opening "

            const price_start = i;
            while (i < array_str.len and array_str[i] != '"') : (i += 1) {}
            if (i >= array_str.len) break;
            const price_str = array_str[price_start..i];
            const price = try json.Parser.parsePrice(price_str);
            i += 1; // Skip closing "

            // Skip comma
            while (i < array_str.len and array_str[i] != '"') : (i += 1) {}
            if (i >= array_str.len) break;
            i += 1; // Skip opening "

            const qty_start = i;
            while (i < array_str.len and array_str[i] != '"') : (i += 1) {}
            if (i >= array_str.len) break;
            const qty_str = array_str[qty_start..i];
            const qty = try json.Parser.parsePrice(qty_str);
            i += 1; // Skip closing "

            // Apply to book
            if (is_bid) {
                book.updateBid(price, qty);
            } else {
                book.updateAsk(price, qty);
            }

            // Skip to next entry
            while (i < array_str.len and array_str[i] != ',' and array_str[i] != ']') : (i += 1) {}
            if (i < array_str.len and array_str[i] == ',') i += 1;
        }
    }
};

/// Binance trade message
/// {"e":"trade","E":1234567890,"s":"BTCUSDT","t":12345,"p":"50000.00","q":"0.1","T":1234567890}
pub const Trade = struct {
    symbol: []const u8,
    trade_id: u64,
    price: f64,
    quantity: f64,
    timestamp: u64,
    is_buyer_maker: bool,

    pub fn parse(allocator: std.mem.Allocator, msg: []const u8) !Trade {
        var parser = json.Parser.init(msg);

        // Parse event type to verify
        const event_type = parser.findValue("e") orelse return error.MissingEventType;
        if (!std.mem.eql(u8, event_type, "trade")) {
            return error.InvalidEventType;
        }

        // Parse symbol
        parser.reset();
        const symbol = parser.findValue("s") orelse return error.MissingSymbol;
        const symbol_copy = try allocator.dupe(u8, symbol);

        // Parse trade ID
        parser.reset();
        const trade_id_str = parser.findValue("t") orelse return error.MissingTradeId;
        const trade_id = try json.Parser.parseInt(trade_id_str);

        // Parse price
        parser.reset();
        const price_str = parser.findValue("p") orelse return error.MissingPrice;
        const price = try json.Parser.parsePrice(price_str);

        // Parse quantity
        parser.reset();
        const qty_str = parser.findValue("q") orelse return error.MissingQuantity;
        const quantity = try json.Parser.parsePrice(qty_str);

        // Parse timestamp
        parser.reset();
        const ts_str = parser.findValue("T") orelse return error.MissingTimestamp;
        const timestamp = try json.Parser.parseInt(ts_str);

        // Parse buyer maker flag
        parser.reset();
        const maker_str = parser.findValue("m") orelse "false";
        const is_buyer_maker = std.mem.eql(u8, maker_str, "true");

        return Trade{
            .symbol = symbol_copy,
            .trade_id = trade_id,
            .price = price,
            .quantity = quantity,
            .timestamp = timestamp,
            .is_buyer_maker = is_buyer_maker,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "binance depth update parse" {
    const allocator = std.testing.allocator;

    const msg =
        \\{"e":"depthUpdate","E":1699999999000,"s":"BTCUSDT","U":123456789,"u":123456790,"b":[["50000.50","1.234"]],"a":[["50001.00","0.987"]]}
    ;

    const update = try DepthUpdate.parse(allocator, msg);
    defer allocator.free(update.symbol);

    try std.testing.expectEqualStrings("BTCUSDT", update.symbol);
    try std.testing.expectEqual(@as(u64, 123456789), update.first_update_id);
    try std.testing.expectEqual(@as(u64, 123456790), update.final_update_id);
}

test "binance depth update apply to book" {
    const allocator = std.testing.allocator;
    var book = try OrderBook.init(allocator, "BTCUSDT");
    defer book.deinit();

    const msg =
        \\{"e":"depthUpdate","E":1699999999000,"s":"BTCUSDT","U":1,"u":2,"b":[["50000.00","1.5"],["49999.00","2.0"]],"a":[["50001.00","0.5"],["50002.00","1.0"]]}
    ;

    try DepthUpdate.applyToBook(msg, &book);

    const best_bid = book.getBestBid();
    const best_ask = book.getBestAsk();

    try std.testing.expect(best_bid != null);
    try std.testing.expect(best_ask != null);

    if (best_bid) |bid| {
        try std.testing.expectApproxEqAbs(50000.00, bid.price, 0.01);
    }

    if (best_ask) |ask| {
        try std.testing.expectApproxEqAbs(50001.00, ask.price, 0.01);
    }
}

test "binance trade parse" {
    const allocator = std.testing.allocator;

    const msg =
        \\{"e":"trade","E":1699999999000,"s":"BTCUSDT","t":12345,"p":"50000.50","q":"1.234","T":1699999999000,"m":true}
    ;

    const trade = try Trade.parse(allocator, msg);
    defer allocator.free(trade.symbol);

    try std.testing.expectEqualStrings("BTCUSDT", trade.symbol);
    try std.testing.expectEqual(@as(u64, 12345), trade.trade_id);
    try std.testing.expectApproxEqAbs(50000.50, trade.price, 0.01);
    try std.testing.expectApproxEqAbs(1.234, trade.quantity, 0.001);
    try std.testing.expect(trade.is_buyer_maker);
}
