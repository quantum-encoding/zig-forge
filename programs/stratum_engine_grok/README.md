# stratum_engine_grok

A Linux-only Stratum V1 mining client: it connects to a mining pool over TCP
(using `io_uring` for the socket I/O), speaks the JSON-RPC Stratum handshake
(`mining.subscribe` / `mining.authorize`), parses incoming `mining.notify` jobs,
and dispatches them to a pool of CPU worker threads that grind SHA-256d nonces
with a vectorized (`@Vector`) inner loop.

## Status

This is a prototype, not a production miner. Notable limitations in the current
source:

- **Linux-only.** The client is built on `std.os.linux.IoUring`, so the
  executable only builds and runs on Linux. On other platforms `zig build`
  (which compiles the executable) will fail; the test step is platform-independent
  and runs anywhere (see below).
- The worker's coinbase assembly uses placeholder `extranonce` strings and the
  main loop does not submit found shares back to the pool, so it does not mine
  real, creditable shares as-is.
- `calculateTarget` is a simplified `nbits` → target decode.

No benchmark numbers are claimed here because none have been measured in-tree.

## Layout

- `src/main.zig` — entry point: arg parsing, connect, subscribe/authorize,
  receive loop, job dispatch.
- `src/stratum/` — `protocol.zig` (JSON-RPC message parser with explicit arena
  ownership), `client.zig` (`io_uring` TCP client), `types.zig` (job types).
- `src/miner/` — `dispatcher.zig` (per-core worker fan-out), `simd_worker.zig`
  (vectorized nonce-grinding loop).
- `src/crypto/` — `sha256d.zig`, `sha256_simd.zig`, `merkle.zig`.
- `src/metrics/stats.zig` — hashrate/uptime counters.
- `src/protocol_test.zig` — external-vector tests for the message parser.

## Build & test

```sh
zig build          # builds the executable (Linux only)
zig build test     # runs the protocol parser tests (any platform)
```

The test step is rooted at `src/protocol_test.zig` rather than the executable so
that `zig build test` does not pull in the Linux-only `io_uring` code. Those
tests exercise the parser's arena-ownership contract against real Stratum V1
wire lines (the canonical slush-pool `mining.notify` example, plus a standard
subscribe response and a `mining.submit` request) — external anchors, not
round-trips of the project's own encoder.

## Usage

```sh
stratum-engine-grok <host> <port> <username> <password>
```
