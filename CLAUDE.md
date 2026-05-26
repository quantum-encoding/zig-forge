# zig-forge — instructions for AI coding agents

## The Golden Rule for in-tree libraries

When an in-tree library is being considered as a shared dependency for code that handles money, keys, auth, or any user-facing correctness contract, **all four of these must be true before it can be promoted**. The audit gates the standardization; the standardization does not authorize the audit.

### 1. Externally-anchored test vectors exist

The library has tests whose inputs **and** expected outputs both come from sources the library author did not write. Acceptable sources:

- Published spec test vectors (BIP fixtures, RFC 4180 examples, JSONTestSuite, NIST CAVP, etc.)
- An authoritative third-party service (a block explorer for a real-world address, a known-good API response shape, etc.)
- A different implementation's golden file (rust-bitcoin, serde_json, the reference Python implementation, etc.)

**Roundtrip-only tests do not count.** A test of the form `decode(encode(x)) == x` proves internal self-consistency only. If you delete every roundtrip test, the remaining tests must still cover encode and decode (or read and write) for every public function the library exposes.

This rule comes from the `zig_base58` audit: 15/15 tests passed against an implementation that emitted Bitcoin addresses with a wrong checksum (single SHA-256 instead of SHA-256d). Every test was a roundtrip; none compared against an external Bitcoin address.

### 2. The library's name unambiguously describes what it does in both directions

A library named `zig_X` must implement `X` in both directions or be renamed.

- `zig_base58` — must encode AND decode Base58. ✓
- `zig_json` — must read AND write JSON. ✗ (in-tree implementation only writes; was renamed `zig_csv2json`)
- `zig_msgpack` — must encode AND decode MessagePack
- `zig_toml` — must parse AND emit TOML
- `zig_pdf_generator` — explicit one-way name. ✓

If a library is one-way only, name it for the actual transformation:

- `zig_csv2json` (one-way: CSV/TSV/KV in → JSON out)
- `zig_X_reader` / `zig_X_writer`
- `zig_X_to_Y`

This rule comes from the `zig_json` audit: the directory name implied a JSON parser, the README said "text-to-JSON formatter," the build.zig didn't expose a library module, and the standardization plan wasted reviewer cycles assuming the wallet could use it for TronGrid response parsing. It could not.

### 3. `build.zig` exposes the library surface the name implies

If the library is meant to be consumed by other in-tree projects, `build.zig` must expose it via `b.addModule(...)` or `b.addLibrary(...)`. A `build.zig` that only declares an executable target is **not a library**, regardless of what the directory is named.

For each promoted library, the build must produce:
- A consumable module/artifact (`addModule`, `addLibrary` with `.static` or `.dynamic`)
- A test target that runs the tier-1/2/3 tests under `zig build test`

If the library is for CLI use only, that's fine — but the name must reflect it (see rule 2) and CLAUDE.md should not list it as a "library."

### 4. The README's first sentence agrees with the audit's reading of the source

Open the README. Read the first sentence. Look at the directory's source code. They must agree on:

- What the library does (the verb: encode, decode, parse, format, sign, verify, etc.)
- The direction (one-way or bidirectional)
- The scope (single algorithm, multi-algorithm, framework)

If the README's first sentence and the source code disagree, fix one before promoting.

This rule would have caught `zig_json`'s naming gap in 30 seconds, before any audit work started. It is the cheapest of the four checks. Apply it first.

## How to add a new library to the canonical list

1. Run the audit. Produce a writeup that explicitly addresses all four checks above. If any fails, fix it before listing.
2. Add the library to `CANONICAL_LIBRARIES` below (one line per library: name, purpose, where to use it).
3. Update the per-project `CLAUDE.md` for any project that should use it, with a `// for X, use zig_Y` line.

## Currently audited & promoted libraries

| Library | Purpose | Audit date | External anchor |
|---|---|---|---|
| `programs/zig_base58` | Base58 / Base58Check for Bitcoin, Tron, Doge, LTC, Ripple, IPFS | 2025-05 | Bitcoin Core `base58_encode_decode.json` + Satoshi address + Tron USDT TRC20 contract |
| `programs/zig_csv2json` | One-way text-to-JSON CLI (CSV/TSV/KV/lines → JSON) | 2025-05 | RFC 8259 §6 number grammar + RFC 4180 examples + roundtrip via `std.json` |
| `programs/zig_msgpack` | MessagePack encoder + decoder, hardened against deep-nesting DoS, length-overflow attacks, and non-canonical float encoding | 2025-05 | MessagePack spec opcode byte vectors (`tier1_anchors.zig`) + iterative-skip DoS guard verified against 50k-deep payload |
| `programs/zig_toml` | Full TOML 1.0.0 parser (dotted keys, array-of-tables, datetimes, hex/oct/bin/inf/nan, all escapes incl. `\UXXXXXXXX`), hardened against duplicate keys, nesting DoS, inline-table extension, reserved escapes; read-only (no emitter) | 2025-05 | toml-test corpus + TOML spec worked examples + Cargo.toml-shaped end-to-end smoke (`tier1_anchors.zig`) |

## Pending audits

_(none currently — all four originally-listed libraries audited and promoted.)_

## Hand-rolled parsers in non-canonical code

Until a library is on the promoted list above, agents working in this tree:

- **MUST NOT** hand-roll a Base58, Base58Check, RLP, bech32, or other binary-serialization parser in any new code. For money-touching code, use a vetted external dependency (e.g. `bs58`, `alloy_rlp`, `rust-bitcoin`) on the Rust side, or wait for the in-tree audit.
- **MUST** flag existing hand-rolled parsers with `// TODO(audit): migrate to <canonical>` rather than "extending" them.
- **MUST** assume tree-internal code is unaudited unless this file says otherwise.

## Why this file exists

This file was created after two consecutive audits found ship-blocking bugs that an external-vector test would have caught immediately:

- `zig_base58` shipped two months with single-SHA256 Base58Check, producing Bitcoin/Tron addresses every external system rejects. 15/15 tests passed because all 15 were self-consistent roundtrips.
- `zig_json` was treated as an in-tree JSON parser by a standardization plan; the actual library only wrote JSON, had no `addModule`, and had unrelated grammar bugs (leading zeros emitting invalid JSON).

The pattern in both cases: internal self-consistency masked external incompatibility. The four-point rule above is the cheapest possible enforcement against that pattern.
