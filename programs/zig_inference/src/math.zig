const std = @import("std");
const quant = @import("quant.zig");
const tensor_mod = @import("tensor.zig");
const TensorView = tensor_mod.TensorView;
const GGMLType = tensor_mod.GGMLType;
const thread_pool_mod = @import("thread_pool.zig");

// ── Thread pool for parallel matmul ──

var g_thread_pool: ?*thread_pool_mod.ThreadPool = null;

pub fn setThreadPool(pool: ?*thread_pool_mod.ThreadPool) void {
    g_thread_pool = pool;
}

// ── Core tensor operations ──

/// RMSNorm: out = weight * x / sqrt(mean(x²) + eps)
pub fn rmsnorm(out: []f32, x: []const f32, weight: []const f32, eps: f32) void {
    const n = x.len;

    // Compute mean of squares
    var ss: f32 = 0.0;
    for (x) |v| ss += v * v;
    ss = ss / @as(f32, @floatFromInt(n));
    ss = 1.0 / @sqrt(ss + eps);

    // Normalize and scale
    for (0..n) |i| {
        out[i] = weight[i] * (x[i] * ss);
    }
}

/// Softmax in-place
pub fn softmax(x: []f32) void {
    // Find max for numerical stability
    var max_val: f32 = x[0];
    for (x[1..]) |v| {
        if (v > max_val) max_val = v;
    }

    // exp and sum
    var sum: f32 = 0.0;
    for (x) |*v| {
        v.* = @exp(v.* - max_val);
        sum += v.*;
    }

    // normalize
    const inv_sum = 1.0 / sum;
    for (x) |*v| {
        v.* *= inv_sum;
    }
}

/// SiLU activation: x = x * sigmoid(x) = x / (1 + exp(-x))
pub fn silu(x: []f32) void {
    for (x) |*v| {
        v.* = v.* / (1.0 + @exp(-v.*));
    }
}

/// Sigmoid activation: x = 1 / (1 + exp(-x))
pub fn sigmoid(x: []f32) void {
    for (x) |*v| {
        v.* = 1.0 / (1.0 + @exp(-v.*));
    }
}

/// Element-wise multiply: a *= b
pub fn elementwiseMul(a: []f32, b: []const f32) void {
    for (0..a.len) |i| {
        a[i] *= b[i];
    }
}

/// Vector add: out = a + b (can be in-place: out == a)
pub fn vectorAdd(out: []f32, a: []const f32, b: []const f32) void {
    for (0..out.len) |i| {
        out[i] = a[i] + b[i];
    }
}

/// Copy embedding row from weight matrix (dequantizing if needed)
pub fn copyRow(out: []f32, weight: TensorView, row: u32) void {
    const cols = weight.cols();
    switch (weight.dtype) {
        .f32 => {
            const src = weight.rowF32(row);
            @memcpy(out[0..cols], src);
        },
        .f16 => {
            // Read f16 byte-by-byte for alignment safety
            const row_bytes = weight.data + @as(usize, row) * cols * 2;
            for (0..cols) |i| {
                const raw = std.mem.readInt(u16, row_bytes[i * 2 ..][0..2], .little);
                out[i] = @floatCast(@as(f16, @bitCast(raw)));
            }
        },
        .q4_0 => {
            const row_ptr = weight.rowData(row);
            const blocks: [*]const quant.BlockQ4_0 = @alignCast(@ptrCast(row_ptr));
            const n_blocks = cols / 32;
            for (0..n_blocks) |b| {
                quant.dequantizeQ4_0(&blocks[b], @ptrCast(out[b * 32 ..][0..32]));
            }
        },
        .q8_0 => {
            const row_ptr = weight.rowData(row);
            const blocks: [*]const quant.BlockQ8_0 = @alignCast(@ptrCast(row_ptr));
            const n_blocks = cols / 32;
            for (0..n_blocks) |b| {
                quant.dequantizeQ8_0(&blocks[b], @ptrCast(out[b * 32 ..][0..32]));
            }
        },
        .q4_1 => {
            const row_ptr = weight.rowData(row);
            const blocks: [*]const quant.BlockQ4_1 = @alignCast(@ptrCast(row_ptr));
            const n_blocks = cols / 32;
            for (0..n_blocks) |b| {
                quant.dequantizeQ4_1(&blocks[b], @ptrCast(out[b * 32 ..][0..32]));
            }
        },
        else => {
            @memset(out[0..cols], 0.0);
        },
    }
}

