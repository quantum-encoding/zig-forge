# zig_inference — Zig ML Inference Engine

## SPEC v1.0 — Quantum Zig Forge

**Program:** `programs/zig_inference/`
**Binary:** `zig-infer`
**Goal:** Run transformer model inference (LLMs, embedding models) at native speed with zero external dependencies, SIMD acceleration, and memory-mapped weights.

---

## Strategic Context

The ML inference stack today is Python on top, C++ underneath. PyTorch, llama.cpp, vLLM — all follow this pattern. The opportunity: a single Zig binary that loads GGUF model files and runs inference with no Python, no CUDA runtime, no framework overhead. Same philosophy as every other program in quantum-zig-forge: zero dependencies, SIMD-optimized, cross-platform.

**Immediate use cases:**
- Local LLM inference for zig-ai agent SDK (replace HTTP API calls with local model)
- Embedding generation for RAG pipelines
- On-device inference for edge deployment (pairs with zig_pdf_generator WASM story)
- Benchmark baseline for comparing API latency vs local inference

**Non-goals for v1.0:**
- Training (inference only)
- GPU/CUDA support (CPU-only first, GPU is a later milestone)
- Serving (no HTTP server — zig-ai or http_sentinel can wrap it)
- Every model architecture (start with LLaMA/Mistral family, expand later)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        CLI / API                             │
│  zig-infer generate --model llama3.gguf --prompt "Hello"     │
│  zig-infer embed    --model nomic.gguf  --input "text"       │
│  zig-infer bench    --model llama3.gguf                      │
│  C FFI: ziginfer_create() / ziginfer_generate() / ...        │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                   Inference Engine                            │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │  Tokenizer  │  │   Sampler    │  │   KV Cache         │  │
│  │  (BPE)      │  │  (temp/top-k │  │  (ring buffer,     │  │
│  │             │  │   top-p/     │  │   per-layer)       │  │
│  │             │  │   min-p)     │  │                    │  │
│  └─────────────┘  └──────────────┘  └────────────────────┘  │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                 Transformer Forward Pass                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │  Embed   │  │ Attention│  │   FFN    │  │  RMSNorm    │ │
│  │  Lookup  │  │ (GQA/MHA)│  │(SwiGLU)  │  │             │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────────┘ │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                    Tensor Operations                         │
│  ┌───────────────────┐  ┌──────────────────────────────┐    │
│  │  matmul (SIMD)    │  │  Quantized matmul            │    │
│  │  AVX2 / AVX-512   │  │  Q4_0, Q4_1, Q8_0, F16, F32 │    │
│  │  NEON (ARM)       │  │  dequant → SIMD dot product  │    │
│  └───────────────────┘  └──────────────────────────────┘    │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                    Model Loader                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  GGUF Parser                                         │   │
│  │  - mmap weights (zero-copy, on-demand paging)        │   │
│  │  - Parse metadata (architecture, tokenizer, quant)   │   │
│  │  - Tensor registry (name → offset + shape + type)    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Milestone Roadmap

### M1: GGUF Loader + Tensor Registry

**Files:**
- `src/gguf.zig` — GGUF file parser
- `src/tensor.zig` — Tensor type, shape, data pointer
- `src/main.zig` — CLI entry point

**GGUF Format (v3):**

GGUF is the standard model distribution format (created by llama.cpp). It's a single file containing metadata + weights.

```
┌──────────────────────────────────────┐
│  Header                              │
│  - magic: "GGUF" (4 bytes)          │
│  - version: u32 (3)                 │
│  - tensor_count: u64                │
│  - metadata_kv_count: u64           │
├──────────────────────────────────────┤
│  Metadata KV pairs                   │
│  - key: string                       │
│  - value_type: enum                  │
│  - value: varies                     │
│  Important keys:                     │
│    general.architecture → "llama"    │
│    llama.block_count → 32            │
│    llama.embedding_length → 4096     │
│    llama.attention.head_count → 32   │
│    llama.attention.head_count_kv → 8 │
│    llama.feed_forward_length → 11008 │
│    llama.context_length → 4096       │
│    tokenizer.ggml.model → "llama"    │
│    tokenizer.ggml.tokens → [...]     │
│    tokenizer.ggml.scores → [...]     │
│    tokenizer.ggml.token_type → [...] │
├──────────────────────────────────────┤
│  Tensor Infos (array)                │
│  Per tensor:                         │
│  - name: string                      │
│  - n_dims: u32                       │
│  - dims: [n_dims]u64                │
│  - type: GGMLType enum              │
│  - offset: u64 (from data start)    │
├──────────────────────────────────────┤
│  Alignment padding                   │
├──────────────────────────────────────┤
│  Tensor Data (bulk weights)          │
│  - Contiguous block, mmap'd         │
│  - Accessed via offset from infos   │
└──────────────────────────────────────┘
```

**GGMLType enum (quantization formats):**

```
GGML_TYPE_F32     = 0,   // 32-bit float, 4 bytes/param
GGML_TYPE_F16     = 1,   // 16-bit float, 2 bytes/param
GGML_TYPE_Q4_0    = 2,   // 4-bit quant, block of 32, ~0.5625 bytes/param
GGML_TYPE_Q4_1    = 3,   // 4-bit quant + min, ~0.625 bytes/param
GGML_TYPE_Q5_0    = 6,   // 5-bit quant
GGML_TYPE_Q5_1    = 7,   // 5-bit quant + min
GGML_TYPE_Q8_0    = 8,   // 8-bit quant, ~1.0625 bytes/param
GGML_TYPE_Q8_1    = 9,   // 8-bit quant + min
GGML_TYPE_Q2_K   = 10,   // k-quant 2-bit
GGML_TYPE_Q3_K   = 11,   // k-quant 3-bit
GGML_TYPE_Q4_K   = 12,   // k-quant 4-bit
GGML_TYPE_Q5_K   = 13,   // k-quant 5-bit
GGML_TYPE_Q6_K   = 14,   // k-quant 6-bit
GGML_TYPE_IQ2_XXS = 16,  // importance quant 2-bit
```

