//! Hybrid Key Encapsulation: ML-KEM-768 + X25519
//!
//! Combines post-quantum ML-KEM-768 with classical X25519 for defense-in-depth.
//! Security holds as long as at least one algorithm remains secure.
//!
//! Key sizes (identical for both combiner versions):
//!   - Hybrid Public Key:  1216 bytes = ML-KEM-768 ek (1184) ‖ X25519 pk (32)
//!   - Hybrid Secret Key:  2432 bytes = ML-KEM-768 dk (2400) ‖ X25519 sk (32)
//!   - Hybrid Ciphertext:  1120 bytes = ML-KEM-768 ct (1088) ‖ X25519 ephemeral pk (32)
//!   - Shared Secret:      32 bytes
//!
//! Two shared-secret combiners exist. The wire layout does not encode which one
//! produced a ciphertext; the caller selects the version explicitly (see
//! `docs/HYBRID-V2.md` for the trade-off and the full byte-level definition).
//!
//!   v1  K = SHA3-256("HYBRID-ML-KEM-768-X25519-v1" ‖ ss_M ‖ ss_X)
//!       Binds only the two shared secrets. Kept so data already produced with
//!       it still decapsulates. Not recommended for new data.
//!
//!   v2  K = HKDF-SHA3-256(salt = "", IKM = ss_M ‖ ss_X ‖ ct_X ‖ pk_X,
//!                         info = "HYBRID-ML-KEM-768-X25519-v2", L = 32)
//!       HKDF per RFC 5869 with HMAC-SHA3-256 (block size 136). The IKM is the
//!       X-Wing combiner input, in X-Wing's order (draft-connolly-cfrg-xwing-kem-10
//!       §5.3: ss_M, ss_X, ct_X, pk_X), so the X25519 ephemeral public key and the
//!       recipient's X25519 public key are bound into the secret. X-Wing does not
//!       mix in the ML-KEM ciphertext or encapsulation key, and neither does v2.
//!       Recommended for all new data.
//!
//! Notation follows X-Wing: ss_M / ss_X are the ML-KEM / X25519 shared secrets,
//! ct_X is the X25519 ephemeral public key carried in the ciphertext, pk_X is the
//! recipient's X25519 public key carried in the encapsulation key.

const std = @import("std");
const crypto = std.crypto;
const mlkem = @import("ml_kem_api.zig");

// X25519 types
const X25519 = crypto.dh.X25519;

// HKDF-SHA3-256: RFC 5869 instantiated with HMAC over SHA3-256.
const HmacSha3_256 = crypto.auth.hmac.Hmac(crypto.hash.sha3.Sha3_256);
const HkdfSha3_256 = crypto.kdf.hkdf.Hkdf(HmacSha3_256);

// Sizes
pub const MLKEM_EK_SIZE = 1184;
pub const MLKEM_DK_SIZE = 2400;
pub const MLKEM_CT_SIZE = 1088;
pub const X25519_KEY_SIZE = 32;
pub const SHARED_SECRET_SIZE = 32;

pub const HYBRID_EK_SIZE = MLKEM_EK_SIZE + X25519_KEY_SIZE; // 1216
pub const HYBRID_DK_SIZE = MLKEM_DK_SIZE + X25519_KEY_SIZE; // 2432
pub const HYBRID_CT_SIZE = MLKEM_CT_SIZE + X25519_KEY_SIZE; // 1120

/// Domain-separation label of the v1 combiner (a SHA3-256 prefix).
pub const V1_LABEL = "HYBRID-ML-KEM-768-X25519-v1";

/// HKDF `info` string of the v2 combiner.
pub const V2_INFO = "HYBRID-ML-KEM-768-X25519-v2";

/// Combiner version. The ciphertext carries no version byte; the two versions
/// share one wire layout and the caller must know which one produced a given
/// ciphertext.
pub const Version = enum {
    v1,
    v2,

    /// The version new data should use.
    pub const default: Version = .v2;
};