/// RoPE (Rotary Position Embeddings) applied to q and k vectors
/// Applies rotation to pairs of values based on position
pub fn applyRope(q: []f32, k: []f32, pos: u32, n_heads: u32, n_kv_heads: u32, head_dim: u32, rope_theta: f32) void {
    // Apply to Q
    applyRopeToVec(q, pos, n_heads, head_dim, rope_theta);
    // Apply to K
    applyRopeToVec(k, pos, n_kv_heads, head_dim, rope_theta);
}

fn applyRopeToVec(vec: []f32, pos: u32, n_heads: u32, head_dim: u32, rope_theta: f32) void {
    const pos_f: f32 = @floatFromInt(pos);
    for (0..n_heads) |h| {
        const offset = h * head_dim;
        var i: u32 = 0;
        while (i < head_dim) : (i += 2) {
            const freq = 1.0 / std.math.pow(f32, rope_theta, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(head_dim)));
            const angle = pos_f * freq;
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            const idx = offset + i;
            const x0 = vec[idx];
            const x1 = vec[idx + 1];
            vec[idx] = x0 * cos_a - x1 * sin_a;
            vec[idx + 1] = x0 * sin_a + x1 * cos_a;
        }
    }
}

/// Matrix-vector multiply: out[rows] = weight[rows×cols] @ x[cols]
/// Dispatches to thread pool if available, otherwise single-threaded
pub fn matmul(out: []f32, x: []const f32, weight: TensorView) void {
    if (g_thread_pool) |pool| {
        pool.matmul(out, x, weight);
    } else {
        matmulRows(out, x, weight, 0, weight.rows());
    }
}

/// Matrix-vector multiply for a range of rows [row_start..row_end)
/// Called by thread pool workers and single-threaded fallback
pub fn matmulRows(out: []f32, x: []const f32, weight: TensorView, row_start: usize, row_end: usize) void {
    const n_cols = weight.cols();

    switch (weight.dtype) {
        .f32 => {
            for (row_start..row_end) |row| {
                const w = weight.rowF32(row);
                out[row] = quant.dotF32Simd(w.ptr, x.ptr, n_cols);
            }
        },
        .f16 => {
            // Read f16 byte-by-byte for alignment safety (ggml format has no padding)
            for (row_start..row_end) |row| {
                var sum: f32 = 0.0;
                const row_bytes = weight.data + row * n_cols * 2;
                for (0..n_cols) |col| {
                    const raw = std.mem.readInt(u16, row_bytes[col * 2 ..][0..2], .little);
                    const w: f32 = @floatCast(@as(f16, @bitCast(raw)));
                    sum += w * x[col];
                }
                out[row] = sum;
            }
        },
        .q4_0 => {
            const blocks_per_row = n_cols / 32;
            for (row_start..row_end) |row| {
                const row_ptr = weight.rowData(row);
                const blocks: [*]const quant.BlockQ4_0 = @alignCast(@ptrCast(row_ptr));
                out[row] = quant.dotQ4_0F32(blocks, x.ptr, blocks_per_row);
            }
        },
        .q8_0 => {
            const blocks_per_row = n_cols / 32;
            for (row_start..row_end) |row| {
                const row_ptr = weight.rowData(row);
                const blocks: [*]const quant.BlockQ8_0 = @alignCast(@ptrCast(row_ptr));
                out[row] = quant.dotQ8_0F32(blocks, x.ptr, blocks_per_row);
            }
        },
        .q4_1 => {
            for (row_start..row_end) |row| {
                const row_ptr = weight.rowData(row);
                const blocks: [*]const quant.BlockQ4_1 = @alignCast(@ptrCast(row_ptr));
                const blocks_per_row = n_cols / 32;
                var sum: f32 = 0.0;
                var temp: [32]f32 = undefined;
                for (0..blocks_per_row) |b| {
                    quant.dequantizeQ4_1(&blocks[b], &temp);
                    for (0..32) |i| {
                        sum += temp[i] * x[b * 32 + i];
                    }
                }
                out[row] = sum;
            }
        },
        .q6_k => {
            const blocks_per_row = n_cols / 256;
            for (row_start..row_end) |row| {
                const row_ptr = weight.rowData(row);
                const blocks: [*]const quant.BlockQ6_K = @alignCast(@ptrCast(row_ptr));
                out[row] = quant.dotQ6_KF32(blocks, x.ptr, blocks_per_row);
            }
        },
        else => {
            // Unsupported quant type — zero output
            @memset(out[row_start..row_end], 0.0);
        },
    }
}