**Implementation:**

```zig
// src/gguf.zig

pub const GGUFHeader = struct {
    magic: [4]u8,       // "GGUF"
    version: u32,       // 3
    tensor_count: u64,
    metadata_kv_count: u64,
};

pub const MetadataValueType = enum(u32) {
    uint8 = 0, int8, uint16, int16, uint32, int32,
    float32, bool, string, array, uint64, int64, float64,
};

pub const TensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u64,       // max 4 dimensions
    type: GGMLType,
    offset: u64,        // offset into data section
};

pub const GGUFFile = struct {
    // mmap'd file
    mmap_ptr: [*]align(4096) const u8,
    mmap_len: usize,

    // parsed metadata
    architecture: []const u8,      // "llama", "mistral", etc.
    block_count: u32,              // number of transformer layers
    embedding_length: u32,         // hidden size (d_model)
    head_count: u32,               // attention heads
    head_count_kv: u32,            // KV heads (for GQA)
    feed_forward_length: u32,      // FFN intermediate size
    context_length: u32,           // max sequence length
    vocab_size: u32,

    // tokenizer data
    tokens: [][]const u8,          // vocabulary strings
    scores: []f32,                 // token scores (for BPE merge priority)
    token_types: []u32,            // normal, unknown, control, etc.

    // tensor registry: name → TensorInfo
    tensors: std.StringHashMap(TensorInfo),
    data_offset: usize,            // where tensor data begins in file

    pub fn open(path: []const u8) !GGUFFile { ... }
    pub fn getTensor(self: *const GGUFFile, name: []const u8) ?TensorView { ... }
    pub fn close(self: *GGUFFile) void { ... }
};

pub const TensorView = struct {
    data: [*]const u8,   // pointer into mmap'd region
    shape: [4]u64,
    n_dims: u32,
    dtype: GGMLType,

    pub fn asF32Slice(self: TensorView) []const f32 { ... }
    pub fn rows(self: TensorView) u64 { ... }
    pub fn cols(self: TensorView) u64 { ... }
};
```

**Verification:**
```bash
zig-infer info llama-3.2-1b-q4_0.gguf
# Output:
# Architecture: llama
# Parameters: 1.24B
# Quantization: Q4_0 (mostly)
# Layers: 16
# Hidden size: 2048
# Heads: 32 (KV: 8)
# Vocab: 128256
# Context: 131072
# File size: 747 MB
# Tensors: 146
```

**Pitfalls:**
- GGUF strings are length-prefixed (u64 length + bytes), NOT null-terminated
- Metadata values can be arrays of other metadata values (recursive parsing)
- Tensor data section starts at an alignment boundary (typically 32 bytes) after all tensor infos
- mmap with `MAP_PRIVATE | MAP_NORESERVE` — don't commit physical pages for the entire file upfront
- Tensor names follow a convention: `blk.{N}.attn_q.weight`, `blk.{N}.ffn_gate.weight`, etc.
- Some models use `token_embd.weight` and `output.weight` as separate tensors, others tie them

---

### M2: BPE Tokenizer

**Files:**
- `src/tokenizer.zig` — BPE tokenizer (encode + decode)

**Algorithm: Byte-Pair Encoding (BPE)**

The tokenizer is embedded in the GGUF file as metadata. No separate tokenizer files needed.

```
Input: "Hello world"

Step 1: UTF-8 bytes → initial tokens (one per byte or per pre-token)
Step 2: Repeatedly merge the highest-priority adjacent pair
Step 3: Return token IDs

Vocabulary comes from GGUF metadata:
  tokenizer.ggml.tokens  → ["<s>", "</s>", "He", "llo", " world", ...]
  tokenizer.ggml.scores  → [0.0, 0.0, -234.5, -567.8, -123.4, ...]
  tokenizer.ggml.merges  → ["H e", "l l", "ll o", ...]  (optional, for GPT-2 style)
```

**Implementation:**

```zig
pub const Tokenizer = struct {
    vocab: [][]const u8,       // token ID → string
    scores: []f32,             // token ID → merge priority score
    vocab_map: StringHashMap(u32),  // string → token ID
    bos_id: u32,               // beginning of sequence
    eos_id: u32,               // end of sequence

    // Special tokens
    special_tokens: std.AutoHashMap([]const u8, u32),

    pub fn init(gguf: *const GGUFFile) !Tokenizer { ... }

    /// Encode text to token IDs
    pub fn encode(self: *const Tokenizer, text: []const u8, add_bos: bool) ![]u32 {
        // 1. Convert text to initial token sequence (byte-level)
        // 2. Build priority queue of adjacent pairs by score
        // 3. Repeatedly merge best pair until no more merges possible
        // 4. Return token IDs
    }

    /// Decode token IDs back to text
    pub fn decode(self: *const Tokenizer, tokens: []const u32) ![]u8 {
        // Concatenate vocab strings for each token ID
        // Handle byte-fallback tokens (e.g., <0xE2>)
    }

    /// Decode a single token (for streaming output)
    pub fn decodeToken(self: *const Tokenizer, token: u32) []const u8 {
        return self.vocab[token];
    }
};
```

