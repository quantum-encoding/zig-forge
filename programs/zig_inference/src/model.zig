const std = @import("std");
const Allocator = std.mem.Allocator;
const gguf_mod = @import("gguf.zig");
const tensor_mod = @import("tensor.zig");
const tokenizer_mod = @import("tokenizer.zig");
const kv_mod = @import("kv_cache.zig");
const math = @import("math.zig");
const thread_pool_mod = @import("thread_pool.zig");
const TensorView = tensor_mod.TensorView;
const GGUFFile = gguf_mod.GGUFFile;
const Tokenizer = tokenizer_mod.Tokenizer;
const KVCache = kv_mod.KVCache;

pub const ModelConfig = struct {
    architecture: []const u8,
    n_layers: u32,
    d_model: u32,
    n_heads: u32,
    n_kv_heads: u32,
    d_head: u32,
    d_ffn: u32,
    vocab_size: u32,
    max_seq_len: u32,
    rope_theta: f32,
    rms_norm_eps: f32,
};

pub const Model = struct {
    allocator: Allocator,
    config: ModelConfig,
    gguf: GGUFFile,
    tokenizer: Tokenizer,
    kv_cache: KVCache,
    thread_pool: ?*thread_pool_mod.ThreadPool,

    // Scratch buffers (allocated once, reused per forward call)
    x: []f32, // [d_model] current hidden state
    xb: []f32, // [d_model] scratch for norm output
    xb2: []f32, // [d_model] scratch
    q: []f32, // [n_heads * d_head]
    att: []f32, // [n_heads * max_seq_len]
    ffn_gate: []f32, // [d_ffn]
    ffn_up: []f32, // [d_ffn]
    ffn_down: []f32, // [d_model]
    logits: []f32, // [vocab_size]
    k_buf: []f32, // [n_kv_heads * d_head] temporary K
    v_buf: []f32, // [n_kv_heads * d_head] temporary V
    att_out: []f32, // [n_heads * d_head] attention output

    // Tensor name format buffer
    name_buf: [128]u8,

    pub fn init(allocator: Allocator, gguf_path: []const u8, n_threads: u32) !Model {
        var gguf = try GGUFFile.open(allocator, gguf_path);

        const config = ModelConfig{
            .architecture = gguf.architecture,
            .n_layers = gguf.block_count,
            .d_model = gguf.embedding_length,
            .n_heads = gguf.head_count,
            .n_kv_heads = gguf.head_count_kv,
            .d_head = if (gguf.head_count > 0) gguf.embedding_length / gguf.head_count else 128,
            .d_ffn = gguf.feed_forward_length,
            .vocab_size = gguf.vocab_size,
            .max_seq_len = @min(gguf.context_length, 8192), // Cap for memory
            .rope_theta = gguf.rope_freq_base,
            .rms_norm_eps = gguf.rms_norm_eps,
        };

        const tokenizer = try Tokenizer.init(allocator, &gguf);

        const kv_cache = try KVCache.init(
            allocator,
            config.n_layers,
            config.max_seq_len,
            config.n_kv_heads,
            config.d_head,
        );

        // Create thread pool if multi-threaded
        const pool: ?*thread_pool_mod.ThreadPool = if (n_threads > 1)
            try thread_pool_mod.ThreadPool.init(allocator, n_threads)
        else
            null;
        math.setThreadPool(pool);

        // Allocate scratch buffers
        const q_dim = config.n_heads * config.d_head;
        const kv_dim = config.n_kv_heads * config.d_head;

        return Model{
            .allocator = allocator,
            .config = config,
            .gguf = gguf,
            .tokenizer = tokenizer,
            .kv_cache = kv_cache,
            .thread_pool = pool,
            .x = try allocator.alloc(f32, config.d_model),
            .xb = try allocator.alloc(f32, config.d_model),
            .xb2 = try allocator.alloc(f32, config.d_model),
            .q = try allocator.alloc(f32, q_dim),
            .att = try allocator.alloc(f32, @as(usize, config.n_heads) * config.max_seq_len),
            .ffn_gate = try allocator.alloc(f32, config.d_ffn),
            .ffn_up = try allocator.alloc(f32, config.d_ffn),
            .ffn_down = try allocator.alloc(f32, config.d_model),
            .logits = try allocator.alloc(f32, config.vocab_size),
            .k_buf = try allocator.alloc(f32, kv_dim),
            .v_buf = try allocator.alloc(f32, kv_dim),
            .att_out = try allocator.alloc(f32, q_dim),
            .name_buf = undefined,
        };
    }

    pub fn deinit(self: *Model) void {
        if (self.thread_pool) |pool| {
            math.setThreadPool(null);
            pool.deinit();
        }
        self.allocator.free(self.x);
        self.allocator.free(self.xb);
        self.allocator.free(self.xb2);
        self.allocator.free(self.q);
        self.allocator.free(self.att);
        self.allocator.free(self.ffn_gate);
        self.allocator.free(self.ffn_up);
        self.allocator.free(self.ffn_down);
        self.allocator.free(self.logits);
        self.allocator.free(self.k_buf);
        self.allocator.free(self.v_buf);
        self.allocator.free(self.att_out);
        self.kv_cache.deinit();
        self.tokenizer.deinit();
        self.gguf.close();
    }

    /// Forward pass for a single token at a given position
    /// Returns logits slice [vocab_size]
    pub fn forward(self: *Model, token: u32, pos: u32) []f32 {
        const cfg = self.config;

        // 1. Embedding lookup
        const embed = self.getWeight("token_embd.weight") orelse return self.logits;
        math.copyRow(self.x, embed, token);

        // 2. Transformer layers
        for (0..cfg.n_layers) |layer| {
            self.transformerLayer(@intCast(layer), pos);
        }

        // 3. Final RMSNorm
        const final_norm = self.getWeight("output_norm.weight") orelse return self.logits;
        math.rmsnorm(self.x, self.x, final_norm.asF32Slice(), cfg.rms_norm_eps);

        // 4. Output head (logits = x @ output.weight)
        // If output.weight is missing, reuse token_embd.weight (tied embeddings)
        const output_w = self.getWeight("output.weight") orelse
            self.getWeight("token_embd.weight") orelse return self.logits;
        math.matmul(self.logits, self.x, output_w);

        return self.logits;
    }

    fn transformerLayer(self: *Model, layer: u32, pos: u32) void {
        const cfg = self.config;

        // Pre-attention RMSNorm
        const attn_norm = self.getLayerWeight(layer, "attn_norm.weight") orelse return;
        math.rmsnorm(self.xb, self.x, attn_norm.asF32Slice(), cfg.rms_norm_eps);

        // QKV projections
        const wq = self.getLayerWeight(layer, "attn_q.weight") orelse return;
        const wk = self.getLayerWeight(layer, "attn_k.weight") orelse return;
        const wv = self.getLayerWeight(layer, "attn_v.weight") orelse return;

        math.matmul(self.q, self.xb, wq);
        math.matmul(self.k_buf, self.xb, wk);
        math.matmul(self.v_buf, self.xb, wv);

        // RoPE on Q and K
        math.applyRope(self.q, self.k_buf, pos, cfg.n_heads, cfg.n_kv_heads, cfg.d_head, cfg.rope_theta);

        // Store K, V in cache
        self.kv_cache.store(layer, self.k_buf, self.v_buf, pos);

        // Multi-head attention with GQA
        self.computeAttention(layer, pos);

        // Output projection
        const wo = self.getLayerWeight(layer, "attn_output.weight") orelse return;
        math.matmul(self.xb, self.att_out, wo);

        // Residual connection
        math.vectorAdd(self.x, self.x, self.xb);

        // Pre-FFN RMSNorm
        const ffn_norm = self.getLayerWeight(layer, "ffn_norm.weight") orelse return;
        math.rmsnorm(self.xb, self.x, ffn_norm.asF32Slice(), cfg.rms_norm_eps);

        // SwiGLU FFN
        const w_gate = self.getLayerWeight(layer, "ffn_gate.weight") orelse return;
        const w_up = self.getLayerWeight(layer, "ffn_up.weight") orelse return;
        const w_down = self.getLayerWeight(layer, "ffn_down.weight") orelse return;

        math.matmul(self.ffn_gate, self.xb, w_gate);
        math.matmul(self.ffn_up, self.xb, w_up);
        math.silu(self.ffn_gate);
        math.elementwiseMul(self.ffn_gate, self.ffn_up);
        math.matmul(self.ffn_down, self.ffn_gate, w_down);

        // Residual connection
        math.vectorAdd(self.x, self.x, self.ffn_down);
    }

    fn computeAttention(self: *Model, layer: u32, pos: u32) void {
        const cfg = self.config;
        const d_head = cfg.d_head;
        const n_heads = cfg.n_heads;
        const n_kv_heads = cfg.n_kv_heads;
        const heads_per_kv = n_heads / n_kv_heads;
        const seq_len = pos + 1; // attend to positions 0..pos inclusive

        // For each query head
        for (0..n_heads) |h| {
            const q_offset = h * d_head;
            const kv_head = h / heads_per_kv;
            const att_offset = h * cfg.max_seq_len;

            // Compute attention scores: Q[h] @ K[kv_head, 0..pos]^T / sqrt(d_head)
            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(d_head)));

            for (0..seq_len) |t| {
                // Get K at position t for this kv_head
                const k_at_t = self.kv_cache.getKeyAt(layer, @intCast(t));
                const k_head_offset = kv_head * d_head;

                // Dot product Q[h] . K[kv_head][t]
                var score: f32 = 0.0;
                for (0..d_head) |d| {
                    score += self.q[q_offset + d] * k_at_t[k_head_offset + d];
                }
                self.att[att_offset + t] = score * scale;
            }

            // Softmax over attention scores [0..seq_len]
            math.softmax(self.att[att_offset..][0..seq_len]);

            // Weighted sum of V: out[h] = sum_t(att[t] * V[kv_head][t])
            const out_offset = h * d_head;
            @memset(self.att_out[out_offset..][0..d_head], 0.0);

            for (0..seq_len) |t| {
                const a = self.att[att_offset + t];
                const v_at_t = self.kv_cache.getValueAt(layer, @intCast(t));
                const v_head_offset = kv_head * d_head;
                for (0..d_head) |d| {
                    self.att_out[out_offset + d] += a * v_at_t[v_head_offset + d];
                }
            }
        }
    }

    // ── Weight lookup helpers ──

    fn getWeight(self: *Model, name: []const u8) ?TensorView {
        return self.gguf.getTensor(name);
    }

    fn getLayerWeight(self: *Model, layer: u32, suffix: []const u8) ?TensorView {
        const name = std.fmt.bufPrint(&self.name_buf, "blk.{d}.{s}", .{ layer, suffix }) catch return null;
        return self.gguf.getTensor(name);
    }
};
