# zig-infer

A from-scratch ML inference engine written in Zig. No frameworks, no C++ dependencies, no Python — just Zig and libc. Runs transformer models directly from GGUF and ggml binary files with quantized weight support and multi-threaded matmul.

Currently supports two model architectures:
- **LLaMA-family** (decoder-only): text generation from GGUF files
- **Whisper** (encoder-decoder): speech-to-text from ggml binary files

## Quick Start

```bash
# Build
zig build

# Text generation (LLaMA / Mistral / etc.)
./zig-out/bin/zig-infer generate --model models/llama-7b-q4_0.gguf --prompt "The capital of France is" --threads 8

# Speech-to-text (Whisper)
./zig-out/bin/zig-infer transcribe --model models/ggml-tiny.en.bin --audio recording.wav --threads 8

# Model info
./zig-out/bin/zig-infer info models/llama-7b-q4_0.gguf

# Tokenize
./zig-out/bin/zig-infer tokenize --model models/llama-7b-q4_0.gguf "Hello world"

# Benchmark
./zig-out/bin/zig-infer bench --model models/llama-7b-q4_0.gguf --prompt-len 128 --gen-len 32
```

## Supported Models

### Text Generation (GGUF)

Any LLaMA-architecture model in GGUF format:
- LLaMA 2/3, Mistral, Mixtral (decoder layers only)
- Quantizations: F32, F16, Q4_0, Q4_1, Q8_0, Q6_K
- BPE tokenizer with merge-based encoding

### Speech-to-Text (ggml binary)

