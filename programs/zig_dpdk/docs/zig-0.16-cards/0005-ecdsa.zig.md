# ECDSA Migration Card

## 1) Concept
This file provides a complete implementation of the Elliptic Curve Digital Signature Algorithm (ECDSA) in Zig's standard `crypto` library, supporting NIST P-256, P-384, and Secp256k1 curves paired with SHA-256, SHA3-256/384, SHA-384, and Bitcoin-style double-SHA256 hashes. Pre-defined public types like `EcdsaP256Sha256` and `EcdsaSecp256k1Sha256oSha256` are exported for common use cases, alongside a generic `Ecdsa(comptime Curve: type, comptime Hash: type)` function that returns a struct encapsulating the full scheme.

Key components include:
- `SecretKey` and `PublicKey`: Encoding/decoding (raw bytes, SEC1 compressed/uncompressed).
- `Signature`: Raw bytes/DER encoding/decoding, direct/incremental verification via `Verifier`.
- `KeyPair`: Generation (random or deterministic), signing via direct `sign`/`signPrehashed` or incremental `Signer`.
The API emphasizes fixed-size buffers, optional randomness (`noise`) for non-deterministic signatures (defending against fault attacks), and strict error handling for invalid keys/signatures. Comprehensive tests validate against Project Wycheproof vectors for edge cases like DER malleability.

## 2) The 0.11 vs 0.16 Diff
This file introduces a generic, comptime-parameterized ECDSA API absent or less mature in Zig 0.11 `std.crypto`, where ECC/DSA was more fragmented (e.g., separate `ecc`/`dsa` modules without unified schemes). Public signatures emphasize incremental I/O via stateful `Signer`/`Verifier` structs (dependency injection pattern: `KeyPair.signer(noise)` → `update(data)` → `finalize()`), replacing any 0.11 direct functions.

| Category | 0.11 Pattern (Inferred) | 0.16 Changes |
|----------|--------------------------|--------------|
| **Allocator** | No allocators historically; fixed arrays common. | No change: Allocator-free (all fixed `[N]u8` or `[]const u8` slices with pre-sized buffers, e.g., `Signature.toDer(buf: *[der_encoded_length_max]u8) []u8`). |
| **I/O Interfaces** | Likely direct hash/verification without incremental state. | New incremental DI: `Signer.init(secret_key, noise?)`, `update(data: []const u8)`, `finalize()`; `Signature.verifier(public_key)` → `Verifier` with `update`/`verify`. DER uses `std.Io.Writer/Reader` internally. |
| **Error Handling** | Generic `error{...}` or crypto-specific. | Specific unions: `VerifyError = Verifier.InitError || Verifier.VerifyError` (e.g., `IdentityElementError`, `NonCanonicalError`, `SignatureVerificationError!void`). No generics; `!Signature` for invalid encodings. |
| **API Structure** | Possible `init`/`deinit`; raw bytes only. | `KeyPair.generate()` (random retries on invalid), `generateDeterministic(seed)`; `PublicKey.fromSec1(slice)` (no "open"); `Signature.fromDer(der)`, `toDer(out_buf)` returns slice. Noise optional for determinism. Raw `fromBytes/toBytes`. |

No breaking changes to allocators (none used); new incremental APIs and DER support require migration from direct 0.11 calls.

## 3) The Golden Snippet
```zig
const std = @import("std");
const crypto = std.crypto;
const Scheme = crypto.sign.ecdsa.EcdsaP256Sha256;

const kp = Scheme.KeyPair.generate();
var noise: [Scheme.noise_length]u8 = undefined;
crypto.random.bytes(&noise);
const sig = try kp.sign("test", noise);
try sig.verify("test", kp.public_key);
```

## 4) Dependencies
- `std.crypto` (heavy: `ecc.P256/P384/Secp256k1`, `hash.sha2.Sha256/Sha384`, `hash.sha3.Sha3_256/384`, `hash.composition.Sha256oSha256`, `auth.hmac.Hmac`, `errors.*`)
- `std.mem` (heavy: `trimLeft`, `zeroInit`, `@memcpy`)
- `std.fmt` (light: hex parsing in tests)
- `std.Io` (medium: `Writer.fixed`, `Reader.fixed` for DER)
- `std.testing`, `builtin` (tests only)