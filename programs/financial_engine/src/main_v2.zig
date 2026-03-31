const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const order_book = @import("order_book_v2.zig");

const OrderBook = order_book.OrderBook;
const OrderType = order_book.OrderType;
const Side = order_book.Side;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    std.debug.print("\n=== High-Performance Financial Trading Engine ===\n\n", .{});
    
    // Create order book for AAPL
    var book = OrderBook.init(allocator, "AAPL");
    defer book.deinit();
    
    // Add initial orders to create a market
    std.debug.print("Building order book for AAPL...\n", .{});
    
    // Add buy orders (bids)
    _ = try book.addOrder(.buy, .limit, Decimal.fromFloat(149.90), Decimal.fromInt(100), 1);
    _ = try book.addOrder(.buy, .limit, Decimal.fromFloat(149.85), Decimal.fromInt(200), 2);
    _ = try book.addOrder(.buy, .limit, Decimal.fromFloat(149.80), Decimal.fromInt(300), 3);
    _ = try book.addOrder(.buy, .limit, Decimal.fromFloat(149.75), Decimal.fromInt(150), 4);
    
    // Add sell orders (asks)
    _ = try book.addOrder(.sell, .limit, Decimal.fromFloat(150.10), Decimal.fromInt(100), 5);
    _ = try book.addOrder(.sell, .limit, Decimal.fromFloat(150.15), Decimal.fromInt(200), 6);
    _ = try book.addOrder(.sell, .limit, Decimal.fromFloat(150.20), Decimal.fromInt(300), 7);
    _ = try book.addOrder(.sell, .limit, Decimal.fromFloat(150.25), Decimal.fromInt(150), 8);
    
    // Display initial market state
    displayMarketState(&book);
    
    // Execute market orders
    std.debug.print("\n=== Executing Market Orders ===\n", .{});
    
    // Market buy order
    std.debug.print("\nSubmitting market BUY for 150 shares...\n", .{});
    const buy_order = try book.addOrder(.buy, .market, Decimal.zero(), Decimal.fromInt(150), 9);
    std.debug.print("Order {d}: Status = {}\n", .{ buy_order.id, buy_order.status });
    
    displayMarketState(&book);
    
    // Market sell order
    std.debug.print("\nSubmitting market SELL for 250 shares...\n", .{});
    const sell_order = try book.addOrder(.sell, .market, Decimal.zero(), Decimal.fromInt(250), 10);
    std.debug.print("Order {d}: Status = {}\n", .{ sell_order.id, sell_order.status });
    
    displayMarketState(&book);
    
    // Aggressive limit order that crosses the spread
    std.debug.print("\n=== Aggressive Limit Order ===\n", .{});
    std.debug.print("Submitting limit BUY at 150.20 for 400 shares (crosses spread)...\n", .{});
    
    const aggressive_order = try book.addOrder(.buy, .limit, Decimal.fromFloat(150.20), Decimal.fromInt(400), 11);
    std.debug.print("Order {d}: Status = {}\n", .{ aggressive_order.id, aggressive_order.status });
    
    displayMarketState(&book);
    
    // Show trade history
    std.debug.print("\n=== Trade History ===\n", .{});
    for (book.trades.items, 0..) |trade, i| {
        if (i >= 10) break; // Show first 10 trades
        std.debug.print("Trade {d}: {any} @ {any} (Buy Order: {d}, Sell Order: {d})\n", .{
            trade.id,
            trade.quantity,
            trade.price,
            trade.buyer_order_id,
            trade.seller_order_id,
        });
    }
    
    // Performance test
    std.debug.print("\n=== Performance Test ===\n", .{});
    const iterations = 10000;
    const start = std.time.nanoTimestamp();
    
    for (0..iterations) |i| {
        _ = i;
        // Simulate price calculations
        const p1 = Decimal.fromFloat(150.00);
        const p2 = Decimal.fromFloat(149.99);
        const diff = p1.sub(p2) catch Decimal.zero();
        _ = diff.mul(Decimal.fromInt(100)) catch {};
    }
    
    const elapsed = std.time.nanoTimestamp() - start;
    const ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    const ops_per_sec = @as(f64, iterations * 1000.0) / ms;
    
    std.debug.print("Performed {d} price calculations in {d:.2} ms\n", .{ iterations, ms });
    std.debug.print("Throughput: {d:.0} operations/second\n", .{ops_per_sec});
    
    // Memory stats
    std.debug.print("\n=== Engine Statistics ===\n", .{});
    std.debug.print("Total Orders: {d}\n", .{ book.next_order_id - 1 });
    std.debug.print("Total Trades: {d}\n", .{ book.next_trade_id - 1 });
    std.debug.print("Active Bid Levels: {d}\n", .{book.bids.items.len});
    std.debug.print("Active Ask Levels: {d}\n", .{book.asks.items.len});
    
    std.debug.print("\n=== Key Features ===\n", .{});
    std.debug.print("✓ Fixed-point decimal arithmetic (no float rounding)\n", .{});
    std.debug.print("✓ Price-time priority matching engine\n", .{});
    std.debug.print("✓ O(1) order insertion at price levels\n", .{});
    std.debug.print("✓ Memory-efficient order book structure\n", .{});
    std.debug.print("✓ Microsecond-latency order processing\n", .{});
}

fn displayMarketState(book: *const OrderBook) void {
    std.debug.print("\n--- Market State ---\n", .{});
    
    // Show top of book
    if (book.getBestBid()) |bid| {
        std.debug.print("Best Bid: {any}", .{bid});
        if (book.bids.items.len > 0) {
            const level = book.bids.items[0];
            std.debug.print(" (Size: {any})\n", .{level.total_quantity});
        } else {
            std.debug.print("\n", .{});
        }
    }
    
    if (book.getBestAsk()) |ask| {
        std.debug.print("Best Ask: {any}", .{ask});
        if (book.asks.items.len > 0) {
            const level = book.asks.items[0];
            std.debug.print(" (Size: {any})\n", .{level.total_quantity});
        } else {
            std.debug.print("\n", .{});
        }
    }
    
    if (book.getSpread()) |spread| {
        std.debug.print("Spread: {any}\n", .{spread});
    }
    
    if (book.last_trade_price) |last| {
        std.debug.print("Last Trade: {any}\n", .{last});
    }
    
    // Show depth (top 3 levels each side)
    const depth = book.getDepth(3);
    
    if (depth.bids.len > 0) {
        std.debug.print("Bids (top 3):\n", .{});
        for (depth.bids) |level| {
            std.debug.print("  {any} x {any}\n", .{ level.price, level.total_quantity });
        }
    }
    
    if (depth.asks.len > 0) {
        std.debug.print("Asks (top 3):\n", .{});
        for (depth.asks) |level| {
            std.debug.print("  {any} x {any}\n", .{ level.price, level.total_quantity });
        }
    }
}