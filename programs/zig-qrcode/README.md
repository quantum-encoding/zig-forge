# zig-qrcode

ZigQR is a one-way QR code **generator** (an ISO/IEC 18004 encoder, versions 1–40) — it encodes data into QR symbols and does not decode them.

It implements numeric / alphanumeric / byte modes, error-correction levels L/M/Q/H, Reed-Solomon
error correction over GF(256), multi-block interleaving, all 8 mask patterns with penalty-based
selection, and three renderers (raw RGB, path-merged SVG, uncompressed PNG). It ships as a
C-ABI static/dynamic library, a WASM module, a CLI, and an in-tree Rust `-sys` crate.

## Direction and naming

This library is **encode-only**. Per `zig-forge/CLAUDE.md` rule 2 the directory name reads
bidirectional, but the C header, this README, and the `zigqr_*` symbol prefix all describe a
generator. There is no decoder in this tree; verification against external decoders (zbar, segno)
is done in the test/audit process, not at runtime.

## Build

```sh
zig build                 # static lib (zigqr), shared lib (zigqr_shared), CLI (zigqr)
zig build test            # unit + external-anchor tests (see below)
zig build cross           # 7 cross targets (macOS arm64/x86_64, Windows, Linux, iOS, Android)
zig build wasm            # wasm32-freestanding ReleaseSmall module
zig build gen-header      # regenerate include/zigqr.h from src/ffi.zig
```

## CLI

```sh
zigqr encode "https://example.com" -o qr.png
zigqr encode "Hello World" --svg -o qr.svg
zigqr encode "data" --ec H --size 8 -o qr.png
```

## FFI memory contract

All output buffers are allocated by the library and must be freed by the caller with
`zigqr_free(ptr, len)` using the exact length the call reported (`size * size` for
`zigqr_encode`, the `output_len`/`size` out-param for the renderers). `zigqr_get_error()`
returns a pointer to a static, NUL-terminated error string; it is process-global (not
thread-local), but the GF(256) tables and encode path are otherwise thread-safe.

Any change to the exported symbol names, signatures, out-params, the RGB 8-byte header layout,
or free semantics is FFI-breaking and must be updated in lockstep across `src/ffi.zig`,
`include/zigqr.h`, and `zigqr-sys/src/bindings.rs`.

## Correctness / promotion status

This library is **not** on the `zig-forge/CLAUDE.md` canonical promoted list. It handles
payment URIs (there is a `bitcoin:` test), so it is money-adjacent and held to the golden rule.

Externally-anchored tests (inputs and expected outputs from the standard, not this
implementation) live in `src/qrcode.zig`:

- The ISO/IEC 18004 worked example ("01234567", version 1, EC level M): the full 26-codeword
  output — 16 data codewords (`10 20 0C 56 61 80 EC 11 …`) plus the 10 Reed-Solomon EC
  codewords (`A5 24 D4 C1 ED 36 C7 87 2C 55`).
- All 32 format-information bit strings from ISO/IEC 18004 Table C.1.
- The Adler-32 "Wikipedia" known-answer test in `src/png.zig`.

Generated symbols are additionally verified end-to-end by decoding them with an external
decoder (zbar) during audit. These anchors caught two ship-blocking bugs that pure round-trip
tests missed (a reversed Reed-Solomon generator polynomial and a broken format-information
BCH/EC-level mapping) — both made every produced symbol undecodable.
