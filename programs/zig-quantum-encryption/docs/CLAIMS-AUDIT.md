# Claims audit — README statements vs. the code

Every substantive statement in `README.md` and `docs/README.md` checked against
the source it describes. Verdicts: **true**, **false**, **imprecise** (true in
spirit, wrong in a detail a reviewer or a porting engineer would trip on),
**unverified** (no evidence in the repo either way).

Line numbers refer to the files as they were when this audit was taken; the
"Fixed" column says whether the statement was corrected in the same change set.

## README.md

| # | Claim (README.md line) | Verdict | Evidence | Fixed |
|---|---|---|---|---|
| 1 | "Both primitives are validated byte-for-byte against the NIST CAVP / ACVP known-answer-test vectors" (L5) | **imprecise** | True for what is covered, but the ML-DSA coverage is narrower than the sentence implies. `src/ml_dsa_tier1_anchors.zig:10-15`: keyGen (tcId 26) and sigGen from `ML-DSA-sigGen-FIPS204/internalProjection.json` **tgId 10 = deterministic / internal / externalMu=false** (tcId 136). That is FIPS 204 `ML-DSA.Sign_internal` with `rnd = 0`, i.e. `μ = H(tr ‖ M)` with **no** context-string framing. The external interface `ML-DSA.Sign(sk, M, ctx)` (μ over `0x00 ‖ len(ctx) ‖ ctx ‖ M`), HashML-DSA, and randomized signing are not covered by any KAT. `src/ml_dsa.zig:901-906` and `:1168-1173` confirm the internal framing. | yes (README states the exact mode) |
| 2 | "Quantum Vault uses ML-KEM-768 as the default" with a table of ML-KEM-512/768/1024 (L20-26) | **imprecise** | `src/ml_kem.zig:77-103` defines all three parameter sets, but the public API (`src/ml_kem_api.zig:104,230,302`) and the C ABI expose ML-KEM-768 **only**. There is no "default" to switch. | yes |
| 3 | Architecture diagram shows AES-256-GCM and an ML-DSA + Ed25519 hybrid signature (L30-55) | **imprecise** | Neither AES-256-GCM nor Ed25519 is implemented in this library (`src/` has no symmetric cipher). The diagram describes the Quantum Vault application; the signature half is labelled "future" but the AES half is not. | yes (labelled as application-level) |
| 4 | `build.zig` exposes no Zig package module; consumers link `quantum_crypto` and call the C ABI (L59-62) | **true** | `build.zig:50` (`quantum_crypto`), `:70` (`quantum_crypto_shared`), `:133` (`quantum_crypto_<target>`). | — |
| 5 | `keyGen768` / `encaps768` / `decaps768` signatures and sizes (L66-93) | **true** | `src/ml_kem_api.zig:104,230,302`; sizes at `:27,38,66`. | — |
| 6 | `zig build -Dtarget=aarch64-macos` is "iOS ARM64" (L121-122) | **false** | `aarch64-macos` is macOS. The iOS slice is `aarch64-ios` (`build.zig:23`, built by `zig build cross`). | yes |
| 7 | "Phase 1: Seed Encryption (Current)" code sample: `crypto.kdf.hkdf.Sha256.expand(&combined, ml_result.K ++ x25519_ss, "quantum-vault-hybrid-kem")` (L128-169) | **false** | This is not the shipped combiner and does not compile against the shipped API. The real v1 combiner is `src/hybrid.zig:149-163`: `SHA3-256("HYBRID-ML-KEM-768-X25519-v1" ‖ K_mlkem ‖ K_x25519)` — no HKDF, no HKDF-SHA256, different label. The sample also uses the panicking `crypto.random.bytes` the library deliberately avoids (`src/rng.zig:43`). | yes (replaced with the real API and the v1/v2 definitions) |
| 8 | `src/hybrid.zig` module doc: "Shared Secret: 32 bytes (HKDF-SHA3-256 output)" (`src/hybrid.zig:10`) | **false** | `combineSecrets` is a single SHA3-256 hash (`src/hybrid.zig:149-163`). HKDF-SHA3-256 arrives with the v2 combiner in this change set; v1 stays plain SHA3-256 so existing ciphertexts still decapsulate. | yes |
| 9 | `src/hybrid.zig:116` comment: `K = SHA3-256(mlkem_ss ‖ x25519_ss ‖ "HYBRID-ML-KEM-768-X25519")` | **false** | The label is a **prefix**, not a suffix, and is `"HYBRID-ML-KEM-768-X25519-v1"` (`src/hybrid.zig:153-158`). A port written from the comment would not interoperate. | yes |
| 10 | Hybrid combiner binds only the two shared secrets (implicit; L128-169) | **true, and a known weakness** | `src/hybrid.zig:149-163` hashes `K_mlkem ‖ K_x25519` only. X-Wing (draft-connolly-cfrg-xwing-kem-10 §5.3) also binds `ct_X` (the X25519 ephemeral public key) and `pk_X` (the recipient's X25519 public key). Addressed by the v2 combiner (`docs/HYBRID-V2.md`). | yes (v2 added; v1 kept for existing data) |
| 11 | ML-DSA-65: "deterministic and randomized `sign`, `verify`, and `keyGen`, byte-exact against the NIST ACVP KATs" (L173-176) | **imprecise** | Deterministic sign and keyGen are byte-exact against the KATs (claim 1). Randomized signing cannot be byte-checked against a KAT by construction; it is round-trip tested only (`src/ml_dsa.zig` tests, `src/quantum_vault_ffi.zig:706-719`). | yes |
| 12 | Performance table "on typical mobile hardware (ARM Cortex-A78)" with ~0.15/0.18/0.20 ms (L183-191) | **unverified** | `bench.zig` exists (`zig build bench`) but the repo carries no recorded A78 run and no figure that can be traced to a commit. | yes (presented as an unmeasured order of magnitude; `zig build bench` is the source of truth) |
| 13 | "Heap: None (stack-only implementation)" (L195) | **true** | No allocator is taken anywhere in `src/ml_kem_api.zig`, `src/ml_kem.zig`, `src/ml_dsa.zig`, `src/hybrid.zig` (grep for `alloc` finds nothing). | — |
| 14 | "All secret-dependent operations use constant-time algorithms … No secret-dependent branches / No secret-dependent memory access patterns" (L199-210) | **imprecise** | ML-KEM decapsulation does use `constantTimeCompare` / `constantTimeSelect` for implicit rejection (`src/ml_kem_api.zig:339-344,601-616`). But ML-DSA signing contains the rejection loops FIPS 204 mandates (secret-dependent by design), and nothing in the repo (no ctgrind/dudect/valgrind run) backs the blanket "no secret-dependent branches" statement. | yes (states what is done and what is not verified) |
| 15 | Decapsulation failure probabilities 2^-138.8 / 2^-164.8 / 2^-174.8 (L214-218) | **true** | Matches FIPS 203 Table 2 (δ for the three parameter sets). Only ML-KEM-768 is exposed here. | — |
| 16 | Implicit rejection returns a pseudorandom value derived from `z` (L222) | **true** | `src/ml_kem_api.zig:326-344` (`K̄ = J(z ‖ c)`, constant-time select). | — |
| 17 | KAT section: which files carry which vectors (L244-250) | **true, incomplete** | Files and algorithms match. Missing the ACVP mode qualifier for ML-DSA (claim 1). | yes |
| 18 | "MIT License - See LICENSE file" (L265) | **false** | There is no `LICENSE` file in `programs/zig-quantum-encryption/` nor at the zig-forge root. `quantum-vault-sys/Cargo.toml:6` and `docs/README.md:274` say "MIT OR Apache-2.0" — the two READMEs disagree with each other. Not fixed here: choosing a licence text is the owner's call. | **no** (flagged) |

## docs/README.md

| # | Claim (docs/README.md line) | Verdict | Evidence | Fixed |
|---|---|---|---|---|
| 19 | Key-size table (L15-21) | **true** | `src/quantum_vault_ffi.zig:22-37`; the hybrid rows are `src/hybrid.zig:26-28`. | — |
| 20 | Project structure lists `src/ml_dsa_v2.zig` (L30) | **false** | The file is `src/ml_dsa.zig` (`build.zig:281`). `ml_dsa_v2.zig` does not exist and never did in this tree. The listing also omits `ml_kem.zig`, `nist_vectors.zig`, both `*_tier1_anchors.zig` files and `tools/secrets.zig`. | yes |
| 21 | `lib/` is "Pre-built libraries" (L44) | **imprecise** | The directory is **not tracked in git**: `.gitignore:65` (`*.a`) and `:69` (`*.lib`) cover it, and `git ls-files quantum-vault-sys/` lists no libs. A fresh clone has no `lib/`; `build.rs:37-60` falls back to `../zig-out/lib`. The libs that exist on a developer machine are a local drop-in and were stale (see claim 24). | yes |
| 22 | Output libraries after `zig build install cross`: `libquantum_vault.a`, `libquantum_vault_shared.dylib`, `libquantum_vault_<target>.a` (L76-91) | **false** | Artifacts are named `libquantum_crypto.a`, `libquantum_crypto_shared.dylib`, `libquantum_crypto_<target>.a`, plus the legacy ML-KEM-only `libquantum-crypto-pqc.a` (`build.zig:50,70,88,133`). `build.rs:19-26` still looks for `quantum_vault_<target>` inside `lib/`, so the rename is invisible only as long as someone renames files by hand. | yes (docs; `build.rs` now accepts both names) |
| 23 | Rust usage: `MlKemKeyPair::generate()`, `kp.ek.encaps()`, `kp.dk.decaps(&ct)`, `kp.sk.sign(msg)`, `kp.pk.verify(msg, &sig)`, `HybridKeyPair::generate()` (L105-146) | **true** | `src/mlkem.rs:31,73`, `src/mldsa.rs:76,30,112-118`, `src/hybrid.rs:101-118`. Field names `ek/dk/pk/sk` are public. | — |
| 24 | (implicit in 21) the bundled libs correspond to the source | **false** | Every lib under a developer's `lib/` reports `qv_version() == "quantum-vault-pqc-1.0.0"` and dates from 2026-02-04, which predates the FIPS-204-final keyGen fix (`src/ml_dsa.zig:721-731`, commit `ffca8179`/`9aea2cd6` era). Baton work item 01D6021B proved it: ρ from the macOS lib equals `SHAKE256(ξ)[0..32]`, the draft expansion. Sizes of 2.3-4.3 MB per archive also indicate Debug builds, not ReleaseSafe. | yes (rebuilt; version bumped to 1.1.0; `build.rs` refuses a lib whose embedded version string does not match the source) |
| 25 | "All private keys are automatically zeroed when dropped" (L197) | **true** | `impl Drop` with `qv_secure_zero` for `MlKemDecapsKey` (`src/mlkem.rs:83-89`), `MlDsaSecretKey` (`src/mldsa.rs:103-109`), `HybridDecapsKey` (`src/hybrid.rs:92-98`). Shared secrets are `SecureBytes` (zeroize on drop). | — |
| 26 | RNG backends: arc4random_buf / getrandom / BCryptGenRandom (L207-213) | **true** | `src/rng.zig:93-102,105-127,151-175`. WASM defers to a host-supplied `crypto.getRandomValues` (`src/rng.zig:47,84`) — not mentioned in the doc. | yes (WASM row added) |
| 27 | C API reference and error-code table (L215-270) | **true** | Matches `include/quantum_vault.h`, which is byte-identical to `quantum-vault-sys/include/quantum_vault.h`. | — (extended with the v2 entry points) |
| 28 | Licence "MIT OR Apache-2.0" (L274) | **imprecise** | Consistent with `Cargo.toml:6`, inconsistent with `README.md:265`, and no licence text exists in the tree (claim 18). | **no** (flagged) |

## What the audit did not cover

- `docs/TAURI_INTEGRATION.md` — application-integration sample; it calls the
  public Rust API correctly and makes no cryptographic claims of its own.
- `tools/secrets.zig` / `tools/SECRETS_README.md` — the secrets CLI is a
  separate tool built from this tree; out of scope for the library's claims.
- `worker/` (Cloudflare Worker + WASM glue) — calls the same C ABI; it will
  need `qv_hybrid_encaps_v2` / `qv_hybrid_decaps_v2` wrappers if it wants v2,
  nothing there is wrong today.
