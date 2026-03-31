const std = @import("std");

// ── Q4_0: 4-bit quantization, block of 32 ──
// Layout: f16 scale (2 bytes) + 16 bytes (32 × 4-bit nibbles) = 18 bytes per block
pub const BlockQ4_0 = extern struct {
    scale: f16, // delta
    quants: [16]u8, // 32 × 4-bit values packed into 16 bytes
};

// ── Q4_1: 4-bit quantization with min, block of 32 ──
pub const BlockQ4_1 = extern struct {
    scale: f16,
    min: f16,
    quants: [16]u8,
};

// ── Q8_0: 8-bit quantization, block of 32 ──
pub const BlockQ8_0 = extern struct {
    scale: f16,
    quants: [32]i8,
};

/// Dequantize a Q4_0 block to 32 f32 values
/// GGML layout: low nibbles → elements 0..15, high nibbles → elements 16..31
pub fn dequantizeQ4_0(block: *const BlockQ4_0, out: *[32]f32) void {
    const d: f32 = @floatCast(block.scale);
    for (0..16) |j| {
        const byte = block.quants[j];
        const lo: i32 = @as(i32, byte & 0x0F) - 8;
        const hi: i32 = @as(i32, byte >> 4) - 8;
        out[j] = @as(f32, @floatFromInt(lo)) * d;
        out[j + 16] = @as(f32, @floatFromInt(hi)) * d;
    }
}

/// Dequantize a Q4_1 block to 32 f32 values
/// GGML layout: low nibbles → elements 0..15, high nibbles → elements 16..31
pub fn dequantizeQ4_1(block: *const BlockQ4_1, out: *[32]f32) void {
    const d: f32 = @floatCast(block.scale);
    const m: f32 = @floatCast(block.min);
    for (0..16) |j| {
        const byte = block.quants[j];
        const lo: f32 = @floatFromInt(@as(u32, byte & 0x0F));
        const hi: f32 = @floatFromInt(@as(u32, byte >> 4));
        out[j] = lo * d + m;
        out[j + 16] = hi * d + m;
    }
}

/// Dequantize a Q8_0 block to 32 f32 values
pub fn dequantizeQ8_0(block: *const BlockQ8_0, out: *[32]f32) void {
    const d: f32 = @floatCast(block.scale);
    for (0..32) |i| {
        out[i] = @as(f32, @floatFromInt(block.quants[i])) * d;
    }
}

/// Dot product: Q4_0 row (n_blocks blocks) dot f32 vector
/// This is THE hot path — ~90% of inference time
/// GGML layout: low nibbles → elements 0..15, high nibbles → elements 16..31
pub fn dotQ4_0F32(blocks: [*]const BlockQ4_0, x: [*]const f32, n_blocks: usize) f32 {
    var sum: f32 = 0.0;
    for (0..n_blocks) |b| {
        const block = &blocks[b];
        const d: f32 = @floatCast(block.scale);
        const xp = x + b * 32;

        var block_sum: f32 = 0.0;
        for (0..16) |j| {
            const byte = block.quants[j];
            const lo: f32 = @floatFromInt(@as(i32, @as(i32, byte & 0x0F) - 8));
            const hi: f32 = @floatFromInt(@as(i32, @as(i32, byte >> 4) - 8));
            block_sum += lo * xp[j];
            block_sum += hi * xp[j + 16];
        }
        sum += block_sum * d;
    }
    return sum;
}

/// Dot product: Q8_0 row dot f32 vector
pub fn dotQ8_0F32(blocks: [*]const BlockQ8_0, x: [*]const f32, n_blocks: usize) f32 {
    var sum: f32 = 0.0;
    for (0..n_blocks) |b| {
        const block = &blocks[b];
        const d: f32 = @floatCast(block.scale);
        const xp = x + b * 32;

        var block_sum: f32 = 0.0;
        for (0..32) |i| {
            block_sum += @as(f32, @floatFromInt(block.quants[i])) * xp[i];
        }
        sum += block_sum * d;
    }
    return sum;
}

/// Vectorized Q4_0 dot product using Zig SIMD vectors
pub fn dotQ4_0F32Simd(blocks: [*]const BlockQ4_0, x: [*]const f32, n_blocks: usize) f32 {
    var total_sum: f32 = 0.0;

    for (0..n_blocks) |b| {
        const block = &blocks[b];
        const d: f32 = @floatCast(block.scale);
        const xp = x + b * 32;

        // Dequantize block into a temp buffer, then do vectorized dot
        var dequant: [32]f32 = undefined;
        dequantizeQ4_0(block, &dequant);

        // Use 8-wide vectors
        var sum_vec: @Vector(8, f32) = @splat(0.0);
        comptime var i: usize = 0;
        inline while (i < 32) : (i += 8) {
            const a: @Vector(8, f32) = dequant[i..][0..8].*;
            const bv: @Vector(8, f32) = xp[i..][0..8].*;
            sum_vec += a * bv;
        }
        total_sum += @reduce(.Add, sum_vec);
        _ = d; // scale already applied in dequantize
    }

    return total_sum;
}

