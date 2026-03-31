const std = @import("std");
const thread_pool_mod = @import("thread_pool.zig");

// ── Vision tensor operations for U2NetP ──
// All tensors are in CHW layout (channels × height × width), f32.

/// Conv2D with fused bias. Direct convolution (no im2col needed for small kernels).
/// input: [C_in x H x W], weight: [C_out x C_in x kH x kW], bias: [C_out]
/// output: [C_out x H_out x W_out]
pub fn conv2d(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_h: u32,
    in_w: u32,
    out_c: u32,
    k: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
    pool: ?*thread_pool_mod.ThreadPool,
) void {
    const ek = (k - 1) * dilation + 1; // effective kernel size
    const out_h = (in_h + 2 * pad - ek) / stride + 1;
    const out_w = (in_w + 2 * pad - ek) / stride + 1;

    if (pool) |p| {
        if (out_c >= p.n_threads * 2) {
            var ctx = Conv2dCtx{
                .out = out,
                .input = input,
                .weight = weight,
                .bias = bias,
                .in_c = in_c,
                .in_h = in_h,
                .in_w = in_w,
                .out_c = out_c,
                .out_h = out_h,
                .out_w = out_w,
                .k = k,
                .stride = stride,
                .pad = pad,
                .dilation = dilation,
            };
            p.parallelFor(0, out_c, @ptrCast(&ctx), conv2dWorker);
            return;
        }
    }

    conv2dRange(out, input, weight, bias, in_c, in_h, in_w, out_c, out_h, out_w, k, stride, pad, dilation, 0, out_c);
}

const Conv2dCtx = struct {
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_h: u32,
    in_w: u32,
    out_c: u32,
    out_h: u32,
    out_w: u32,
    k: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
};

fn conv2dWorker(start: usize, end: usize, ctx_ptr: *anyopaque) void {
    const ctx: *Conv2dCtx = @alignCast(@ptrCast(ctx_ptr));
    conv2dRange(
        ctx.out,
        ctx.input,
        ctx.weight,
        ctx.bias,
        ctx.in_c,
        ctx.in_h,
        ctx.in_w,
        ctx.out_c,
        ctx.out_h,
        ctx.out_w,
        ctx.k,
        ctx.stride,
        ctx.pad,
        ctx.dilation,
        @intCast(start),
        @intCast(end),
    );
}

fn conv2dRange(
    out: []f32,
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    in_c: u32,
    in_h: u32,
    in_w: u32,
    _: u32, // out_c (unused directly)
    out_h: u32,
    out_w: u32,
    k: u32,
    stride: u32,
    pad: u32,
    dilation: u32,
    oc_start: u32,
    oc_end: u32,
) void {
    const in_hw: usize = @as(usize, in_h) * in_w;
    const out_hw: usize = @as(usize, out_h) * out_w;
    const k2: usize = @as(usize, k) * k;
    const weight_per_oc: usize = @as(usize, in_c) * k2;

    for (oc_start..oc_end) |oc| {
        const bias_val = bias[oc];
        const w_base = oc * weight_per_oc;
        const out_base = oc * out_hw;

        for (0..out_h) |oh| {
            for (0..out_w) |ow| {
                var sum: f32 = bias_val;

                for (0..in_c) |ic| {
                    const w_ic_base = w_base + ic * k2;
                    const in_base = ic * in_hw;

                    for (0..k) |kh| {
                        const ih_signed: i64 = @as(i64, @intCast(oh * stride)) + @as(i64, @intCast(kh * dilation)) - @as(i64, @intCast(pad));
                        if (ih_signed < 0 or ih_signed >= @as(i64, @intCast(in_h))) continue;
                        const ih: usize = @intCast(ih_signed);

                        for (0..k) |kw| {
                            const iw_signed: i64 = @as(i64, @intCast(ow * stride)) + @as(i64, @intCast(kw * dilation)) - @as(i64, @intCast(pad));
                            if (iw_signed < 0 or iw_signed >= @as(i64, @intCast(in_w))) continue;
                            const iw: usize = @intCast(iw_signed);

                            sum += weight[w_ic_base + kh * k + kw] * input[in_base + ih * in_w + iw];
                        }
                    }
                }

                out[out_base + oh * out_w + ow] = sum;
            }
        }
    }
}

/// ReLU in-place
pub fn relu(x: []f32) void {
    for (x) |*v| {
        if (v.* < 0) v.* = 0;
    }
}

/// Sigmoid in-place
pub fn sigmoid(x: []f32) void {
    for (x) |*v| {
        v.* = 1.0 / (1.0 + @exp(-v.*));
    }
}

/// MaxPool2D (2x2, stride 2)
/// input: [C x H x W] -> output: [C x H/2 x W/2]
pub fn maxpool2d(out: []f32, input: []const f32, c: u32, h: u32, w: u32) void {
    const oh = h / 2;
    const ow = w / 2;
    const in_hw: usize = @as(usize, h) * w;
    const out_hw: usize = @as(usize, oh) * ow;

    for (0..c) |ch| {
        const in_base = ch * in_hw;
        const out_base = ch * out_hw;

        for (0..oh) |y| {
            for (0..ow) |x| {
                const iy = y * 2;
                const ix = x * 2;
                var max_val = input[in_base + iy * w + ix];
                const v1 = input[in_base + iy * w + ix + 1];
                const v2 = input[in_base + (iy + 1) * w + ix];
                const v3 = input[in_base + (iy + 1) * w + ix + 1];
                if (v1 > max_val) max_val = v1;
                if (v2 > max_val) max_val = v2;
                if (v3 > max_val) max_val = v3;
                out[out_base + y * ow + x] = max_val;
            }
        }
    }
}

