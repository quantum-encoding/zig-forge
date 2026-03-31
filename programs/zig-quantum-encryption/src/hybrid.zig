//! Hybrid Key Encapsulation: ML-KEM-768 + X25519
//!
//! Combines post-quantum ML-KEM-768 with classical X25519 for defense-in-depth.
//! Security holds as long as at least one algorithm remains secure.
//!
//! Key sizes:
//!   - Hybrid Public Key:  1216 bytes (1184 ML-KEM + 32 X25519)
//!   - Hybrid Secret Key:  2432 bytes (2400 ML-KEM + 32 X25519)
//!   - Hybrid Ciphertext:  1120 bytes (1088 ML-KEM + 32 X25519)
//!   - Shared Secret:      32 bytes (HKDF-SHA3-256 output)

const std = @import("std");
const crypto = std.crypto;
const mlkem = @import("ml_kem_api.zig");

// X25519 types
const X25519 = crypto.dh.X25519;

// Sizes
pub const MLKEM_EK_SIZE = 1184;
pub const MLKEM_DK_SIZE = 2400;
pub const MLKEM_CT_SIZE = 1088;
pub const X25519_KEY_SIZE = 32;
pub const SHARED_SECRET_SIZE = 32;

pub const HYBRID_EK_SIZE = MLKEM_EK_SIZE + X25519_KEY_SIZE; // 1216
pub const HYBRID_DK_SIZE = MLKEM_DK_SIZE + X25519_KEY_SIZE; // 2432
pub const HYBRID_CT_SIZE = MLKEM_CT_SIZE + X25519_KEY_SIZE; // 1120

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
const getRandomBytes = rng.fillSecureRandom;

/// Generate a hybrid key pair
/// Combines ML-KEM-768 and X25519 key generation
pub fn keyGen() HybridError!HybridKeyPair {
    var result: HybridKeyPair = undefined;

    // Generate ML-KEM-768 key pair
    const mlkem_kp = mlkem.keyGen768() catch return HybridError.KeyGenFailed;

    // Generate X25519 key pair
    var x25519_sk: [X25519_KEY_SIZE]u8 = undefined;
    getRandomBytes(&x25519_sk);
    const x25519_pk = X25519.recoverPublicKey(x25519_sk) catch return HybridError.KeyGenFailed;

    // Combine into hybrid keys
    // Encapsulation key: [ML-KEM ek (1184)] || [X25519 pk (32)]
    @memcpy(result.ek[0..MLKEM_EK_SIZE], &mlkem_kp.ek.data);
    @memcpy(result.ek[MLKEM_EK_SIZE..], &x25519_pk);

    // Decapsulation key: [ML-KEM dk (2400)] || [X25519 sk (32)]
    @memcpy(result.dk[0..MLKEM_DK_SIZE], &mlkem_kp.dk.data);
    @memcpy(result.dk[MLKEM_DK_SIZE..], &x25519_sk);

    return result;
}

/// Encapsulate a shared secret using the hybrid scheme
/// Performs both X25519 key exchange and ML-KEM encapsulation
pub fn encaps(ek: *const HybridEncapsulationKey) HybridError!HybridEncapsResult {
    var result: HybridEncapsResult = undefined;

    // Extract component public keys
    const x25519_pk: *const [X25519_KEY_SIZE]u8 = ek[MLKEM_EK_SIZE..][0..X25519_KEY_SIZE];

    // Construct ML-KEM encapsulation key struct
    var mlkem_ek: mlkem.EncapsulationKey768 = undefined;
    @memcpy(&mlkem_ek.data, ek[0..MLKEM_EK_SIZE]);

    // ML-KEM encapsulation
    const mlkem_result = mlkem.encaps768(&mlkem_ek) catch return HybridError.EncapsFailed;

    // X25519 key exchange (ephemeral)
    var x25519_eph_sk: [X25519_KEY_SIZE]u8 = undefined;
    getRandomBytes(&x25519_eph_sk);
    const x25519_eph_pk = X25519.recoverPublicKey(x25519_eph_sk) catch return HybridError.EncapsFailed;
    const x25519_ss = X25519.scalarmult(x25519_eph_sk, x25519_pk.*) catch return HybridError.InvalidPublicKey;

    // Combine ciphertexts: [ML-KEM ct (1088)] || [X25519 ephemeral pk (32)]
    @memcpy(result.ct[0..MLKEM_CT_SIZE], &mlkem_result.c.data);
    @memcpy(result.ct[MLKEM_CT_SIZE..], &x25519_eph_pk);

    // Combine shared secrets using SHA3-256
    // K = SHA3-256(mlkem_ss || x25519_ss || "HYBRID-ML-KEM-768-X25519")
    result.K = combineSecrets(&mlkem_result.K, &x25519_ss);

    return result;
}

