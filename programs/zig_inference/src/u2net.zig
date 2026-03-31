const std = @import("std");
const Allocator = std.mem.Allocator;
const conv_mod = @import("conv.zig");
const vision_loader = @import("vision_loader.zig");
const thread_pool_mod = @import("thread_pool.zig");

/// U2NetP — Lightweight salient object detection model (4.7M params).
///
/// Architecture:
///   6 encoder stages (RSU-7, RSU-6, RSU-5, RSU-4, RSU-4F, RSU-4F)
///   5 decoder stages (RSU-4F, RSU-4, RSU-5, RSU-6, RSU-7) with skip connections
///   6 side outputs → 1x1 conv fusion → sigmoid → 320x320 alpha mask
///
/// All BatchNorm layers are fused into Conv2D weights at export time.
/// Only 6 operators: Conv2D, ReLU, MaxPool2D, Upsample, Sigmoid, Add.

pub const U2NetP = struct {
    allocator: Allocator,
    vfile: vision_loader.VisionFile,
    pool: ?*thread_pool_mod.ThreadPool,

    // Pre-allocated scratch buffers (rotated during forward pass)
    // Largest: 64 channels x 320 x 320 = 6.5M floats = 26MB
    scratch: [6][]f32,

    pub fn init(allocator: Allocator, model_path: []const u8, n_threads: u32) !U2NetP {
        const vfile = try vision_loader.VisionFile.open(allocator, model_path);

        var pool: ?*thread_pool_mod.ThreadPool = null;
        if (n_threads > 1) {
            pool = try thread_pool_mod.ThreadPool.init(allocator, n_threads);
        }

        // Allocate scratch buffers
        // Sizes chosen for worst-case intermediates at each resolution
        const scratch_sizes = [6]usize{
            64 * 320 * 320, // enc1 level: 64 ch at 320x320
            64 * 160 * 160, // enc2 level: 64 ch at 160x160
            64 * 80 * 80, // enc3 level
            64 * 40 * 40, // enc4 level
            64 * 20 * 20, // enc5 level
            64 * 320 * 320, // extra for side outputs / fusion
        };

        var scratch: [6][]f32 = undefined;
        for (0..6) |i| {
            scratch[i] = try allocator.alloc(f32, scratch_sizes[i]);
        }

        return U2NetP{
            .allocator = allocator,
            .vfile = vfile,
            .pool = pool,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *U2NetP) void {
        for (0..6) |i| {
            self.allocator.free(self.scratch[i]);
        }
        if (self.pool) |p| p.deinit();
        self.vfile.close();
    }

    /// Run full forward pass on input [3 x 320 x 320] tensor.
    /// Returns alpha mask [320 x 320] as f32 in [0, 1].
    /// The returned slice is owned by the caller (allocated from self.allocator).
    pub fn forward(self: *U2NetP, allocator: Allocator, input: []const f32) ![]f32 {
        const S = 320; // input spatial size

        // ── Encoder ──
        // En1: RSU-7, in=3, mid=16, out=64, 320x320
        const enc1_size: usize = 64 * S * S;
        const enc1 = try allocator.alloc(f32, enc1_size);
        defer allocator.free(enc1);
        self.rsuBlock(enc1, input, "stage1", 7, 3, 16, 64, S, S);

        // Pool 320->160
        const enc1_pool_size: usize = 64 * (S / 2) * (S / 2);
        const enc1_pool = try allocator.alloc(f32, enc1_pool_size);
        defer allocator.free(enc1_pool);
        conv_mod.maxpool2d(enc1_pool, enc1, 64, S, S);

        // En2: RSU-6, in=64, mid=16, out=64, 160x160
        const s2 = S / 2;
        const enc2_size: usize = 64 * s2 * s2;
        const enc2 = try allocator.alloc(f32, enc2_size);
        defer allocator.free(enc2);
        self.rsuBlock(enc2, enc1_pool, "stage2", 6, 64, 16, 64, s2, s2);

        // Pool 160->80
        const s3 = S / 4;
        const enc2_pool = try allocator.alloc(f32, 64 * s3 * s3);
        defer allocator.free(enc2_pool);
        conv_mod.maxpool2d(enc2_pool, enc2, 64, s2, s2);

        // En3: RSU-5, in=64, mid=16, out=64, 80x80
        const enc3 = try allocator.alloc(f32, 64 * s3 * s3);
        defer allocator.free(enc3);
        self.rsuBlock(enc3, enc2_pool, "stage3", 5, 64, 16, 64, s3, s3);

        // Pool 80->40
        const s4 = S / 8;
        const enc3_pool = try allocator.alloc(f32, 64 * s4 * s4);
        defer allocator.free(enc3_pool);
        conv_mod.maxpool2d(enc3_pool, enc3, 64, s3, s3);

        // En4: RSU-4, in=64, mid=16, out=64, 40x40
        const enc4 = try allocator.alloc(f32, 64 * s4 * s4);
        defer allocator.free(enc4);
        self.rsuBlock(enc4, enc3_pool, "stage4", 4, 64, 16, 64, s4, s4);

        // Pool 40->20
        const s5 = S / 16;
        const enc4_pool = try allocator.alloc(f32, 64 * s5 * s5);
        defer allocator.free(enc4_pool);
        conv_mod.maxpool2d(enc4_pool, enc4, 64, s4, s4);

        // En5: RSU-4F (dilated), in=64, mid=16, out=64, 20x20
        const enc5 = try allocator.alloc(f32, 64 * s5 * s5);
        defer allocator.free(enc5);
        self.rsuBlockF(enc5, enc4_pool, "stage5", 64, 16, 64, s5, s5);

        // Pool 20->10
        const s6 = S / 32;
        const enc5_pool = try allocator.alloc(f32, 64 * s6 * s6);
        defer allocator.free(enc5_pool);
        conv_mod.maxpool2d(enc5_pool, enc5, 64, s5, s5);

        // En6: RSU-4F (dilated), in=64, mid=16, out=64, 10x10
        const enc6 = try allocator.alloc(f32, 64 * s6 * s6);
        defer allocator.free(enc6);
        self.rsuBlockF(enc6, enc5_pool, "stage6", 64, 16, 64, s6, s6);

        // ── Decoder ──
        // De5: upsample enc6 (10->20) + concat with enc5 -> RSU-4F
        const enc6_up = try allocator.alloc(f32, 64 * s5 * s5);
        defer allocator.free(enc6_up);
        conv_mod.upsample2x(enc6_up, enc6, 64, s6, s6);

        const dec5_in = try allocator.alloc(f32, 128 * s5 * s5);
        defer allocator.free(dec5_in);
        catChannels(dec5_in, enc6_up, 64, enc5, 64, s5, s5);

        const dec5 = try allocator.alloc(f32, 64 * s5 * s5);
        defer allocator.free(dec5);
        self.rsuBlockF(dec5, dec5_in, "stage5d", 128, 16, 64, s5, s5);

        // De4: upsample dec5 (20->40) + concat with enc4 -> RSU-4
        const dec5_up = try allocator.alloc(f32, 64 * s4 * s4);
        defer allocator.free(dec5_up);
        conv_mod.upsample2x(dec5_up, dec5, 64, s5, s5);

        const dec4_in = try allocator.alloc(f32, 128 * s4 * s4);
        defer allocator.free(dec4_in);
        catChannels(dec4_in, dec5_up, 64, enc4, 64, s4, s4);

        const dec4 = try allocator.alloc(f32, 64 * s4 * s4);
        defer allocator.free(dec4);
        self.rsuBlock(dec4, dec4_in, "stage4d", 4, 128, 16, 64, s4, s4);

        // De3: upsample dec4 (40->80) + concat with enc3 -> RSU-5
        const dec4_up = try allocator.alloc(f32, 64 * s3 * s3);
        defer allocator.free(dec4_up);
        conv_mod.upsample2x(dec4_up, dec4, 64, s4, s4);

        const dec3_in = try allocator.alloc(f32, 128 * s3 * s3);
        defer allocator.free(dec3_in);
        catChannels(dec3_in, dec4_up, 64, enc3, 64, s3, s3);

        const dec3 = try allocator.alloc(f32, 64 * s3 * s3);
        defer allocator.free(dec3);
        self.rsuBlock(dec3, dec3_in, "stage3d", 5, 128, 16, 64, s3, s3);

        // De2: upsample dec3 (80->160) + concat with enc2 -> RSU-6
        const dec3_up = try allocator.alloc(f32, 64 * s2 * s2);
        defer allocator.free(dec3_up);
        conv_mod.upsample2x(dec3_up, dec3, 64, s3, s3);

        const dec2_in = try allocator.alloc(f32, 128 * s2 * s2);
        defer allocator.free(dec2_in);
        catChannels(dec2_in, dec3_up, 64, enc2, 64, s2, s2);

        const dec2 = try allocator.alloc(f32, 64 * s2 * s2);
        defer allocator.free(dec2);
        self.rsuBlock(dec2, dec2_in, "stage2d", 6, 128, 16, 64, s2, s2);

        // De1: upsample dec2 (160->320) + concat with enc1 -> RSU-7
        const dec2_up = try allocator.alloc(f32, 64 * S * S);
        defer allocator.free(dec2_up);
        conv_mod.upsample2x(dec2_up, dec2, 64, s2, s2);

        const dec1_in = try allocator.alloc(f32, 128 * S * S);
        defer allocator.free(dec1_in);
        catChannels(dec1_in, dec2_up, 64, enc1, 64, S, S);

        const dec1 = try allocator.alloc(f32, 64 * S * S);
        defer allocator.free(dec1);
        self.rsuBlock(dec1, dec1_in, "stage1d", 7, 128, 16, 64, S, S);

        // ── Side outputs ──
        // Each stage -> 1x1 conv -> 1 channel -> upsample to 320x320
        const side1 = try allocator.alloc(f32, S * S);
        defer allocator.free(side1);
        self.convLayer(side1, dec1, "side1", 64, 1, S, S, 1, 1, 0, 1);

        const side2_small = try allocator.alloc(f32, s2 * s2);
        defer allocator.free(side2_small);
        self.convLayer(side2_small, dec2, "side2", 64, 1, s2, s2, 1, 1, 0, 1);
        const side2 = try allocator.alloc(f32, S * S);
        defer allocator.free(side2);
        conv_mod.resizeBilinear(side2, side2_small, 1, s2, s2, S, S);

        const side3_small = try allocator.alloc(f32, s3 * s3);
        defer allocator.free(side3_small);
        self.convLayer(side3_small, dec3, "side3", 64, 1, s3, s3, 1, 1, 0, 1);
        const side3 = try allocator.alloc(f32, S * S);
        defer allocator.free(side3);
        conv_mod.resizeBilinear(side3, side3_small, 1, s3, s3, S, S);

        const side4_small = try allocator.alloc(f32, s4 * s4);
        defer allocator.free(side4_small);
        self.convLayer(side4_small, dec4, "side4", 64, 1, s4, s4, 1, 1, 0, 1);
        const side4 = try allocator.alloc(f32, S * S);
        defer allocator.free(side4);
        conv_mod.resizeBilinear(side4, side4_small, 1, s4, s4, S, S);

        const side5_small = try allocator.alloc(f32, s5 * s5);
        defer allocator.free(side5_small);
        self.convLayer(side5_small, dec5, "side5", 64, 1, s5, s5, 1, 1, 0, 1);
        const side5 = try allocator.alloc(f32, S * S);
        defer allocator.free(side5);
        conv_mod.resizeBilinear(side5, side5_small, 1, s5, s5, S, S);

        const side6_small = try allocator.alloc(f32, s6 * s6);
        defer allocator.free(side6_small);
        self.convLayer(side6_small, enc6, "side6", 64, 1, s6, s6, 1, 1, 0, 1);
        const side6 = try allocator.alloc(f32, S * S);
        defer allocator.free(side6);
        conv_mod.resizeBilinear(side6, side6_small, 1, s6, s6, S, S);

        // ── Fusion ──
        // Concatenate 6 side outputs [6 x 320 x 320] -> 1x1 conv -> [1 x 320 x 320]
        const fused_in = try allocator.alloc(f32, 6 * S * S);
        defer allocator.free(fused_in);

        const side_ptrs = [6][]const f32{ side1, side2, side3, side4, side5, side6 };
        const side_chs = [6]u32{ 1, 1, 1, 1, 1, 1 };
        conv_mod.concatChannels(fused_in, &side_ptrs, &side_chs, S, S);

        const output = try allocator.alloc(f32, S * S);
        self.convLayer(output, fused_in, "outconv", 6, 1, S, S, 1, 1, 0, 1);

        // Sigmoid
        conv_mod.sigmoid(output);

        return output;
    }

    // ── Building blocks ──

    /// Single conv layer: conv2d (no relu). Used for side outputs and fusion.
    fn convLayer(
        self: *U2NetP,
        out: []f32,
        input: []const f32,
        name: []const u8,
        in_c: u32,
        out_c: u32,
        h: u32,
        w: u32,
        k: u32,
        stride: u32,
        pad: u32,
        dilation: u32,
    ) void {
        var name_buf: [128]u8 = undefined;
        const wname = std.fmt.bufPrint(&name_buf, "{s}.weight", .{name}) catch return;
        const weight = self.vfile.getTensor(wname) orelse return;

        var bname_buf: [128]u8 = undefined;
        const bname = std.fmt.bufPrint(&bname_buf, "{s}.bias", .{name}) catch return;
        const bias = self.vfile.getTensor(bname) orelse return;

        conv_mod.conv2d(out, input, weight, bias, in_c, h, w, out_c, k, stride, pad, dilation, self.pool);
    }

    /// Conv + ReLU with fused BN weights
    fn convBnRelu(
        self: *U2NetP,
        out: []f32,
        input: []const f32,
        name: []const u8,
        in_c: u32,
        out_c: u32,
        h: u32,
        w: u32,
        dilation: u32,
    ) void {
        var name_buf: [128]u8 = undefined;
        const wname = std.fmt.bufPrint(&name_buf, "{s}.weight", .{name}) catch return;
        const weight = self.vfile.getTensor(wname) orelse return;

        var bname_buf: [128]u8 = undefined;
        const bname = std.fmt.bufPrint(&bname_buf, "{s}.bias", .{name}) catch return;
        const bias = self.vfile.getTensor(bname) orelse return;

        const pad: u32 = dilation; // for 3x3 conv with dilation d, pad=d preserves spatial dims
        conv_mod.conv2d(out, input, weight, bias, in_c, h, w, out_c, 3, 1, pad, dilation, self.pool);

        // ReLU
        const out_hw: usize = @as(usize, h) * w;
        conv_mod.relu(out[0 .. @as(usize, out_c) * out_hw]);
    }

    /// RSU-N block (Residual U-block with depth N).
    /// Uses maxpool/upsample for spatial reduction.
    fn rsuBlock(
        self: *U2NetP,
        out: []f32,
        input: []const f32,
        stage: []const u8,
        depth: u32,
        in_c: u32,
        mid_c: u32,
        out_c: u32,
        h: u32,
        w: u32,
    ) void {
        const hw: usize = @as(usize, h) * w;

        // Input conv: in_c -> out_c (rebnconvin)
        var name_buf: [128]u8 = undefined;
        const in_name = std.fmt.bufPrint(&name_buf, "{s}.rebnconvin", .{stage}) catch return;
        self.convBnRelu(out, input, in_name, in_c, out_c, h, w, 1);

        // Save residual (copy out -> scratch[5])
        const res_size = @as(usize, out_c) * hw;
        @memcpy(self.scratch[5][0..res_size], out[0..res_size]);

        // Encoder path: depth-1 stages with maxpool between
        // We alternate between scratch buffers for encoder features
        var enc_bufs: [8]struct { data: []f32, c: u32, h: u32, w: u32 } = undefined;
        enc_bufs[0] = .{ .data = out, .c = out_c, .h = h, .w = w };

        var cur_h = h;
        var cur_w = w;
        var cur_input: []const f32 = out[0..res_size];

        for (1..depth) |i| {
            // Pool current input
            const ph = cur_h / 2;
            const pw = cur_w / 2;
            const c_to_use: u32 = if (i == 1) out_c else mid_c;
            const pool_size = @as(usize, c_to_use) * ph * pw;

            // Use scratch[0] for pool output (temporary)
            conv_mod.maxpool2d(self.scratch[0][0..pool_size], cur_input, c_to_use, cur_h, cur_w);

            // Conv: c_to_use -> mid_c
            const enc_size = @as(usize, mid_c) * ph * pw;
            var enc_name_buf: [128]u8 = undefined;
            const enc_name = std.fmt.bufPrint(&enc_name_buf, "{s}.rebnconv{d}", .{ stage, i }) catch return;

            // Allocate from scratch for this encoder level's output
            // We need these to persist for skip connections, so we use scratch[1..4]
            const scratch_idx = @min(i, @as(usize, 4));
            self.convBnRelu(self.scratch[scratch_idx][0..enc_size], self.scratch[0][0..pool_size], enc_name, c_to_use, mid_c, ph, pw, 1);

            enc_bufs[i] = .{ .data = self.scratch[scratch_idx], .c = mid_c, .h = ph, .w = pw };
            cur_h = ph;
            cur_w = pw;
            cur_input = self.scratch[scratch_idx][0..enc_size];
        }

        // Bottleneck conv (at deepest level, same spatial size, no pool)
        {
            const bot_size = @as(usize, mid_c) * cur_h * cur_w;
            var bot_name_buf: [128]u8 = undefined;
            const bot_name = std.fmt.bufPrint(&bot_name_buf, "{s}.rebnconv{d}", .{ stage, depth }) catch return;
            // Use scratch[0] for bottleneck output
            self.convBnRelu(self.scratch[0][0..bot_size], cur_input, bot_name, mid_c, mid_c, cur_h, cur_w, 1);
            cur_input = self.scratch[0][0..bot_size];
        }

        // Decoder path: upsample + add skip + conv
        var dec_idx: u32 = @intCast(depth - 1);
        while (dec_idx >= 1) : (dec_idx -= 1) {
            const skip = enc_bufs[dec_idx];
            const target_h = skip.h;
            const target_w = skip.w;
            const mid_hw = @as(usize, target_h) * target_w;

            // Upsample current
            const up_size = @as(usize, mid_c) * mid_hw;
            // scratch[0] has current, upsample to a temp area
            // We need a temp for the upsampled result
            const up_buf = self.scratch[if (dec_idx % 2 == 0) @as(usize, 3) else @as(usize, 2)];
            conv_mod.resizeBilinear(up_buf[0..up_size], cur_input, mid_c, cur_h, cur_w, target_h, target_w);

            // Add skip connection (element-wise)
            conv_mod.add(up_buf[0..up_size], up_buf[0..up_size], skip.data[0..up_size]);

            // Conv on concatenated result
            const dec_c: u32 = if (dec_idx == 1) out_c else mid_c;
            const dec_size = @as(usize, dec_c) * mid_hw;
            var dec_name_buf: [128]u8 = undefined;
            const dec_name = std.fmt.bufPrint(&dec_name_buf, "{s}.rebnconv{d}d", .{ stage, dec_idx }) catch return;

            const dec_out = self.scratch[if (dec_idx % 2 == 0) @as(usize, 0) else @as(usize, 1)];
            self.convBnRelu(dec_out[0..dec_size], up_buf[0..up_size], dec_name, mid_c, dec_c, target_h, target_w, 1);

            cur_input = dec_out[0..dec_size];
            cur_h = target_h;
            cur_w = target_w;

            if (dec_idx == 1) break;
        }

        // Residual add: out = decoder_output + saved_residual
        conv_mod.add(out[0..res_size], cur_input[0..res_size], self.scratch[5][0..res_size]);
    }

    /// RSU-F block (Residual U-block with dilated convolutions instead of pooling).
    /// Used for the deepest encoder/decoder stages where spatial dims are already small.
    fn rsuBlockF(
        self: *U2NetP,
        out: []f32,
        input: []const f32,
        stage: []const u8,
        in_c: u32,
        mid_c: u32,
        out_c: u32,
        h: u32,
        w: u32,
    ) void {
        const hw: usize = @as(usize, h) * w;

        // Input conv
        var name_buf: [128]u8 = undefined;
        const in_name = std.fmt.bufPrint(&name_buf, "{s}.rebnconvin", .{stage}) catch return;
        self.convBnRelu(out, input, in_name, in_c, out_c, h, w, 1);

        // Save residual
        const res_size = @as(usize, out_c) * hw;
        @memcpy(self.scratch[5][0..res_size], out[0..res_size]);

        // Encoder with increasing dilation (no spatial reduction)
        const mid_size = @as(usize, mid_c) * hw;

        // Conv1: out_c -> mid_c, dilation=1
        {
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv1", .{stage}) catch return;
            self.convBnRelu(self.scratch[0][0..mid_size], out[0..res_size], name, out_c, mid_c, h, w, 1);
        }

        // Conv2: mid_c -> mid_c, dilation=2
        {
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv2", .{stage}) catch return;
            self.convBnRelu(self.scratch[1][0..mid_size], self.scratch[0][0..mid_size], name, mid_c, mid_c, h, w, 2);
        }

        // Conv3: mid_c -> mid_c, dilation=4
        {
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv3", .{stage}) catch return;
            self.convBnRelu(self.scratch[2][0..mid_size], self.scratch[1][0..mid_size], name, mid_c, mid_c, h, w, 4);
        }

        // Bottleneck: conv4, dilation=8
        {
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv4", .{stage}) catch return;
            self.convBnRelu(self.scratch[3][0..mid_size], self.scratch[2][0..mid_size], name, mid_c, mid_c, h, w, 8);
        }

        // Decoder: add skip + conv (decreasing dilation)
        // Dec3: scratch[3] + scratch[2] (skip from conv3 output)
        {
            conv_mod.add(self.scratch[3][0..mid_size], self.scratch[3][0..mid_size], self.scratch[2][0..mid_size]);
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv3d", .{stage}) catch return;
            self.convBnRelu(self.scratch[4][0..mid_size], self.scratch[3][0..mid_size], name, mid_c, mid_c, h, w, 4);
        }

        // Dec2: scratch[4] + scratch[1] (skip from conv2 output)
        {
            conv_mod.add(self.scratch[4][0..mid_size], self.scratch[4][0..mid_size], self.scratch[1][0..mid_size]);
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv2d", .{stage}) catch return;
            self.convBnRelu(self.scratch[3][0..mid_size], self.scratch[4][0..mid_size], name, mid_c, mid_c, h, w, 2);
        }

        // Dec1: scratch[3] + scratch[0] (skip from conv1 output)
        {
            conv_mod.add(self.scratch[3][0..mid_size], self.scratch[3][0..mid_size], self.scratch[0][0..mid_size]);
            var n: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&n, "{s}.rebnconv1d", .{stage}) catch return;
            self.convBnRelu(self.scratch[0][0 .. @as(usize, out_c) * hw], self.scratch[3][0..mid_size], name, mid_c, out_c, h, w, 1);
        }

        // Residual add
        conv_mod.add(out[0..res_size], self.scratch[0][0..res_size], self.scratch[5][0..res_size]);
    }
};

/// Concatenate two tensors along channel dimension
fn catChannels(out: []f32, a: []const f32, a_c: u32, b: []const f32, b_c: u32, h: u32, w: u32) void {
    const hw: usize = @as(usize, h) * w;
    const a_size = @as(usize, a_c) * hw;
    const b_size = @as(usize, b_c) * hw;
    @memcpy(out[0..a_size], a[0..a_size]);
    @memcpy(out[a_size..][0..b_size], b[0..b_size]);
}