/// Hybrid encapsulation key (public key)
pub const HybridEncapsulationKey = [HYBRID_EK_SIZE]u8;

/// Hybrid decapsulation key (private key)
pub const HybridDecapsulationKey = [HYBRID_DK_SIZE]u8;

/// Hybrid ciphertext
pub const HybridCiphertext = [HYBRID_CT_SIZE]u8;

/// Shared secret (32 bytes)
pub const SharedSecret = [SHARED_SECRET_SIZE]u8;

/// Hybrid key pair
pub const HybridKeyPair = struct {
    ek: HybridEncapsulationKey,
    dk: HybridDecapsulationKey,
};

/// Hybrid encapsulation result
pub const HybridEncapsResult = struct {
    K: SharedSecret,
    ct: HybridCiphertext,
};

/// Error types
pub const HybridError = error{
    KeyGenFailed,
    EncapsFailed,
    DecapsFailed,
    InvalidPublicKey,
};

// Cross-platform secure RNG
const rng = @import("rng.zig");

/// Zero a stack value holding key material. `std.crypto.secureZero` writes
/// through a volatile slice so the optimiser cannot elide the stores.
inline fn scrub(ptr: anytype) void {
    crypto.secureZero(u8, std.mem.asBytes(ptr));
}

// ============================================================================
// Key generation
// ============================================================================

/// Generate a hybrid key pair from fresh system randomness.
pub fn keyGen() HybridError!HybridKeyPair {
    var d: [32]u8 = undefined;
    var z: [32]u8 = undefined;
    var x25519_sk: [X25519_KEY_SIZE]u8 = undefined;
    defer scrub(&d);
    defer scrub(&z);
    defer scrub(&x25519_sk);

    rng.fillSecureRandomSafe(&d) catch return HybridError.KeyGenFailed;
    rng.fillSecureRandomSafe(&z) catch return HybridError.KeyGenFailed;
    rng.fillSecureRandomSafe(&x25519_sk) catch return HybridError.KeyGenFailed;

    return keyGenDeterministic(&d, &z, &x25519_sk);
}

/// Deterministic key generation from explicit seeds.
///
/// `d`, `z` feed FIPS 203 `ML-KEM.KeyGen_internal`; `x25519_sk` is stored in the
/// decapsulation key exactly as given (RFC 7748 clamping happens inside every
/// scalar multiplication, not at storage time). Exposed for known-answer tests
/// and cross-implementation vectors; production callers use `keyGen`.
pub fn keyGenDeterministic(
    d: *const [32]u8,
    z: *const [32]u8,
    x25519_sk: *const [X25519_KEY_SIZE]u8,
) HybridError!HybridKeyPair {
    var result: HybridKeyPair = undefined;

    const mlkem_kp = mlkem.keyGenInternal768(d, z) catch return HybridError.KeyGenFailed;
    const x25519_pk = X25519.recoverPublicKey(x25519_sk.*) catch return HybridError.KeyGenFailed;

    // Encapsulation key: [ML-KEM ek (1184)] ‖ [X25519 pk (32)]
    @memcpy(result.ek[0..MLKEM_EK_SIZE], &mlkem_kp.ek.data);
    @memcpy(result.ek[MLKEM_EK_SIZE..], &x25519_pk);

    // Decapsulation key: [ML-KEM dk (2400)] ‖ [X25519 sk (32)]
    @memcpy(result.dk[0..MLKEM_DK_SIZE], &mlkem_kp.dk.data);
    @memcpy(result.dk[MLKEM_DK_SIZE..], x25519_sk);

    return result;
}

// ============================================================================
// Encapsulation
// ============================================================================

/// Encapsulate with the v1 combiner. Kept for callers that must produce data an
/// existing v1 decapsulator will accept; new data should use `encapsV2`.
pub fn encaps(ek: *const HybridEncapsulationKey) HybridError!HybridEncapsResult {
    return encapsVersioned(ek, .v1);
}

