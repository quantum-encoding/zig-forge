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
| `programs/zig-quantum-encryption/src/ml_dsa.zig` | **ML-DSA-65 ONLY** (FIPS 204 post-quantum signatures): keyGen + sign + verify, deterministic. Single-parameter-set — NOT polymorphic over ML-DSA-44/87. | 2026-05 | NIST CAVP / ACVP FIPS 204 ML-DSA-65 KATs (`src/ml_dsa_tier1_anchors.zig`): keyGen (seed→pk,sk), sigGen (sk,msg→sig, deterministic/internal), verify — all byte-exact |
| `programs/zig-quantum-encryption/src/ml_kem_api.zig` | **ML-KEM-768 ONLY** (FIPS 203 post-quantum KEM): keyGen + encaps + decaps, deterministic internals. Single-parameter-set — NOT polymorphic over ML-KEM-512/1024. | 2026-05 | NIST CAVP / ACVP FIPS 203 ML-KEM-768 KATs (`src/ml_kem_tier1_anchors.zig`): keyGen (d,z→ek,dk), encaps (ek,m→c,K), decaps (dk,c→K) — all byte-exact |
| `programs/zig_jwt` | JSON Web Token (RFC 7519) HMAC sign **and** verify: HS256/384/512, registered-claim validation (`exp`/`nbf`/`iss`/`aud`/`sub`) with injectable clock. Signature compare is constant-time; `alg:none` refused on both sign and verify. Consumed by `zig_token_service`. | 2026-07 | RFC 7515 Appendix A.1 HS256 example (spec JWK octet key + published signature) + jwt.io HS256/384/512 cross-impl goldens + an independent `std.crypto` signer (`mintHS256`) so the verifier is checked against signatures the library did not construct + `alg:none`/tampered-segment/bad-base64url negative vectors (`src/tier1_anchors.zig`) |

> **Scope note:** the two post-quantum entries above are promoted **only** for their stated parameter sets (ML-DSA-65, ML-KEM-768) — the exact sets the FFI / `quantum_vault` consumers use. The implementations are monolithic single-set (parameters are module constants; vector types are comptime-sized). They are **not** generic over the other security levels (44/87, 512/1024), which remain unimplemented and unvalidated. Do not assume they cover other parameter sets.

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

## High-signal anti-patterns to grep for proactively

The campaign that ran from `4f3e4fe` through `db9b685` (zig_ai_server C1-C5, http_sentinel, stratum_engine_claude, financial_engine/order_sender, mempool_sniffer, simd_crypto_ffi, plus the four canonical library audits, plus the zig_lens scanner build-out and the JSON-IN-FMT / SHELL-CHILD / EQL-FOR-SECRETS / MBEDTLS-VERIFY-NONE purges across 30+ files in batches 19-26) repeatedly hit the same six structural classes. When auditing a new module, search for these *before* reading the code in detail — each one paid out multiple times.

Each class names the symptom, the root cause, and the corrective shape that the codebase has now standardized on. The scanner (`programs/zig_lens`) currently catches the first four classes; the last two are human-review-only.

### 1. JSON injection via printf-style format strings — JSON-IN-FMT

Symptom: `std.fmt.allocPrint` / `bufPrint` with a format string containing `{{"key":"{s}"}}` shape. Caller-controlled string substituted unescaped — the moment the value contains `"` or `\`, the JSON breaks (denial of service) or claims a new field (privilege escalation, billing fraud).

Where it bit us: C5 in zig_ai_server (WAL / ledger / Firestore / BigQuery), `images.zig`, `oidc.zig`, `stratum_engine_claude` proxy/server share-accept/reject and exchange OrderTemplate.buildJson, `zig_jwt` Builder.sign header + payload (paired with a real timing attack), `zigix_chat` chat-body forwarding (substring-extracted `messages` array re-interpolated into Claude API request), `financial_engine` Alpaca order placement, `stratum_engine_grok` authorize/submitShare.

Corrective shape: `std.json.Stringify.valueAlloc(allocator, anonymous_struct, .{})` for small payloads; `std.json.Stringify` against `std.Io.Writer.fixed(buf)` (stack buffer) or `std.Io.Writer.Allocating` (heap) for streaming / conditional / heterogeneous shapes. Heterogeneous JSON arrays (e.g. Stratum `params: ["user", "job_id", "ntime", ...]`) require streaming (`beginArray` / `write` / `endArray`) — anonymous tuples are tuples, not arrays, when passed to `write`. Append the trailing `\n` after `Stringify.write` finishes if the wire format requires JSONL or SSE `data: <json>\n\n` framing.

Pre-existing escape helpers (`escapeJsonString`, `escapeJsonResponse`, `escapeJson`, hand-rolled `escapeJson` per file) should be deleted — Stringify handles all the cases (`"`, `\`, control chars, UTF-8) and is already audited.

### 2. Shell-out RCE — SHELL-CHILD

Symptom: `std.process.Child` invoked with `argv = .{"/bin/sh", "-c", cmd}` or `bash -c`, where `cmd` is built via `allocPrint("…{s}…")` from any caller-influenced input.

Where it bit us: `vertex.zig` runTokenCommand, `quantum_curl/engine/auth_refresher.zig` CommandSource, `qai_chat` bash tool (renamed to `exec` with `argv: string[]`), `zig_ai/execute_command.zig` (now declares `extern "c" fn execvp` since `std.c` only exposes execve), `zig_ai/trash_file.zig` macOS trash invocation.