**BPE merge algorithm (SentencePiece style):**

```
function encode(text):
    // Initial: each UTF-8 character or byte-fallback is a token
    tokens = split_to_initial_tokens(text)

    loop:
        best_score = -inf
        best_pos = -1

        // Find the best adjacent pair to merge
        for i in 0..tokens.len-1:
            merged = concat(tokens[i], tokens[i+1])
            if merged in vocab_map:
                score = scores[vocab_map[merged]]
                if score > best_score:
                    best_score = score
                    best_pos = i

        if best_pos == -1: break  // no more merges

        // Merge the pair
        tokens[best_pos] = concat(tokens[best_pos], tokens[best_pos+1])
        remove tokens[best_pos+1]

    return [vocab_map[t] for t in tokens]
```

**Optimization:** Use a min-heap (priority queue) instead of linear scan. O(n log n) instead of O(n²) per merge step.

**Verification:**
```bash
# Encode and decode should round-trip
zig-infer tokenize --model llama3.gguf "Hello, world!"
# Output:
# Tokens: [128000, 9906, 11, 1917, 0]
# Text:   ["<|begin_of_text|>", "Hello", ",", " world", "!"]
# Count:  5 tokens
```

**Pitfalls:**
- LLaMA 3 uses a GPT-4-style BPE with `merges` list (pair-based), LLaMA 1/2 use SentencePiece-style with `scores` (unigram-based). Support both.
- Byte-fallback tokens: `<0x00>` through `<0xFF>` represent raw bytes for unknown characters
- BOS token should be prepended for generation, not for embedding
- Some models have added tokens (e.g., chat template tokens `<|start_header_id|>`) that need special handling
- Unicode normalization: some tokenizers expect NFKC, others don't. Check `tokenizer.ggml.pre` metadata key.

---

### M3: Tensor Math + SIMD Kernels

**Files:**
- `src/math.zig` — Core tensor operations
- `src/simd.zig` — SIMD-optimized kernels
- `src/quant.zig` — Quantization/dequantization

This is the performance-critical layer. Every operation in the forward pass reduces to these primitives.

**Core operations needed:**

| Operation | Used By | Complexity |
|-----------|---------|------------|
| `matmul(A, B)` | Attention Q/K/V projections, FFN layers | O(m·n·k) |
| `matmul_quantized(A_quant, x_f32)` | All weight multiplications | O(m·n·k) |
| `rmsnorm(x, weight)` | Pre-attention and pre-FFN normalization | O(n) |
| `rope(q, k, pos)` | Rotary position embeddings | O(n) |
| `softmax(x)` | Attention scores | O(n) |
| `silu(x)` | SwiGLU activation (gate) | O(n) |
| `elementwise_mul(a, b)` | SwiGLU (gate * up projection) | O(n) |
| `add(a, b)` | Residual connections | O(n) |

**Quantized matmul (the hot path):**

Most weights are quantized. The inner loop is: dequantize a block of weights → dot product with input → accumulate.

```
Q4_0 format (block of 32 values):
┌──────────┬────────────────────────────────┐
│ scale    │ 16 bytes (32 × 4-bit values)   │
│ (f16)    │ packed as nibbles              │
│ 2 bytes  │                                │
└──────────┴────────────────────────────────┘
Total: 18 bytes for 32 values = 0.5625 bytes/value

Dequantize: value[i] = (nibble[i] - 8) * scale
```

```zig
// src/quant.zig

pub const BlockQ4_0 = extern struct {
    scale: f16,                    // delta
    quants: [16]u8,                // 32 × 4-bit values packed into 16 bytes
};

/// Dequantize Q4_0 block to f32 (scalar fallback)
pub fn dequantize_q4_0(block: *const BlockQ4_0, out: *[32]f32) void {
    const d: f32 = @floatCast(block.scale);
    for (0..16) |i| {
        const byte = block.quants[i];
        out[i * 2]     = @as(f32, @intCast(@as(i8, @truncate(byte & 0x0F)) - 8)) * d;
        out[i * 2 + 1] = @as(f32, @intCast(@as(i8, @truncate(byte >> 4)) - 8)) * d;
    }
}
```

**SIMD dot product (AVX2):**

```zig
// src/simd.zig

/// Dot product of two f32 vectors using AVX2 (8-wide)
pub fn dot_f32_avx2(a: [*]const f32, b: [*]const f32, n: usize) f32 {
    var sum_vec: @Vector(8, f32) = @splat(0.0);
    var i: usize = 0;

    // Process 8 floats at a time
    while (i + 8 <= n) : (i += 8) {
        const va: @Vector(8, f32) = a[i..][0..8].*;
        const vb: @Vector(8, f32) = b[i..][0..8].*;
        sum_vec += va * vb;   // Zig compiles this to vfmadd or vmulps+vaddps
    }

    // Horizontal sum
    var sum = @reduce(.Add, sum_vec);

    // Scalar tail
    while (i < n) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

/// Quantized Q4_0 dot product with f32 vector (AVX2)
/// This is THE hot loop — ~90% of inference time is here
pub fn dot_q4_0_f32_avx2(
    blocks: [*]const BlockQ4_0,
    x: [*]const f32,
    n_blocks: usize,
) f32 {
    // For each block of 32:
    //   1. Load 16 bytes of packed nibbles
    //   2. Unpack to 32 × i8 values (subtract 8)
    //   3. Convert to f32
    //   4. Multiply by scale
    //   5. Dot product with corresponding 32 x values
    //   6. Accumulate
    // All steps vectorized with AVX2
    ...
}
```

