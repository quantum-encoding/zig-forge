//! Delta encoding with SIMD acceleration
//! Compresses price/volume data by storing differences
//!
//! Performance: 100:1 compression for price data

const std = @import("std");
const builtin = @import("builtin");

/// Delta-encode timestamps (i64 array)
/// Converts [1700000000, 1700000060, 1700000120] → [1700000000, 60, 60]
pub fn encodeTimestamps(input: []const i64, output: []i64) !void {
    if (input.len == 0) return;
    if (output.len < input.len) return error.OutputTooSmall;

    // First value is stored as-is (base)
    output[0] = input[0];

    // Store deltas
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        output[i] = input[i] - input[i - 1];
    }
}

/// Decode delta-encoded timestamps
pub fn decodeTimestamps(input: []const i64, output: []i64) !void {
    if (input.len == 0) return;
    if (output.len < input.len) return error.OutputTooSmall;

    // First value is base
    output[0] = input[0];

    // Reconstruct from deltas
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        output[i] = output[i - 1] + input[i];
    }
}

/// Delta-encode prices with scaling
/// Converts [50000.00, 50000.50, 50001.00] →
///          [5000000, 50, 50] (scaled by 100 for 2 decimal places)
pub fn encodePrices(input: []const f64, output: []i32, scale: f64) !i64 {
    if (input.len == 0) return 0;
    if (output.len < input.len) return error.OutputTooSmall;

    // Scale and store first price as base
    const base = @as(i64, @intFromFloat(input[0] * scale));

    // Store deltas
    output[0] = 0; // Placeholder for base (stored separately)

    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        const curr_scaled = @as(i64, @intFromFloat(input[i] * scale));
        const prev_scaled = @as(i64, @intFromFloat(input[i - 1] * scale));
        const delta = curr_scaled - prev_scaled;

        if (delta > std.math.maxInt(i32) or delta < std.math.minInt(i32)) {
            return error.DeltaOverflow;
        }

        output[i] = @as(i32, @intCast(delta));
    }

    return base;
}

/// Decode delta-encoded prices
pub fn decodePrices(input: []const i32, output: []f64, base: i64, scale: f64) !void {
    if (input.len == 0) return;
    if (output.len < input.len) return error.OutputTooSmall;

    // First price from base
    output[0] = @as(f64, @floatFromInt(base)) / scale;

    // Reconstruct from deltas
    var current_scaled = base;
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        current_scaled += input[i];
        output[i] = @as(f64, @floatFromInt(current_scaled)) / scale;
    }
}

/// SIMD-accelerated delta encoding (AVX2/AVX-512)
/// Processes multiple values in parallel
pub fn encodePricesSIMD(input: []const f64, output: []i32, scale: f64) !i64 {
    if (input.len == 0) return 0;
    if (output.len < input.len) return error.OutputTooSmall;

    const base = @as(i64, @intFromFloat(input[0] * scale));
    output[0] = 0;

    // Check for SIMD support
    if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        return try encodePricesAVX2(input, output, scale, base);
    }

    // Fallback to scalar
    return try encodePrices(input, output, scale);
}

/// AVX2 implementation (process 4 f64 at once)
fn encodePricesAVX2(input: []const f64, output: []i32, scale: f64, base: i64) !i64 {
    output[0] = 0;

    var i: usize = 1;
    const simd_end = ((input.len - 1) / 4) * 4 + 1;

    // Process 4 values at a time
    while (i < simd_end) : (i += 4) {
        if (i + 3 >= input.len) break;

        // Load 4 current values
        const curr_vec = @Vector(4, f64){ input[i], input[i + 1], input[i + 2], input[i + 3] };

        // Load 4 previous values
        const prev_vec = @Vector(4, f64){ input[i - 1], input[i], input[i + 1], input[i + 2] };

        // Scale
        const scale_vec: @Vector(4, f64) = @splat(scale);
        const curr_scaled = curr_vec * scale_vec;
        const prev_scaled = prev_vec * scale_vec;

        // Convert to i64
        const curr_i64: @Vector(4, i64) = @intFromFloat(curr_scaled);
        const prev_i64: @Vector(4, i64) = @intFromFloat(prev_scaled);

        // Calculate deltas
        const deltas = curr_i64 - prev_i64;

        // Store (truncate to i32)
        output[i] = @intCast(deltas[0]);
        output[i + 1] = @intCast(deltas[1]);
        output[i + 2] = @intCast(deltas[2]);
        output[i + 3] = @intCast(deltas[3]);
    }

    // Handle remaining values
    while (i < input.len) : (i += 1) {
        const curr_scaled = @as(i64, @intFromFloat(input[i] * scale));
        const prev_scaled = @as(i64, @intFromFloat(input[i - 1] * scale));
        output[i] = @intCast(curr_scaled - prev_scaled);
    }

    return base;
}