Corrective shape: argv-mode `std.process.Child.init(argv, allocator)` with the argv pre-split by whitespace (or, better, structured as a `[]const []const u8`). For tools surfaced to LLMs, accept `argv: string[]` from the model — not a string. Never pass a shell. If the command genuinely needs pipes / redirects, write the orchestration in native Zig (e.g. dup2 onto fd 2 for `2>/dev/null`). The previous attempt at a "bash blocklist" (denylist) was already replaced with a structured exec allowlist (`9d3ebb2`).

### 3. Non-constant-time comparison on auth-context values — EQL-FOR-SECRETS

Symptom: `std.mem.eql(u8, expected, claim)` where one side is a signature, HMAC, OAuth nonce, session token, password, or any value an attacker can iterate one byte at a time. Byte-by-byte short-circuit comparison leaks length and byte-position via timing.

Where it bit us: `zig_jwt` Builder.sign signature compare (paired with H-1 in batch 22), `zig_ai_server/oidc.zig` nonce SHA-256 verification.

Corrective shape: `std.crypto.timing_safe.eql([N]u8, expected_arr.*, claim_arr.*)` where both sides are fixed-size arrays. Length-check first; refuse on mismatch (the length check is fine to short-circuit — it's the byte-level compare that leaks). For HMAC / signature buffers, allocate `[Hmac.mac_length]u8` arrays on the stack and `@memcpy` into them. For SHA-256 hex digests, length-check `== 64` then coerce to `*const [64]u8`.

Distinguish from harmless string-equality on enum-like values (algorithm names, role strings, MIME types). The scanner can't always tell — it relies on the enclosing function's name/params tokenizing into one of: signature, hmac, password, secret, nonce, apikey, or a recognized two-token pair (api/key, session/token, auth/token, bearer/token, csrf/token, access/token, refresh/token, verify/token, id/token). False positives are suppressed with `// zig-lens-ignore: EQL-FOR-SECRETS <reason>` and a documented reason.

### 4. TLS verification disabled — MBEDTLS-VERIFY-NONE (and equivalents)

Symptom: any source line referencing `MBEDTLS_SSL_VERIFY_NONE`. Also: OpenSSL `SSL_VERIFY_NONE`, Go `tls.Config{InsecureSkipVerify: true}`, Rust rustls `dangerous().set_certificate_verifier`, custom callbacks that always return success.

The scanner only catches the literal mbedTLS form — the other equivalents are not scanned and must be human-reviewed. Listed here so an audit knows to grep for the full class, not just the one form CI catches.

Corrective shape: cert verification on by default; certs pinned where possible; production never reads from an env-var that flips verification off. The `stratum_engine_claude` TLS cert verification fix (`4cf6cc2`) is the reference implementation.

### 5. Hand-rolled binary parsers in money-touching code

Symptom: parseTransaction / parseBlock / parseRLP / parseBase58 with bespoke byte arithmetic. The defects look like off-by-one but cascade into wrong addresses, wrong txids, wrong amounts.

Where it bit us: `mempool_sniffer/bitcoin_protocol` parseTransaction (H-1..H-4 in `777cf85`), `simd_crypto_ffi/spv` compact-target endianness + CVE-2012-2459 binding (`ffb069c`), `zig_base58` SHA-256d checksum bug that shipped for two months because every test was a roundtrip.

Corrective shape: external test vectors before promotion (golden rule §1 above). For now, only the four libraries listed in the canonical list are cleared for money-touching consumers; everything else either uses a vetted external dependency on the Rust side or carries a `// TODO(audit): migrate to <canonical>` and is treated as quarantined.

### 6. Wall-clock time in security checks

Symptom: `std.time.timestamp()` or `std.time.nanoTimestamp()` used to validate token expiry, issue timestamps, replay windows, or anything an attacker can move by adjusting the system clock (NTP poisoning, container clock drift, intentional time-travel).

Where it bit us: `zig_ai_server` C3 fake-clock (`1c78542`), `http_sentinel` HSEN-A livelock + deprecated time API (`c97c957`).

Corrective shape: a single injected `Clock` interface that test code can override; production uses `std.time.Instant.now()` (monotonic) for elapsed-time math and `std.time.timestamp()` only for emitting wire timestamps to consumers who already trust the server clock. Never compare a wall-clock value against an attacker-controlled "issued_at" field without a server-side allowed-skew bound.

### How to use this list

When opening an unfamiliar file:

1. `grep -nE 'allocPrint|bufPrint' <file>` and inspect every format string for `{{"`, `\":`, `,\"` — JSON-IN-FMT.
2. `grep -nE 'process\.Child|Child\.init|"/bin/sh|"sh".*"-c"' <file>` — SHELL-CHILD.
3. `grep -n 'std\.mem\.eql.*u8' <file>` then check whether the enclosing function name or its params name a secret — EQL-FOR-SECRETS.
4. `grep -nE 'VERIFY_NONE|InsecureSkipVerify|dangerous\(\)\.set_certificate_verifier' <file>` — disabled TLS.
5. `grep -nE 'std\.time\.(timestamp|nanoTimestamp)' <file>` and audit every callsite for "is this a security check?" — wall-clock-in-security.
6. For binary parsers: check for external test vectors before reading the code in depth.

`zig-lens --strict programs/<dir>/` catches classes 1-4 by default. The whole repo currently exits 0 under `--strict` — keep it that way.