**SIMD dispatch pattern (same as zsha256sum):**

```zig
// Runtime feature detection, compile-time SIMD code
pub const SimdLevel = enum { scalar, avx2, avx512, neon };

pub fn detectSimd() SimdLevel {
    if (comptime builtin.cpu.arch == .aarch64) return .neon;
    // Check CPUID for AVX-512, AVX2
    const cpuid = asm volatile ("cpuid" : ...);
    if (cpuid has avx512f) return .avx512;
    if (cpuid has avx2) return .avx2;
    return .scalar;
}

// Function pointers set at init based on detected level
pub var dot_f32: *const fn([*]const f32, [*]const f32, usize) f32 = undefined;
pub var dot_q4_0: *const fn([*]const BlockQ4_0, [*]const f32, usize) f32 = undefined;

pub fn init() void {
    switch (detectSimd()) {
        .avx512 => { dot_f32 = dot_f32_avx512; dot_q4_0 = dot_q4_0_avx512; },
        .avx2   => { dot_f32 = dot_f32_avx2;   dot_q4_0 = dot_q4_0_avx2; },
        .neon   => { dot_f32 = dot_f32_neon;    dot_q4_0 = dot_q4_0_neon; },
        .scalar => { dot_f32 = dot_f32_scalar;  dot_q4_0 = dot_q4_0_scalar; },
    }
}
```

**RMSNorm:**
```
RMSNorm(x, w) = w * x / sqrt(mean(x²) + epsilon)

Where:
  x = input vector [d_model]
  w = learned weight vector [d_model]
  epsilon = 1e-5 (or 1e-6, check model metadata)
```

**RoPE (Rotary Position Embeddings):**
```
For each pair (x[2i], x[2i+1]) at position pos:
  freq = 1.0 / (theta ^ (2i / d_head))
  angle = pos * freq
  x_rot[2i]   = x[2i] * cos(angle) - x[2i+1] * sin(angle)
  x_rot[2i+1] = x[2i] * sin(angle) + x[2i+1] * cos(angle)

Where theta = 10000.0 (or from model metadata rope_freq_base)
```

**Verification:**
```bash
zig-infer bench-math
# matmul 4096×4096: 48ms (scalar), 12ms (AVX2), 6ms (AVX-512)
# Q4_0 dot 4096: 1.2μs (AVX2)
# RMSNorm 4096: 0.3μs
# RoPE 128×32: 0.8μs
```

**Pitfalls:**
- Q4_0 nibbles: low nibble is first value, high nibble is second. Easy to swap.
- RoPE frequency base varies by model: LLaMA 1/2 use 10000, LLaMA 3 uses 500000. Read from GGUF metadata.
- RoPE can be "normal" (rotate pairs) or "neox" (rotate halves). Check `rope_scaling_type` metadata.
- Denormalized floats in dot products can tank performance. Flush-to-zero (FTZ) and denormals-are-zero (DAZ) should be set via MXCSR register.
- Memory alignment: SIMD loads need 32-byte alignment for AVX2, 64-byte for AVX-512. Zig's `@alignCast` handles this.

---

### M4: Transformer Forward Pass

**Files:**
- `src/model.zig` — Model struct, forward pass
- `src/attention.zig` — Multi-head attention (GQA/MHA)
- `src/kv_cache.zig` — KV cache for autoregressive generation

**LLaMA Transformer Architecture:**

```
Input token → Embedding lookup
                │
                ▼
        ┌───────────────┐
        │  For each of   │
        │  N layers:     │
        │                │
        │  ┌───────────┐ │
        │  │ RMSNorm   │ │  (pre-attention norm)
        │  └─────┬─────┘ │
        │        │        │
        │  ┌─────▼─────┐ │
        │  │ Attention  │ │  Q = x @ Wq, K = x @ Wk, V = x @ Wv
        │  │ (GQA)     │ │  Q,K = RoPE(Q,K, pos)
        │  │           │ │  scores = Q @ K^T / sqrt(d_head)
        │  │           │ │  scores = softmax(scores + causal_mask)
        │  │           │ │  out = scores @ V
        │  │           │ │  out = out @ Wo
        │  └─────┬─────┘ │
        │        │        │
        │    x = x + out  │  (residual connection)
        │        │        │
        │  ┌─────▼─────┐ │
        │  │ RMSNorm   │ │  (pre-FFN norm)
        │  └─────┬─────┘ │
        │        │        │
        │  ┌─────▼─────┐ │
        │  │   FFN      │ │  gate = x @ Wgate
        │  │  (SwiGLU)  │ │  up   = x @ Wup
        │  │           │ │  out  = (silu(gate) * up) @ Wdown
        │  └─────┬─────┘ │
        │        │        │
        │    x = x + out  │  (residual connection)
        │        │        │
        └────────┼────────┘
                 │
                 ▼
           ┌───────────┐
           │  RMSNorm   │  (final norm)
           └─────┬─────┘
                 │
                 ▼
           ┌───────────┐
           │  Output    │  logits = x @ Woutput
           │  Head      │  → [vocab_size] logits
           └───────────┘
```

**Grouped Query Attention (GQA):**

LLaMA 3 uses GQA where multiple query heads share a single KV head. This reduces KV cache size.