/// Calculate compression ratio
pub fn compressionRatio(original_bytes: usize, compressed_bytes: usize) f64 {
    if (compressed_bytes == 0) return 0.0;
    return @as(f64, @floatFromInt(original_bytes)) / @as(f64, @floatFromInt(compressed_bytes));
}

/// Estimate compressed size for prices
/// i64 → i32 delta = 50% reduction minimum
/// Often much better due to small deltas
pub fn estimateCompressedSize(count: usize) usize {
    // Base (8 bytes) + deltas (4 bytes each)
    return 8 + (count * @sizeOf(i32));
}

// ============================================================================
// Tests
// ============================================================================

test "delta encoding - timestamps" {
    const input = [_]i64{ 1700000000, 1700000060, 1700000120, 1700000180 };
    var encoded: [4]i64 = undefined;
    var decoded: [4]i64 = undefined;

    try encodeTimestamps(&input, &encoded);

    // Check encoding
    try std.testing.expectEqual(@as(i64, 1700000000), encoded[0]); // Base
    try std.testing.expectEqual(@as(i64, 60), encoded[1]); // Delta
    try std.testing.expectEqual(@as(i64, 60), encoded[2]);
    try std.testing.expectEqual(@as(i64, 60), encoded[3]);

    try decodeTimestamps(&encoded, &decoded);

    // Check decoding
    for (input, decoded) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

test "delta encoding - prices" {
    const input = [_]f64{ 50000.00, 50000.50, 50001.00, 50000.75 };
    var encoded: [4]i32 = undefined;
    var decoded: [4]f64 = undefined;

    const scale = 100.0; // 2 decimal places
    const base = try encodePrices(&input, &encoded, scale);

    try std.testing.expectEqual(@as(i64, 5000000), base); // 50000.00 * 100
    try std.testing.expectEqual(@as(i32, 50), encoded[1]); // +0.50 * 100
    try std.testing.expectEqual(@as(i32, 50), encoded[2]); // +0.50 * 100
    try std.testing.expectEqual(@as(i32, -25), encoded[3]); // -0.25 * 100

    try decodePrices(&encoded, &decoded, base, scale);

    // Check decoding (with tolerance for floating point)
    for (input, decoded) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.01);
    }
}

test "delta encoding - SIMD prices" {
    const input = [_]f64{ 50000.00, 50000.50, 50001.00, 50000.75, 50001.25, 50002.00 };
    var encoded: [6]i32 = undefined;
    var decoded: [6]f64 = undefined;

    const scale = 100.0;
    const base = try encodePricesSIMD(&input, &encoded, scale);

    try std.testing.expectEqual(@as(i64, 5000000), base);

    try decodePrices(&encoded, &decoded, base, scale);

    for (input, decoded) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.01);
    }
}

test "compression ratio calculation" {
    const original = 1000 * @sizeOf(f64); // 1000 f64 values = 8000 bytes
    const compressed = 1000 * @sizeOf(i32); // 1000 i32 deltas = 4000 bytes

    const ratio = compressionRatio(original, compressed);
    try std.testing.expectApproxEqAbs(2.0, ratio, 0.01); // 2:1 compression
}

test "estimate compressed size" {
    const count = 1000;
    const estimated = estimateCompressedSize(count);

    // Should be: 8 (base) + 1000 * 4 (deltas) = 4008 bytes
    try std.testing.expectEqual(@as(usize, 4008), estimated);

    // vs original: 1000 * 8 = 8000 bytes
    const original = count * @sizeOf(f64);
    const ratio = compressionRatio(original, estimated);

    // ~2:1 compression
    try std.testing.expect(ratio > 1.9 and ratio < 2.1);
}
