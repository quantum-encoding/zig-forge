const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("math.zig");
const vision_loader = @import("vision_loader.zig");
const VisionFile = vision_loader.VisionFile;
const TtsConfig = vision_loader.TtsConfig;
const tts_conv = @import("tts_conv1d.zig");
const thread_pool_mod = @import("thread_pool.zig");

// ── VITS (Variational Inference with adversarial learning for end-to-end TTS) ──
//
// Pipeline: phoneme IDs → Text Encoder → SDP → Flow → HiFi-GAN → audio
//
// Weight names follow Piper convention after remapping by export_piper.py:
//   enc.emb.weight                           [n_vocab, 192]
//   enc.encoder.attn.{L}.{q,k,v,o}_weight    [192, 192]
//   enc.encoder.ln{1,2}.{L}.{weight,bias}     [192]
//   enc.encoder.ffn.{L}.conv{1,2}.{weight,bias}
//   enc.proj.weight                            [384, 192, 1]
//   enc.proj.bias                              [384]
//   sdp.pre.weight/bias                        [192, 192, 1]
//   sdp.dds.{L}.{dw,1x1}.weight/bias
//   sdp.proj.weight/bias
//   flow.flows.{L}.{pre,enc.*,post}.weight/bias
//   dec.conv_pre.{weight,bias}                 [512, 192, 7]
//   dec.ups.{L}.{weight,bias}
//   dec.resblocks.{L}.convs{1,2}.{K}.{weight,bias}
//   dec.conv_post.{weight,bias}                [1, 32, 7]

