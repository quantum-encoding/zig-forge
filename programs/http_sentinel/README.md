# Zig HTTP Sentinel

A production-grade, **pure Zig** HTTP client library for Zig **0.16.0** — zero libc, zero `extern "c"`, zero `@cImport`.

> **Pure Zig**: `link_libc = false`, zero `@cImport` on the live path. Uses `std.Io.Threaded` throughout. Cross-compiles for any Linux-ABI target — including the [Zigix OS](ZIGIX_INTEGRATION.md), which services the Linux syscalls `std.os.linux` emits, so the client runs there as a userspace ELF with no custom `std.Io` backend. (It is *not* a Linux kernel module; it is hosted userspace code that talks to a kernel via syscalls.)

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
zig build test     # Run tests (lib + manifest + SSRF regressions + attack suite)
zig build attack   # Run the security attack suite standalone
zig build cli      # Build AI CLI (zig-ai)
zig build quantum  # Build Quantum Curl
```

`zig build test` runs the library unit tests, the `engine/manifest.zig`
hostile-input tests, the externally-anchored SSRF guard tests
(`src/security_test.zig`), and the `tests/attack.zig` CRLF/SSRF/redirect/
path-traversal regression suite. The live-network integration tests in
`tests/http_client_test.zig` hit `httpbin.org` and are intentionally **not**
wired into `zig build test`; run them by hand when a network is available.

## Consumers / API stability

`http_sentinel` is not a C-ABI / WASM library — it exposes **no** `export fn`,
`extern "c"`, or `callconv(.c)` surface. It is consumed as a first-class
**Zig module**, published as `b.addModule("http-sentinel")` (see `build.zig`),
and imported by other in-tree programs via:

```zig
exe_module.addImport(
    "http-sentinel",
    b.dependency("http_sentinel", .{}).module("http-sentinel"),
);
```

The public API contract is the export set in `src/lib.zig`: `HttpClient`,
`AIClient`, `ClaudeClient` / `GeminiClient` / `GrokClient` / `OpenAIClient` /
`VertexClient` / `CloudflareClient` / `DeepSeekClient`, `ResponseManager`,
`OpenAITTSClient` / `OpenAISTTClient` / `GoogleTTSClient`, `RetryEngine`,
`ClientPool`, `HttpError`, and the `encoding`, `ai`, `audio`, `batch` modules.

Known in-tree consumers whose builds break if any of those symbols is renamed,
removed, or has its signature changed:

| Consumer | How it depends |
|---|---|
| `programs/gcp_auth` | `b.dependency("http_sentinel").module("http-sentinel")` |
| `programs/zig_ai_server` | same; used in `iap.zig`, `stream.zig`, `search.zig`, `gcp.zig` |
| `programs/qai_chat` | `build.zig.zon` dependency |
| `programs/quantum_curl` | `build.zig.zon` dependency (wrapper program) |
| `programs/zig_ai` | `build.zig.zon` dependency |

Because five programs pin this contract, treat changes to the `src/lib.zig`
export set — and to any re-exported type such as `ai.common.RequestConfig` or
`ai.common.escapeJsonString` — as **breaking**: update the consumers in
lockstep, or don't change the symbol.
