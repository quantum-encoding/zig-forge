//! Example: Parse Binance WebSocket feed
//! Demonstrates parsing real WebSocket messages (hardcoded test data)

const std = @import("std");
const parser = @import("parser");
const binance = parser.binance;
const orderbook = parser.orderbook;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("=== Binance WebSocket Parser Example ===\n\n", .{});

    // Example 1: Parse depth update
    std.debug.print("1. Depth Update Message\n", .{});
    const depth_msg =
        \\{"e":"depthUpdate","E":1699999999000,"s":"BTCUSDT","U":123456789,"u":123456790,"b":[["50000.50","1.234"],["49999.50","2.567"]],"a":[["50001.00","0.987"],["50002.00","1.543"]]}
    ;

    std.debug.print("   Parsing: {s}\n", .{depth_msg});

    const depth = binance.DepthUpdate.parse(allocator, depth_msg) catch |err| {
        std.debug.print("   Error parsing depth: {}\n", .{err});
        return;
    };
    defer allocator.free(depth.symbol);

    std.debug.print("   Symbol: {s}\n", .{depth.symbol});
    std.debug.print("   Event Time: {}\n", .{depth.event_time});
    std.debug.print("   Update IDs: {} to {}\n", .{ depth.first_update_id, depth.final_update_id });

    // Apply to order book and display
    var book = orderbook.OrderBook.init(depth.symbol);
    try binance.DepthUpdate.applyToBook(depth_msg, &book);

    if (book.getBestBid()) |bid| {
        std.debug.print("   Best Bid: {} @ {}\n", .{ bid.price, bid.quantity });
    }
    if (book.getBestAsk()) |ask| {
        std.debug.print("   Best Ask: {} @ {}\n", .{ ask.price, ask.quantity });
    }
    if (book.getMidPrice()) |mid| {
        std.debug.print("   Mid Price: {}\n", .{mid});
    }
    if (book.getSpreadBps()) |spread| {
        std.debug.print("   Spread (bps): {}\n", .{spread});
    }

    std.debug.print("\n", .{});

    // Example 2: Parse trade message
    std.debug.print("2. Trade Message\n", .{});
    const trade_msg =
        \\{"e":"trade","E":1699999999000,"s":"ETHUSDT","t":12345,"p":"2500.50","q":"10.5","T":1699999999000,"m":true}
    ;

    std.debug.print("   Parsing: {s}\n", .{trade_msg});

    const trade = binance.Trade.parse(allocator, trade_msg) catch |err| {
        std.debug.print("   Error parsing trade: {}\n", .{err});
        return;
    };
    defer allocator.free(trade.symbol);

    std.debug.print("   Symbol: {s}\n", .{trade.symbol});
    std.debug.print("   Trade ID: {}\n", .{trade.trade_id});
    std.debug.print("   Price: {}\n", .{trade.price});
    std.debug.print("   Quantity: {}\n", .{trade.quantity});
    std.debug.print("   Buyer Maker: {}\n", .{trade.is_buyer_maker});
    std.debug.print("   Timestamp: {}\n", .{trade.timestamp});

    std.debug.print("\n", .{});

    // Example 3: Process multiple messages
    std.debug.print("3. Processing Multiple Messages\n", .{});

    const messages = [_][]const u8{
        \\{"e":"trade","E":1699999999000,"s":"BTCUSDT","t":10000,"p":"49999.00","q":"0.5","T":1699999999000,"m":false}
        ,
        \\{"e":"trade","E":1699999999100,"s":"BTCUSDT","t":10001,"p":"50001.00","q":"1.2","T":1699999999100,"m":true}
        ,
        \\{"e":"trade","E":1699999999200,"s":"BTCUSDT","t":10002,"p":"50000.50","q":"2.3","T":1699999999200,"m":true}
        ,
    };

    var total_volume: f64 = 0.0;
    var trade_count: u32 = 0;

    for (messages) |msg| {
        const t = binance.Trade.parse(allocator, msg) catch continue;
        defer allocator.free(t.symbol);

        total_volume += t.quantity;
        trade_count += 1;

        std.debug.print("   Trade #{}: {s} {} @ {}\n", .{ trade_count, t.symbol, t.quantity, t.price });
    }

    std.debug.print("\n   Total Trades: {}\n", .{trade_count});
    std.debug.print("   Total Volume: {}\n", .{total_volume});
    std.debug.print("   Average Trade Size: {}\n", .{total_volume / @as(f64, @floatFromInt(trade_count))});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
