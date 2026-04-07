# Zig HTTP Sentinel

A production-grade, **pure Zig** HTTP client library for Zig **0.16.0** — zero libc, zero `extern "c"`, zero `@cImport`.

> **Pure Zig**: `link_libc = false`. Uses `std.Io.Threaded` throughout. Runs on any Zig target including freestanding OS kernels.

**Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io)**

> Tested against Zig `0.16.0-dev.3091+`
>
> Standalone repo: [zig-http-concurrent](https://github.com/quantum-encoding/zig-http-concurrent)

---

## Pure Zig — No C Dependencies

Every C dependency has been replaced with native Zig equivalents:

| Was (C/libc) | Now (pure Zig) |
|---|---|
| `std.c.pthread_mutex_*` | Atomic spinlock (`std.atomic.Value`) |
| `std.c.clock_gettime` / `timespec` | `std.Io.Timestamp.now(io, .awake)` |
| `std.c.nanosleep` / `usleep` | `io.sleep(Duration, .awake)` |
| `std.c.arc4random_buf` | `std.Random.DefaultCsprng` |
| C `fopen`/`fread`/`fseek` | `std.Io.Dir.readFileAlloc` |
| `popen`/`pclose` | `std.process.run(allocator, io, ...)` |
| `std.c.getenv` | `std.process.Environ.Map.get()` |
| `std.c.environ` | `std.Io.Threaded.init(allocator, .{})` |
| `std.heap.c_allocator` | `std.heap.smp_allocator` |

## Features

- **Full HTTP**: GET, POST, PUT, PATCH, DELETE, HEAD with auto gzip decompression
- **AI Providers**: Claude, OpenAI, DeepSeek, Gemini, Grok, Vertex AI, ElevenLabs, HeyGen, Meshy
- **Audio**: TTS/STT via OpenAI and Google
- **Batch Processing**: CSV-based concurrent execution (up to 200 parallel)
- **Resilience**: Exponential backoff, circuit breaker, rate limiting
- **Client-Per-Worker**: Zero contention threading model

## Build

```bash
zig build          # Build all
zig build test     # Run tests
zig build cli      # Build AI CLI (zig-ai)
zig build quantum  # Build Quantum Curl
```
