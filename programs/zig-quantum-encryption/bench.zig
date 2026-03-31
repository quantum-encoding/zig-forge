//! ML-KEM Performance Benchmarks
//!
//! Run with: zig build bench
//!
//! Tests performance of:
//! - Key generation
//! - Encapsulation
//! - Decapsulation
//! - Full round-trip

const std = @import("std");
const pqc = @import("src/ml_kem_api.zig");
const hybrid = @import("src/hybrid.zig");

const ITERATIONS = 1000;

// Zig 0.16+ removed std.io, use posix directly
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

fn nanoTimestamp() i128 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, msg.ptr, msg.len);
}

pub fn main() !void {

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║         Quantum Vault ML-KEM-768 Benchmarks                ║\n", .{});
    print("║         FIPS 203 Post-Quantum Cryptography                 ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // Warmup
    print("Warming up...\n", .{});
    for (0..10) |_| {
        const kp = try pqc.keyGen768();
        const enc = try pqc.encaps768(&kp.ek);
        _ = pqc.decaps768(&kp.dk, &enc.c);
    }

    // Benchmark Key Generation
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ KeyGen (generating {d} key pairs)                          │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    var keygen_total: u64 = 0;
    var last_keypair: ?pqc.KeyPair768 = null;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const keypair = try pqc.keyGen768();
        const end = nanoTimestamp();
        keygen_total += @intCast(end - start);
        last_keypair = keypair;
    }

    const keygen_avg_ns = keygen_total / ITERATIONS;
    const keygen_avg_us = @as(f64, @floatFromInt(keygen_avg_ns)) / 1000.0;
    const keygen_avg_ms = keygen_avg_us / 1000.0;

    print("  Average: {d:.2} µs ({d:.3} ms)\n", .{ keygen_avg_us, keygen_avg_ms });
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(keygen_avg_ns))});

    // Benchmark Encapsulation
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Encaps (encapsulating {d} shared secrets)                  │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    const keypair = last_keypair.?;
    var encaps_total: u64 = 0;
    var last_encaps: ?pqc.EncapsResult768 = null;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const result = try pqc.encaps768(&keypair.ek);
        const end = nanoTimestamp();
        encaps_total += @intCast(end - start);
        last_encaps = result;
    }

    const encaps_avg_ns = encaps_total / ITERATIONS;
    const encaps_avg_us = @as(f64, @floatFromInt(encaps_avg_ns)) / 1000.0;
    const encaps_avg_ms = encaps_avg_us / 1000.0;

    print("  Average: {d:.2} µs ({d:.3} ms)\n", .{ encaps_avg_us, encaps_avg_ms });
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(encaps_avg_ns))});

    // Benchmark Decapsulation
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Decaps (decapsulating {d} ciphertexts)                     │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    const encaps_result = last_encaps.?;
    var decaps_total: u64 = 0;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const K = pqc.decaps768(&keypair.dk, &encaps_result.c);
        const end = nanoTimestamp();
        decaps_total += @intCast(end - start);
        _ = K;
    }

    const decaps_avg_ns = decaps_total / ITERATIONS;
    const decaps_avg_us = @as(f64, @floatFromInt(decaps_avg_ns)) / 1000.0;
    const decaps_avg_ms = decaps_avg_us / 1000.0;

    print("  Average: {d:.2} µs ({d:.3} ms)\n", .{ decaps_avg_us, decaps_avg_ms });
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(decaps_avg_ns))});

    // Summary
    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║                        Summary                             ║\n", .{});
    print("╠════════════════════════════════════════════════════════════╣\n", .{});
    print("║  Operation     │  Time (µs)  │  Time (ms)  │  Ops/sec     ║\n", .{});
    print("╠────────────────┼─────────────┼─────────────┼──────────────╣\n", .{});
    print("║  KeyGen        │  {d:9.2}  │  {d:9.3}  │  {d:10.0}  ║\n", .{
        keygen_avg_us,
        keygen_avg_ms,
        1_000_000_000.0 / @as(f64, @floatFromInt(keygen_avg_ns)),
    });
    print("║  Encaps        │  {d:9.2}  │  {d:9.3}  │  {d:10.0}  ║\n", .{
        encaps_avg_us,
        encaps_avg_ms,
        1_000_000_000.0 / @as(f64, @floatFromInt(encaps_avg_ns)),
    });
    print("║  Decaps        │  {d:9.2}  │  {d:9.3}  │  {d:10.0}  ║\n", .{
        decaps_avg_us,
        decaps_avg_ms,
        1_000_000_000.0 / @as(f64, @floatFromInt(decaps_avg_ns)),
    });
    print("╚════════════════════════════════════════════════════════════╝\n", .{});

    // Key sizes
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│                     Key Sizes                              │\n", .{});
    print("├────────────────────────────────────────────────────────────┤\n", .{});
    print("│  Encapsulation Key (public):    {d:5} bytes                │\n", .{@sizeOf(pqc.EncapsulationKey768)});
    print("│  Decapsulation Key (private):   {d:5} bytes                │\n", .{@sizeOf(pqc.DecapsulationKey768)});
    print("│  Ciphertext:                    {d:5} bytes                │\n", .{@sizeOf(pqc.Ciphertext768)});
    print("│  Shared Secret:                 {d:5} bytes                │\n", .{@sizeOf(pqc.SharedSecret)});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    // Verify correctness
    // ========================================================================
    // Hybrid ML-KEM-768 + X25519 Benchmarks
    // ========================================================================

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║      Hybrid ML-KEM-768 + X25519 Benchmarks                 ║\n", .{});
    print("║      Defense-in-Depth Post-Quantum + Classical            ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // Warmup hybrid
    for (0..10) |_| {
        const hkp = try hybrid.keyGen();
        const henc = try hybrid.encaps(&hkp.ek);
        _ = hybrid.decaps(&hkp.dk, &henc.ct);
    }

    // Benchmark Hybrid KeyGen
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Hybrid KeyGen ({d} iterations)                             │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    var hybrid_keygen_total: u64 = 0;
    var last_hybrid_kp: ?hybrid.HybridKeyPair = null;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const hkp = try hybrid.keyGen();
        const end = nanoTimestamp();
        hybrid_keygen_total += @intCast(end - start);
        last_hybrid_kp = hkp;
    }

    const hybrid_keygen_avg_ns = hybrid_keygen_total / ITERATIONS;
    const hybrid_keygen_avg_us = @as(f64, @floatFromInt(hybrid_keygen_avg_ns)) / 1000.0;
    print("  Average: {d:.2} µs\n", .{hybrid_keygen_avg_us});
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(hybrid_keygen_avg_ns))});

    // Benchmark Hybrid Encaps
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Hybrid Encaps ({d} iterations)                             │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    const hybrid_kp = last_hybrid_kp.?;
    var hybrid_encaps_total: u64 = 0;
    var last_hybrid_enc: ?hybrid.HybridEncapsResult = null;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const henc = try hybrid.encaps(&hybrid_kp.ek);
        const end = nanoTimestamp();
        hybrid_encaps_total += @intCast(end - start);
        last_hybrid_enc = henc;
    }

    const hybrid_encaps_avg_ns = hybrid_encaps_total / ITERATIONS;
    const hybrid_encaps_avg_us = @as(f64, @floatFromInt(hybrid_encaps_avg_ns)) / 1000.0;
    print("  Average: {d:.2} µs\n", .{hybrid_encaps_avg_us});
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(hybrid_encaps_avg_ns))});

    // Benchmark Hybrid Decaps
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│ Hybrid Decaps ({d} iterations)                             │\n", .{ITERATIONS});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    const hybrid_enc = last_hybrid_enc.?;
    var hybrid_decaps_total: u64 = 0;

    for (0..ITERATIONS) |_| {
        const start = nanoTimestamp();
        const hss = hybrid.decaps(&hybrid_kp.dk, &hybrid_enc.ct);
        const end = nanoTimestamp();
        hybrid_decaps_total += @intCast(end - start);
        _ = hss;
    }

    const hybrid_decaps_avg_ns = hybrid_decaps_total / ITERATIONS;
    const hybrid_decaps_avg_us = @as(f64, @floatFromInt(hybrid_decaps_avg_ns)) / 1000.0;
    print("  Average: {d:.2} µs\n", .{hybrid_decaps_avg_us});
    print("  Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(hybrid_decaps_avg_ns))});

    // Hybrid key sizes
    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│                  Hybrid Key Sizes                          │\n", .{});
    print("├────────────────────────────────────────────────────────────┤\n", .{});
    print("│  Hybrid Public Key:             {d:5} bytes                │\n", .{hybrid.HYBRID_EK_SIZE});
    print("│  Hybrid Secret Key:             {d:5} bytes                │\n", .{hybrid.HYBRID_DK_SIZE});
    print("│  Hybrid Ciphertext:             {d:5} bytes                │\n", .{hybrid.HYBRID_CT_SIZE});
    print("│  Shared Secret:                 {d:5} bytes                │\n", .{hybrid.SHARED_SECRET_SIZE});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    // ========================================================================
    // Correctness Checks
    // ========================================================================

    print("\n", .{});
    print("┌────────────────────────────────────────────────────────────┐\n", .{});
    print("│                  Correctness Checks                        │\n", .{});
    print("└────────────────────────────────────────────────────────────┘\n", .{});

    // ML-KEM correctness
    const fresh_keypair = try pqc.keyGen768();
    const fresh_encaps = try pqc.encaps768(&fresh_keypair.ek);
    const decapsulated_K = pqc.decaps768(&fresh_keypair.dk, &fresh_encaps.c);

    const mlkem_match = std.mem.eql(u8, &fresh_encaps.K, &decapsulated_K);
    if (mlkem_match) {
        print("  ✓ ML-KEM-768: secrets match\n", .{});
    } else {
        print("  ✗ ML-KEM-768: ERROR - secrets do not match!\n", .{});
    }

    // Hybrid correctness
    const fresh_hybrid_kp = try hybrid.keyGen();
    const fresh_hybrid_enc = try hybrid.encaps(&fresh_hybrid_kp.ek);
    const hybrid_dec_ss = hybrid.decaps(&fresh_hybrid_kp.dk, &fresh_hybrid_enc.ct);

    const hybrid_match = std.mem.eql(u8, &fresh_hybrid_enc.K, &hybrid_dec_ss);
    if (hybrid_match) {
        print("  ✓ Hybrid ML-KEM+X25519: secrets match\n", .{});
    } else {
        print("  ✗ Hybrid ML-KEM+X25519: ERROR - secrets do not match!\n", .{});
    }

    print("\n", .{});
}
