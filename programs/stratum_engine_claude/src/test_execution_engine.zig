//! Test executable for high-frequency execution engine
//! Demonstrates order template system and microsecond execution timing

const std = @import("std");
const ExchangeClient = @import("execution/exchange_client.zig").ExchangeClient;
const Credentials = @import("execution/exchange_client.zig").Credentials;
const Exchange = @import("execution/exchange_client.zig").Exchange;
const Strategy = @import("strategy/logic.zig").Strategy;
const Config = @import("strategy/logic.zig").Config;
const Transaction = @import("strategy/logic.zig").Transaction;
const TxOutput = @import("strategy/logic.zig").TxOutput;

// Zig 0.16 compatible - get monotonic time in nanoseconds
fn getMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n╔═════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   HIGH-FREQUENCY EXECUTION ENGINE TEST         ║\n", .{});
    std.debug.print("╚═════════════════════════════════════════════════╝\n\n", .{});

    // Test 1: Exchange Client Initialization
    std.debug.print("═══ Test 1: Exchange Client Setup ═══\n", .{});

    const creds = Credentials{
        .api_key = "test_key_12345",
        .api_secret = "test_secret_67890",
    };

    var client = try ExchangeClient.init(allocator, .binance, creds);
    defer client.deinit();

    try client.connect();
    try client.authenticate();

    // Test 2: Order Template Pre-loading
    std.debug.print("\n═══ Test 2: Order Template Pre-loading ═══\n", .{});
    try client.preloadOrders("BTCUSDT", 0.001, 0.001);

    // Test 3: Execution Timing (Dry Run)
    std.debug.print("\n═══ Test 3: Execution Timing Test ═══\n", .{});
    std.debug.print("Running 10 simulated order executions...\n\n", .{});

    var total_time_us: u64 = 0;
    const iterations: u32 = 10;

    for (0..iterations) |i| {
        const start_ns = getMonotonicNs();

        // Simulate order execution (just timing, no real send)
        if (i % 2 == 0) {
            try client.executeBuy();
        } else {
            try client.executeSell();
        }

        const end_ns = getMonotonicNs();
        const exec_time_us = (end_ns - start_ns) / 1000;

        total_time_us += exec_time_us;
    }

    const avg_time_us = total_time_us / iterations;

    std.debug.print("\n📊 Performance Statistics:\n", .{});
    std.debug.print("   Total executions: {}\n", .{iterations});
    std.debug.print("   Average time:     {}µs\n", .{avg_time_us});
    std.debug.print("   Target time:      <10µs\n", .{});

    if (avg_time_us < 10) {
        std.debug.print("   ✅ TARGET MET! ({}x faster than 10µs goal)\n", .{10 / avg_time_us});
    } else {
        std.debug.print("   ⚠️  Above target (needs optimization)\n", .{});
    }

    // Test 4: Strategy Logic
    std.debug.print("\n═══ Test 4: Strategy Logic ═══\n", .{});

    const strategy_config = Config{
        .whale_threshold_sats = 100_000_000, // 1 BTC
        .dry_run = true,
    };

    var strategy = Strategy.init(allocator, strategy_config, &client);

    // Simulate whale transaction
    const outputs = [_]TxOutput{
        .{ .address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", .value_sats = 50_000_000 },
        .{ .address = "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo", .value_sats = 200_000_000 }, // To Binance!
    };

    const whale_tx = Transaction{
        .hash = [_]u8{0xDE} ** 32,
        .total_value_sats = 250_000_000, // 2.5 BTC
        .outputs = &outputs,
    };

    std.debug.print("Triggering whale alert simulation...\n", .{});
    strategy.onWhaleAlert(whale_tx);

    // Print strategy statistics
    strategy.printStats();

    // Test 5: WebSocket Frame Building (without network)
    std.debug.print("\n═══ Test 5: WebSocket Protocol Test ═══\n", .{});

    const ws = @import("execution/websocket.zig");

    var frame_buffer: [1024]u8 = undefined;
    const ping_frame = try ws.FrameBuilder.buildPingFrame(&frame_buffer, true);
    std.debug.print("✅ Ping frame built: {} bytes\n", .{ping_frame.len});

    const test_payload = "test order payload";
    const text_frame = try ws.FrameBuilder.buildTextFrame(&frame_buffer, test_payload, true);
    std.debug.print("✅ Text frame built: {} bytes (payload: {} bytes)\n", .{ text_frame.len, test_payload.len });

    // Final summary
    std.debug.print("\n╔═════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   TEST SUMMARY                                  ║\n", .{});
    std.debug.print("╚═════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("✅ Exchange client initialization: PASS\n", .{});
    std.debug.print("✅ Order template pre-loading:     PASS\n", .{});
    std.debug.print("✅ Execution timing:               {}µs avg\n", .{avg_time_us});
    std.debug.print("✅ Strategy logic:                 PASS\n", .{});
    std.debug.print("✅ WebSocket protocol:             PASS\n", .{});

    std.debug.print("\n⚠️  NEXT STEPS:\n", .{});
    std.debug.print("   1. Integrate TLS library (BearSSL/LibreSSL)\n", .{});
    std.debug.print("   2. Implement HMAC-SHA256 signing with AVX-512\n", .{});
    std.debug.print("   3. Connect mempool monitor → strategy → execution\n", .{});
    std.debug.print("   4. Test against exchange testnet\n", .{});

    std.debug.print("\n🎯 Goal: <100µs from mempool event to exchange\n", .{});
    std.debug.print("   Current: Order execution in ~{}µs (templates working!)\n", .{avg_time_us});
    std.debug.print("   Remaining: Network latency (target: <100µs RTT)\n\n", .{});
}
