//! ML-DSA-65 Performance Benchmarks
//!
//! Measures KeyGen, Sign, and Verify operations against FIPS 204 specification.

const std = @import("std");
const ml_dsa = @import("ml_dsa_complete.zig");

const c = @cImport({
    @cInclude("time.h");
});

fn getTimeNs() i128 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + @as(i128, ts.tv_nsec);
}

fn formatTime(ns: u64) void {
    const writer = std.io.getStdOut().writer();
    if (ns >= 1_000_000_000) {
        writer.print("{d:.2} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch {};
    } else if (ns >= 1_000_000) {
        writer.print("{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch {};
    } else if (ns >= 1_000) {
        writer.print("{d:.2} µs", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch {};
    } else {
        writer.print("{d} ns", .{ns}) catch {};
    }
}

fn benchmarkKeyGen(iterations: usize) !void {
    const stdout = std.io.getStdOut().writer();

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |_| {
        const start = getTimeNs();
        _ = ml_dsa.keyGen(null);
        const elapsed: u64 = @intCast(getTimeNs() - start);

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;

    try stdout.print("  KeyGen:\n", .{});
    try stdout.print("    Average: ", .{});
    formatTime(avg_ns);
    try stdout.print("\n    Min:     ", .{});
    formatTime(min_ns);
    try stdout.print("\n    Max:     ", .{});
    formatTime(max_ns);
    try stdout.print("\n    Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns))});
}

fn benchmarkSign(iterations: usize) !void {
    const stdout = std.io.getStdOut().writer();

    const keypair = ml_dsa.keyGen(null);
    const msg = "Benchmark message for ML-DSA-65 signing operation";

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var reject_count: usize = 0;

    for (0..iterations) |_| {
        const start = getTimeNs();
        if (ml_dsa.sign(&keypair.sk, msg, true)) |_| {
            const elapsed: u64 = @intCast(getTimeNs() - start);
            total_ns += elapsed;
            min_ns = @min(min_ns, elapsed);
            max_ns = @max(max_ns, elapsed);
        } else {
            reject_count += 1;
        }
    }

    const successful = iterations - reject_count;
    const avg_ns = if (successful > 0) total_ns / successful else 0;

    try stdout.print("  Sign (randomized):\n", .{});
    try stdout.print("    Average: ", .{});
    formatTime(avg_ns);
    try stdout.print("\n    Min:     ", .{});
    formatTime(min_ns);
    try stdout.print("\n    Max:     ", .{});
    formatTime(max_ns);
    try stdout.print("\n    Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns))});

    if (reject_count > 0) {
        try stdout.print("    Rejects: {d} ({d:.1}%)\n", .{
            reject_count,
            @as(f64, @floatFromInt(reject_count)) * 100.0 / @as(f64, @floatFromInt(iterations)),
        });
    }
}

fn benchmarkVerify(iterations: usize) !void {
    const stdout = std.io.getStdOut().writer();

    const keypair = ml_dsa.keyGen(null);
    const msg = "Benchmark message for ML-DSA-65 verification";
    const sig = ml_dsa.sign(&keypair.sk, msg, false) orelse return error.SigningFailed;

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |_| {
        const start = getTimeNs();
        const valid = ml_dsa.verify(&keypair.pk, msg, &sig);
        const elapsed: u64 = @intCast(getTimeNs() - start);

        if (!valid) {
            try stdout.print("ERROR: Verification failed!\n", .{});
            return error.VerificationFailed;
        }

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;

    try stdout.print("  Verify:\n", .{});
    try stdout.print("    Average: ", .{});
    formatTime(avg_ns);
    try stdout.print("\n    Min:     ", .{});
    formatTime(min_ns);
    try stdout.print("\n    Max:     ", .{});
    formatTime(max_ns);
    try stdout.print("\n    Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns))});
}

fn benchmarkRoundTrip(iterations: usize) !void {
    const stdout = std.io.getStdOut().writer();

    var total_ns: u64 = 0;

    for (0..iterations) |i| {
        // Unique message per iteration
        var msg_buf: [64]u8 = undefined;
        const msg_len = std.fmt.bufPrint(&msg_buf, "Message {d} for round-trip benchmark", .{i}) catch 32;
        const msg = msg_buf[0..msg_len];

        const start = getTimeNs();

        const keypair = ml_dsa.keyGen(null);
        const sig = ml_dsa.sign(&keypair.sk, msg, false) orelse continue;
        const valid = ml_dsa.verify(&keypair.pk, msg, &sig);

        const elapsed: u64 = @intCast(getTimeNs() - start);

        if (!valid) {
            try stdout.print("ERROR: Round-trip verification failed!\n", .{});
            return error.VerificationFailed;
        }

        total_ns += elapsed;
    }

    const avg_ns = total_ns / iterations;

    try stdout.print("  Full Round-Trip (KeyGen + Sign + Verify):\n", .{});
    try stdout.print("    Average: ", .{});
    formatTime(avg_ns);
    try stdout.print("\n    Ops/sec: {d:.0}\n", .{1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns))});
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n", .{});
    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║         ML-DSA-65 (FIPS 204) Performance Benchmarks          ║\n", .{});
    try stdout.print("║                   Security Level 3 (192-bit)                 ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("\n", .{});

    try stdout.print("Algorithm Parameters:\n", .{});
    try stdout.print("  q = {d} (prime modulus)\n", .{ml_dsa.Q});
    try stdout.print("  n = {d} (polynomial degree)\n", .{ml_dsa.N});
    try stdout.print("  k = {d}, l = {d} (matrix dimensions)\n", .{ ml_dsa.K, ml_dsa.L });
    try stdout.print("  η = {d} (secret key bound)\n", .{ml_dsa.ETA});
    try stdout.print("  γ1 = {d} (mask bound)\n", .{ml_dsa.GAMMA1});
    try stdout.print("  γ2 = {d} (low-order range)\n", .{ml_dsa.GAMMA2});
    try stdout.print("  τ = {d} (challenge weight)\n", .{ml_dsa.TAU});
    try stdout.print("  β = {d} (signature bound)\n", .{ml_dsa.BETA});
    try stdout.print("  ω = {d} (max hint weight)\n", .{ml_dsa.OMEGA});
    try stdout.print("\n", .{});

    try stdout.print("Key/Signature Sizes:\n", .{});
    try stdout.print("  Public Key:  {d} bytes\n", .{ml_dsa.PUBLIC_KEY_SIZE});
    try stdout.print("  Secret Key:  {d} bytes\n", .{ml_dsa.SECRET_KEY_SIZE});
    try stdout.print("  Signature:   {d} bytes\n", .{ml_dsa.SIGNATURE_SIZE});
    try stdout.print("\n", .{});

    const warmup = 10;
    const iterations = 100;

    try stdout.print("Warming up ({d} iterations)...\n", .{warmup});
    for (0..warmup) |_| {
        const kp = ml_dsa.keyGen(null);
        if (ml_dsa.sign(&kp.sk, "warmup", false)) |sig| {
            _ = ml_dsa.verify(&kp.pk, "warmup", &sig);
        }
    }

    try stdout.print("\nBenchmarking ({d} iterations each):\n\n", .{iterations});

    try benchmarkKeyGen(iterations);
    try stdout.print("\n", .{});

    try benchmarkSign(iterations);
    try stdout.print("\n", .{});

    try benchmarkVerify(iterations);
    try stdout.print("\n", .{});

    try benchmarkRoundTrip(iterations);
    try stdout.print("\n", .{});

    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("Comparison Notes:\n", .{});
    try stdout.print("  • Ed25519:  ~60µs sign, ~200µs verify (classical)\n", .{});
    try stdout.print("  • ML-DSA-65 provides 192-bit post-quantum security\n", .{});
    try stdout.print("  • Signature 3309 bytes vs Ed25519 64 bytes (~52x larger)\n", .{});
    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
}
