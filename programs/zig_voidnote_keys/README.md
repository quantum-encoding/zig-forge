# zig_voidnote_keys

A `wasm32-freestanding` FFI module that generates VoidNote API keys and computes/verifies HMAC-SHA256, built for Cloudflare Workers. SHA-256 and HMAC-SHA256 come from `std.crypto` (audited, pure Zig, constant-time) — there is no hand-rolled crypto in this module.

## What it does

Three cryptographic operations, exported as WASM functions over a fixed result buffer (no allocator):

- `generate_api_key()` → writes `"vn_"` + 64 lowercase hex chars (32 random bytes) to the result buffer, returns `67`.
- `hmac_sha256(secret, message)` → writes 64 lowercase hex chars of `HMAC-SHA256(secret, message)`, returns `64` (or `0` on out-of-bounds input).
- `hmac_sha256_verify(secret, message, expected_hex)` → constant-time compare, returns `1` (valid) or `0` (invalid); wipes the result buffer afterward so no MAC oracle remains.

Supporting exports: `get_result_ptr()`, `get_result_len()`, `get_error_code()`, and `clear_result_buf()`.

## Randomness

On the shipped `wasm32-freestanding` target, random bytes come from the JS host import `env.js_get_random_bytes(ptr, len)`, which the host must back with `crypto.getRandomValues`. On the native (test-only) target the extern import is comptime-eliminated and a `std.Random` CSPRNG is used instead, so the module can be compiled and exercised without a JS host — that native path is never present in the shipped wasm binary.

## Result-buffer lifecycle

The result buffer is a global inside the WASM instance. After reading a sensitive result (a freshly generated API key in particular), the JS host **must** call `clear_result_buf()` — otherwise the bytes persist in linear memory and are recoverable by a later caller sharing the same instance. See the LIFECYCLE CONTRACT comment at the top of `src/wasm_ffi.zig`.

## Build

```sh
# WASM module for Cloudflare Workers → zig-out/wasm/
zig build wasm

# Tier-1 external-anchor crypto tests (native target)
zig build test
```

## Tests

`src/tier1_anchors.zig` pins the module's output to externally-anchored vectors:

- **SHA-256** — NIST FIPS 180-2 / CAVP known-answer vectors (empty string, `"abc"`, and the 448-bit and 896-bit multi-block messages).
- **HMAC-SHA256** — all seven RFC 4231 §4 test cases, driven through the exported `hmac_sha256` entry point (not `std.crypto` directly), so they validate the actual FFI path a webhook verifier calls.

Plus FFI behaviour tests for the verify path, result-buffer hygiene, and input-bounds rejection. Per the repository's golden rule #1, weakening `tier1_anchors.zig` requires a re-audit, not a refactor.
