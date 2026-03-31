//! Example: Order book reconstruction and querying
//! Demonstrates adding orders and querying best bid/ask, spread, and depth

const std = @import("std");
const parser = @import("parser");
const orderbook = parser.orderbook;

pub fn main() !void {
    std.debug.print("=== Order Book Demo ===\n\n", .{});

    // Create order book for BTC/USDT
    var book = orderbook.OrderBook.init("BTCUSDT");

    std.debug.print("1. Creating Order Book for BTCUSDT\n", .{});
    std.debug.print("   Initial state: {} bids, {} asks\n\n", .{ book.bid_count, book.ask_count });

    // Add bids (buy orders, sorted descending by price)
    std.debug.print("2. Adding Bid Orders (Buy Side)\n", .{});
    const bids = [_][2]f64{
        .{ 50000.00, 1.5 },
        .{ 49999.00, 2.0 },
        .{ 49998.50, 0.75 },
        .{ 49997.00, 3.25 },
        .{ 49995.00, 1.1 },
    };

    for (bids) |bid| {
        book.updateBid(bid[0], bid[1]);
        std.debug.print("   Added bid: {} BTC @ {}\n", .{ bid[1], bid[0] });
    }

    std.debug.print("\n3. Adding Ask Orders (Sell Side)\n", .{});
    const asks = [_][2]f64{
        .{ 50001.00, 0.5 },
        .{ 50002.00, 1.0 },
        .{ 50003.50, 2.5 },
        .{ 50005.00, 0.8 },
        .{ 50010.00, 1.2 },
    };

    for (asks) |ask| {
        book.updateAsk(ask[0], ask[1]);
        std.debug.print("   Added ask: {} BTC @ {}\n", .{ ask[1], ask[0] });
    }

    std.debug.print("\n4. Order Book State\n", .{});
    std.debug.print("   Total bids: {}\n", .{book.bid_count});
    std.debug.print("   Total asks: {}\n", .{book.ask_count});

    // Query best bid/ask
    std.debug.print("\n5. Best Bid/Ask\n", .{});
    if (book.getBestBid()) |bid| {
        std.debug.print("   Best Bid: {} BTC @ {}\n", .{ bid.quantity, bid.price });
    }
    if (book.getBestAsk()) |ask| {
        std.debug.print("   Best Ask: {} BTC @ {}\n", .{ ask.quantity, ask.price });
    }

    // Mid price
    std.debug.print("\n6. Derived Metrics\n", .{});
    if (book.getMidPrice()) |mid| {
        std.debug.print("   Mid Price: {}\n", .{mid});
    }

    if (book.getSpreadBps()) |spread| {
        std.debug.print("   Spread (bps): {}\n", .{spread});
    }

    // Display top 3 levels
    std.debug.print("\n7. Top 3 Price Levels\n", .{});
    std.debug.print("   Bids (Descending):\n", .{});
    const bid_limit = @min(3, book.bid_count);
    for (0..bid_limit) |i| {
        const bid = book.bids[i];
        std.debug.print("     L{}: {} BTC @ {} ({} orders)\n", .{ i + 1, bid.quantity, bid.price, bid.orders });
    }

    std.debug.print("   Asks (Ascending):\n", .{});
    const ask_limit = @min(3, book.ask_count);
    for (0..ask_limit) |i| {
        const ask = book.asks[i];
        std.debug.print("     L{}: {} BTC @ {} ({} orders)\n", .{ i + 1, ask.quantity, ask.price, ask.orders });
    }

    // Calculate total volume at each level
    std.debug.print("\n8. Cumulative Volume\n", .{});
    var bid_volume: f64 = 0.0;
    var ask_volume: f64 = 0.0;

    std.debug.print("   Cumulative Bid Volume:\n", .{});
    for (0..bid_limit) |i| {
        bid_volume += book.bids[i].quantity;
        std.debug.print("     L{}: {} BTC\n", .{ i + 1, bid_volume });
    }

    std.debug.print("   Cumulative Ask Volume:\n", .{});
    for (0..ask_limit) |i| {
        ask_volume += book.asks[i].quantity;
        std.debug.print("     L{}: {} BTC\n", .{ i + 1, ask_volume });
    }

    // Demonstrate updating an order
    std.debug.print("\n9. Updating an Order\n", .{});
    std.debug.print("   Updating bid 50000.00 from 1.5 to 2.5 BTC\n", .{});
    book.updateBid(50000.00, 2.5);

    if (book.getBestBid()) |bid| {
        std.debug.print("   New best bid: {} BTC @ {}\n", .{ bid.quantity, bid.price });
    }

    // Demonstrate removing an order
    std.debug.print("\n10. Removing an Order\n", .{});
    std.debug.print("   Removing ask 50005.00 (qty 0.8)\n", .{});
    book.updateAsk(50005.00, 0.0);
    std.debug.print("   Remaining asks: {}\n", .{book.ask_count});

    // Show final state
    std.debug.print("\n11. Final Order Book State\n", .{});
    std.debug.print("   Bids: {}, Asks: {}\n", .{ book.bid_count, book.ask_count });

    if (book.getBestBid()) |bid| {
        if (book.getBestAsk()) |ask| {
            const spread = ask.price - bid.price;
            std.debug.print("   Best Spread: {} ({} bps)\n", .{ spread, (spread / bid.price) * 10000.0 });
        }
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