Whisper models from [whisper.cpp](https://github.com/ggerganov/whisper.cpp):
- whisper-tiny.en (39M params, ~75MB) — tested and verified
- Larger Whisper variants should work but are untested
- Input: 16kHz mono 16-bit PCM WAV files
- Output: streaming transcription text

## Architecture

~4,200 lines of Zig across 16 source files. Zero external dependencies beyond libc.

```
src/
  main.zig           CLI: info, tokenize, generate, bench, transcribe
  gguf.zig           GGUF v3 file parser (mmap, metadata, tensor registry)
  whisper_loader.zig ggml binary format parser (whisper.cpp models)
  tensor.zig         TensorView: typed access to mmap'd weight data
  tokenizer.zig      BPE tokenizer with merge-based encode/decode
  quant.zig          Dequantization: Q4_0, Q4_1, Q8_0, Q6_K + SIMD dot products
  math.zig           Core ops: matmul, rmsnorm, layernorm, softmax, gelu, silu, rope
  kv_cache.zig       Key-value cache for autoregressive decoding
  thread_pool.zig    Persistent thread pool with futex sync for parallel matmul
  sampler.zig        Temperature, top-k, top-p, repetition penalty sampling
  model.zig          LLaMA forward pass (RMSNorm, SwiGLU, RoPE, GQA)
  generate.zig       Text generation loop with streaming output
  audio.zig          WAV reader, 512-point FFT, Hann window, mel spectrogram
  whisper.zig        Whisper forward pass (Conv1D, encoder, cross-attn, decoder)
  whisper_decode.zig Greedy decode with special token suppression
  ffi.zig            C FFI exports for embedding in other languages
```

### Key Design Decisions

**mmap for weights.** Model files are memory-mapped, not loaded. The OS pages in weights on demand. A 7B Q4_0 model uses ~3.5GB of address space but only the accessed pages consume physical memory.

**Quantized matmul stays quantized.** Dot products operate directly on Q4_0/Q8_0/Q6_K blocks without bulk dequantization. Each block's scale factor is applied inline during accumulation. This keeps memory bandwidth low.

**Thread pool is persistent.** Worker threads are created once at model load and reused for every matmul via futex-based wake/sleep. No thread creation overhead per inference step.

**Alignment-safe tensor access.** The ggml binary format has no alignment padding — tensor data can start at arbitrary byte offsets. The loader detects unaligned f32 tensors and copies them to aligned memory at parse time. f16 tensors are read byte-by-byte in the matmul inner loop.

## Build Targets

```bash
zig build              # CLI executable: zig-out/bin/zig-infer
zig build shared       # Shared library: zig-out/lib/libziginfer.so (.dylib on macOS)
zig build static       # Static library: zig-out/lib/libziginfer.a
zig build test         # Run unit tests
```

## C FFI

The engine can be embedded in any language that calls C functions:

```c
// Text generation
void *model = ziginfer_create("model.gguf");
int len = ziginfer_generate(model, "Hello", 256, 0.7, buf, buf_size);
ziginfer_destroy(model);

// Speech-to-text
void *wmodel = ziginfer_whisper_create("ggml-tiny.en.bin");
int len = ziginfer_whisper_transcribe(wmodel, "audio.wav", buf, buf_size);
ziginfer_whisper_destroy(wmodel);
```

## Performance

Measured on Apple M2 (24GB), 8 threads, Debug build:

| Task | Model | Result |
|------|-------|--------|
| Transcribe 11s audio | whisper-tiny.en (39M) | ~66s (encode 64s, decode 2s) |
| Text generation | LLaMA-family Q4_0 | Depends on model size |

The encoder is currently bottlenecked by per-element f16 dequantization in the matmul inner loop. A bulk pre-dequantization pass per layer would bring this down significantly. Release builds (`-DReleaseFast`) also help considerably.

## Future Directions

### Near-term Optimizations

- **Bulk f16 dequantization**: Copy f16 weight rows to aligned f32 buffers once per layer instead of byte-by-byte in the matmul inner loop. This alone should cut Whisper encode time by 10-20x.
- **NEON/ARM SIMD**: The f32 dot product uses Zig's `@Vector` but the f16 path is scalar. ARM NEON has native `vcvt_f32_f16` for fast f16-to-f32 conversion.
- **Release build tuning**: The entire engine runs in Debug mode. ReleaseFast with LTO would eliminate bounds checks and inline aggressively.

### ONNX Runtime (Vision Models)

ONNX is the natural next format to support. It would unlock vision and image processing models that don't exist in GGUF:

**Background removal (e.g., U2-Net, RMBG-1.4, MODNet):**
- ONNX graph: parse protobuf tensor format, operator registry
- New operators: Conv2D, BatchNorm2D, MaxPool2D, Upsample/Resize, Sigmoid
- Image I/O: decode PNG/JPEG input, write PNG with alpha channel output
- Pre/post processing: resize to model input dimensions, normalize RGB, threshold mask, composite alpha

**Image classification (e.g., MobileNet, EfficientNet):**
- Reuses Conv2D/BatchNorm2D/Pool infrastructure from above
- Add: Global average pooling, fully-connected layer, top-k output
- Simpler pipeline — no spatial output, just class probabilities

**Object detection (e.g., YOLOv8, RT-DETR):**
- Extends classification with spatial heads
- Add: anchor-free decoding, non-maximum suppression (NMS)
- Output: bounding boxes + class labels + confidence scores

The ONNX operator set is large (~180 ops), but a practical subset of ~20 operators covers most vision models: Conv, Relu, BatchNormalization, MaxPool, AveragePool, Reshape, Transpose, MatMul, Add, Mul, Sigmoid, Resize, Concat, Clip, Flatten, Gemm, Softmax, Pad, Split, Gather.

### Diffusion Models (Image Generation)

Stable Diffusion-style models could run with:
- CLIP text encoder (transformer — reuse existing attention/layernorm)
- U-Net denoiser (Conv2D + cross-attention + timestep embeddings)
- VAE decoder (Conv2D + upsample)
- Scheduler: DDIM/Euler/DPM-Solver stepping

This is the heaviest workload — a single 512x512 image requires ~20-50 U-Net passes. Would strongly benefit from the SIMD and threading optimizations above.

### Additional Audio Models

- **Whisper large-v3**: Already supported architecturally (same encoder-decoder), just needs more memory and the performance optimizations to be practical
- **Audio classification (e.g., YAMNet)**: Reuses mel spectrogram pipeline, add MobileNet-style CNN classifier on top
- **Text-to-speech (e.g., VITS/Bark)**: Decoder-only transformer (reuse LLaMA infra) + vocoder (WaveNet/HiFi-GAN convolutions)

### Model Format Support

| Format | Status | Use Case |
|--------|--------|----------|
| GGUF | Supported | LLaMA-family text generation |
| ggml binary | Supported | Whisper speech-to-text |
| ONNX | Planned | Vision, classification, segmentation |
| SafeTensors | Possible | HuggingFace model weights |

### Operator Coverage

Current operators and what they unlock:

| Operator | Status | Used By |
|----------|--------|---------|
| MatMul (f32/f16/quantized) | Done | All models |
| RMSNorm | Done | LLaMA |
| LayerNorm | Done | Whisper, BERT, ViT |
| Softmax | Done | All attention |
| SiLU | Done | LLaMA |
| GELU | Done | Whisper, BERT, GPT |
| RoPE | Done | LLaMA |
| Conv1D | Done | Whisper encoder |
| KV Cache | Done | All autoregressive |
| BPE Tokenizer | Done | LLaMA, Whisper |
| FFT / Mel Spectrogram | Done | Audio models |
| Conv2D | Needed | Vision models |
| BatchNorm2D | Needed | Vision models |
| MaxPool2D / AvgPool2D | Needed | Vision models |
| Upsample / Resize | Needed | Segmentation, diffusion |
| Sigmoid | Needed | Detection, segmentation |

## Requirements

- Zig 0.16+
- libc (linked automatically)
- No other dependencies

## License

Part of the [quantum-zig-forge](https://github.com/quantum-encoding/quantum-zig-forge) project.
