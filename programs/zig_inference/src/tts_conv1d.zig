const std = @import("std");
const thread_pool_mod = @import("thread_pool.zig");

// ── 1D Convolution operators for VITS TTS ──
// All tensors are in [C, L] layout (channels × length), f32.

/// Standard Conv1d with variable kernel, stride, padding, dilation.
/// input:  [in_c × in_len]
/// weight: [out_c × in_c × kernel]
/// bias:   [out_c]
/// output: [out_c × out_len]
pub fn conv1d(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_len: u32,
    out_c: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
    pool: ?*thread_pool_mod.ThreadPool,
) void {
    const ek = (kernel - 1) * dilation + 1; // effective kernel size
    const out_len = (in_len + 2 * pad - ek) / stride + 1;

    if (pool) |p| {
        if (out_c >= p.n_threads * 2) {
            var ctx = Conv1dCtx{
                .out = out,
                .input = input,
                .weight = weight,
                .bias = bias,
                .in_c = in_c,
                .in_len = in_len,
                .out_c = out_c,
                .out_len = out_len,
                .kernel = kernel,
                .stride = stride,
                .pad = pad,
                .dilation = dilation,
            };
            p.parallelFor(0, out_c, @ptrCast(&ctx), conv1dWorker);
            return;
        }
    }

    conv1dRange(out, input, weight, bias, in_c, in_len, out_len, kernel, stride, pad, dilation, 0, out_c);
}

const Conv1dCtx = struct {
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_len: u32,
    out_c: u32,
    out_len: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
};

fn conv1dWorker(start: usize, end: usize, ctx_ptr: *anyopaque) void {
    const ctx: *Conv1dCtx = @alignCast(@ptrCast(ctx_ptr));
    conv1dRange(
        ctx.out,
        ctx.input,
        ctx.weight,
        ctx.bias,
        ctx.in_c,
        ctx.in_len,
        ctx.out_len,
        ctx.kernel,
        ctx.stride,
        ctx.pad,
        ctx.dilation,
        @intCast(start),
        @intCast(end),
    );
}

fn conv1dRange(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_len: u32,
    out_len: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
    oc_start: u32,
    oc_end: u32,
) void {
    const weight_per_oc: usize = @as(usize, in_c) * kernel;

    for (oc_start..oc_end) |oc| {
        const bias_val = bias[oc];
        const w_base = oc * weight_per_oc;
        const out_base = oc * @as(usize, out_len);

        for (0..out_len) |ot| {
            var sum: f32 = bias_val;
            for (0..in_c) |ic| {
                const w_ic_base = w_base + ic * @as(usize, kernel);
                const in_base = ic * @as(usize, in_len);
                for (0..kernel) |k| {
                    const pos_signed: i64 = @as(i64, @intCast(ot)) * @as(i64, stride) + @as(i64, @intCast(k)) * @as(i64, dilation) - @as(i64, @intCast(pad));
                    if (pos_signed >= 0 and pos_signed < @as(i64, @intCast(in_len))) {
                        const pos: usize = @intCast(pos_signed);
                        sum += weight[w_ic_base + k] * input[in_base + pos];
                    }
                }
            }
            out[out_base + ot] = sum;
        }
    }
}

/// ConvTranspose1d (fractionally-strided convolution) for HiFi-GAN upsampling.
/// input:  [in_c × in_len]
/// weight: [in_c × out_c × kernel]
/// bias:   [out_c]
/// output: [out_c × out_len] where out_len = (in_len - 1) * stride - 2*pad + kernel
pub fn convTranspose1d(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_len: u32,
    out_c: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
    pool: ?*thread_pool_mod.ThreadPool,
) void {
    const out_len: u32 = (@as(u32, @intCast(in_len)) - 1) * stride - 2 * pad + kernel;

    // Initialize output with bias
    for (0..out_c) |oc| {
        const base = oc * @as(usize, out_len);
        for (0..out_len) |i| {
            out[base + i] = bias[oc];
        }
    }

    // Note: parallel over input channels requires atomic adds — not worth it.
    // ConvTranspose1d uses scatter-based accumulation, so we run single-threaded.
    _ = pool;

    convTranspose1dScatter(out, input, weight, in_c, in_len, out_c, out_len, kernel, stride, pad);
}