/// LayerNorm: out = weight * ((x - mean) / sqrt(var + eps)) + bias
pub fn layernorm(out: []f32, x: []const f32, weight: []const f32, bias: []const f32, eps: f32) void {
    const n = x.len;
    const n_f: f32 = @floatFromInt(n);

    // Mean
    var mean: f32 = 0.0;
    for (x) |v| mean += v;
    mean /= n_f;

    // Variance
    var variance: f32 = 0.0;
    for (x) |v| {
        const d = v - mean;
        variance += d * d;
    }
    variance /= n_f;

    const inv_std = 1.0 / @sqrt(variance + eps);
    for (0..n) |i| {
        out[i] = weight[i] * ((x[i] - mean) * inv_std) + bias[i];
    }
}

/// GELU activation: x * 0.5 * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
pub fn gelu(x: []f32) void {
    const sqrt_2_over_pi: f32 = 0.7978845608; // sqrt(2/pi)
    for (x) |*v| {
        const x3 = v.* * v.* * v.*;
        const inner = sqrt_2_over_pi * (v.* + 0.044715 * x3);
        v.* = 0.5 * v.* * (1.0 + std.math.tanh(inner));
    }
}

/// Add bias vector to output: out[i] += bias[i]
pub fn addBias(out: []f32, bias: TensorView) void {
    const b = bias.asF32Slice();
    const n = @min(out.len, b.len);
    for (0..n) |i| {
        out[i] += b[i];
    }
}

/// LeakyReLU in-place: max(x, alpha*x)
pub fn leakyRelu(x: []f32, alpha: f32) void {
    for (x) |*v| {
        if (v.* < 0) v.* = v.* * alpha;
    }
}

/// Tanh in-place
pub fn tanh(x: []f32) void {
    for (x) |*v| {
        v.* = std.math.tanh(v.*);
    }
}

/// Exp in-place
pub fn exp(x: []f32) void {
    for (x) |*v| {
        v.* = @exp(v.*);
    }
}

/// Log in-place (clamped to avoid -inf)
pub fn log(x: []f32) void {
    for (x) |*v| {
        v.* = @log(@max(v.*, 1e-10));
    }
}

/// Random normal via Box-Muller: out = mean + exp(log_stddev) * N(0,1)
pub fn randomNormal(out: []f32, mean: []const f32, log_stddev: []const f32, noise_scale: f32) void {
    const n = out.len;
    var i: usize = 0;
    while (i + 1 < n) : (i += 2) {
        // Generate two uniform random values using arc4random_buf
        var bytes: [8]u8 = undefined;
        std.c.arc4random_buf(&bytes, 8);
        const u1_int = std.mem.readInt(u32, bytes[0..4], .little);
        const u2_int = std.mem.readInt(u32, bytes[4..8], .little);
        const @"u1" = (@as(f32, @floatFromInt(u1_int)) + 1.0) / 4294967297.0; // (0,1)
        const @"u2" = @as(f32, @floatFromInt(u2_int)) / 4294967296.0;
        const r = @sqrt(-2.0 * @log(@"u1"));
        const theta = 2.0 * std.math.pi * @"u2";
        const z0 = r * @cos(theta);
        const z1 = r * @sin(theta);
        out[i] = mean[i] + @exp(log_stddev[i]) * noise_scale * z0;
        out[i + 1] = mean[i + 1] + @exp(log_stddev[i + 1]) * noise_scale * z1;
    }
    if (i < n) {
        var bytes: [8]u8 = undefined;
        std.c.arc4random_buf(&bytes, 8);
        const u1_int = std.mem.readInt(u32, bytes[0..4], .little);
        const u2_int = std.mem.readInt(u32, bytes[4..8], .little);
        const unif1 = (@as(f32, @floatFromInt(u1_int)) + 1.0) / 4294967297.0;
        const unif2 = @as(f32, @floatFromInt(u2_int)) / 4294967296.0;
        const r = @sqrt(-2.0 * @log(unif1));
        const z0 = r * @cos(2.0 * std.math.pi * unif2);
        out[i] = mean[i] + @exp(log_stddev[i]) * noise_scale * z0;
    }
}

/// Cumulative sum in-place
pub fn cumsum(x: []f32) void {
    if (x.len < 2) return;
    for (1..x.len) |i| {
        x[i] += x[i - 1];
    }
}

/// Element-wise add scalar: out[i] = a[i] + scalar
pub fn addScalar(out: []f32, a: []const f32, scalar: f32) void {
    for (0..out.len) |i| {
        out[i] = a[i] + scalar;
    }
}

/// Element-wise multiply scalar: out[i] = a[i] * scalar
pub fn mulScalar(out: []f32, a: []const f32, scalar: f32) void {
    for (0..out.len) |i| {
        out[i] = a[i] * scalar;
    }
}

/// Argmax over a slice
pub fn argmax(x: []const f32) u32 {
    var best_idx: u32 = 0;
    var best_val: f32 = x[0];
    for (x[1..], 1..) |v, i| {
        if (v > best_val) {
            best_val = v;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}
