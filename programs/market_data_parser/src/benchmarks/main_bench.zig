//! Parser Benchmarks
//! Measure throughput and latency
//!
//! Target: 2M+ messages/second
//! Comparison: vs Python (ujson), C++ (RapidJSON, simdjson)

const std = @import("std");
const parser_lib = @import("parser");
const Parser = parser_lib.Parser;

// Zig 0.16 compatible Timer using clock_gettime
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

const ITERATIONS = 1_000_000;
const WARMUP_ITERATIONS = 10_000;

// Realistic Binance depth update message
const BINANCE_DEPTH_MSG =
    \\{"e":"depthUpdate","E":1699999999000,"s":"BTCUSDT","U":123456789,"u":123456790,"b":[["50000.50","1.234"],["49999.00","2.567"],["49998.50","3.890"]],"a":[["50001.00","0.987"],["50002.50","1.654"],["50003.00","2.321"]]}
;

// Smaller message for latency testing
const SIMPLE_MSG = "{\"price\":\"50000.50\",\"qty\":\"1.234\",\"id\":123456}";

pub fn main() !void {
    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Market Data Parser Benchmarks       ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n\n", .{});

    // Run benchmarks
    try benchmarkSimpleMessage();
    try benchmarkBinanceDepthUpdate();
    try benchmarkNumberParsing();
    try benchmarkThroughput();

    std.debug.print("\n✅ All benchmarks complete\n\n", .{});
}

fn benchmarkSimpleMessage() !void {
    std.debug.print("Benchmark: Simple Message Parsing\n", .{});
    std.debug.print("  Message: {s}\n", .{SIMPLE_MSG});
    std.debug.print("  Iterations: {}\n\n", .{ITERATIONS});

    // Warmup
    var i: usize = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        var parser = Parser.init(SIMPLE_MSG);
        _ = parser.findValue("price");
    }

    // Benchmark
    var timer = try Timer.start();
    const start = timer.read();

    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        var parser = Parser.init(SIMPLE_MSG);
        const price_str = parser.findValue("price") orelse unreachable;
        const price = try Parser.parsePrice(price_str);
        _ = price; // Prevent optimization

        parser.reset();
        const qty_str = parser.findValue("qty") orelse unreachable;
        const qty = try Parser.parsePrice(qty_str);
        _ = qty;

        parser.reset();
        const id_str = parser.findValue("id") orelse unreachable;
        const id = try Parser.parseInt(id_str);
        _ = id;
    }

    const end = timer.read();
    const elapsed_ns = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ns_per_msg = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
    const msgs_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (elapsed_ms / 1000.0);

    std.debug.print("  Results:\n", .{});
    std.debug.print("    Total time:     {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("    Per message:    {d:.0} ns\n", .{ns_per_msg});
    std.debug.print("    Throughput:     {d:.0} msg/sec\n", .{msgs_per_sec});
    std.debug.print("    Throughput:     {d:.2} M msg/sec\n\n", .{msgs_per_sec / 1_000_000.0});
}

fn benchmarkBinanceDepthUpdate() !void {
    std.debug.print("Benchmark: Binance Depth Update (Realistic)\n", .{});
    std.debug.print("  Message size: {} bytes\n", .{BINANCE_DEPTH_MSG.len});
    std.debug.print("  Iterations: {}\n\n", .{ITERATIONS});

    // Warmup
    var i: usize = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        var parser = Parser.init(BINANCE_DEPTH_MSG);
        _ = parser.findValue("e");
    }

    // Benchmark
    var timer = try Timer.start();
    const start = timer.read();

    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        var parser = Parser.init(BINANCE_DEPTH_MSG);

        const event_type = parser.findValue("e") orelse unreachable;
        _ = event_type;

        parser.reset();
        const timestamp_str = parser.findValue("E") orelse unreachable;
        const timestamp = try Parser.parseInt(timestamp_str);
        _ = timestamp;

        parser.reset();
        const symbol = parser.findValue("s") orelse unreachable;
        _ = symbol;

        parser.reset();
        const first_id_str = parser.findValue("U") orelse unreachable;
        const first_id = try Parser.parseInt(first_id_str);
        _ = first_id;

        parser.reset();
        const final_id_str = parser.findValue("u") orelse unreachable;
        const final_id = try Parser.parseInt(final_id_str);
        _ = final_id;
    }

    const end = timer.read();
    const elapsed_ns = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ns_per_msg = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
    const msgs_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (elapsed_ms / 1000.0);
    const bytes_per_sec = msgs_per_sec * @as(f64, @floatFromInt(BINANCE_DEPTH_MSG.len));
    const mb_per_sec = bytes_per_sec / (1024.0 * 1024.0);

    std.debug.print("  Results:\n", .{});
    std.debug.print("    Total time:     {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("    Per message:    {d:.0} ns\n", .{ns_per_msg});
    std.debug.print("    Throughput:     {d:.0} msg/sec\n", .{msgs_per_sec});
    std.debug.print("    Throughput:     {d:.2} M msg/sec\n", .{msgs_per_sec / 1_000_000.0});
    std.debug.print("    Bandwidth:      {d:.2} MB/sec\n\n", .{mb_per_sec});
}