/// Encapsulate with the v2 (HKDF-SHA3-256, X-Wing-bound) combiner.
pub fn encapsV2(ek: *const HybridEncapsulationKey) HybridError!HybridEncapsResult {
    return encapsVersioned(ek, .v2);
}

/// Encapsulate with an explicit combiner version, using fresh randomness for
/// the ML-KEM message `m` and the X25519 ephemeral scalar.
pub fn encapsVersioned(ek: *const HybridEncapsulationKey, version: Version) HybridError!HybridEncapsResult {
    var m: [32]u8 = undefined;
    var eph_sk: [X25519_KEY_SIZE]u8 = undefined;
    defer scrub(&m);
    defer scrub(&eph_sk);

    rng.fillSecureRandomSafe(&m) catch return HybridError.EncapsFailed;
    rng.fillSecureRandomSafe(&eph_sk) catch return HybridError.EncapsFailed;

    return encapsDeterministic(ek, version, &m, &eph_sk);
}

/// Deterministic encapsulation from an explicit ML-KEM message `m` and X25519
/// ephemeral scalar. Exposed for known-answer tests and cross-implementation
/// vectors; production callers use `encaps` / `encapsV2` / `encapsVersioned`.
pub fn encapsDeterministic(
    ek: *const HybridEncapsulationKey,
    version: Version,
    m: *const [32]u8,
    eph_sk: *const [X25519_KEY_SIZE]u8,
) HybridError!HybridEncapsResult {
    var result: HybridEncapsResult = undefined;

    // Component public keys
    const pk_x: *const [X25519_KEY_SIZE]u8 = ek[MLKEM_EK_SIZE..][0..X25519_KEY_SIZE];

    var mlkem_ek: mlkem.EncapsulationKey768 = undefined;
    @memcpy(&mlkem_ek.data, ek[0..MLKEM_EK_SIZE]);

    // ML-KEM-768 encapsulation (FIPS 203 §7.2 input check, then Encaps_internal)
    if (!mlkem.validateEncapsulationKey768(&mlkem_ek)) return HybridError.InvalidPublicKey;
    var mlkem_result = mlkem.encapsInternal768(&mlkem_ek, m) catch return HybridError.EncapsFailed;
    defer scrub(&mlkem_result.K);

    // X25519 (RFC 7748) with the ephemeral scalar
    const ct_x = X25519.recoverPublicKey(eph_sk.*) catch return HybridError.EncapsFailed;
    var ss_x = X25519.scalarmult(eph_sk.*, pk_x.*) catch return HybridError.InvalidPublicKey;
    defer scrub(&ss_x);

    // Ciphertext: [ML-KEM ct (1088)] ‖ [X25519 ephemeral pk (32)]
    @memcpy(result.ct[0..MLKEM_CT_SIZE], &mlkem_result.c.data);
    @memcpy(result.ct[MLKEM_CT_SIZE..], &ct_x);

    result.K = switch (version) {
        .v1 => combineSecretsV1(&mlkem_result.K, &ss_x),
        .v2 => combineSecretsV2(&mlkem_result.K, &ss_x, &ct_x, pk_x),
    };

    return result;
}

// ============================================================================
// Decapsulation
// ============================================================================

/// Decapsulate a ciphertext produced by `encaps` (v1 combiner).
pub fn decaps(dk: *const HybridDecapsulationKey, ct: *const HybridCiphertext) SharedSecret {
    return decapsVersioned(dk, ct, .v1);
}

/// Decapsulate a ciphertext produced by `encapsV2` (v2 combiner).
pub fn decapsV2(dk: *const HybridDecapsulationKey, ct: *const HybridCiphertext) SharedSecret {
    return decapsVersioned(dk, ct, .v2);
}