```
Example: head_count=32, head_count_kv=8
→ 4 query heads per KV head (group size = 4)
→ KV cache is 4x smaller than full MHA

For head i:
  kv_head = i / (head_count / head_count_kv)
  Q[i] uses K[kv_head] and V[kv_head]
```

**KV Cache:**

For autoregressive generation, we cache K and V from previous positions to avoid recomputation.

```zig
// src/kv_cache.zig

pub const KVCache = struct {
    /// Shape: [n_layers][max_seq_len][n_kv_heads][head_dim]
    key_cache: []f32,
    value_cache: []f32,

    n_layers: u32,
    max_seq_len: u32,
    n_kv_heads: u32,
    head_dim: u32,
    current_pos: u32,         // next position to write

    pub fn init(allocator: Allocator, config: ModelConfig) !KVCache { ... }

    /// Store K,V for layer at current position
    pub fn store(self: *KVCache, layer: u32, k: []const f32, v: []const f32) void { ... }

    /// Get K,V slices for layer (positions 0..current_pos)
    pub fn getK(self: *const KVCache, layer: u32) []const f32 { ... }
    pub fn getV(self: *const KVCache, layer: u32) []const f32 { ... }

    /// Advance position
    pub fn advance(self: *KVCache) void { self.current_pos += 1; }

    /// Reset for new generation
    pub fn reset(self: *KVCache) void { self.current_pos = 0; }
};
```

**Model struct:**

```zig
// src/model.zig

pub const ModelConfig = struct {
    architecture: []const u8,
    n_layers: u32,
    d_model: u32,           // embedding_length
    n_heads: u32,           // attention.head_count
    n_kv_heads: u32,        // attention.head_count_kv
    d_head: u32,            // d_model / n_heads
    d_ffn: u32,             // feed_forward_length
    vocab_size: u32,
    max_seq_len: u32,       // context_length
    rope_theta: f32,        // rope_freq_base
    rms_norm_eps: f32,      // attention.layer_norm_rms_epsilon
};

pub const Model = struct {
    config: ModelConfig,
    gguf: GGUFFile,
    tokenizer: Tokenizer,
    kv_cache: KVCache,

    // Scratch buffers (allocated once, reused)
    x: []f32,              // [d_model] current hidden state
    xb: []f32,             // [d_model] scratch for norm output
    q: []f32,              // [n_heads * d_head] query
    k: []f32,              // [n_kv_heads * d_head] key
    v: []f32,              // [n_kv_heads * d_head] value
    att: []f32,            // [n_heads * max_seq_len] attention scores
    ffn_gate: []f32,       // [d_ffn]
    ffn_up: []f32,         // [d_ffn]
    ffn_down: []f32,       // [d_model]
    logits: []f32,         // [vocab_size]

    pub fn init(allocator: Allocator, gguf_path: []const u8) !Model { ... }

    /// Forward pass for a single token at a given position
    pub fn forward(self: *Model, token: u32, pos: u32) []f32 {
        // 1. Embedding lookup
        const embed = self.gguf.getTensor("token_embd.weight").?;
        copyRow(self.x, embed, token);  // x = embedding[token]

        // 2. For each layer
        for (0..self.config.n_layers) |layer| {
            // Pre-attention RMSNorm
            rmsnorm(self.xb, self.x, self.getWeight("blk.{}.attn_norm.weight", layer));

            // QKV projections (quantized matmul)
            matmul(self.q, self.xb, self.getWeight("blk.{}.attn_q.weight", layer));
            matmul(self.k, self.xb, self.getWeight("blk.{}.attn_k.weight", layer));
            matmul(self.v, self.xb, self.getWeight("blk.{}.attn_v.weight", layer));

            // RoPE
            applyRope(self.q, self.k, pos, self.config);

            // Store K,V in cache
            self.kv_cache.store(layer, self.k, self.v);

            // Multi-head attention with GQA
            self.computeAttention(layer, pos);

            // Output projection
            matmul(self.xb, self.att_out, self.getWeight("blk.{}.attn_output.weight", layer));

            // Residual
            vectorAdd(self.x, self.x, self.xb);

            // Pre-FFN RMSNorm
            rmsnorm(self.xb, self.x, self.getWeight("blk.{}.ffn_norm.weight", layer));

            // SwiGLU FFN
            matmul(self.ffn_gate, self.xb, self.getWeight("blk.{}.ffn_gate.weight", layer));
            matmul(self.ffn_up, self.xb, self.getWeight("blk.{}.ffn_up.weight", layer));
            silu(self.ffn_gate);
            elementwiseMul(self.ffn_gate, self.ffn_up);
            matmul(self.ffn_down, self.ffn_gate, self.getWeight("blk.{}.ffn_down.weight", layer));

            // Residual
            vectorAdd(self.x, self.x, self.ffn_down);
        }

        // Final RMSNorm
        rmsnorm(self.x, self.x, self.gguf.getTensor("output_norm.weight").?);

        // Output head
        matmul(self.logits, self.x, self.gguf.getTensor("output.weight").?);

        return self.logits;
    }
};
```

**Verification:**
```bash
# Prefill benchmark (process prompt in one pass)
zig-infer bench --model llama-3.2-1b-q4_0.gguf --prompt-len 128
# Prompt eval: 128 tokens in 340ms (376 tok/s)
# Generation:  32 tokens in 1.2s  (26.7 tok/s)
```

