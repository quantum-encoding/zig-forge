const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const hft_system = @import("hft_system.zig");
const order_book = @import("order_book_v2.zig");
const network = @import("network.zig");

/// C-compatible structures for FFI
pub const CMarketTick = extern struct {
    symbol_ptr: [*c]const u8,
    symbol_len: u32,
    bid_value: i128,
    ask_value: i128,
    bid_size_value: i128,
    ask_size_value: i128,
    timestamp: i64,
    sequence: u64,
};

pub const CSignal = extern struct {
    symbol_ptr: [*c]const u8,
    symbol_len: u32,
    action: u32, // 0=hold, 1=buy, 2=sell
    confidence: f32,
    target_price_value: i128,
    quantity_value: i128,
    timestamp: i64,
};

pub const CSystemStats = extern struct {
    ticks_processed: u64,
    signals_generated: u64,
    orders_sent: u64,
    trades_executed: u64,
    avg_latency_us: u64,
    peak_latency_us: u64,
};

/// Global HFT system instance
var g_hft_system: ?*hft_system.HFTSystem = null;
var g_allocator: ?std.mem.Allocator = null;

// Lock-free signal queue for C API consumers
var g_signal_queue: ?network.LockFreeQueue(CSignal, 1024) = null;

/// Initialize the HFT system
export fn hft_init() callconv(.c) i32 {
    const allocator = std.heap.c_allocator;
    g_allocator = allocator;
    
    const config = hft_system.HFTSystem.SystemConfig{
        .max_order_rate = 10000,
        .max_message_rate = 100000,
        .latency_threshold_us = 100,
        .tick_buffer_size = 100000,
        .enable_logging = false,
    };
    
    const hft_ptr = allocator.create(hft_system.HFTSystem) catch return -1;
    hft_ptr.* = hft_system.HFTSystem.init(allocator, config) catch return -2;
    
    // Add default strategy
    const strategy_params = hft_system.Strategy.StrategyParams{
        .max_position = Decimal.fromInt(1000),
        .max_spread = Decimal.fromFloat(0.50),
        .min_edge = Decimal.fromFloat(0.05),
        .tick_window = 100,
    };
    hft_ptr.addStrategy(hft_system.Strategy.init("C_API_Strategy", strategy_params)) catch return -3;
    
    g_hft_system = hft_ptr;

    // Initialize signal queue
    g_signal_queue = network.LockFreeQueue(CSignal, 1024){};

    return 0;
}

/// Process a market tick
export fn hft_process_tick(tick: *const CMarketTick) callconv(.c) i32 {
    const hft = g_hft_system orelse return -1;
    
    // Convert C tick to Zig tick
    const symbol_slice = tick.symbol_ptr[0..tick.symbol_len];
    const zig_tick = hft_system.MarketTick{
        .symbol = symbol_slice,
        .bid = Decimal{ .value = tick.bid_value },
        .ask = Decimal{ .value = tick.ask_value },
        .bid_size = Decimal{ .value = tick.bid_size_value },
        .ask_size = Decimal{ .value = tick.ask_size_value },
        .timestamp = tick.timestamp,
        .sequence = tick.sequence,
    };
    
    hft.processTick(zig_tick) catch return -2;
    return 0;
}

/// Get the next signal if available
export fn hft_get_next_signal(signal_out: *CSignal) callconv(.c) i32 {
    const queue = g_signal_queue orelse return -1;

    // Try to dequeue a signal
    if (queue.dequeue()) |signal| {
        signal_out.* = signal;
        return 1; // Signal available
    }

    return 0; // No signal available
}

/// Get system statistics
export fn hft_get_stats(stats_out: *CSystemStats) callconv(.c) i32 {
    const hft = g_hft_system orelse return -1;
    
    stats_out.ticks_processed = hft.metrics.ticks_processed;
    stats_out.signals_generated = hft.metrics.signals_generated;
    stats_out.orders_sent = hft.metrics.orders_sent;
    stats_out.trades_executed = hft.metrics.trades_executed;
    stats_out.avg_latency_us = hft.metrics.avg_latency_us;
    stats_out.peak_latency_us = hft.metrics.peak_latency_us;
    
    return 0;
}

/// Cleanup the HFT system
export fn hft_cleanup() callconv(.c) void {
    if (g_hft_system) |hft| {
        hft.deinit();
        if (g_allocator) |allocator| {
            allocator.destroy(hft);
        }
        g_hft_system = null;
        g_allocator = null;
    }
}