/// Decapsulate with an explicit combiner version.
///
/// Never fails: ML-KEM implicit rejection yields a pseudorandom secret for a
/// tampered ML-KEM ciphertext, and a low-order X25519 point yields the all-zero
/// RFC 7748 output, which is fed to the combiner as-is (the same value a
/// non-checking X25519 implementation would compute).
pub fn decapsVersioned(dk: *const HybridDecapsulationKey, ct: *const HybridCiphertext, version: Version) SharedSecret {
    const x25519_sk: *const [X25519_KEY_SIZE]u8 = dk[MLKEM_DK_SIZE..][0..X25519_KEY_SIZE];
    const ct_x: *const [X25519_KEY_SIZE]u8 = ct[MLKEM_CT_SIZE..][0..X25519_KEY_SIZE];

    var mlkem_dk: mlkem.DecapsulationKey768 = undefined;
    @memcpy(&mlkem_dk.data, dk[0..MLKEM_DK_SIZE]);
    defer scrub(&mlkem_dk);

    var mlkem_ct: mlkem.Ciphertext768 = undefined;
    @memcpy(&mlkem_ct.data, ct[0..MLKEM_CT_SIZE]);

    var ss_m = mlkem.decaps768(&mlkem_dk, &mlkem_ct);
    defer scrub(&ss_m);

    var ss_x: [X25519_KEY_SIZE]u8 = X25519.scalarmult(x25519_sk.*, ct_x.*) catch [_]u8{0} ** X25519_KEY_SIZE;
    defer scrub(&ss_x);

    switch (version) {
        .v1 => return combineSecretsV1(&ss_m, &ss_x),
        .v2 => {
            // The decapsulation key stores only the X25519 scalar (the layout
            // predates v2), so the recipient public key the combiner binds is
            // recomputed here. A clamped scalar cannot produce the identity.
            const pk_x = X25519.recoverPublicKey(x25519_sk.*) catch [_]u8{0} ** X25519_KEY_SIZE;
            return combineSecretsV2(&ss_m, &ss_x, ct_x, &pk_x);
        },
    }
}

// ============================================================================
// Combiners
// ============================================================================

/// v1 combiner: `SHA3-256(V1_LABEL ‖ ss_M ‖ ss_X)`.
pub fn combineSecretsV1(ss_m: *const [32]u8, ss_x: *const [32]u8) SharedSecret {
    var hasher = crypto.hash.sha3.Sha3_256.init(.{});
    hasher.update(V1_LABEL);
    hasher.update(ss_m);
    hasher.update(ss_x);

    var result: SharedSecret = undefined;
    hasher.final(&result);
    return result;
}

/// v2 combiner: `HKDF-SHA3-256(salt = "", IKM = ss_M ‖ ss_X ‖ ct_X ‖ pk_X, info = V2_INFO, L = 32)`.
///
/// An empty salt is, per RFC 5869 §2.2, a string of HashLen (32) zero bytes;
/// HMAC zero-pads its key, so both spellings produce the same PRK.
pub fn combineSecretsV2(
    ss_m: *const [32]u8,
    ss_x: *const [32]u8,
    ct_x: *const [X25519_KEY_SIZE]u8,
    pk_x: *const [X25519_KEY_SIZE]u8,
) SharedSecret {
    var ikm: [128]u8 = undefined;
    @memcpy(ikm[0..32], ss_m);
    @memcpy(ikm[32..64], ss_x);
    @memcpy(ikm[64..96], ct_x);
    @memcpy(ikm[96..128], pk_x);
    defer scrub(&ikm);

    var prk = HkdfSha3_256.extract("", &ikm);
    defer scrub(&prk);

    var result: SharedSecret = undefined;
    HkdfSha3_256.expand(&result, V2_INFO, prk);
    return result;
}