/// Vectorized f32 dot product
pub fn dotF32Simd(a: [*]const f32, b: [*]const f32, n: usize) f32 {
    var sum_vec: @Vector(8, f32) = @splat(0.0);
    var i: usize = 0;

    // Process 8 floats at a time
    while (i + 8 <= n) : (i += 8) {
        const va: @Vector(8, f32) = a[i..][0..8].*;
        const vb: @Vector(8, f32) = b[i..][0..8].*;
        sum_vec += va * vb;
    }

    var sum = @reduce(.Add, sum_vec);

    // Scalar tail
    while (i < n) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

// ── Q6_K: 6-bit quantization (K-quant), block of 256 ──
// Layout: ql[128] (lower 4 bits) + qh[64] (upper 2 bits) + scales[16] + f16 d = 210 bytes
pub const BlockQ6_K = extern struct {
    ql: [128]u8, // lower 4 bits of quantized values
    qh: [64]u8, // upper 2 bits of quantized values
    scales: [16]i8, // sub-block scales
    d: f16, // super-block scale
};

/// Dequantize a Q6_K block to 256 f32 values
/// Matches GGML's dequantize_row_q6_K exactly: is=l/16, sc advances by 8 per half
pub fn dequantizeQ6_K(block: *const BlockQ6_K, out: *[256]f32) void {
    const d: f32 = @floatCast(block.d);

    // Process two 128-element halves
    inline for (0..2) |half| {
        const ql_off: usize = half * 64;
        const qh_off: usize = half * 32;
        const sc_off: usize = half * 8; // sc pointer advances by 8 per half
        const out_off: usize = half * 128;

        for (0..32) |l| {
            const is: usize = l / 16; // 0 for l=0..15, 1 for l=16..31

            // Extract 6-bit values from split storage
            const q1: i32 = @as(i32, block.ql[ql_off + l] & 0x0F) | (@as(i32, (block.qh[qh_off + l] >> 0) & 3) << 4);
            const q2: i32 = @as(i32, block.ql[ql_off + l + 32] & 0x0F) | (@as(i32, (block.qh[qh_off + l] >> 2) & 3) << 4);
            const q3: i32 = @as(i32, block.ql[ql_off + l] >> 4) | (@as(i32, (block.qh[qh_off + l] >> 4) & 3) << 4);
            const q4: i32 = @as(i32, block.ql[ql_off + l + 32] >> 4) | (@as(i32, (block.qh[qh_off + l] >> 6) & 3) << 4);

            const s0: f32 = @floatFromInt(block.scales[sc_off + is + 0]);
            const s2: f32 = @floatFromInt(block.scales[sc_off + is + 2]);
            const s4: f32 = @floatFromInt(block.scales[sc_off + is + 4]);
            const s6: f32 = @floatFromInt(block.scales[sc_off + is + 6]);

            out[out_off + l + 0] = d * s0 * @as(f32, @floatFromInt(q1 - 32));
            out[out_off + l + 32] = d * s2 * @as(f32, @floatFromInt(q2 - 32));
            out[out_off + l + 64] = d * s4 * @as(f32, @floatFromInt(q3 - 32));
            out[out_off + l + 96] = d * s6 * @as(f32, @floatFromInt(q4 - 32));
        }
    }
}

/// Dot product: Q6_K row (n_blocks blocks) dot f32 vector
/// Uses dequantize-then-dot approach for correctness (matches GGML scale indexing)
pub fn dotQ6_KF32(blocks: [*]const BlockQ6_K, x: [*]const f32, n_blocks: usize) f32 {
    var sum: f32 = 0.0;
    var dequant_buf: [256]f32 = undefined;
    for (0..n_blocks) |b| {
        dequantizeQ6_K(&blocks[b], &dequant_buf);
        const xp = x + b * 256;
        for (0..256) |i| {
            sum += dequant_buf[i] * xp[i];
        }
    }
    return sum;
}

/// Scalar f32 dot product (fallback)
pub fn dotF32Scalar(a: [*]const f32, b: [*]const f32, n: usize) f32 {
    var sum: f32 = 0.0;
    for (0..n) |i| {
        sum += a[i] * b[i];
    }
    return sum;
}
