# zig-forge — instructions for AI coding agents

Rules only. The reasons, the incidents behind each rule, wave results and mutation-test
evidence live in `docs/CLAUDE-audit-history.md`. Read that when a rule looks arbitrary.

## Promoting an in-tree library (all four, before any money/key/auth consumer uses it)

1. **External anchors.** Tests whose inputs AND expected outputs come from something the
   author did not write: spec vectors, a third-party service, another implementation's
   goldens. Roundtrip tests (`decode(encode(x)) == x`) do not count; delete them all and every
   public function must still be covered. **Mutation-test each anchor**: break the thing it
   guards, see red, revert, see green, record it. A hash of your own output is a *drift lock*,
   not an anchor; label it so.
2. **The name says the direction.** `zig_X` implements X both ways or is renamed
   (`zig_X_reader`, `zig_X_writer`, `zig_X_to_Y`).
3. **`build.zig` exposes what the name implies** (`addModule`/`addLibrary`) plus a
   `zig build test` target. An executable-only build is not a library.
4. **README first sentence agrees with the source** on verb, direction and scope. Check this
   first; it is the cheapest.

To promote: run the audit against all four, add a row to the table below, add a
`// for X, use zig_Y` line to each consuming project's CLAUDE.md.

## Promoted libraries

| Library | Scope (promoted for exactly this) | Anchor |
|---|---|---|
| `programs/zig_base58` | Base58 / Base58Check (BTC, Tron, Doge, LTC, Ripple, IPFS) | Bitcoin Core `base58_encode_decode.json`, real addresses |
| `programs/zig_csv2json` | One-way CSV/TSV/KV → JSON CLI | RFC 8259 §6, RFC 4180 examples |
| `programs/zig_msgpack` | MessagePack encode + decode, DoS-hardened | Spec opcode vectors, 50k-deep payload |
| `programs/zig_toml` | TOML 1.0.0 parser, read-only | toml-test corpus, spec examples |
| `programs/zig-quantum-encryption/src/ml_dsa.zig` | **ML-DSA-65 only** (not 44/87) | NIST ACVP FIPS 204 KATs, byte-exact |
| `programs/zig-quantum-encryption/src/ml_kem_api.zig` | **ML-KEM-768 only** (not 512/1024) | NIST ACVP FIPS 203 KATs, byte-exact |
| `programs/zig_docx` | **DOCX read + write only**; its XLSX/PDF/RAG surfaces are NOT promoted, and `xlsx.zig` deliberately does not neutralise CSV formula injection (consumer's job, see `src/xlsx.zig:95`) | LibreOffice-authored `.docx` with CPython-derived CRCs/text, APPNOTE + ECMA-376 assertions, tampered negatives, mutation-tested |
| `programs/zig_jwt` | RFC 7519 HMAC sign + verify (HS256/384/512), constant-time compare, `alg:none` refused | RFC 7515 A.1, jwt.io goldens, independent `std.crypto` signer, negatives |
| `programs/zig_darwin_kit` | ObjC block ABI (`Block`), mach time, `AuditToken`, runtime macOS version, `malloc`-owned out-params, NUL-termination | libdispatch copies/invokes the blocks; libbsm `audit_token_to_*`; kernel `CLOCK_UPTIME_RAW`; `getpid`/`uname`; mutation-tested |
| `programs/zig_endpoint_sec` | EndpointSecurity client: `sys` bindings for the macOS 27 SDK (133 structs, 162 event types), `Client`/`Message`/`Event`/`Exec`, version-gated fields, weak imports for post-10.15 APIs | Apple clang `sizeof`/`offsetof`/enumerator table generated from the SDK (`tools/gen_layout_anchors.py`), version gates from the header comments, live `es_new_client` refusal; mutation-tested |

Everything not in this table is unaudited. In new code: never hand-roll Base58, RLP, bech32 or
any binary-serialisation parser for money-touching paths; use a vetted dependency on the Rust
side or wait for the audit. Mark existing hand-rolled parsers `// TODO(audit): migrate to <canonical>`
instead of extending them.

## Anti-patterns: grep for these before reading a file in detail

`zig-lens --strict programs/<dir>/` catches 1–4. 5–7 are human-review only.

1. **JSON-IN-FMT** — `allocPrint`/`bufPrint` with `{{"key":"{s}"}}`. Unescaped input breaks or
   forges JSON. Use `std.json.Stringify` (`valueAlloc`, or streaming for heterogeneous arrays);
   delete per-file `escapeJson` helpers.
   `grep -nE 'allocPrint|bufPrint'` and inspect for `{{"`, `\":`, `,\"`.
2. **SHELL-CHILD** — `Child` with `/bin/sh -c <built string>`. Use argv-mode `Child.init`; tools
   surfaced to LLMs take `argv: string[]`, never a string; pipes/redirects in native Zig.
   `grep -nE 'process\.Child|"/bin/sh|"sh".*"-c"'`.
3. **EQL-FOR-SECRETS** — `std.mem.eql` on a signature, HMAC, nonce, token or password. Length-check,
   then `std.crypto.timing_safe.eql` on fixed-size arrays. Enum-like strings are fine; suppress
   false positives with `// zig-lens-ignore: EQL-FOR-SECRETS <reason>`.
   `grep -n 'std\.mem\.eql.*u8'`.
4. **TLS verification off** — `MBEDTLS_SSL_VERIFY_NONE`, `SSL_VERIFY_NONE`, `InsecureSkipVerify`,
   rustls `dangerous()`. The scanner sees only the mbedTLS form; grep the rest.
5. **Hand-rolled binary parsers in money paths** — external vectors before promotion; otherwise
   quarantine with the TODO above.
6. **Wall-clock in security checks** — `std.time.timestamp()` for expiry/replay. Inject a `Clock`;
   monotonic for elapsed time; wall-clock only to emit timestamps; bound attacker-supplied
   `issued_at` by server-side skew.
   `grep -nE 'std\.time\.(timestamp|nanoTimestamp)'`.
7. **Hand-rolled libc struct layouts** — local `extern struct Stat` + `extern "c" fn lstat`. On
   x86_64 macOS the unsuffixed symbols are the legacy 32-bit-inode ABI: sizes and inodes read
   garbage, silently, only on Intel. Use `std.c.fstatat` + `std.c.Stat`; one normalised struct per
   tree (`zdedupe/src/pstat.zig`); `dev` as `u64` `(major << 32) | minor`.
   `grep -nE 'extern "c" fn (l?stat|fstat)|extern struct Stat'`.

## Zig 0.16 gotchas agents keep rediscovering

- `std.time.Instant` / `std.time.Timer` do not exist; `std/time.zig` is constants. Use
  `std.c.clock_gettime(.MONOTONIC, &ts)` behind an injected `Clock`
  (`zig_ratelimit/src/compat.zig`, `zig_watch/src/watcher.zig`).
- `std.crypto.random.bytes` → `std.c.arc4random_buf` / `getrandom`; `std.time.sleep` → `std.c.nanosleep`.
- `std.c.stat` does not compile on arm64 macOS; route `stat` and `lstat` through `fstatat`.
- `std.testing.tmpDir` roots under `.zig-cache/tmp` inside the tree, and the chronos tick hook
  runs `git add .`, so hostile fixtures get committed. Use `$TMPDIR` and assert the path is outside
  the repo (`zdedupe/src/testing_scratch.zig`).
- Zig 0.16 emits 2-byte-aligned Mach-O members; ld-prime needs 8. After rebuilding any lib
  consumed by Xcode, run `scripts/repack-for-xcode.sh <lib.a …>`.
- `@cImport` of `EndpointSecurity/EndpointSecurity.h` fails on the macOS 27 SDK (Zig's clang
  rejects a nullability attribute in `xpc/xpc.h`); bind by hand and anchor with
  `zig_endpoint_sec/tools/gen_layout_anchors.py`. `@Type` reification and `std.once` are gone.
- Apple APIs taking `^` blocks (`es_new_client`, libdispatch, XPC) need a real `Block_literal`:
  use `zig_darwin_kit.Block`. A bare `fn` pointer is dereferenced as a block header and
  crashes or misbehaves.

## Gate

Repo-wide `zig-lens --strict programs/` still carries 5 known gating findings in fleet-owned
files (`chronos_engine/chronos-run.zig`, `guardian_shield/guardian-shield-v9/build.zig`,
`terminal_mux` ctl/zterm). Per-program `--strict` must be clean for anything you touch, and
your program must never add a sixth.