/// Bilinear upsample 2x
/// input: [C x H x W] -> output: [C x 2H x 2W]
pub fn upsample2x(out: []f32, input: []const f32, c: u32, h: u32, w: u32) void {
    const out_h = h * 2;
    const out_w = w * 2;
    const in_hw: usize = @as(usize, h) * w;
    const out_hw: usize = @as(usize, out_h) * out_w;

    for (0..c) |ch| {
        const in_base = ch * in_hw;
        const out_base = ch * out_hw;

        for (0..out_h) |oy| {
            for (0..out_w) |ox| {
                // Map output pixel to input coordinates
                // Use align_corners=False convention (like PyTorch default)
                const src_y_f = (@as(f32, @floatFromInt(oy)) + 0.5) / 2.0 - 0.5;
                const src_x_f = (@as(f32, @floatFromInt(ox)) + 0.5) / 2.0 - 0.5;

                const y0_f = @floor(src_y_f);
                const x0_f = @floor(src_x_f);

                const dy = src_y_f - y0_f;
                const dx = src_x_f - x0_f;

                const y0: i32 = @intFromFloat(y0_f);
                const x0: i32 = @intFromFloat(x0_f);
                const y1 = y0 + 1;
                const x1 = x0 + 1;

                const h_i: i32 = @intCast(h);
                const w_i: i32 = @intCast(w);

                const cy0: usize = @intCast(std.math.clamp(y0, 0, h_i - 1));
                const cy1: usize = @intCast(std.math.clamp(y1, 0, h_i - 1));
                const cx0: usize = @intCast(std.math.clamp(x0, 0, w_i - 1));
                const cx1: usize = @intCast(std.math.clamp(x1, 0, w_i - 1));

                const v00 = input[in_base + cy0 * w + cx0];
                const v01 = input[in_base + cy0 * w + cx1];
                const v10 = input[in_base + cy1 * w + cx0];
                const v11 = input[in_base + cy1 * w + cx1];

                out[out_base + oy * out_w + ox] = v00 * (1 - dy) * (1 - dx) +
                    v01 * (1 - dy) * dx +
                    v10 * dy * (1 - dx) +
                    v11 * dy * dx;
            }
        }
    }
}

/// Bilinear resize to arbitrary target dimensions
/// input: [C x H_in x W_in] -> output: [C x H_out x W_out]
pub fn resizeBilinear(out: []f32, input: []const f32, c: u32, in_h: u32, in_w: u32, out_h: u32, out_w: u32) void {
    const in_hw: usize = @as(usize, in_h) * in_w;
    const out_hw: usize = @as(usize, out_h) * out_w;

    for (0..c) |ch| {
        const in_base = ch * in_hw;
        const out_base = ch * out_hw;

        for (0..out_h) |oy| {
            for (0..out_w) |ox| {
                const src_y_f = (@as(f32, @floatFromInt(oy)) + 0.5) * @as(f32, @floatFromInt(in_h)) / @as(f32, @floatFromInt(out_h)) - 0.5;
                const src_x_f = (@as(f32, @floatFromInt(ox)) + 0.5) * @as(f32, @floatFromInt(in_w)) / @as(f32, @floatFromInt(out_w)) - 0.5;

                const y0_f = @floor(src_y_f);
                const x0_f = @floor(src_x_f);

                const dy = src_y_f - y0_f;
                const dx = src_x_f - x0_f;

                const y0: i32 = @intFromFloat(y0_f);
                const x0: i32 = @intFromFloat(x0_f);
                const y1 = y0 + 1;
                const x1 = x0 + 1;

                const h_i: i32 = @intCast(in_h);
                const w_i: i32 = @intCast(in_w);

                const cy0: usize = @intCast(std.math.clamp(y0, 0, h_i - 1));
                const cy1: usize = @intCast(std.math.clamp(y1, 0, h_i - 1));
                const cx0: usize = @intCast(std.math.clamp(x0, 0, w_i - 1));
                const cx1: usize = @intCast(std.math.clamp(x1, 0, w_i - 1));

                const v00 = input[in_base + cy0 * in_w + cx0];
                const v01 = input[in_base + cy0 * in_w + cx1];
                const v10 = input[in_base + cy1 * in_w + cx0];
                const v11 = input[in_base + cy1 * in_w + cx1];

                out[out_base + oy * out_w + ox] = v00 * (1 - dy) * (1 - dx) +
                    v01 * (1 - dy) * dx +
                    v10 * dy * (1 - dx) +
                    v11 * dy * dx;
            }
        }
    }
}

/// Elementwise add: out = a + b
pub fn add(out: []f32, a: []const f32, b: []const f32) void {
    for (0..out.len) |i| {
        out[i] = a[i] + b[i];
    }
}

/// Concatenate along channel dimension
/// inputs: array of [C_i x H x W] tensors -> output: [sum(C_i) x H x W]
pub fn concatChannels(out: []f32, inputs: []const []const f32, channels: []const u32, h: u32, w: u32) void {
    const hw: usize = @as(usize, h) * w;
    var out_offset: usize = 0;
    for (0..inputs.len) |i| {
        const size = @as(usize, channels[i]) * hw;
        @memcpy(out[out_offset..][0..size], inputs[i][0..size]);
        out_offset += size;
    }
}
