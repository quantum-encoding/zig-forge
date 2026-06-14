# chronos_ledger

`chronos_ledger` **builds and verifies** a tamper-evident accountability log of
AI-agent actions: it canonicalises each event (RFC 8785), folds it into a rolling
SHA-256 hash chain, and signs the chain head with ML-DSA-65 (FIPS 204) on
milestones — and verifies all three in reverse. It is the security plane of the
Chronos system (the squashable git ticks are the other, human-facing plane); see
[`DESIGN.md`](DESIGN.md) for the full architecture and threat model.

This is **Step 1** of that design: the shared library that the in-agent
emit-client, the privileged sink, and the proxy verifier all reuse.

## What it does (both directions)

- **Produce** — `Chain.append(content, milestone)` injects `v`/`seq`/`prev`,
  computes `this = SHA-256(canonical(event))`, and on a milestone signs `this`
  with ML-DSA-65. Returns the canonical shipped event JSON.
- **Verify** — `verifyEvent(pk, json)` recomputes the head from the canonical
  body and checks it against the claimed `this` (**chain_ok**), then ML-DSA
  verifies the signature over `this` (**sig_ok**). An event is trustworthy only
  when `chain_ok AND sig_ok`.

## Guardrails (by construction)

1. **RFC 8785 canonicalization** (`canonical.zig`) — object keys sorted by UTF-16
   code units (astral chars by leading surrogate), JCS string escaping, raw UTF-8
   for non-ASCII. No float variant exists: the schema is float-free and carries
   all large magnitudes/timestamps as decimal *strings*, so the chain hash is
   identical across Zig, Go and Swift and exact above 2^53. Anchored against the
   RFC's own property-sorting test vector.
2. **Stable C-ABI** (`c_api.zig` + `include/chronos_ledger.h`) — `cl_*` functions
   using `std.heap.c_allocator`; the Zig core takes a `std.mem.Allocator`. Floats
   and >i64 integers are rejected at the JSON boundary.
3. **Non-blocking IPC** (`emit_client.zig`) — `cl_emit` does a single
   `socket`+`sendto(MSG_DONTWAIT)`+`close` to an AF_UNIX datagram socket; if the
   sink is down or its buffer is full it fails fast (`WouldBlock`/`SinkUnavailable`)
   and never stalls the agent. A dropped event surfaces as a `seq` gap.

The signing key lives only in a sink-side chain (`initSigning`), never in the
audited agent's client-side chain (`init`) — see Addition 1 in `DESIGN.md`.

## Build & test

```sh
zig build test     # canonical + ledger + C-ABI suites (external RFC 8785 anchor)
zig build          # → zig-out/lib/libchronos_ledger.a + zig-out/include/chronos_ledger.h
```

> macOS consumers (Swift/Xcode): repack the static lib with
> `../../scripts/repack-for-xcode.sh zig-out/lib/libchronos_ledger.a` — Zig 0.16
> emits 2-byte-aligned Mach-O members and Apple's ld-prime needs 8-byte.

## Status

Step 1 complete and tested (23/23). Next: the emit-client integration in
`chronos-hook` and the privileged reference `ledger-daemon` that ships to the
proxy (`POST /v1/ledger`).
