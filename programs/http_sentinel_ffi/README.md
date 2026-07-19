# http_sentinel_ffi

A blocking C-ABI HTTP/HTTPS client for FFI hosts (Rust, C, Swift): it wraps Zig's `std.http.Client`, copies the response body into a caller-owned buffer, and opens one connection per call.

Builds to a static library, `libhttp_sentinel.a`, plus a C header at `include/http_sentinel.h`.

> **Naming note:** despite the name, this does **not** wrap the sibling `programs/http_sentinel` (the multi-provider pure-Zig HTTP client library). It is an independent, minimal client built directly on `std.http`.

## What it does

- Verbs: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`.
- Caller owns every buffer. The library returns nothing the caller must free.
- Automatic `gzip` / `deflate` response decompression.
- Up to 64 request headers, passed as an array of pointer+length pairs.
- Thread-safe: each call constructs its own IO context and client, sharing no state. The last-error message is thread-local.
- TLS certificate verification is always on (system CA bundle). There is no switch to disable it.

## What it does not do

- **No connection reuse.** Every call pays a fresh TCP and TLS handshake — deliberate (it is what makes calls independent and thread-safe), but it is the dominant latency cost for a hot path. A persistent-handle API is the natural next addition.
- **No redirects, no cookies, no chunked request bodies.** Request bodies are sent with `Content-Length`.
- **No streaming.** The response body must fit the caller's buffer, or it is truncated and flagged.
- `zstd` / `compress` content-encodings are rejected with an error rather than returned as raw bytes.

## Contract

The authoritative contract is `include/http_sentinel.h`; `src/ffi.zig` is the implementation. Key points:

| Topic | Behavior |
|---|---|
| Return code | `0` on a completed exchange; negative `HTTP_SENTINEL_*` on failure. |
| Non-2xx status | **Not** a failure. Returns `0`; the status is in `HttpResponse.status_code`. |
| Truncation | If the body exceeds `response_body_size`, the first `response_body_size` bytes are written and `truncated` is set. For compressed responses this reflects the *decompressed* size. |
| Corrupt gzip | Hard failure (`HTTP_SENTINEL_REQUEST_FAILED`). A partial body is **never** returned with a success code. |
| Null pointers | A null `url`, `response`, or header `name`/`value` returns `HTTP_SENTINEL_INVALID_INPUT`. |
| Header limit | `header_count > 64` returns `HTTP_SENTINEL_INVALID_INPUT` — headers are never silently dropped. |
| Error message | `http_sentinel_get_error` fills a caller buffer with the thread-local message; cleared at the start of every request, so it is never stale. Passing a null buffer returns the required length. |

### Timeouts

Every request is bounded by a total (connect + send + receive) deadline, **30000 ms by default**. Expiry returns `HTTP_SENTINEL_TIMEOUT` (`-6`).

```sh
HTTP_SENTINEL_TIMEOUT_MS=5000   # 5s deadline
HTTP_SENTINEL_TIMEOUT_MS=0      # disable the deadline (pure blocking)
```

## Usage

```c
#include "http_sentinel.h"

HttpHeader headers[] = {
    { (const uint8_t *)"Authorization", 13, (const uint8_t *)token, token_len },
    { (const uint8_t *)"Content-Type",  12, (const uint8_t *)"application/json", 16 },
};

uint8_t body[1 << 20];
HttpResponse resp;

int rc = http_sentinel_post((const uint8_t *)"https://api.example.com/v2/orders",
                            headers, 2,
                            (const uint8_t *)payload, payload_len,
                            body, sizeof(body), &resp);
if (rc != HTTP_SENTINEL_SUCCESS) {
    uint8_t err[256];
    http_sentinel_get_error(err, sizeof(err));   /* same thread as the call */
    fprintf(stderr, "request failed (%d): %s\n", rc, (const char *)err);
} else if (resp.truncated) {
    /* body holds only the first sizeof(body) bytes — do not parse it as JSON */
}
```

## Build

```sh
zig build                 # zig-out/lib/libhttp_sentinel.a
zig build android         # zig-out/lib/android-arm64/libhttp_sentinel.a (aarch64-linux-android)
zig build test            # Zig unit tests + the C-side ABI smoke test
zig build abi-smoke       # ABI smoke test only
```

`tests/abi_smoke.c` includes `http_sentinel.h` via the `-Iinclude` that `build.zig` passes. To build it by hand, supply the same flag:

```sh
cc -std=c11 -Wall -Wextra -Werror -I include/ tests/abi_smoke.c \
   zig-out/lib/libhttp_sentinel.a -o /tmp/abi_smoke && /tmp/abi_smoke
```

`compile_flags.txt` carries the same include path for clangd, so editors resolve the header without a compilation database.

On macOS, repack the archive before linking it into an Xcode/Cargo build — Zig 0.16 emits 2-byte-aligned Mach-O members and Apple's linker requires 8-byte:

```sh
../../scripts/repack-for-xcode.sh zig-out/lib/libhttp_sentinel.a
```

## Tests

`zig build test` runs offline and deterministically. Coverage:

- **External gzip vector** — a real RFC 1952 stream produced by CPython's `gzip` module (an independent implementation), decoded to its exact known plaintext. Also covers bounded output, a truncated stream (must fail hard), and non-gzip garbage.
- **Loopback HTTP server** — an in-process TCP server on an OS-assigned port serves canned responses: gzip body decoded end-to-end through the FFI, an oversized body (asserts `truncated` and exact `body_len`), a 404 with header echo (asserts the caller's headers reached the wire verbatim), and a non-responsive server (asserts the timeout fires).
- **ABI anchors** — struct layouts and error-code values are asserted against the hand-written mirrors in `include/http_sentinel.h` and quantum_vault's `#[repr(C)]` declarations, from both the Zig and the C side.
- **Input validation** — null header pointers and over-limit header counts.

Two live-network smoke tests against httpbin are opt-in: `HTTP_SENTINEL_LIVE_TESTS=1 zig build test`.

## Consumers

`quantum_vault` (Tauri/Rust) links this library:

- `src-tauri/src/core/http_sentinel.rs` — hand-written `extern` block and `#[repr(C)]` mirrors of `HttpResponse` / `HttpHeader`.
- `src-tauri/src/trading/hft_service.rs` — routes Alpaca orders through `AlpacaFastClient`, which is built on these bindings. **Money-touching.**
- `src-tauri/build.rs` — links `zig-out/lib/libhttp_sentinel.a` from this directory.

**Any change to an exported symbol name, a signature, or the `HttpResponse` / `HttpHeader` layout is an FFI break.** Update `include/http_sentinel.h` and `quantum_vault/src-tauri/src/core/http_sentinel.rs` in the same change, and rebuild + repack the archive before the consumer relinks.
