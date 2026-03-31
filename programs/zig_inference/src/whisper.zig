const std = @import("std");
const Allocator = std.mem.Allocator;
const wl = @import("whisper_loader.zig");
const tensor_mod = @import("tensor.zig");
const kv_mod = @import("kv_cache.zig");
const math = @import("math.zig");
const thread_pool_mod = @import("thread_pool.zig");
const audio_mod = @import("audio.zig");
const TensorView = tensor_mod.TensorView;
const WhisperFile = wl.WhisperFile;
const KVCache = kv_mod.KVCache;

pub const WhisperConfig = struct {
    n_mels: u32,
    n_audio_ctx: u32, // encoder output length (1500)
    n_audio_layer: u32,
    n_text_ctx: u32, // max decoder sequence length (448)
    n_text_layer: u32,
    d_model: u32, // embedding dimension (384 for tiny)
    n_heads: u32,
    d_head: u32,
    d_ffn: u32,
    vocab_size: u32,
    n_vocab: u32, // tokens in file (may differ from vocab_size used for logits)
    eps: f32,
};

pub const WhisperModel = struct {
    allocator: Allocator,
    config: WhisperConfig,
    wfile: WhisperFile,
    thread_pool: ?*thread_pool_mod.ThreadPool,

    // Encoder scratch
    conv1_out: []f32, // [d_model × n_audio_ctx*2] = [384 × 3000]
    conv2_out: []f32, // [d_model × n_audio_ctx] = [384 × 1500]
    encoder_out: []f32, // [n_audio_ctx × d_model] = [1500 × 384]
    enc_xb: []f32, // [d_model] norm scratch
    enc_att: []f32, // [n_heads × n_audio_ctx]
    enc_att_out: []f32, // [d_model]
    enc_ffn_up: []f32, // [d_ffn]
    enc_ffn_down: []f32, // [d_model]

    // Cross-attention KV: precomputed from encoder output
    cross_k: []f32,
    cross_v: []f32,

    // Decoder self-attention KV cache
    dec_kv_cache: KVCache,

    // Decoder scratch
    dec_x: []f32, // [d_model]
    dec_xb: []f32, // [d_model]
    dec_q: []f32, // [d_model]
    dec_k: []f32, // [d_model]
    dec_v: []f32, // [d_model]
    dec_att: []f32, // [n_heads × max(n_text_ctx, n_audio_ctx)]
    dec_att_out: []f32, // [d_model]
    dec_ffn_up: []f32, // [d_ffn]
    dec_ffn_down: []f32, // [d_model]
    logits: []f32, // [vocab_size]

    // Temporary buffer for dequantizing f16 conv weights
    conv_weight_buf: []f32,

    name_buf: [128]u8,

    pub fn init(allocator: Allocator, model_path: []const u8, n_threads: u32) !WhisperModel {
        const wfile = try WhisperFile.open(allocator, model_path);
        const hp = wfile.hparams;

        const d_model = hp.n_audio_state;
        const n_heads = hp.n_audio_head;
        // Whisper uses 4× hidden for FFN
        const d_ffn = d_model * 4;
        // Vocab for logits: n_vocab from file includes special tokens
        // The full vocab (51864 for English) includes 50257 base + special tokens
        const vocab_size = hp.n_vocab;

        const config = WhisperConfig{
            .n_mels = hp.n_mels,
            .n_audio_ctx = hp.n_audio_ctx,
            .n_audio_layer = hp.n_audio_layer,
            .n_text_ctx = hp.n_text_ctx,
            .n_text_layer = hp.n_text_layer,
            .d_model = d_model,
            .n_heads = n_heads,
            .d_head = if (n_heads > 0) d_model / n_heads else 64,
            .d_ffn = d_ffn,
            .vocab_size = vocab_size,
            .n_vocab = hp.n_vocab,
            .eps = 1e-5,
        };

        // Thread pool
        const pool: ?*thread_pool_mod.ThreadPool = if (n_threads > 1)
            try thread_pool_mod.ThreadPool.init(allocator, n_threads)
        else
            null;
        math.setThreadPool(pool);

        const n_audio_ctx = config.n_audio_ctx;
        const att_dim = @max(config.n_text_ctx, n_audio_ctx);
        const n_text_layer = config.n_text_layer;

        const dec_kv = try KVCache.init(allocator, n_text_layer, config.n_text_ctx, n_heads, config.d_head);

        // Max conv weight size: conv2 = 3 * 384 * 384 = 442368
        const max_conv_elems: usize = 3 * @as(usize, d_model) * d_model;

        return WhisperModel{
            .allocator = allocator,
            .config = config,
            .wfile = wfile,
            .thread_pool = pool,
            .conv1_out = try allocator.alloc(f32, @as(usize, d_model) * audio_mod.N_FRAMES),
            .conv2_out = try allocator.alloc(f32, @as(usize, d_model) * n_audio_ctx),
            .encoder_out = try allocator.alloc(f32, @as(usize, n_audio_ctx) * d_model),
            .enc_xb = try allocator.alloc(f32, d_model),
            .enc_att = try allocator.alloc(f32, @as(usize, n_heads) * n_audio_ctx),
            .enc_att_out = try allocator.alloc(f32, d_model),
            .enc_ffn_up = try allocator.alloc(f32, d_ffn),
            .enc_ffn_down = try allocator.alloc(f32, d_model),
            .cross_k = try allocator.alloc(f32, @as(usize, n_text_layer) * n_audio_ctx * d_model),
            .cross_v = try allocator.alloc(f32, @as(usize, n_text_layer) * n_audio_ctx * d_model),
            .dec_kv_cache = dec_kv,
            .dec_x = try allocator.alloc(f32, d_model),
            .dec_xb = try allocator.alloc(f32, d_model),
            .dec_q = try allocator.alloc(f32, d_model),
            .dec_k = try allocator.alloc(f32, d_model),
            .dec_v = try allocator.alloc(f32, d_model),
            .dec_att = try allocator.alloc(f32, @as(usize, n_heads) * att_dim),
            .dec_att_out = try allocator.alloc(f32, d_model),
            .dec_ffn_up = try allocator.alloc(f32, d_ffn),
            .dec_ffn_down = try allocator.alloc(f32, d_model),
            .logits = try allocator.alloc(f32, vocab_size),
            .conv_weight_buf = try allocator.alloc(f32, max_conv_elems),
            .name_buf = undefined,
        };
    }

    pub fn deinit(self: *WhisperModel) void {
        if (self.thread_pool) |pool| {
            math.setThreadPool(null);
            pool.deinit();
        }
        self.allocator.free(self.conv1_out);
        self.allocator.free(self.conv2_out);
        self.allocator.free(self.encoder_out);
        self.allocator.free(self.enc_xb);
        self.allocator.free(self.enc_att);
        self.allocator.free(self.enc_att_out);
        self.allocator.free(self.enc_ffn_up);
        self.allocator.free(self.enc_ffn_down);
        self.allocator.free(self.cross_k);
        self.allocator.free(self.cross_v);
        self.dec_kv_cache.deinit();
        self.allocator.free(self.dec_x);
        self.allocator.free(self.dec_xb);
        self.allocator.free(self.dec_q);
        self.allocator.free(self.dec_k);
        self.allocator.free(self.dec_v);
        self.allocator.free(self.dec_att);
        self.allocator.free(self.dec_att_out);
        self.allocator.free(self.dec_ffn_up);
        self.allocator.free(self.dec_ffn_down);
        self.allocator.free(self.logits);
        self.allocator.free(self.conv_weight_buf);
        self.wfile.close();
    }

    // ── Encoder ──

    pub fn encode(self: *WhisperModel, mel: []const f32) void {
        const cfg = self.config;
        const d = cfg.d_model;
        const n_frames = audio_mod.N_FRAMES; // 3000
        const n_ctx = cfg.n_audio_ctx; // 1500

        // Conv1: mel [n_mels × n_frames] → conv1_out [d_model × n_frames]
        self.conv1d(self.conv1_out, mel, cfg.n_mels, n_frames, d, "encoder.conv1.weight", "encoder.conv1.bias", 1);
        math.gelu(self.conv1_out[0 .. @as(usize, d) * n_frames]);

        // Conv2: conv1_out [d_model × n_frames] → conv2_out [d_model × n_ctx]
        self.conv1d(self.conv2_out, self.conv1_out, d, n_frames, d, "encoder.conv2.weight", "encoder.conv2.bias", 2);
        math.gelu(self.conv2_out[0 .. @as(usize, d) * n_ctx]);

        // Transpose [d_model × n_ctx] → [n_ctx × d_model] and add positional embedding
        const pos_emb = self.getTensor("encoder.positional_embedding") orelse return;
        const pos_data = pos_emb.asF32Slice();

        for (0..n_ctx) |t| {
            for (0..d) |c| {
                self.encoder_out[t * d + c] = self.conv2_out[c * n_ctx + t] + pos_data[t * d + c];
            }
        }

        // Encoder transformer layers
        for (0..cfg.n_audio_layer) |layer| {
            self.encoderLayer(@intCast(layer));
        }

        // Final layer norm
        const ln_w = self.getTensor("encoder.ln_post.weight") orelse return;
        const ln_b = self.getTensor("encoder.ln_post.bias") orelse return;
        for (0..n_ctx) |t| {
            const offset = t * d;
            const frame = self.encoder_out[offset..][0..d];
            math.layernorm(frame, frame, ln_w.asF32Slice(), ln_b.asF32Slice(), cfg.eps);
        }
    }

    fn conv1d(
        self: *WhisperModel,
        out: []f32,
        input: []const f32,
        in_channels: u32,
        in_len: u32,
        out_channels: u32,
        weight_name: []const u8,
        bias_name: []const u8,
        stride: u32,
    ) void {
        const kernel_size: u32 = 3;
        const pad: u32 = 1;
        const out_len = (in_len + 2 * pad - kernel_size) / stride + 1;
        const weight_tv = self.getTensor(weight_name) orelse return;
        const bias_tv = self.getTensor(bias_name) orelse return;

        // Dequantize weight to f32 if needed (conv weights may be f16)
        const w_data = self.getF32Data(weight_tv);
        // Bias is always f32 but may have leading 1 dim: [1, N] → asF32Slice works
        const b_data = bias_tv.asF32Slice();

        // ggml conv weight layout: dims = [kernel, in_ch, out_ch]
        // Memory layout (row-major with dim[0] as innermost):
        //   w[oc * in_ch * kernel + ic * kernel + k]
        for (0..out_channels) |oc| {
            for (0..out_len) |ot| {
                var sum: f32 = b_data[oc];
                for (0..in_channels) |ic| {
                    for (0..kernel_size) |k| {
                        const in_pos_signed: i64 = @as(i64, @intCast(ot)) * @as(i64, stride) + @as(i64, @intCast(k)) - @as(i64, pad);
                        if (in_pos_signed >= 0 and in_pos_signed < @as(i64, @intCast(in_len))) {
                            const in_pos: usize = @intCast(in_pos_signed);
                            const w_idx = oc * @as(usize, in_channels) * kernel_size + ic * kernel_size + k;
                            const i_idx = ic * @as(usize, in_len) + in_pos;
                            sum += w_data[w_idx] * input[i_idx];
                        }
                    }
                }
                out[oc * @as(usize, out_len) + ot] = sum;
            }
        }
    }

    fn encoderLayer(self: *WhisperModel, layer: u32) void {
        const cfg = self.config;
        const d = cfg.d_model;
        const n_ctx = cfg.n_audio_ctx;

        const attn_ln_w = self.getEncLayerTensor(layer, "attn_ln.weight") orelse return;
        const attn_ln_b = self.getEncLayerTensor(layer, "attn_ln.bias") orelse return;
        const wq = self.getEncLayerTensor(layer, "attn.query.weight") orelse return;
        const wk = self.getEncLayerTensor(layer, "attn.key.weight") orelse return;
        const wv = self.getEncLayerTensor(layer, "attn.value.weight") orelse return;
        const wo = self.getEncLayerTensor(layer, "attn.out.weight") orelse return;
        const bq = self.getEncLayerTensor(layer, "attn.query.bias") orelse return;
        const bv = self.getEncLayerTensor(layer, "attn.value.bias") orelse return;
        const bo = self.getEncLayerTensor(layer, "attn.out.bias") orelse return;

        const bq_data = bq.asF32Slice();
        const bv_data = bv.asF32Slice();
        const bo_data = bo.asF32Slice();

        const alloc = self.allocator;
        const qkv_buf = alloc.alloc(f32, @as(usize, n_ctx) * d * 3) catch return;
        defer alloc.free(qkv_buf);
        const all_q = qkv_buf[0 .. @as(usize, n_ctx) * d];
        const all_k = qkv_buf[@as(usize, n_ctx) * d ..][0 .. @as(usize, n_ctx) * d];
        const all_v = qkv_buf[@as(usize, n_ctx) * d * 2 ..][0 .. @as(usize, n_ctx) * d];

        for (0..n_ctx) |t| {
            const offset = t * d;
            const frame = self.encoder_out[offset..][0..d];
            math.layernorm(self.enc_xb, frame, attn_ln_w.asF32Slice(), attn_ln_b.asF32Slice(), cfg.eps);

            math.matmul(all_q[offset..][0..d], self.enc_xb, wq);
            math.matmul(all_k[offset..][0..d], self.enc_xb, wk);
            math.matmul(all_v[offset..][0..d], self.enc_xb, wv);

            for (0..d) |i| {
                all_q[offset + i] += bq_data[i];
                all_v[offset + i] += bv_data[i];
            }
        }

        const d_head = cfg.d_head;
        const n_heads = cfg.n_heads;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(d_head)));

        for (0..n_ctx) |t| {
            for (0..n_heads) |h| {
                const q_off = t * d + h * d_head;

                for (0..n_ctx) |s| {
                    const k_off = s * d + h * d_head;
                    var score: f32 = 0.0;
                    for (0..d_head) |di| {
                        score += all_q[q_off + di] * all_k[k_off + di];
                    }
                    self.enc_att[h * n_ctx + s] = score * scale;
                }

                math.softmax(self.enc_att[h * n_ctx ..][0..n_ctx]);

                const out_off = h * d_head;
                @memset(self.enc_att_out[out_off..][0..d_head], 0.0);
                for (0..n_ctx) |s| {
                    const a = self.enc_att[h * n_ctx + s];
                    const v_off = s * d + h * d_head;
                    for (0..d_head) |di| {
                        self.enc_att_out[out_off + di] += a * all_v[v_off + di];
                    }
                }
            }

            math.matmul(self.enc_xb, self.enc_att_out, wo);
            for (0..d) |i| self.enc_xb[i] += bo_data[i];

            const offset = t * d;
            for (0..d) |i| self.encoder_out[offset + i] += self.enc_xb[i];
        }

        // MLP
        const mlp_ln_w = self.getEncLayerTensor(layer, "mlp_ln.weight") orelse return;
        const mlp_ln_b = self.getEncLayerTensor(layer, "mlp_ln.bias") orelse return;
        const mlp_0_w = self.getEncLayerTensor(layer, "mlp.0.weight") orelse return;
        const mlp_0_b = self.getEncLayerTensor(layer, "mlp.0.bias") orelse return;
        const mlp_2_w = self.getEncLayerTensor(layer, "mlp.2.weight") orelse return;
        const mlp_2_b = self.getEncLayerTensor(layer, "mlp.2.bias") orelse return;

        const mlp_0_b_data = mlp_0_b.asF32Slice();
        const mlp_2_b_data = mlp_2_b.asF32Slice();

        for (0..n_ctx) |t| {
            const offset = t * d;
            const frame = self.encoder_out[offset..][0..d];

            math.layernorm(self.enc_xb, frame, mlp_ln_w.asF32Slice(), mlp_ln_b.asF32Slice(), cfg.eps);

            math.matmul(self.enc_ffn_up, self.enc_xb, mlp_0_w);
            for (0..cfg.d_ffn) |i| self.enc_ffn_up[i] += mlp_0_b_data[i];
            math.gelu(self.enc_ffn_up[0..cfg.d_ffn]);

            math.matmul(self.enc_ffn_down, self.enc_ffn_up, mlp_2_w);
            for (0..d) |i| self.enc_ffn_down[i] += mlp_2_b_data[i];

            for (0..d) |i| self.encoder_out[offset + i] += self.enc_ffn_down[i];
        }
    }

    // ── Cross-attention KV precomputation ──

    pub fn computeCrossKV(self: *WhisperModel) void {
        const cfg = self.config;
        const d = cfg.d_model;
        const n_ctx = cfg.n_audio_ctx;

        for (0..cfg.n_text_layer) |layer| {
            const wk = self.getDecLayerTensor(@intCast(layer), "cross_attn.key.weight") orelse continue;
            const wv = self.getDecLayerTensor(@intCast(layer), "cross_attn.value.weight") orelse continue;
            const bv = self.getDecLayerTensor(@intCast(layer), "cross_attn.value.bias");
            const bv_data = if (bv) |b| b.asF32Slice() else null;

            const layer_offset = layer * @as(usize, n_ctx) * d;

            for (0..n_ctx) |t| {
                const enc_frame = self.encoder_out[t * d ..][0..d];
                const kv_offset = layer_offset + t * d;

                math.matmul(self.cross_k[kv_offset..][0..d], enc_frame, wk);
                math.matmul(self.cross_v[kv_offset..][0..d], enc_frame, wv);

                if (bv_data) |bd| {
                    for (0..d) |i| self.cross_v[kv_offset + i] += bd[i];
                }
            }
        }
    }

    // ── Decoder ──

    pub fn decode(self: *WhisperModel, token: u32, pos: u32) []f32 {
        const cfg = self.config;
        const d = cfg.d_model;

        const tok_emb = self.getTensor("decoder.token_embedding.weight") orelse return self.logits;
        const pos_emb = self.getTensor("decoder.positional_embedding") orelse return self.logits;

        math.copyRow(self.dec_x, tok_emb, token);
        const pos_data = pos_emb.asF32Slice();
        const pos_offset = @as(usize, pos) * d;
        for (0..d) |i| {
            self.dec_x[i] += pos_data[pos_offset + i];
        }

        for (0..cfg.n_text_layer) |layer| {
            self.decoderLayer(@intCast(layer), pos);
        }

        const ln_w = self.getTensor("decoder.ln.weight") orelse return self.logits;
        const ln_b = self.getTensor("decoder.ln.bias") orelse return self.logits;
        math.layernorm(self.dec_x, self.dec_x, ln_w.asF32Slice(), ln_b.asF32Slice(), cfg.eps);

        // Logits: x @ token_embedding^T (tied weights)
        math.matmul(self.logits, self.dec_x, tok_emb);

        return self.logits;
    }

    fn decoderLayer(self: *WhisperModel, layer: u32, pos: u32) void {
        const cfg = self.config;
        const d = cfg.d_model;
        const d_head = cfg.d_head;
        const n_heads = cfg.n_heads;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(d_head)));

        // ── Causal self-attention ──
        const attn_ln_w = self.getDecLayerTensor(layer, "attn_ln.weight") orelse return;
        const attn_ln_b = self.getDecLayerTensor(layer, "attn_ln.bias") orelse return;
        math.layernorm(self.dec_xb, self.dec_x, attn_ln_w.asF32Slice(), attn_ln_b.asF32Slice(), cfg.eps);

        const wq = self.getDecLayerTensor(layer, "attn.query.weight") orelse return;
        const wk = self.getDecLayerTensor(layer, "attn.key.weight") orelse return;
        const wv = self.getDecLayerTensor(layer, "attn.value.weight") orelse return;
        const wo = self.getDecLayerTensor(layer, "attn.out.weight") orelse return;
        const bq = self.getDecLayerTensor(layer, "attn.query.bias");
        const bv = self.getDecLayerTensor(layer, "attn.value.bias");
        const bo = self.getDecLayerTensor(layer, "attn.out.bias");

        math.matmul(self.dec_q, self.dec_xb, wq);
        math.matmul(self.dec_k, self.dec_xb, wk);
        math.matmul(self.dec_v, self.dec_xb, wv);

        if (bq) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_q[i] += bd[i]; }
        if (bv) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_v[i] += bd[i]; }

        self.dec_kv_cache.store(layer, self.dec_k, self.dec_v, pos);

        const seq_len = pos + 1;

        for (0..n_heads) |h| {
            const q_off = h * d_head;
            for (0..seq_len) |t| {
                const k_at_t = self.dec_kv_cache.getKeyAt(layer, @intCast(t));
                const k_off = h * d_head;
                var score_val: f32 = 0.0;
                for (0..d_head) |di| {
                    score_val += self.dec_q[q_off + di] * k_at_t[k_off + di];
                }
                self.dec_att[h * cfg.n_text_ctx + t] = score_val * scale;
            }
            math.softmax(self.dec_att[h * cfg.n_text_ctx ..][0..seq_len]);

            const out_off = h * d_head;
            @memset(self.dec_att_out[out_off..][0..d_head], 0.0);
            for (0..seq_len) |t| {
                const a = self.dec_att[h * cfg.n_text_ctx + t];
                const v_at_t = self.dec_kv_cache.getValueAt(layer, @intCast(t));
                const v_off = h * d_head;
                for (0..d_head) |di| {
                    self.dec_att_out[out_off + di] += a * v_at_t[v_off + di];
                }
            }
        }

        math.matmul(self.dec_xb, self.dec_att_out, wo);
        if (bo) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_xb[i] += bd[i]; }

        for (0..d) |i| self.dec_x[i] += self.dec_xb[i];

        // ── Cross-attention ──
        const cross_ln_w = self.getDecLayerTensor(layer, "cross_attn_ln.weight") orelse return;
        const cross_ln_b = self.getDecLayerTensor(layer, "cross_attn_ln.bias") orelse return;
        math.layernorm(self.dec_xb, self.dec_x, cross_ln_w.asF32Slice(), cross_ln_b.asF32Slice(), cfg.eps);

        const cross_wq = self.getDecLayerTensor(layer, "cross_attn.query.weight") orelse return;
        const cross_wo = self.getDecLayerTensor(layer, "cross_attn.out.weight") orelse return;
        const cross_bq = self.getDecLayerTensor(layer, "cross_attn.query.bias");
        const cross_bo = self.getDecLayerTensor(layer, "cross_attn.out.bias");

        math.matmul(self.dec_q, self.dec_xb, cross_wq);
        if (cross_bq) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_q[i] += bd[i]; }

        const n_audio_ctx = cfg.n_audio_ctx;
        const layer_offset = @as(usize, layer) * n_audio_ctx * d;

        for (0..n_heads) |h| {
            const q_off = h * d_head;
            for (0..n_audio_ctx) |s| {
                const k_off = layer_offset + s * d + h * d_head;
                var score_val: f32 = 0.0;
                for (0..d_head) |di| {
                    score_val += self.dec_q[q_off + di] * self.cross_k[k_off + di];
                }
                self.dec_att[h * n_audio_ctx + s] = score_val * scale;
            }
            math.softmax(self.dec_att[h * n_audio_ctx ..][0..n_audio_ctx]);

            const out_off = h * d_head;
            @memset(self.dec_att_out[out_off..][0..d_head], 0.0);
            for (0..n_audio_ctx) |s| {
                const a = self.dec_att[h * n_audio_ctx + s];
                const v_off = layer_offset + s * d + h * d_head;
                for (0..d_head) |di| {
                    self.dec_att_out[out_off + di] += a * self.cross_v[v_off + di];
                }
            }
        }

        math.matmul(self.dec_xb, self.dec_att_out, cross_wo);
        if (cross_bo) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_xb[i] += bd[i]; }

        for (0..d) |i| self.dec_x[i] += self.dec_xb[i];

        // ── MLP ──
        const mlp_ln_w = self.getDecLayerTensor(layer, "mlp_ln.weight") orelse return;
        const mlp_ln_b = self.getDecLayerTensor(layer, "mlp_ln.bias") orelse return;
        math.layernorm(self.dec_xb, self.dec_x, mlp_ln_w.asF32Slice(), mlp_ln_b.asF32Slice(), cfg.eps);

        const mlp_0_w = self.getDecLayerTensor(layer, "mlp.0.weight") orelse return;
        const mlp_0_b = self.getDecLayerTensor(layer, "mlp.0.bias");
        const mlp_2_w = self.getDecLayerTensor(layer, "mlp.2.weight") orelse return;
        const mlp_2_b = self.getDecLayerTensor(layer, "mlp.2.bias");

        math.matmul(self.dec_ffn_up, self.dec_xb, mlp_0_w);
        if (mlp_0_b) |b| { const bd = b.asF32Slice(); for (0..cfg.d_ffn) |i| self.dec_ffn_up[i] += bd[i]; }
        math.gelu(self.dec_ffn_up[0..cfg.d_ffn]);

        math.matmul(self.dec_ffn_down, self.dec_ffn_up, mlp_2_w);
        if (mlp_2_b) |b| { const bd = b.asF32Slice(); for (0..d) |i| self.dec_ffn_down[i] += bd[i]; }

        for (0..d) |i| self.dec_x[i] += self.dec_ffn_down[i];
    }

    pub fn resetDecoder(self: *WhisperModel) void {
        self.dec_kv_cache.reset();
    }

    // ── Helpers ──

    fn getTensor(self: *WhisperModel, name: []const u8) ?TensorView {
        return self.wfile.getTensor(name);
    }

    fn getEncLayerTensor(self: *WhisperModel, layer: u32, suffix: []const u8) ?TensorView {
        const name = std.fmt.bufPrint(&self.name_buf, "encoder.blocks.{d}.{s}", .{ layer, suffix }) catch return null;
        return self.wfile.getTensor(name);
    }

    fn getDecLayerTensor(self: *WhisperModel, layer: u32, suffix: []const u8) ?TensorView {
        const name = std.fmt.bufPrint(&self.name_buf, "decoder.blocks.{d}.{s}", .{ layer, suffix }) catch return null;
        return self.wfile.getTensor(name);
    }

    /// Dequantize a tensor to f32 if it's f16, using conv_weight_buf as scratch.
    /// Handles unaligned data (ggml format has no alignment padding).
    fn getF32Data(self: *WhisperModel, tv: TensorView) []const f32 {
        if (tv.dtype == .f32) {
            // f32 data — check alignment before using asF32Slice
            if (@intFromPtr(tv.data) % 4 == 0) return tv.asF32Slice();
            // Unaligned f32: read byte-by-byte
            const count = tv.elementCount();
            for (0..count) |i| {
                const bytes = tv.data[i * 4 ..][0..4];
                self.conv_weight_buf[i] = @bitCast(std.mem.readInt(u32, bytes, .little));
            }
            return self.conv_weight_buf[0..count];
        }
        // f16 → dequantize into conv_weight_buf (byte-by-byte for alignment safety)
        const count = tv.elementCount();
        for (0..count) |i| {
            const bytes = tv.data[i * 2 ..][0..2];
            const raw = std.mem.readInt(u16, bytes, .little);
            self.conv_weight_buf[i] = @floatCast(@as(f16, @bitCast(raw)));
        }
        return self.conv_weight_buf[0..count];
    }
};