**Pitfalls:**
- Causal mask: attention scores for future positions must be set to -inf before softmax
- Scratch buffers: allocate once at model init, not per forward call. These are the working memory.
- Weight tensor names: vary by model family. LLaMA uses `blk.{N}.attn_q.weight`, Mistral might use slightly different naming. Parse `general.architecture` and dispatch accordingly.
- Tied embeddings: if `output.weight` is missing, reuse `token_embd.weight` for the output head
- Prompt processing (prefill): process all prompt tokens at once as a batch for efficiency, not one at a time

---

### M5: Sampler + Text Generation

**Files:**
- `src/sampler.zig` — Token sampling strategies
- `src/generate.zig` — Generation loop

**Sampling strategies:**

```zig
pub const SamplerConfig = struct {
    temperature: f32 = 0.7,    // 0.0 = greedy, higher = more random
    top_k: u32 = 40,           // Keep top K logits
    top_p: f32 = 0.9,          // Nucleus sampling threshold
    min_p: f32 = 0.05,         // Minimum probability threshold
    repeat_penalty: f32 = 1.1, // Penalize repeated tokens
    seed: u64 = 0,             // RNG seed (0 = random)
};

pub const Sampler = struct {
    config: SamplerConfig,
    rng: std.rand.Xoshiro256,

    pub fn init(config: SamplerConfig) Sampler { ... }

    /// Sample next token from logits
    pub fn sample(self: *Sampler, logits: []f32, prev_tokens: []const u32) u32 {
        // 1. Apply repeat penalty
        for (prev_tokens) |tok| {
            if (logits[tok] > 0) logits[tok] /= self.config.repeat_penalty
            else logits[tok] *= self.config.repeat_penalty;
        }

        // 2. Temperature
        if (self.config.temperature == 0.0) return argmax(logits);
        for (logits) |*l| l.* /= self.config.temperature;

        // 3. Softmax
        softmax(logits);

        // 4. Top-K: zero out everything below Kth probability
        if (self.config.top_k > 0) applyTopK(logits, self.config.top_k);

        // 5. Top-P (nucleus): zero out tail below cumulative threshold
        if (self.config.top_p < 1.0) applyTopP(logits, self.config.top_p);

        // 6. Min-P: zero out tokens below min_p * max_prob
        if (self.config.min_p > 0.0) applyMinP(logits, self.config.min_p);

        // 7. Renormalize and sample
        renormalize(logits);
        return sampleFromDistribution(logits, self.rng.next());
    }
};
```

**Generation loop:**

```zig
// src/generate.zig

pub fn generate(
    model: *Model,
    prompt: []const u8,
    config: SamplerConfig,
    max_tokens: u32,
    writer: anytype,          // streaming output
) !GenerateResult {
    var sampler = Sampler.init(config);
    const tokens = try model.tokenizer.encode(prompt, true);  // add BOS

    var total_prompt_time: u64 = 0;
    var total_gen_time: u64 = 0;
    var generated: u32 = 0;

    // Prefill: process prompt tokens
    const prefill_start = std.time.nanoTimestamp();
    for (tokens, 0..) |tok, pos| {
        _ = model.forward(tok, @intCast(pos));
    }
    total_prompt_time = std.time.nanoTimestamp() - prefill_start;

    // Generate
    var pos: u32 = @intCast(tokens.len);
    var prev_token: u32 = tokens[tokens.len - 1];
    var prev_tokens = std.ArrayList(u32).init(allocator);
    try prev_tokens.appendSlice(tokens);

    while (generated < max_tokens) {
        const gen_start = std.time.nanoTimestamp();

        const logits = model.forward(prev_token, pos);
        const next_token = sampler.sample(logits, prev_tokens.items);

        total_gen_time += std.time.nanoTimestamp() - gen_start;

        // Check for EOS
        if (next_token == model.tokenizer.eos_id) break;

        // Stream output
        const piece = model.tokenizer.decodeToken(next_token);
        try writer.writeAll(piece);

        try prev_tokens.append(next_token);
        prev_token = next_token;
        pos += 1;
        generated += 1;
    }

    return GenerateResult{
        .tokens_generated = generated,
        .prompt_tokens = @intCast(tokens.len),
        .prompt_tok_per_sec = @as(f64, @floatFromInt(tokens.len)) /
            (@as(f64, @floatFromInt(total_prompt_time)) / 1e9),
        .gen_tok_per_sec = @as(f64, @floatFromInt(generated)) /
            (@as(f64, @floatFromInt(total_gen_time)) / 1e9),
    };
}
```

**Verification:**
```bash
zig-infer generate --model llama-3.2-1b-q4_0.gguf \
    --prompt "The capital of France is" \
    --max-tokens 32 \
    --temperature 0.0
# The capital of France is Paris. It is the largest city in France and...
#
# Prompt: 7 tokens (423 tok/s)
# Generation: 32 tokens (28.4 tok/s)
# Total: 1.89s
```

**Pitfalls:**
- Greedy (temperature=0) must be argmax, NOT softmax with temp=0 (division by zero)
- top_k partial sort is O(n) with `std.sort.partialSort`, not O(n log n) full sort
- Repeat penalty should look back a window (e.g., last 64 tokens), not entire history
- Streaming output: write each token's text immediately, don't buffer. UX matters.
- Some tokens decode to partial UTF-8 sequences. Buffer output and only flush complete codepoints.

---

### M6: CLI + C FFI

**Files:**
- `src/main.zig` — CLI interface
- `src/ffi.zig` — C FFI exports

**CLI Interface:**