fn convTranspose1dScatter(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    in_c: u32,
    in_len: u32,
    out_c: u32,
    out_len: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
) void {
    // Weight layout: [in_c × out_c × kernel]
    for (0..in_c) |ic| {
        for (0..in_len) |il| {
            const x = input[ic * @as(usize, in_len) + il];
            for (0..out_c) |oc| {
                const w_base = (ic * @as(usize, out_c) + oc) * kernel;
                for (0..kernel) |k| {
                    const o_pos_signed: i64 = @as(i64, @intCast(il)) * @as(i64, stride) + @as(i64, @intCast(k)) - @as(i64, @intCast(pad));
                    if (o_pos_signed >= 0 and o_pos_signed < @as(i64, @intCast(out_len))) {
                        const o_pos: usize = @intCast(o_pos_signed);
                        out[oc * @as(usize, out_len) + o_pos] += x * weight[w_base + k];
                    }
                }
            }
        }
    }
}

/// Depthwise Conv1d: groups == channels, each channel has its own kernel.
/// input:  [C × in_len]
/// weight: [C × 1 × kernel]
/// bias:   [C]
/// output: [C × out_len]
pub fn depthwiseConv1d(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    channels: u32,
    in_len: u32,
    kernel: u32,
    pad: u32,
    dilation: u32,
) void {
    const ek = (kernel - 1) * dilation + 1;
    const out_len = (in_len + 2 * pad - ek) + 1; // stride=1

    for (0..channels) |c| {
        const in_base = c * @as(usize, in_len);
        const out_base = c * @as(usize, out_len);
        const w_base = c * @as(usize, kernel);
        const bias_val = bias[c];

        for (0..out_len) |ot| {
            var sum: f32 = bias_val;
            for (0..kernel) |k| {
                const pos_signed: i64 = @as(i64, @intCast(ot)) + @as(i64, @intCast(k)) * @as(i64, dilation) - @as(i64, @intCast(pad));
                if (pos_signed >= 0 and pos_signed < @as(i64, @intCast(in_len))) {
                    const pos: usize = @intCast(pos_signed);
                    sum += weight[w_base + k] * input[in_base + pos];
                }
            }
            out[out_base + ot] = sum;
        }
    }
}

/// Conv1d without bias.
pub fn conv1dNoBias(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    in_c: u32,
    in_len: u32,
    out_c: u32,
    kernel: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
) void {
    const ek = (kernel - 1) * dilation + 1;
    const out_len = (in_len + 2 * pad - ek) / stride + 1;
    const weight_per_oc: usize = @as(usize, in_c) * kernel;

    for (0..out_c) |oc| {
        const w_base = oc * weight_per_oc;
        const out_base = oc * @as(usize, out_len);

        for (0..out_len) |ot| {
            var sum: f32 = 0.0;
            for (0..in_c) |ic| {
                const w_ic_base = w_base + ic * @as(usize, kernel);
                const in_base = ic * @as(usize, in_len);
                for (0..kernel) |k| {
                    const pos_signed: i64 = @as(i64, @intCast(ot)) * @as(i64, stride) + @as(i64, @intCast(k)) * @as(i64, dilation) - @as(i64, @intCast(pad));
                    if (pos_signed >= 0 and pos_signed < @as(i64, @intCast(in_len))) {
                        const pos: usize = @intCast(pos_signed);
                        sum += weight[w_ic_base + k] * input[in_base + pos];
                    }
                }
            }
            out[out_base + ot] = sum;
        }
    }
}