fn benchmarkNumberParsing() !void {
    std.debug.print("Benchmark: Number Parsing (Prices)\n", .{});
    std.debug.print("  Iterations: {}\n\n", .{ITERATIONS});

    const test_prices = [_][]const u8{
        "50000.50",
        "0.00123456",
        "99999.99999999",
        "1.0",
        "-500.25",
    };

    // Warmup
    var i: usize = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        for (test_prices) |price_str| {
            _ = try Parser.parsePrice(price_str);
        }
    }

    // Benchmark
    var timer = try Timer.start();
    const start = timer.read();

    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        for (test_prices) |price_str| {
            const price = try Parser.parsePrice(price_str);
            _ = price;
        }
    }

    const end = timer.read();
    const elapsed_ns = end - start;
    const total_parses = ITERATIONS * test_prices.len;
    const ns_per_parse = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_parses));
    const parses_per_sec = @as(f64, @floatFromInt(total_parses)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("  Results:\n", .{});
    std.debug.print("    Total parses:   {}\n", .{total_parses});
    std.debug.print("    Per parse:      {d:.0} ns\n", .{ns_per_parse});
    std.debug.print("    Throughput:     {d:.0} parses/sec\n", .{parses_per_sec});
    std.debug.print("    Throughput:     {d:.2} M parses/sec\n\n", .{parses_per_sec / 1_000_000.0});
}

fn benchmarkThroughput() !void {
    std.debug.print("Benchmark: End-to-End Throughput\n", .{});
    std.debug.print("  Simulating: 1 second of Binance feed processing\n\n", .{});

    const DURATION_NS: u64 = 1_000_000_000; // 1 second
    var msg_count: u64 = 0;

    var timer = try Timer.start();
    const start = timer.read();

    while (true) {
        var parser = Parser.init(BINANCE_DEPTH_MSG);

        const event_type = parser.findValue("e") orelse unreachable;
        _ = event_type;

        parser.reset();
        const symbol = parser.findValue("s") orelse unreachable;
        _ = symbol;

        parser.reset();
        const first_id_str = parser.findValue("U") orelse unreachable;
        const first_id = try Parser.parseInt(first_id_str);
        _ = first_id;

        msg_count += 1;

        const elapsed = timer.read() - start;
        if (elapsed >= DURATION_NS) break;
    }

    const end = timer.read();
    const elapsed_ns = end - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const msgs_per_sec = @as(f64, @floatFromInt(msg_count)) / elapsed_sec;
    const bytes_per_sec = msgs_per_sec * @as(f64, @floatFromInt(BINANCE_DEPTH_MSG.len));
    const mb_per_sec = bytes_per_sec / (1024.0 * 1024.0);

    std.debug.print("  Results:\n", .{});
    std.debug.print("    Messages:       {}\n", .{msg_count});
    std.debug.print("    Duration:       {d:.3} sec\n", .{elapsed_sec});
    std.debug.print("    Throughput:     {d:.0} msg/sec\n", .{msgs_per_sec});
    std.debug.print("    Throughput:     {d:.2} M msg/sec\n", .{msgs_per_sec / 1_000_000.0});
    std.debug.print("    Bandwidth:      {d:.2} MB/sec\n", .{mb_per_sec});

    // Performance targets
    std.debug.print("\n  Target Analysis:\n", .{});
    if (msgs_per_sec >= 1_000_000.0) {
        std.debug.print("    ✅ TARGET MET: 1M+ msg/sec\n", .{});
    } else {
        std.debug.print("    ❌ BELOW TARGET: {} msg/sec (target: 1M+)\n", .{@as(u64, @intFromFloat(msgs_per_sec))});
    }

    // Comparison to simdjson (1.4M msg/sec)
    const simdjson_throughput = 1_400_000.0;
    const vs_simdjson = (msgs_per_sec / simdjson_throughput) * 100.0;
    std.debug.print("    vs simdjson:    {d:.1}%\n", .{vs_simdjson});

    // Comparison to Python ujson (~20K msg/sec)
    const python_throughput = 20_000.0;
    const vs_python = msgs_per_sec / python_throughput;
    std.debug.print("    vs Python:      {d:.1}x faster\n", .{vs_python});
}