```bash
# Text generation
zig-infer generate --model <path.gguf> --prompt "text" [options]
    --max-tokens N          # Maximum tokens to generate (default: 256)
    --temperature F         # Sampling temperature (default: 0.7)
    --top-k N               # Top-K sampling (default: 40)
    --top-p F               # Nucleus sampling (default: 0.9)
    --min-p F               # Minimum probability (default: 0.05)
    --repeat-penalty F      # Repetition penalty (default: 1.1)
    --seed N                # RNG seed (default: random)
    --threads N             # Thread count for matmul (default: cpu_count)

# Embedding
zig-infer embed --model <path.gguf> --input "text"
    --normalize             # L2-normalize output (default: true)
    --pooling mean|cls|last # Pooling strategy (default: mean)

# Interactive chat
zig-infer chat --model <path.gguf>
    --system "prompt"       # System prompt
    --template auto|llama3|chatml|mistral  # Chat template

# Model info
zig-infer info <path.gguf>

# Tokenization
zig-infer tokenize --model <path.gguf> "text"

# Benchmark
zig-infer bench --model <path.gguf>
    --prompt-len N          # Prompt length for prefill bench (default: 128)
    --gen-len N             # Generation length bench (default: 64)
    --warmup N              # Warmup iterations (default: 1)
    --iterations N          # Benchmark iterations (default: 3)

# Perplexity measurement
zig-infer perplexity --model <path.gguf> --input <text_file>
```

**C FFI:**

```zig
// src/ffi.zig — same pattern as zig_pdf_generator

export fn ziginfer_create(model_path: [*:0]const u8) ?*Model { ... }
export fn ziginfer_destroy(model: *Model) void { ... }

export fn ziginfer_generate(
    model: *Model,
    prompt: [*:0]const u8,
    max_tokens: u32,
    temperature: f32,
    output_buf: [*]u8,
    output_buf_len: usize,
) i32 { ... }  // returns bytes written or negative error

export fn ziginfer_embed(
    model: *Model,
    input: [*:0]const u8,
    output: [*]f32,
    output_dim: usize,
) i32 { ... }  // returns embedding dimension or negative error

export fn ziginfer_tokenize(
    model: *Model,
    text: [*:0]const u8,
    output: [*]u32,
    max_tokens: usize,
) i32 { ... }  // returns token count or negative error
```

**Build targets:**

```bash
zig build                     # Native binary (zig-infer)
zig build shared              # libziginfer.so for FFI
zig build static              # libziginfer.a
zig build -Dtarget=aarch64-linux  # ARM64 cross-compile
```

---

### M7: Multi-threaded Matmul

**Files:**
- `src/threadpool.zig` — Thread pool for parallel matmul

Matmul is the bottleneck. A 4096×4096 matmul at Q4_0 does 4096 × 4096 × 32 / 32 = 16M dequant+dot operations. Split across rows.

```zig
pub const ThreadPool = struct {
    threads: []std.Thread,
    tasks: BoundedQueue(Task),
    done: std.Thread.ResetEvent,

    pub fn init(n_threads: u32) !ThreadPool { ... }

    /// Parallel matmul: split output rows across threads
    pub fn parallelMatmul(
        self: *ThreadPool,
        out: []f32,           // [rows]
        x: []const f32,       // [cols]
        weight: TensorView,   // [rows × cols], possibly quantized
    ) void {
        const rows = weight.rows();
        const rows_per_thread = rows / self.threads.len;

        for (0..self.threads.len) |t| {
            const start = t * rows_per_thread;
            const end = if (t == self.threads.len - 1) rows else (t + 1) * rows_per_thread;
            self.enqueue(.{ .matmul_rows = .{
                .out = out[start..end],
                .x = x,
                .weight = weight,
                .start_row = start,
                .end_row = end,
            }});
        }

        self.waitAll();
    }
};
```

**Expected scaling:**

| Threads | 1B Q4_0 tok/s | 7B Q4_0 tok/s | 13B Q4_0 tok/s |
|---------|--------------|--------------|---------------|
| 1       | ~28          | ~6           | ~3            |
| 4       | ~90          | ~20          | ~10           |
| 8       | ~150         | ~35          | ~18           |
| 16      | ~200         | ~50          | ~25           |

(Estimates based on llama.cpp benchmarks on comparable hardware)

---

### M8: Chat Templates + Embedding Mode

**Files:**
- `src/chat.zig` — Chat template formatting
- `src/embed.zig` — Embedding extraction

**Chat templates:**

```zig
pub const ChatTemplate = enum {
    llama3,     // <|start_header_id|>system<|end_header_id|>\n\n{text}<|eot_id|>
    chatml,     // <|im_start|>system\n{text}<|im_end|>\n
    mistral,    // [INST] {text} [/INST]
    auto,       // Detect from GGUF metadata

    pub fn format(self: ChatTemplate, messages: []const Message) ![]u8 { ... }
};

pub const Message = struct {
    role: enum { system, user, assistant },
    content: []const u8,
};
```

**Embedding mode:**

For embedding models (nomic-embed, etc.), extract the hidden state after the last layer instead of projecting to vocab logits. Apply pooling (mean, CLS, or last token).

---

## Performance Targets

| Model | Quantization | Size | Prefill (tok/s) | Generation (tok/s) | Memory |
|-------|-------------|------|-----------------|-------------------|--------|
| LLaMA 3.2 1B | Q4_0 | 747MB | 400+ | 25-30 | ~1GB |
| LLaMA 3.2 3B | Q4_0 | 1.9GB | 200+ | 15-20 | ~2.5GB |
| Mistral 7B | Q4_0 | 3.8GB | 100+ | 8-12 | ~5GB |
| LLaMA 3.1 8B | Q4_0 | 4.7GB | 80+ | 6-10 | ~6GB |
| LLaMA 3.1 70B | Q4_0 | 40GB | 10+ | 1-2 | ~42GB |