/// Decapsulate a shared secret using the hybrid scheme
pub fn decaps(dk: *const HybridDecapsulationKey, ct: *const HybridCiphertext) SharedSecret {
    // Extract X25519 keys
    const x25519_sk: *const [X25519_KEY_SIZE]u8 = dk[MLKEM_DK_SIZE..][0..X25519_KEY_SIZE];
    const x25519_eph_pk: *const [X25519_KEY_SIZE]u8 = ct[MLKEM_CT_SIZE..][0..X25519_KEY_SIZE];

    // Construct ML-KEM structs
    var mlkem_dk: mlkem.DecapsulationKey768 = undefined;
    @memcpy(&mlkem_dk.data, dk[0..MLKEM_DK_SIZE]);

    var mlkem_ct: mlkem.Ciphertext768 = undefined;
    @memcpy(&mlkem_ct.data, ct[0..MLKEM_CT_SIZE]);

    // ML-KEM decapsulation
    const mlkem_ss = mlkem.decaps768(&mlkem_dk, &mlkem_ct);

    // X25519 key exchange
    const x25519_ss = X25519.scalarmult(x25519_sk.*, x25519_eph_pk.*) catch {
        // On invalid public key, use zeros (implicit rejection)
        return combineSecrets(&mlkem_ss, &[_]u8{0} ** X25519_KEY_SIZE);
    };

    // Combine shared secrets
    return combineSecrets(&mlkem_ss, &x25519_ss);
}

/// Combine two shared secrets using SHA3-256
fn combineSecrets(mlkem_ss: *const [32]u8, x25519_ss: *const [32]u8) SharedSecret {
    var hasher = crypto.hash.sha3.Sha3_256.init(.{});

    // Domain separator for algorithm binding
    const domain = "HYBRID-ML-KEM-768-X25519-v1";
    hasher.update(domain);

    // Add both shared secrets
    hasher.update(mlkem_ss);
    hasher.update(x25519_ss);

    var result: SharedSecret = undefined;
    hasher.final(&result);
    return result;
}

// ============================================================================
// C API for FFI
// ============================================================================

/// C-compatible key pair structure
pub const CHybridKeyPair = extern struct {
    ek: [HYBRID_EK_SIZE]u8,
    dk: [HYBRID_DK_SIZE]u8,
};

/// C-compatible encapsulation result
pub const CHybridEncapsResult = extern struct {
    K: [SHARED_SECRET_SIZE]u8,
    ct: [HYBRID_CT_SIZE]u8,
};

/// Generate hybrid key pair (C API)
export fn hybrid_keygen(out: *CHybridKeyPair) c_int {
    const kp = keyGen() catch return -1;
    out.ek = kp.ek;
    out.dk = kp.dk;
    return 0;
}

/// Encapsulate (C API)
export fn hybrid_encaps(ek: *const [HYBRID_EK_SIZE]u8, out: *CHybridEncapsResult) c_int {
    const result = encaps(ek) catch return -1;
    out.K = result.K;
    out.ct = result.ct;
    return 0;
}

/// Decapsulate (C API)
export fn hybrid_decaps(
    dk: *const [HYBRID_DK_SIZE]u8,
    ct: *const [HYBRID_CT_SIZE]u8,
    out: *[SHARED_SECRET_SIZE]u8,
) void {
    out.* = decaps(dk, ct);
}

/// Get key sizes (C API)
export fn hybrid_ek_size() usize {
    return HYBRID_EK_SIZE;
}

export fn hybrid_dk_size() usize {
    return HYBRID_DK_SIZE;
}

export fn hybrid_ct_size() usize {
    return HYBRID_CT_SIZE;
}

export fn hybrid_ss_size() usize {
    return SHARED_SECRET_SIZE;
}

// ============================================================================
// Tests
// ============================================================================

test "hybrid key generation" {
    const kp = try keyGen();

    // Verify sizes
    try std.testing.expectEqual(@as(usize, HYBRID_EK_SIZE), kp.ek.len);
    try std.testing.expectEqual(@as(usize, HYBRID_DK_SIZE), kp.dk.len);
}

test "hybrid encaps/decaps round trip" {
    // Generate key pair
    const kp = try keyGen();

    // Encapsulate
    const enc_result = try encaps(&kp.ek);

    // Decapsulate
    const dec_ss = decaps(&kp.dk, &enc_result.ct);

    // Shared secrets must match
    try std.testing.expectEqualSlices(u8, &enc_result.K, &dec_ss);
}

test "hybrid different keys produce different secrets" {
    const kp1 = try keyGen();
    const kp2 = try keyGen();

    const enc1 = try encaps(&kp1.ek);
    const enc2 = try encaps(&kp2.ek);

    // Different keys should produce different secrets
    try std.testing.expect(!std.mem.eql(u8, &enc1.K, &enc2.K));
}

test "hybrid wrong key decapsulation" {
    const kp1 = try keyGen();
    const kp2 = try keyGen();

    // Encapsulate with kp1's public key
    const enc = try encaps(&kp1.ek);

    // Decapsulate with kp2's private key (wrong key)
    const wrong_ss = decaps(&kp2.dk, &enc.ct);

    // Should NOT match the original shared secret
    try std.testing.expect(!std.mem.eql(u8, &enc.K, &wrong_ss));
}

test "hybrid deterministic combination" {
    // Test that the same inputs produce the same combined secret
    var ss1: [32]u8 = undefined;
    var ss2: [32]u8 = undefined;

    for (&ss1, 0..) |*b, i| b.* = @intCast(i);
    for (&ss2, 0..) |*b, i| b.* = @intCast(i + 32);

    const combined1 = combineSecrets(&ss1, &ss2);
    const combined2 = combineSecrets(&ss1, &ss2);

    try std.testing.expectEqualSlices(u8, &combined1, &combined2);
}
