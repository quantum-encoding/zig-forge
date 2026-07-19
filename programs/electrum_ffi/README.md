# electrum_ffi

A C-ABI static library of Electrum wallet-protocol **helpers** — scripthash computation, JSON-RPC 2.0 request framing, and response parsing — with **no networking**: the calling layer owns sockets and TLS.

It is consumed by `quantum_vault` (the Tauri crypto-wallet), whose Rust core (`src-tauri/src/core/electrum.rs`) hand-declares the matching `extern "C"` block and drives the actual ElectrumX transport.

## What it does (and doesn't)

- **Does:** compute Electrum scripthashes (`reverse(SHA256(script))`) for P2WPKH / P2PKH / arbitrary scripts; build newline-delimited JSON-RPC request frames for the seven wallet methods (`get_balance`, `listunspent`, `get_history`, `transaction.broadcast`, `transaction.get`, `headers.subscribe`, `server.version`); parse the corresponding responses into fixed C structs.
- **Does not:** open sockets, do TLS, or perform any I/O. It also has **no SPV** logic — SPV lives in `simd_crypto_ffi`. (The top-level README previously mis-credited this library with "Bitcoin SPV"; corrected.)

## Design contract

JSON is emitted only through `std.json.Stringify` on anonymous structs (never printf-style concatenation), so a method name or string param containing `"` cannot inject sibling JSON-RPC keys (ELE-1). Responses are parsed structurally through `std.json` with per-field type/range validation — the `broadcast` / `transaction.get` / `headers.subscribe` parsers reject JSON-RPC error objects **before** reading `result`, and `broadcast` requires a 64-char lowercase-hex txid, so a string-typed error result can never be reported as a successful broadcast (F2).

## API

The C surface is committed at [`include/electrum_ffi.h`](include/electrum_ffi.h) — the single source of truth for exported symbols and the `CUtxo` / `CBalance` / `CTxHistoryEntry` layouts. Per `zig-forge/CLAUDE.md`'s lockstep rule, any change there must be mirrored in `quantum_vault`'s extern block.

Request builders and the length-returning parsers return a non-negative byte length on success or a negative `ElectrumResult` code; fixed-output functions return `ELECTRUM_SUCCESS` (0). Callers supply fixed-length output buffers (20-byte pubkey hash in, 64-byte hex scripthash/txid out, 32-byte decoded scripthash) — these lengths are contracts, not parameters.

## Build & test

```sh
zig build            # -> zig-out/lib/libelectrum_ffi.a + zig-out/include/electrum_ffi.h
zig build test       # core + FFI unit tests (both suites)
zig build android    # aarch64-linux-android cross-build
```

> macOS/Xcode consumers: after rebuilding the static lib, repack it via `zig-forge/scripts/repack-for-xcode.sh` so the Mach-O members are 8-byte aligned for Apple's `ld-prime` (Zig 0.16 emits 2-byte alignment).

## Test anchors

Externally anchored (not roundtrip-only): the scripthash core is pinned to the NIST FIPS 180-4 SHA-256 `"abc"` KAT (byte-reversed) and to Python-`hashlib`-derived P2WPKH/P2PKH known answers; the response parsers are anchored to real, publicly recorded Bitcoin/ElectrumX values (the first-ever Bitcoin txid, the genesis coinbase raw transaction, and an ElectrumX-documented `headers.subscribe` response at height 520481).