Targets are for 8-core x86_64 with AVX2. ARM NEON targets will be ~60-70% of these.

---

## Dependency Graph

```
M1 (GGUF Loader) ─── must be first, everything depends on it
  │
  ├── M2 (Tokenizer) ─── needs GGUF metadata
  │
  └── M3 (Tensor Math) ─── needs TensorView from M1
       │
       └── M4 (Forward Pass) ─── needs M1 + M2 + M3
            │
            ├── M5 (Sampler + Generation) ─── needs M4
            │    │
            │    └── M6 (CLI + FFI) ─── needs M5, the user-facing milestone
            │
            └── M7 (Thread Pool) ─── can parallelize M4, independent of M5
                 │
                 └── M8 (Chat + Embed) ─── finishing touches
```

**Critical path:** M1 → M3 → M4 → M5 → M6
**Parallelizable:** M2 can be built alongside M3. M7 can be built alongside M5.

---

## File Structure

```
programs/zig_inference/
├── build.zig
├── README.md
├── src/
│   ├── main.zig          # CLI entry point
│   ├── gguf.zig          # GGUF file parser + mmap
│   ├── tensor.zig        # Tensor type + views
│   ├── tokenizer.zig     # BPE tokenizer
│   ├── math.zig          # Core tensor operations (rmsnorm, rope, softmax, silu)
│   ├── simd.zig          # SIMD dispatch + kernels (AVX2, AVX-512, NEON)
│   ├── quant.zig         # Quantization formats (Q4_0, Q4_1, Q8_0, F16)
│   ├── model.zig         # Model config + forward pass
│   ├── attention.zig     # Multi-head / grouped-query attention
│   ├── kv_cache.zig      # KV cache for autoregressive generation
│   ├── sampler.zig       # Sampling strategies (temp, top-k, top-p, min-p)
│   ├── generate.zig      # Generation loop (prefill + decode)
│   ├── chat.zig          # Chat template formatting
│   ├── embed.zig         # Embedding extraction + pooling
│   ├── threadpool.zig    # Multi-threaded matmul
│   └── ffi.zig           # C FFI exports
├── tests/
│   ├── test_gguf.zig
│   ├── test_tokenizer.zig
│   ├── test_math.zig
│   ├── test_quant.zig
│   └── test_generate.zig
└── examples/
    ├── simple_generate.zig
    └── embedding.zig
```

---

## Integration Points

### With zig-ai agent SDK

```zig
// In zig_ai: local provider alongside Claude, OpenAI, Gemini, Grok
const local_model = try zig_inference.Model.init(allocator, "models/llama-3.2-1b-q4_0.gguf");
defer local_model.deinit();

// Use for tool-calling agent with local model (no API costs)
const response = try zig_inference.generate(&local_model, prompt, .{
    .temperature = 0.0,
    .max_tokens = 512,
}, writer);
```

### With http_sentinel (serving)

```zig
// Wrap zig_inference behind http_sentinel as OpenAI-compatible API
// POST /v1/chat/completions
// POST /v1/embeddings
```

### With Python via FFI

```python
import ctypes

lib = ctypes.CDLL("./libziginfer.so")
model = lib.ziginfer_create(b"llama-3.2-1b-q4_0.gguf")

buf = ctypes.create_string_buffer(4096)
n = lib.ziginfer_generate(model, b"Hello", 64, ctypes.c_float(0.7), buf, 4096)
print(buf.value[:n].decode())

lib.ziginfer_destroy(model)
```

---

## Build Configuration

```zig
// build.zig
const exe = b.addExecutable(.{
    .name = "zig-infer",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// Enable SIMD based on target
if (target.result.cpu.arch == .x86_64) {
    exe.root_module.addCMacro("HAVE_AVX2", "1");
    // AVX-512 detected at runtime
}

// Shared library for FFI
const shared = b.addSharedLibrary(.{
    .name = "ziginfer",
    .root_source_file = b.path("src/ffi.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});

b.installArtifact(exe);
b.installArtifact(shared);
```

---

## Test Models (recommended for development)

| Model | Params | Quant | Size | Notes |
|-------|--------|-------|------|-------|
| TinyLLaMA 1.1B | 1.1B | Q4_0 | 600MB | Fast iteration during development |
| LLaMA 3.2 1B | 1.24B | Q4_0 | 747MB | First real target |
| Phi-3 Mini 3.8B | 3.8B | Q4_0 | 2.2GB | Good quality/size ratio |
| Mistral 7B v0.3 | 7.2B | Q4_0 | 3.8GB | Production quality baseline |

Download from Hugging Face (`huggingface.co/TheBloke/` or official repos in GGUF format).

---

## Reference Implementations

Study these for correctness verification:

| Project | Language | Value |
|---------|----------|-------|
| [llama.cpp](https://github.com/ggerganov/llama.cpp) | C/C++ | Reference GGUF + quantization |
| [llama2.c](https://github.com/karpathy/llama2.c) | C | Minimal single-file transformer (~700 lines) |
| [llm.zig](https://github.com/nichochar/llm.zig) | Zig | Existing Zig inference (study but don't copy) |
| [llama3.java](https://github.com/mukel/llama3.java) | Java | Clean GQA implementation |

**Karpathy's llama2.c is the best starting reference** — it's a single 700-line C file that implements the full forward pass. The Zig version should start similarly simple and then add quantization, SIMD, and threading on top.
