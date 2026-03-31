//! ═══════════════════════════════════════════════════════════════════════════
//! WARP GATE BENCHMARKS
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Run: zig build bench
//!
//! Measures:
//! • Warp code generation/parsing
//! • ChaCha20-Poly1305 encryption throughput
//! • UDP packet serialization
//! • File chunking overhead

const std = @import("std");
const warp_gate = @import("warp_gate");

const WarpCode = warp_gate.WarpCode;
const crypto = warp_gate.crypto;
const protocol = warp_gate.protocol;

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

    pub fn reset(self: *Timer) void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        self.start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    print("║              WARP GATE PERFORMANCE BENCHMARKS                ║\n", .{});
    print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    try benchWarpCode();
    try benchCrypto(allocator);
    try benchProtocol();

    print("\n✓ All benchmarks complete\n\n", .{});
}

fn benchWarpCode() !void {
    print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Warp Code Generation & Parsing                             │\n", .{});
    print("└─────────────────────────────────────────────────────────────┘\n", .{});

    const iterations: u64 = 100_000;

    // Benchmark generation
    var timer = Timer.start() catch unreachable;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const code = WarpCode.generate();
        std.mem.doNotOptimizeAway(&code);
    }
    const gen_ns = timer.read();
    const gen_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(gen_ns)) / 1e9);

    print("  Generate:     {d:.2} ops/sec ({d:.0} ns/op)\n", .{
        gen_ops_per_sec,
        @as(f64, @floatFromInt(gen_ns)) / @as(f64, @floatFromInt(iterations)),
    });

    // Benchmark parsing
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const code = WarpCode.parse("warp-729-alpha") catch unreachable;
        std.mem.doNotOptimizeAway(&code);
    }
    const parse_ns = timer.read();
    const parse_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(parse_ns)) / 1e9);

    print("  Parse:        {d:.2} ops/sec ({d:.0} ns/op)\n", .{
        parse_ops_per_sec,
        @as(f64, @floatFromInt(parse_ns)) / @as(f64, @floatFromInt(iterations)),
    });

    // Benchmark key derivation
    const code = WarpCode.generate();
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const key = code.deriveKey();
        std.mem.doNotOptimizeAway(&key);
    }
    const derive_ns = timer.read();
    const derive_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(derive_ns)) / 1e9);

    print("  Key derive:   {d:.2} ops/sec ({d:.0} ns/op)\n", .{
        derive_ops_per_sec,
        @as(f64, @floatFromInt(derive_ns)) / @as(f64, @floatFromInt(iterations)),
    });

    print("\n", .{});
}

fn benchCrypto(allocator: std.mem.Allocator) !void {
    print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    print("│ ChaCha20-Poly1305 Encryption                               │\n", .{});
    print("└─────────────────────────────────────────────────────────────┘\n", .{});

    const key = [_]u8{0x42} ** 32;
    const sizes = [_]usize{ 64, 1024, 16384, 65536 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, 0xAB);

        const iterations: u64 = if (size < 1024) 100_000 else if (size < 16384) 10_000 else 1000;

        // Encrypt benchmark
        var timer = Timer.start() catch unreachable;
        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            const encrypted = try crypto.encrypt(&key, data);
            allocator.free(encrypted);
        }
        const enc_ns = timer.read();

        const total_bytes = size * iterations;
        const enc_throughput = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(enc_ns)) / 1e9) / (1024 * 1024);

        print("  {d:>6} bytes: {d:>8.2} MB/s encrypt\n", .{ size, enc_throughput });
    }

    print("\n", .{});
}

fn benchProtocol() !void {
    print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Wire Protocol Serialization                                │\n", .{});
    print("└─────────────────────────────────────────────────────────────┘\n", .{});

    const iterations: u64 = 1_000_000;

    // Header serialization
    const header = protocol.Header{
        .msg_type = .file_chunk,
        .length = 65536,
    };

    var timer = Timer.start() catch unreachable;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const buf = header.serialize();
        std.mem.doNotOptimizeAway(&buf);
    }
    const ser_ns = timer.read();
    const ser_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(ser_ns)) / 1e9);

    print("  Header serialize:   {d:.2}M ops/sec\n", .{ser_ops_per_sec / 1e6});

    // Header deserialization
    const buf = header.serialize();
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const decoded = protocol.Header.deserialize(&buf) catch unreachable;
        std.mem.doNotOptimizeAway(&decoded);
    }
    const deser_ns = timer.read();
    const deser_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(deser_ns)) / 1e9);

    print("  Header deserialize: {d:.2}M ops/sec\n", .{deser_ops_per_sec / 1e6});

    print("\n", .{});
}

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