// ============================================================================
// C-ABI boundary
// ============================================================================
//
// This module deliberately exposes NO `export fn`. `quantum_vault_ffi.zig` is
// the single source of truth for the C-ABI surface — it wraps the `pub fn`
// hybrid primitives above as `qv_hybrid_*` (v1) and `qv_hybrid_*_v2` with the
// unified `QvError` codes, panic seal, and comptime layout guards.

// ============================================================================
// Known-answer inputs (shared with tools/hybrid_vectors.zig)
// ============================================================================

/// Fixed combiner inputs. Expected outputs were computed independently with
/// Python's hashlib.sha3_256 / hmac (see docs/HYBRID-V2.md), not with this code.
pub const kat_ss_m = hexToArray(32, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
pub const kat_ss_x = hexToArray(32, "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
pub const kat_ct_x = hexToArray(32, "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f");
pub const kat_pk_x = hexToArray(32, "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f");

/// Fixed seeds for the full-path vector (keyGen -> encaps -> decaps).
pub const kat_seed_d = [_]u8{0xa1} ** 32;
pub const kat_seed_z = [_]u8{0xa2} ** 32;
pub const kat_seed_x25519_sk = [_]u8{0xa3} ** 32;
pub const kat_seed_m = [_]u8{0xa4} ** 32;
pub const kat_seed_eph_sk = [_]u8{0xa5} ** 32;

pub fn hexToArray(comptime n: usize, hex: *const [2 * n]u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "hybrid key generation" {
    const kp = try keyGen();

    try testing.expectEqual(@as(usize, HYBRID_EK_SIZE), kp.ek.len);
    try testing.expectEqual(@as(usize, HYBRID_DK_SIZE), kp.dk.len);
}

test "hybrid v1 encaps/decaps round trip" {
    const kp = try keyGen();
    const enc_result = try encaps(&kp.ek);
    const dec_ss = decaps(&kp.dk, &enc_result.ct);
    try testing.expectEqualSlices(u8, &enc_result.K, &dec_ss);
}

test "hybrid v2 encaps/decaps round trip" {
    const kp = try keyGen();
    const enc_result = try encapsV2(&kp.ek);
    const dec_ss = decapsV2(&kp.dk, &enc_result.ct);
    try testing.expectEqualSlices(u8, &enc_result.K, &dec_ss);
}

test "hybrid v1 and v2 derive different secrets from the same ciphertext" {
    const kp = try keyGen();
    const enc = try encapsV2(&kp.ek);

    const ss_v2 = decapsV2(&kp.dk, &enc.ct);
    const ss_v1 = decaps(&kp.dk, &enc.ct);

    try testing.expectEqualSlices(u8, &enc.K, &ss_v2);
    try testing.expect(!std.mem.eql(u8, &ss_v1, &ss_v2));
}

test "hybrid different keys produce different secrets" {
    const kp1 = try keyGen();
    const kp2 = try keyGen();

    const enc1 = try encapsV2(&kp1.ek);
    const enc2 = try encapsV2(&kp2.ek);

    try testing.expect(!std.mem.eql(u8, &enc1.K, &enc2.K));
}

test "hybrid wrong key decapsulation" {
    const kp1 = try keyGen();
    const kp2 = try keyGen();

    const enc = try encapsV2(&kp1.ek);
    const wrong_ss = decapsV2(&kp2.dk, &enc.ct);

    try testing.expect(!std.mem.eql(u8, &enc.K, &wrong_ss));
}

test "hybrid v2 rejects a tampered X25519 ephemeral public key" {
    const kp = try keyGen();
    const enc = try encapsV2(&kp.ek);

    var tampered = enc.ct;
    tampered[MLKEM_CT_SIZE] ^= 0x01;

    const ss_v2 = decapsV2(&kp.dk, &tampered);
    try testing.expect(!std.mem.eql(u8, &enc.K, &ss_v2));
}

test "hybrid combiner v1 KAT" {
    const expected = hexToArray(32, "59b451d64cdb071634a1d609082690ce46624beebe947a43dbf397f319018a25");
    const got = combineSecretsV1(&kat_ss_m, &kat_ss_x);
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "hybrid combiner v2 KAT" {
    const expected = hexToArray(32, "22de6874d487bc9a0e2e68679f914ef2b3df2a4e4bb09a8ffed1095ce4dfd3e0");
    const got = combineSecretsV2(&kat_ss_m, &kat_ss_x, &kat_ct_x, &kat_pk_x);
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "hybrid combiner v2 KAT with all-zero ss_X (low-order X25519 point path)" {
    const expected = hexToArray(32, "3047921a56cb394acade1101753eb5ba5843f1ac8d6108eba9be2432f6b947be");
    const zero = [_]u8{0} ** 32;
    const got = combineSecretsV2(&kat_ss_m, &zero, &kat_ct_x, &kat_pk_x);
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "hybrid combiner v2 is deterministic" {
    const a = combineSecretsV2(&kat_ss_m, &kat_ss_x, &kat_ct_x, &kat_pk_x);
    const b = combineSecretsV2(&kat_ss_m, &kat_ss_x, &kat_ct_x, &kat_pk_x);
    try testing.expectEqualSlices(u8, &a, &b);
}

fn sha3(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    crypto.hash.sha3.Sha3_256.hash(bytes, &out, .{});
    return out;
}

// Full-path deterministic vector: fixed seeds -> (ek, dk, ct, K_v1, K_v2). The
// complete hex is in docs/HYBRID-V2.md (generated by `zig build hybrid-vectors`);
// here the large fields are pinned by SHA3-256 digest and the secrets in full.
test "hybrid full-path deterministic vector (v1 and v2)" {
    const kp = try keyGenDeterministic(&kat_seed_d, &kat_seed_z, &kat_seed_x25519_sk);
    const enc_v1 = try encapsDeterministic(&kp.ek, .v1, &kat_seed_m, &kat_seed_eph_sk);
    const enc_v2 = try encapsDeterministic(&kp.ek, .v2, &kat_seed_m, &kat_seed_eph_sk);

    // Same randomness -> same ciphertext regardless of combiner version.
    try testing.expectEqualSlices(u8, &enc_v1.ct, &enc_v2.ct);

    // Round trips through the non-deterministic decaps entry points.
    try testing.expectEqualSlices(u8, &enc_v1.K, &decaps(&kp.dk, &enc_v1.ct));
    try testing.expectEqualSlices(u8, &enc_v2.K, &decapsV2(&kp.dk, &enc_v2.ct));

    // Pinned values (docs/HYBRID-V2.md, "Full-path vector").
    try testing.expectEqualSlices(u8, &hexToArray(32, KAT_EK_SHA3), &sha3(&kp.ek));
    try testing.expectEqualSlices(u8, &hexToArray(32, KAT_DK_SHA3), &sha3(&kp.dk));
    try testing.expectEqualSlices(u8, &hexToArray(32, KAT_CT_SHA3), &sha3(&enc_v1.ct));
    try testing.expectEqualSlices(u8, &hexToArray(32, KAT_K_V1), &enc_v1.K);
    try testing.expectEqualSlices(u8, &hexToArray(32, KAT_K_V2), &enc_v2.K);
}

const KAT_EK_SHA3 = "464dfb1c07923faf3bf4942a17660062f4578f0a4eb72ca1f1d0b355b57f139a";
const KAT_DK_SHA3 = "df93eed15f3a736854e002ec6f3ddfd9ec28dda5674ea6664c499015d2ac94f3";
const KAT_CT_SHA3 = "1efb4b6fa294d4df8dc87f5bf7277e698b557303c4c21db33da71801cee0356d";
const KAT_K_V1 = "ece5edee3b04bc365a58066bc579e46de88ccb700fa20cdb44fd6289e9a56a02";
const KAT_K_V2 = "554119be4c831483f20bc6050d4e5c243a3e45fa91093bdd86e4a5fc1a64db5b";