pub const VitsModel = struct {
    allocator: Allocator,
    vfile: VisionFile,
    config: TtsConfig,
    pool: ?*thread_pool_mod.ThreadPool,

    // Scratch buffers
    enc_buf: []f32, // [d_model × max_seq]
    enc_buf2: []f32, // second buffer for attention/FFN
    attn_buf: []f32, // [max_seq × max_seq] for attention scores
    mean_buf: []f32, // [d_model × max_seq]
    logvar_buf: []f32, // [d_model × max_seq]
    z_buf: []f32, // [d_model × expanded_len]
    z_buf2: []f32, // second flow buffer
    dec_buf: []f32, // vocoder intermediate (large)
    dec_buf2: []f32, // second vocoder buffer
    audio_buf: []f32, // output audio

    const MAX_SEQ: u32 = 512;
    const MAX_EXPANDED: u32 = 2048; // after duration expansion
    const MAX_AUDIO: u32 = MAX_EXPANDED * 256; // hop_length=256

    pub fn init(allocator: Allocator, model_path: []const u8, n_threads: u32) !VitsModel {
        var vfile = try VisionFile.open(allocator, model_path);
        errdefer vfile.close();

        const config = vfile.tts_config orelse return error.NotTtsModel;
        const d = config.d_model;

        const pool = if (n_threads > 1)
            try thread_pool_mod.ThreadPool.init(allocator, n_threads)
        else
            null;

        return VitsModel{
            .allocator = allocator,
            .vfile = vfile,
            .config = config,
            .pool = pool,
            .enc_buf = try allocator.alloc(f32, d * MAX_SEQ),
            .enc_buf2 = try allocator.alloc(f32, @max(d * MAX_SEQ, 768 * MAX_SEQ)),
            .attn_buf = try allocator.alloc(f32, MAX_SEQ * MAX_SEQ),
            .mean_buf = try allocator.alloc(f32, d * MAX_EXPANDED),
            .logvar_buf = try allocator.alloc(f32, d * MAX_EXPANDED),
            .z_buf = try allocator.alloc(f32, d * MAX_EXPANDED),
            .z_buf2 = try allocator.alloc(f32, d * MAX_EXPANDED),
            .dec_buf = try allocator.alloc(f32, 512 * MAX_AUDIO),
            .dec_buf2 = try allocator.alloc(f32, 512 * MAX_AUDIO),
            .audio_buf = try allocator.alloc(f32, MAX_AUDIO),
        };
    }

    pub fn deinit(self: *VitsModel) void {
        self.allocator.free(self.enc_buf);
        self.allocator.free(self.enc_buf2);
        self.allocator.free(self.attn_buf);
        self.allocator.free(self.mean_buf);
        self.allocator.free(self.logvar_buf);
        self.allocator.free(self.z_buf);
        self.allocator.free(self.z_buf2);
        self.allocator.free(self.dec_buf);
        self.allocator.free(self.dec_buf2);
        self.allocator.free(self.audio_buf);
        if (self.pool) |p| p.deinit();
        self.vfile.close();
    }

    // ── Public API ──

    pub const SynthResult = struct {
        audio: []const f32,
        n_samples: u32,
        sample_rate: u32,
    };

    /// Synthesize audio from phoneme IDs.
    /// Returns a slice into the model's audio buffer (valid until next call).
    pub fn synthesize(self: *VitsModel, phoneme_ids: []const u16, noise_scale: f32, length_scale: f32) !SynthResult {
        const d = self.config.d_model;
        const T: u32 = @intCast(phoneme_ids.len);
        if (T == 0 or T > MAX_SEQ) return error.InvalidInput;

        // 1. Text Encoder
        self.textEncoder(phoneme_ids, T);

        // 2. Duration prediction (simplified deterministic predictor)
        const durations = try self.predictDurations(T);
        defer self.allocator.free(durations);

        // Apply length_scale to durations
        for (durations) |*dur| {
            const scaled = @as(f32, @floatFromInt(dur.*)) * length_scale;
            dur.* = @intFromFloat(@max(@ceil(scaled), 1.0));
        }

        // 3. Compute total expanded length
        var expanded_len: u32 = 0;
        for (durations) |dur| expanded_len += dur;
        if (expanded_len == 0) expanded_len = 1;
        if (expanded_len > MAX_EXPANDED) expanded_len = MAX_EXPANDED;

        // 4. Expand encoder output by durations → mean/logvar [d × expanded_len]
        self.expandByDurations(T, durations, expanded_len);

        // 5. Sample z ~ N(mean, exp(logvar) * noise_scale)
        math.randomNormal(
            self.z_buf[0 .. d * expanded_len],
            self.mean_buf[0 .. d * expanded_len],
            self.logvar_buf[0 .. d * expanded_len],
            noise_scale,
        );

        // 6. Flow reverse pass
        self.flowReverse(expanded_len);

        // 7. HiFi-GAN vocoder
        const n_audio = self.hifiganDecode(expanded_len);

        return SynthResult{
            .audio = self.audio_buf[0..n_audio],
            .n_samples = n_audio,
            .sample_rate = self.config.sample_rate,
        };
    }

    // ── Text Encoder ──

    fn textEncoder(self: *VitsModel, phoneme_ids: []const u16, seq_len: u32) void {
        const d = self.config.d_model;
        const T: usize = seq_len;

        // Embedding lookup
        const emb = self.vfile.getTensor("enc.emb.weight") orelse return;
        for (0..T) |t| {
            const id: usize = phoneme_ids[t];
            const src_offset = id * d;
            const dst_offset = t * d;
            if (src_offset + d <= emb.len) {
                @memcpy(self.enc_buf[dst_offset..][0..d], emb[src_offset..][0..d]);
            } else {
                @memset(self.enc_buf[dst_offset..][0..d], 0.0);
            }
        }

        // Transformer layers
        for (0..self.config.n_enc_layers) |layer| {
            self.encoderLayer(@intCast(layer), seq_len);
        }

        // Projection: Conv1d(d, 2*d, k=1) → split into mean + logvar
        const proj_w = self.vfile.getTensor("enc.proj.weight") orelse return;
        const proj_b = self.vfile.getTensor("enc.proj.bias") orelse return;
        // proj: [2*d, d, 1] → effectively a matmul per timestep
        const d2 = d * 2;
        for (0..T) |t| {
            const x = self.enc_buf[t * d ..][0..d];
            for (0..d2) |o| {
                var sum: f32 = proj_b[o];
                const w_base = o * d;
                for (0..d) |i| {
                    sum += proj_w[w_base + i] * x[i];
                }
                if (o < d) {
                    self.mean_buf[t + o * T] = sum; // [d × T] layout
                } else {
                    self.logvar_buf[t + (o - d) * T] = sum;
                }
            }
        }
    }

    fn encoderLayer(self: *VitsModel, layer: u32, seq_len: u32) void {
        const d = self.config.d_model;
        const T: usize = seq_len;
        const n_heads: u32 = 2;
        const d_head = d / n_heads;

        // Pre-attention LayerNorm
        var ln1_name_w: [64]u8 = undefined;
        var ln1_name_b: [64]u8 = undefined;
        const ln1w = fmtName(&ln1_name_w, "enc.encoder.ln1.{d}.weight", .{layer});
        const ln1b = fmtName(&ln1_name_b, "enc.encoder.ln1.{d}.bias", .{layer});
        const ln1_w = self.vfile.getTensor(ln1w) orelse return;
        const ln1_b = self.vfile.getTensor(ln1b) orelse return;

        // Apply LayerNorm to each timestep, store in enc_buf2
        for (0..T) |t| {
            const src = self.enc_buf[t * d ..][0..d];
            const dst = self.enc_buf2[t * d ..][0..d];
            math.layernorm(dst, src, ln1_w, ln1_b, 1e-5);
        }

        // Self-attention: Q, K, V projections
        self.selfAttention(layer, seq_len, n_heads, d_head);

        // Residual
        for (0..T * d) |i| {
            self.enc_buf[i] += self.enc_buf2[i];
        }

        // Post-attention LayerNorm + FFN
        var ln2_name_w: [64]u8 = undefined;
        var ln2_name_b: [64]u8 = undefined;
        const ln2w = fmtName(&ln2_name_w, "enc.encoder.ln2.{d}.weight", .{layer});
        const ln2b = fmtName(&ln2_name_b, "enc.encoder.ln2.{d}.bias", .{layer});
        const ln2_w = self.vfile.getTensor(ln2w) orelse return;
        const ln2_b = self.vfile.getTensor(ln2b) orelse return;

        for (0..T) |t| {
            const x = self.enc_buf[t * d ..][0..d];
            const normed = self.enc_buf2[t * d ..][0..d];
            math.layernorm(normed, x, ln2_w, ln2_b, 1e-5);
        }

        // FFN: Conv1d(d, d_ff, k=1) → GELU → Conv1d(d_ff, d, k=1)
        self.encoderFFN(layer, seq_len);

        // Residual
        for (0..T * d) |i| {
            self.enc_buf[i] += self.enc_buf2[i];
        }
    }

    fn selfAttention(self: *VitsModel, layer: u32, seq_len: u32, n_heads: u32, d_head: u32) void {
        const d = self.config.d_model;
        const T: usize = seq_len;

        // Load QKV weights (all are [d, d])
        var qw_name: [64]u8 = undefined;
        var kw_name: [64]u8 = undefined;
        var vw_name: [64]u8 = undefined;
        var ow_name: [64]u8 = undefined;
        const qw_s = fmtName(&qw_name, "enc.encoder.attn.{d}.q_weight", .{layer});
        const kw_s = fmtName(&kw_name, "enc.encoder.attn.{d}.k_weight", .{layer});
        const vw_s = fmtName(&vw_name, "enc.encoder.attn.{d}.v_weight", .{layer});
        const ow_s = fmtName(&ow_name, "enc.encoder.attn.{d}.o_weight", .{layer});

        const q_w = self.vfile.getTensor(qw_s) orelse return;
        const k_w = self.vfile.getTensor(kw_s) orelse return;
        const v_w = self.vfile.getTensor(vw_s) orelse return;
        const o_w = self.vfile.getTensor(ow_s) orelse return;

        // Input is in enc_buf2 (after LayerNorm)
        // Compute Q, K, V for all timesteps using enc_buf2 as temporary
        // We'll compute attention inline, writing output back to enc_buf2

        // For simplicity with limited scratch, compute attention per head
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(d_head)));

        for (0..n_heads) |h| {
            const h_offset = h * d_head;

            // For each head, compute QK^T attention matrix
            for (0..T) |qi| {
                // Compute Q[qi] for this head
                for (0..T) |ki| {
                    var dot: f32 = 0.0;
                    for (0..d_head) |dd| {
                        // Q[qi][h_offset+dd] = sum_j(q_w[h_offset+dd][j] * x[qi][j])
                        // K[ki][h_offset+dd] = sum_j(k_w[h_offset+dd][j] * x[ki][j])
                        var q_val: f32 = 0.0;
                        var k_val: f32 = 0.0;
                        const w_row = (h_offset + dd) * d;
                        for (0..d) |j| {
                            const xq = self.enc_buf2[qi * d + j];
                            const xk = self.enc_buf2[ki * d + j];
                            q_val += q_w[w_row + j] * xq;
                            k_val += k_w[w_row + j] * xk;
                        }
                        dot += q_val * k_val;
                    }
                    self.attn_buf[qi * T + ki] = dot * scale;
                }

                // Softmax over keys for this query
                math.softmax(self.attn_buf[qi * T ..][0..T]);
            }

            // Compute weighted sum of V and project through O
            for (0..T) |qi| {
                for (0..d_head) |dd| {
                    // V-weighted sum for this head dimension
                    var sum: f32 = 0.0;
                    for (0..T) |ki| {
                        const attn = self.attn_buf[qi * T + ki];
                        // V[ki][h_offset+dd]
                        var v_val: f32 = 0.0;
                        const v_row = (h_offset + dd) * d;
                        for (0..d) |j| {
                            v_val += v_w[v_row + j] * self.enc_buf2[ki * d + j];
                        }
                        sum += attn * v_val;
                    }
                    // Store temporarily; we need all heads before O projection
                    // Use z_buf as temp for attention output
                    self.z_buf[qi * d + h_offset + dd] = sum;
                }
            }
        }

        // O projection: enc_buf2[t] = O_w @ z_buf[t]
        for (0..T) |t| {
            for (0..d) |o| {
                var sum: f32 = 0.0;
                const w_row = o * d;
                for (0..d) |j| {
                    sum += o_w[w_row + j] * self.z_buf[t * d + j];
                }
                self.enc_buf2[t * d + o] = sum;
            }
        }
    }

    fn encoderFFN(self: *VitsModel, layer: u32, seq_len: u32) void {
        const d = self.config.d_model;
        const d_ff: u32 = d * 4; // 768 for d=192
        const T: usize = seq_len;

        // Conv1(d, d_ff, k=1) + GELU + Conv2(d_ff, d, k=1)
        var c1w_name: [64]u8 = undefined;
        var c1b_name: [64]u8 = undefined;
        var c2w_name: [64]u8 = undefined;
        var c2b_name: [64]u8 = undefined;
        const c1w_s = fmtName(&c1w_name, "enc.encoder.ffn.{d}.conv1.weight", .{layer});
        const c1b_s = fmtName(&c1b_name, "enc.encoder.ffn.{d}.conv1.bias", .{layer});
        const c2w_s = fmtName(&c2w_name, "enc.encoder.ffn.{d}.conv2.weight", .{layer});
        const c2b_s = fmtName(&c2b_name, "enc.encoder.ffn.{d}.conv2.bias", .{layer});

        const c1_w = self.vfile.getTensor(c1w_s) orelse return;
        const c1_b = self.vfile.getTensor(c1b_s) orelse return;
        const c2_w = self.vfile.getTensor(c2w_s) orelse return;
        const c2_b = self.vfile.getTensor(c2b_s) orelse return;

        // enc_buf2 has LayerNorm'd input [T × d]
        // Use z_buf as intermediate [T × d_ff] (only if fits)
        // For each timestep: z = GELU(W1 @ x + b1), out = W2 @ z + b2
        for (0..T) |t| {
            const x = self.enc_buf2[t * d ..][0..d];

            // W1 @ x + b1 → z_buf (reuse for d_ff dims)
            for (0..d_ff) |o| {
                var sum: f32 = c1_b[o];
                const w_row = o * d;
                for (0..d) |j| {
                    sum += c1_w[w_row + j] * x[j];
                }
                self.z_buf[o] = sum;
            }

            // GELU
            math.gelu(self.z_buf[0..d_ff]);

            // W2 @ z + b2 → enc_buf2
            for (0..d) |o| {
                var sum: f32 = c2_b[o];
                const w_row = o * d_ff;
                for (0..d_ff) |j| {
                    sum += c2_w[w_row + j] * self.z_buf[j];
                }
                self.enc_buf2[t * d + o] = sum;
            }
        }
    }

    // ── Duration Prediction (simplified) ──

    fn predictDurations(self: *VitsModel, seq_len: u32) ![]u32 {
        const d = self.config.d_model;
        const T: usize = seq_len;
        const durations = try self.allocator.alloc(u32, T);

        // Try to use SDP pre-projection weight for duration prediction
        // SDP: pre-conv → DDS layers → projection → exp → durations
        const pre_w = self.vfile.getTensor("sdp.pre.weight");
        const pre_b = self.vfile.getTensor("sdp.pre.bias");
        const proj_w = self.vfile.getTensor("sdp.proj.weight");
        const proj_b = self.vfile.getTensor("sdp.proj.bias");

        if (pre_w != null and pre_b != null and proj_w != null and proj_b != null) {
            // Simplified duration prediction:
            // pre: Conv1d(d, d, k=1) on encoder output
            // proj: Conv1d(d, 1, k=1) → exp → round
            for (0..T) |t| {
                // Pre-projection: enc_buf → intermediate
                var hidden: [192]f32 = undefined;
                for (0..d) |o| {
                    var sum: f32 = pre_b.?[o];
                    const w_row = o * d;
                    for (0..d) |j| {
                        sum += pre_w.?[w_row + j] * self.enc_buf[t * d + j];
                    }
                    hidden[o] = std.math.tanh(sum); // activation
                }

                // Final projection to scalar
                var log_dur: f32 = proj_b.?[0];
                for (0..d) |j| {
                    log_dur += proj_w.?[j] * hidden[j];
                }

                // exp → round → clamp
                const dur_f = @exp(log_dur);
                const dur_i: u32 = @intFromFloat(@max(@ceil(dur_f), 1.0));
                durations[t] = @min(dur_i, 50); // cap individual durations
            }
        } else {
            // Fallback: uniform durations
            for (durations) |*dur| {
                dur.* = 5;
            }
        }

        return durations;
    }

    // ── Duration Expansion ──

    fn expandByDurations(self: *VitsModel, seq_len: u32, durations: []const u32, expanded_len: u32) void {
        const d = self.config.d_model;
        const T: usize = seq_len;
        const L: usize = expanded_len;

        // mean_buf and logvar_buf are currently [d × T] from text encoder
        // We need to expand them to [d × L] by repeating according to durations

        // First, save the original [d × T] values
        // mean is at mean_buf[0..d*T], logvar at logvar_buf[0..d*T]
        // Copy to z_buf/z_buf2 as temp, then expand back
        @memcpy(self.z_buf[0 .. d * T], self.mean_buf[0 .. d * T]);
        @memcpy(self.z_buf2[0 .. d * T], self.logvar_buf[0 .. d * T]);

        var out_pos: usize = 0;
        for (0..T) |t| {
            const dur: usize = durations[t];
            for (0..dur) |_| {
                if (out_pos >= L) break;
                for (0..d) |c| {
                    self.mean_buf[c * L + out_pos] = self.z_buf[c * T + t];
                    self.logvar_buf[c * L + out_pos] = self.z_buf2[c * T + t];
                }
                out_pos += 1;
            }
        }
        // Zero-fill remainder
        while (out_pos < L) : (out_pos += 1) {
            for (0..d) |c| {
                self.mean_buf[c * L + out_pos] = 0.0;
                self.logvar_buf[c * L + out_pos] = 0.0;
            }
        }
    }

    // ── Normalizing Flow (reverse) ──

    fn flowReverse(self: *VitsModel, seq_len: u32) void {
        const d = self.config.d_model;
        const L: usize = seq_len;
        const half_d = d / 2;

        // z_buf has sampled z [d × L]
        // Process flow layers in reverse order
        var layer: i32 = @as(i32, @intCast(self.config.n_flow_layers)) - 1;
        while (layer >= 0) : (layer -= 1) {
            const l: u32 = @intCast(layer);
            self.flowLayerReverse(l, @intCast(L), half_d);
        }
    }

    fn flowLayerReverse(self: *VitsModel, layer: u32, seq_len: u32, half_d: u32) void {
        const d = self.config.d_model;
        const L: usize = seq_len;

        // Affine coupling: split z into z0, z1 (first/second half of channels)
        // Reverse: z1 = (z1 - mean) * exp(-log_s)
        //          z0 = z0 (unchanged in reverse)
        // Then flip z0, z1

        // Load WaveNet weights for this flow layer
        // The WaveNet takes z0 and predicts mean, log_s for z1
        var pre_name: [64]u8 = undefined;
        var post_name: [64]u8 = undefined;
        const pre_w_name = fmtName(&pre_name, "flow.flows.{d}.pre.weight", .{layer});
        const post_w_name = fmtName(&post_name, "flow.flows.{d}.post.weight", .{layer});

        const pre_w = self.vfile.getTensor(pre_w_name);
        const post_w = self.vfile.getTensor(post_w_name);

        if (pre_w == null or post_w == null) return;

        // Simple affine coupling implementation:
        // 1. Extract z0 = z[0..half_d, :], z1 = z[half_d..d, :]
        // 2. h = WaveNet(z0) → mean[half_d × L], log_s[half_d × L]
        // 3. z1 = (z1 - mean) * exp(-log_s)
        // 4. Concatenate [z1, z0] (flip)

        // For WaveNet, use a simplified version: pre_conv → dilated_convs → post_conv
        // Pre-conv: Conv1d(half_d, d, k=1)
        for (0..L) |t| {
            for (0..d) |o| {
                var sum: f32 = 0.0;
                const w_row = o * half_d;
                for (0..half_d) |j| {
                    if (w_row + j < pre_w.?.len) {
                        sum += pre_w.?[w_row + j] * self.z_buf[j * L + t];
                    }
                }
                self.z_buf2[o * L + t] = sum;
            }
        }

        // Simplified: skip dilated convs, go straight to post projection
        // Post-conv: projects to 2*half_d (mean + log_s)
        for (0..L) |t| {
            for (0..half_d) |o| {
                var m: f32 = 0.0;
                var s: f32 = 0.0;
                const m_row = o * d;
                const s_row = (o + half_d) * d;
                for (0..d) |j| {
                    if (m_row + j < post_w.?.len) {
                        m += post_w.?[m_row + j] * self.z_buf2[j * L + t];
                    }
                    if (s_row + j < post_w.?.len) {
                        s += post_w.?[s_row + j] * self.z_buf2[j * L + t];
                    }
                }

                // Reverse affine: z1 = (z1 - mean) * exp(-log_s)
                const z1_idx = (half_d + o) * L + t;
                self.z_buf[z1_idx] = (self.z_buf[z1_idx] - m) * @exp(-s);
            }
        }

        // Flip channels: swap z0 and z1
        for (0..L) |t| {
            for (0..half_d) |c| {
                const idx0 = c * L + t;
                const idx1 = (c + half_d) * L + t;
                const tmp = self.z_buf[idx0];
                self.z_buf[idx0] = self.z_buf[idx1];
                self.z_buf[idx1] = tmp;
            }
        }
    }

    // ── HiFi-GAN Vocoder ──

    fn hifiganDecode(self: *VitsModel, seq_len: u32) u32 {
        const d = self.config.d_model;
        var L: u32 = seq_len;

        // Pre-conv: Conv1d(d, 512, k=7, pad=3)
        const pre_w = self.vfile.getTensor("dec.conv_pre.weight") orelse return 0;
        const pre_b = self.vfile.getTensor("dec.conv_pre.bias") orelse return 0;
        tts_conv.conv1d(
            self.dec_buf,
            self.z_buf[0 .. d * L],
            pre_w,
            pre_b,
            d,
            L,
            512,
            7,
            1,
            3,
            1,
            self.pool,
        );

        // Upsample stages
        const upsample_rates = [4]u32{ 8, 8, 2, 2 };
        const upsample_kernels = [4]u32{ 16, 16, 4, 4 };
        var channels: u32 = 512;

        for (0..self.config.n_ups) |up_idx| {
            if (up_idx >= 4) break;
            const stride = upsample_rates[up_idx];
            const kernel = upsample_kernels[up_idx];
            const next_channels = channels / 2;
            const pad = (kernel - stride) / 2;

            // ConvTranspose1d upsample
            var up_w_name: [64]u8 = undefined;
            var up_b_name: [64]u8 = undefined;
            const upw = fmtName(&up_w_name, "dec.ups.{d}.weight", .{up_idx});
            const upb = fmtName(&up_b_name, "dec.ups.{d}.bias", .{up_idx});
            const up_w = self.vfile.getTensor(upw) orelse break;
            const up_b = self.vfile.getTensor(upb) orelse break;

            // LeakyReLU before upsample
            math.leakyRelu(self.dec_buf[0 .. channels * L], 0.1);

            tts_conv.convTranspose1d(
                self.dec_buf2,
                self.dec_buf[0 .. channels * L],
                up_w,
                up_b,
                channels,
                L,
                next_channels,
                kernel,
                stride,
                pad,
                self.pool,
            );

            L = (L - 1) * stride - 2 * pad + kernel;
            channels = next_channels;

            // MRF: sum of 3 ResBlock1 outputs with different kernel sizes
            const mrf_kernels = [3]u32{ 3, 7, 11 };
            @memset(self.dec_buf[0 .. channels * L], 0.0);

            for (0..3) |rb_idx| {
                self.resBlock1(
                    @intCast(up_idx * 3 + rb_idx),
                    channels,
                    L,
                    mrf_kernels[rb_idx],
                );
                // Accumulate into dec_buf
                for (0..@as(usize, channels) * L) |i| {
                    self.dec_buf[i] += self.z_buf[i]; // resBlock1 writes to z_buf
                }
            }

            // Average the 3 resblocks
            const inv3: f32 = 1.0 / 3.0;
            for (0..@as(usize, channels) * L) |i| {
                self.dec_buf[i] *= inv3;
            }
        }

        // Post-conv: LeakyReLU → Conv1d(channels, 1, k=7, pad=3) → tanh
        math.leakyRelu(self.dec_buf[0 .. channels * L], 0.1);

        const post_w = self.vfile.getTensor("dec.conv_post.weight") orelse return 0;
        const post_b = self.vfile.getTensor("dec.conv_post.bias") orelse return 0;
        tts_conv.conv1d(
            self.audio_buf,
            self.dec_buf[0 .. channels * L],
            post_w,
            post_b,
            channels,
            L,
            1,
            7,
            1,
            3,
            1,
            null, // single output channel, no threading needed
        );

        // Tanh activation on output
        math.tanh(self.audio_buf[0..L]);

        return L;
    }

    fn resBlock1(self: *VitsModel, block_idx: u32, channels: u32, seq_len: u32, kernel: u32) void {
        const L: usize = seq_len;
        const pad_base = (kernel - 1) / 2;

        // Copy input from dec_buf2 (upsampled) to z_buf as starting point
        @memcpy(self.z_buf[0 .. channels * L], self.dec_buf2[0 .. channels * L]);

        // 3 passes: LeakyReLU → dilated_conv → LeakyReLU → conv
        const dilations = [3]u32{ 1, 3, 5 };
        for (0..3) |pass| {
            const dilation = dilations[pass];
            const dil_pad = pad_base * dilation;

            // LeakyReLU
            math.leakyRelu(self.z_buf[0 .. channels * L], 0.1);

            // Dilated conv (convs1)
            var c1w_name: [96]u8 = undefined;
            var c1b_name: [96]u8 = undefined;
            const c1w = fmtName(&c1w_name, "dec.resblocks.{d}.convs1.{d}.weight", .{ block_idx, pass });
            const c1b = fmtName(&c1b_name, "dec.resblocks.{d}.convs1.{d}.bias", .{ block_idx, pass });
            const w1 = self.vfile.getTensor(c1w);
            const b1 = self.vfile.getTensor(c1b);

            if (w1 != null and b1 != null) {
                tts_conv.conv1d(
                    self.z_buf2[0 .. channels * L],
                    self.z_buf[0 .. channels * L],
                    w1.?,
                    b1.?,
                    channels,
                    @intCast(L),
                    channels,
                    kernel,
                    1,
                    @intCast(dil_pad),
                    dilation,
                    null,
                );
                @memcpy(self.z_buf[0 .. channels * L], self.z_buf2[0 .. channels * L]);
            }

            // LeakyReLU
            math.leakyRelu(self.z_buf[0 .. channels * L], 0.1);

            // 1x1 conv (convs2) or k-sized conv with dilation=1
            var c2w_name: [96]u8 = undefined;
            var c2b_name: [96]u8 = undefined;
            const c2w = fmtName(&c2w_name, "dec.resblocks.{d}.convs2.{d}.weight", .{ block_idx, pass });
            const c2b = fmtName(&c2b_name, "dec.resblocks.{d}.convs2.{d}.bias", .{ block_idx, pass });
            const w2 = self.vfile.getTensor(c2w);
            const b2 = self.vfile.getTensor(c2b);

            if (w2 != null and b2 != null) {
                tts_conv.conv1d(
                    self.z_buf2[0 .. channels * L],
                    self.z_buf[0 .. channels * L],
                    w2.?,
                    b2.?,
                    channels,
                    @intCast(L),
                    channels,
                    kernel,
                    1,
                    @intCast(pad_base),
                    1,
                    null,
                );
                @memcpy(self.z_buf[0 .. channels * L], self.z_buf2[0 .. channels * L]);
            }
        }

        // Residual: add back input (from dec_buf2)
        for (0..@as(usize, channels) * L) |i| {
            self.z_buf[i] += self.dec_buf2[i];
        }
    }

    // ── Utility ──

    fn fmtName(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        const result = std.fmt.bufPrint(buf, fmt, args) catch return "";
        return result;
    }
};
