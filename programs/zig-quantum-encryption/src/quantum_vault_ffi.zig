//! Quantum Vault FFI - Unified Post-Quantum Cryptography API
//!
//! Combines ML-KEM-768 (FIPS 203), ML-DSA-65 (FIPS 204), and Hybrid ML-KEM+X25519
//! for Rust/Tauri integration in cryptocurrency wallet applications.
//!
//! All types use `extern struct` for C ABI compatibility.
//! Memory management: caller allocates, library fills.
//! Thread safety: no global state.
//!
//! Version: 1.0.0

const std = @import("std");
const ml_kem = @import("ml_kem_api.zig");
const ml_dsa = @import("ml_dsa_v2.zig");
const hybrid = @import("hybrid.zig");

// ============================================================================
// Algorithm Size Constants
// ============================================================================

// ML-KEM-768 (FIPS 203)
pub const MLKEM768_EK_SIZE: usize = 1184; // Encapsulation key (public)
pub const MLKEM768_DK_SIZE: usize = 2400; // Decapsulation key (private)
pub const MLKEM768_CT_SIZE: usize = 1088; // Ciphertext
pub const MLKEM768_SS_SIZE: usize = 32; // Shared secret

// ML-DSA-65 (FIPS 204)
pub const MLDSA65_PK_SIZE: usize = 1952; // Public key
pub const MLDSA65_SK_SIZE: usize = 4032; // Secret key
pub const MLDSA65_SIG_SIZE: usize = 3309; // Signature
pub const MLDSA65_SEED_SIZE: usize = 32; // Seed for deterministic keygen

// Hybrid ML-KEM-768 + X25519
pub const HYBRID_EK_SIZE: usize = 1216; // 1184 + 32
pub const HYBRID_DK_SIZE: usize = 2432; // 2400 + 32
pub const HYBRID_CT_SIZE: usize = 1120; // 1088 + 32
pub const HYBRID_SS_SIZE: usize = 32; // Combined shared secret

// ============================================================================
// Unified Error Codes
// ============================================================================

pub const QvError = enum(c_int) {
    success = 0,

    // General errors (-1 to -9)
    invalid_parameter = -1,
    rng_failure = -2,
    memory_error = -3,

    // ML-KEM errors (-10 to -19)
    mlkem_invalid_ek = -10,
    mlkem_invalid_dk = -11,
    mlkem_invalid_ct = -12,
    mlkem_encaps_failed = -13,
    mlkem_decaps_failed = -14,
    mlkem_keygen_failed = -15,

    // ML-DSA errors (-20 to -29)
    mldsa_invalid_pk = -20,
    mldsa_invalid_sk = -21,
    mldsa_invalid_sig = -22,
    mldsa_signing_failed = -23,
    mldsa_verification_failed = -24,
    mldsa_keygen_failed = -25,

    // Hybrid errors (-30 to -39)
    hybrid_keygen_failed = -30,
    hybrid_encaps_failed = -31,
    hybrid_decaps_failed = -32,
    hybrid_invalid_pk = -33,
};

// ============================================================================
// ML-KEM-768 Types (extern struct for C ABI)
// ============================================================================

pub const QvMlKemEncapsKey = extern struct {
    data: [MLKEM768_EK_SIZE]u8,
};

pub const QvMlKemDecapsKey = extern struct {
    data: [MLKEM768_DK_SIZE]u8,
};

pub const QvMlKemCiphertext = extern struct {
    data: [MLKEM768_CT_SIZE]u8,
};

pub const QvMlKemKeyPair = extern struct {
    ek: QvMlKemEncapsKey,
    dk: QvMlKemDecapsKey,
};

pub const QvMlKemEncapsResult = extern struct {
    shared_secret: [MLKEM768_SS_SIZE]u8,
    ciphertext: QvMlKemCiphertext,
};

// ============================================================================
// ML-DSA-65 Types
// ============================================================================

pub const QvMlDsaPublicKey = extern struct {
    data: [MLDSA65_PK_SIZE]u8,
};

pub const QvMlDsaSecretKey = extern struct {
    data: [MLDSA65_SK_SIZE]u8,
};

pub const QvMlDsaSignature = extern struct {
    data: [MLDSA65_SIG_SIZE]u8,
};

pub const QvMlDsaKeyPair = extern struct {
    pk: QvMlDsaPublicKey,
    sk: QvMlDsaSecretKey,
};

// ============================================================================
// Hybrid ML-KEM+X25519 Types
// ============================================================================

pub const QvHybridEncapsKey = extern struct {
    data: [HYBRID_EK_SIZE]u8,
};

pub const QvHybridDecapsKey = extern struct {
    data: [HYBRID_DK_SIZE]u8,
};

pub const QvHybridCiphertext = extern struct {
    data: [HYBRID_CT_SIZE]u8,
};

pub const QvHybridKeyPair = extern struct {
    ek: QvHybridEncapsKey,
    dk: QvHybridDecapsKey,
};

pub const QvHybridEncapsResult = extern struct {
    shared_secret: [HYBRID_SS_SIZE]u8,
    ciphertext: QvHybridCiphertext,
};

// ============================================================================
// ML-KEM-768 API
// ============================================================================

/// Generate ML-KEM-768 key pair for key encapsulation
export fn qv_mlkem768_keygen(keypair: *QvMlKemKeyPair) QvError {
    const result = ml_kem.keyGen768() catch return .mlkem_keygen_failed;
    @memcpy(&keypair.ek.data, &result.ek.data);
    @memcpy(&keypair.dk.data, &result.dk.data);
    return .success;
}

/// Encapsulate: generate shared secret and ciphertext using public key
export fn qv_mlkem768_encaps(
    ek: *const QvMlKemEncapsKey,
    result: *QvMlKemEncapsResult,
) QvError {
    var mlkem_ek: ml_kem.EncapsulationKey768 = undefined;
    @memcpy(&mlkem_ek.data, &ek.data);

    const encaps_result = ml_kem.encaps768(&mlkem_ek) catch return .mlkem_encaps_failed;
    @memcpy(&result.shared_secret, &encaps_result.K);
    @memcpy(&result.ciphertext.data, &encaps_result.c.data);
    return .success;
}

/// Decapsulate: recover shared secret from ciphertext using private key
export fn qv_mlkem768_decaps(
    dk: *const QvMlKemDecapsKey,
    ct: *const QvMlKemCiphertext,
    shared_secret: *[MLKEM768_SS_SIZE]u8,
) QvError {
    var mlkem_dk: ml_kem.DecapsulationKey768 = undefined;
    @memcpy(&mlkem_dk.data, &dk.data);

    var mlkem_ct: ml_kem.Ciphertext768 = undefined;
    @memcpy(&mlkem_ct.data, &ct.data);

    const ss = ml_kem.decaps768(&mlkem_dk, &mlkem_ct);
    @memcpy(shared_secret, &ss);
    return .success;
}

// ============================================================================
// ML-DSA-65 API
// ============================================================================

/// Generate ML-DSA-65 key pair with optional deterministic seed
export fn qv_mldsa65_keygen(
    keypair: *QvMlDsaKeyPair,
    seed: ?*const [MLDSA65_SEED_SIZE]u8,
) QvError {
    const result = ml_dsa.keyGen(seed);
    @memcpy(&keypair.pk.data, &result.pk.data);
    @memcpy(&keypair.sk.data, &result.sk.data);
    return .success;
}

/// Generate ML-DSA-65 key pair with random seed
export fn qv_mldsa65_keygen_random(keypair: *QvMlDsaKeyPair) QvError {
    return qv_mldsa65_keygen(keypair, null);
}

/// Sign message with ML-DSA-65 (with randomization option)
export fn qv_mldsa65_sign(
    sk: *const QvMlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
    signature: *QvMlDsaSignature,
    randomized: bool,
) QvError {
    const secret_key: *const ml_dsa.SecretKey = @ptrCast(sk);
    if (ml_dsa.sign(secret_key, message[0..message_len], randomized)) |sig| {
        @memcpy(&signature.data, &sig.data);
        return .success;
    }
    return .mldsa_signing_failed;
}

/// Sign message with randomized ML-DSA-65
export fn qv_mldsa65_sign_randomized(
    sk: *const QvMlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
    signature: *QvMlDsaSignature,
) QvError {
    return qv_mldsa65_sign(sk, message, message_len, signature, true);
}

/// Sign message with deterministic ML-DSA-65
export fn qv_mldsa65_sign_deterministic(
    sk: *const QvMlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
    signature: *QvMlDsaSignature,
) QvError {
    return qv_mldsa65_sign(sk, message, message_len, signature, false);
}

/// Verify ML-DSA-65 signature
export fn qv_mldsa65_verify(
    pk: *const QvMlDsaPublicKey,
    message: [*]const u8,
    message_len: usize,
    signature: *const QvMlDsaSignature,
) QvError {
    const public_key: *const ml_dsa.PublicKey = @ptrCast(pk);
    const sig: *const ml_dsa.Signature = @ptrCast(signature);

    if (ml_dsa.verify(public_key, message[0..message_len], sig)) {
        return .success;
    }
    return .mldsa_verification_failed;
}

// ============================================================================
// Hybrid ML-KEM+X25519 API
// ============================================================================

/// Generate hybrid key pair (ML-KEM-768 + X25519)
export fn qv_hybrid_keygen(keypair: *QvHybridKeyPair) QvError {
    const result = hybrid.keyGen() catch return .hybrid_keygen_failed;
    @memcpy(&keypair.ek.data, &result.ek);
    @memcpy(&keypair.dk.data, &result.dk);
    return .success;
}

/// Hybrid encapsulation: generate combined shared secret
export fn qv_hybrid_encaps(
    ek: *const QvHybridEncapsKey,
    result: *QvHybridEncapsResult,
) QvError {
    const encaps_result = hybrid.encaps(&ek.data) catch return .hybrid_encaps_failed;
    @memcpy(&result.shared_secret, &encaps_result.K);
    @memcpy(&result.ciphertext.data, &encaps_result.ct);
    return .success;
}

/// Hybrid decapsulation: recover combined shared secret
export fn qv_hybrid_decaps(
    dk: *const QvHybridDecapsKey,
    ct: *const QvHybridCiphertext,
    shared_secret: *[HYBRID_SS_SIZE]u8,
) QvError {
    const ss = hybrid.decaps(&dk.data, &ct.data);
    @memcpy(shared_secret, &ss);
    return .success;
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Securely zero memory (prevents compiler optimization)
export fn qv_secure_zero(ptr: [*]u8, len: usize) void {
    @memset(ptr[0..len], 0);
    // Use volatile pointer access to prevent optimization
    const volatile_ptr: *volatile u8 = @ptrCast(ptr);
    _ = volatile_ptr.*;
}

/// Constant-time comparison (prevents timing attacks)
export fn qv_constant_time_eq(a: [*]const u8, b: [*]const u8, len: usize) bool {
    var diff: u8 = 0;
    for (0..len) |i| {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

/// Get library version string
export fn qv_version() [*:0]const u8 {
    return "quantum-vault-pqc-1.0.0";
}

// ============================================================================
// Size Query Functions (for dynamic languages)
// ============================================================================

// ML-KEM-768 sizes
export fn qv_mlkem768_ek_size() usize {
    return MLKEM768_EK_SIZE;
}
export fn qv_mlkem768_dk_size() usize {
    return MLKEM768_DK_SIZE;
}
export fn qv_mlkem768_ct_size() usize {
    return MLKEM768_CT_SIZE;
}
export fn qv_mlkem768_ss_size() usize {
    return MLKEM768_SS_SIZE;
}

// ML-DSA-65 sizes
export fn qv_mldsa65_pk_size() usize {
    return MLDSA65_PK_SIZE;
}
export fn qv_mldsa65_sk_size() usize {
    return MLDSA65_SK_SIZE;
}
export fn qv_mldsa65_sig_size() usize {
    return MLDSA65_SIG_SIZE;
}

// Hybrid sizes
export fn qv_hybrid_ek_size() usize {
    return HYBRID_EK_SIZE;
}
export fn qv_hybrid_dk_size() usize {
    return HYBRID_DK_SIZE;
}
export fn qv_hybrid_ct_size() usize {
    return HYBRID_CT_SIZE;
}
export fn qv_hybrid_ss_size() usize {
    return HYBRID_SS_SIZE;
}

// ============================================================================
// C Header (for Rust bindgen and C consumers)
// ============================================================================

pub const C_HEADER =
    \\/**
    \\ * Quantum Vault Post-Quantum Cryptography Library
    \\ *
    \\ * FIPS 203 (ML-KEM-768) + FIPS 204 (ML-DSA-65) + Hybrid ML-KEM+X25519
    \\ *
    \\ * Auto-generated from quantum_vault_ffi.zig
    \\ * Do not edit manually.
    \\ *
    \\ * Version: 1.0.0
    \\ */
    \\
    \\#ifndef QUANTUM_VAULT_H
    \\#define QUANTUM_VAULT_H
    \\
    \\#include <stddef.h>
    \\#include <stdint.h>
    \\#include <stdbool.h>
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* ========================================================================== */
    \\/* Size Constants                                                              */
    \\/* ========================================================================== */
    \\
    \\/* ML-KEM-768 (FIPS 203) */
    \\#define QV_MLKEM768_EK_SIZE   1184   /* Encapsulation key (public) */
    \\#define QV_MLKEM768_DK_SIZE   2400   /* Decapsulation key (private) */
    \\#define QV_MLKEM768_CT_SIZE   1088   /* Ciphertext */
    \\#define QV_MLKEM768_SS_SIZE   32     /* Shared secret */
    \\
    \\/* ML-DSA-65 (FIPS 204) */
    \\#define QV_MLDSA65_PK_SIZE    1952   /* Public key */
    \\#define QV_MLDSA65_SK_SIZE    4032   /* Secret key */
    \\#define QV_MLDSA65_SIG_SIZE   3309   /* Signature */
    \\#define QV_MLDSA65_SEED_SIZE  32     /* Seed */
    \\
    \\/* Hybrid ML-KEM-768 + X25519 */
    \\#define QV_HYBRID_EK_SIZE     1216   /* Encapsulation key */
    \\#define QV_HYBRID_DK_SIZE     2432   /* Decapsulation key */
    \\#define QV_HYBRID_CT_SIZE     1120   /* Ciphertext */
    \\#define QV_HYBRID_SS_SIZE     32     /* Shared secret */
    \\
    \\/* ========================================================================== */
    \\/* Error Codes                                                                 */
    \\/* ========================================================================== */
    \\
    \\typedef enum {
    \\    QV_SUCCESS = 0,
    \\
    \\    /* General errors (-1 to -9) */
    \\    QV_INVALID_PARAMETER = -1,
    \\    QV_RNG_FAILURE = -2,
    \\    QV_MEMORY_ERROR = -3,
    \\
    \\    /* ML-KEM errors (-10 to -19) */
    \\    QV_MLKEM_INVALID_EK = -10,
    \\    QV_MLKEM_INVALID_DK = -11,
    \\    QV_MLKEM_INVALID_CT = -12,
    \\    QV_MLKEM_ENCAPS_FAILED = -13,
    \\    QV_MLKEM_DECAPS_FAILED = -14,
    \\    QV_MLKEM_KEYGEN_FAILED = -15,
    \\
    \\    /* ML-DSA errors (-20 to -29) */
    \\    QV_MLDSA_INVALID_PK = -20,
    \\    QV_MLDSA_INVALID_SK = -21,
    \\    QV_MLDSA_INVALID_SIG = -22,
    \\    QV_MLDSA_SIGNING_FAILED = -23,
    \\    QV_MLDSA_VERIFICATION_FAILED = -24,
    \\    QV_MLDSA_KEYGEN_FAILED = -25,
    \\
    \\    /* Hybrid errors (-30 to -39) */
    \\    QV_HYBRID_KEYGEN_FAILED = -30,
    \\    QV_HYBRID_ENCAPS_FAILED = -31,
    \\    QV_HYBRID_DECAPS_FAILED = -32,
    \\    QV_HYBRID_INVALID_PK = -33
    \\} QvError;
    \\
    \\/* ========================================================================== */
    \\/* ML-KEM-768 Types                                                            */
    \\/* ========================================================================== */
    \\
    \\typedef struct { uint8_t data[QV_MLKEM768_EK_SIZE]; } QvMlKemEncapsKey;
    \\typedef struct { uint8_t data[QV_MLKEM768_DK_SIZE]; } QvMlKemDecapsKey;
    \\typedef struct { uint8_t data[QV_MLKEM768_CT_SIZE]; } QvMlKemCiphertext;
    \\
    \\typedef struct {
    \\    QvMlKemEncapsKey ek;
    \\    QvMlKemDecapsKey dk;
    \\} QvMlKemKeyPair;
    \\
    \\typedef struct {
    \\    uint8_t shared_secret[QV_MLKEM768_SS_SIZE];
    \\    QvMlKemCiphertext ciphertext;
    \\} QvMlKemEncapsResult;
    \\
    \\/* ========================================================================== */
    \\/* ML-DSA-65 Types                                                             */
    \\/* ========================================================================== */
    \\
    \\typedef struct { uint8_t data[QV_MLDSA65_PK_SIZE]; } QvMlDsaPublicKey;
    \\typedef struct { uint8_t data[QV_MLDSA65_SK_SIZE]; } QvMlDsaSecretKey;
    \\typedef struct { uint8_t data[QV_MLDSA65_SIG_SIZE]; } QvMlDsaSignature;
    \\
    \\typedef struct {
    \\    QvMlDsaPublicKey pk;
    \\    QvMlDsaSecretKey sk;
    \\} QvMlDsaKeyPair;
    \\
    \\/* ========================================================================== */
    \\/* Hybrid Types                                                                */
    \\/* ========================================================================== */
    \\
    \\typedef struct { uint8_t data[QV_HYBRID_EK_SIZE]; } QvHybridEncapsKey;
    \\typedef struct { uint8_t data[QV_HYBRID_DK_SIZE]; } QvHybridDecapsKey;
    \\typedef struct { uint8_t data[QV_HYBRID_CT_SIZE]; } QvHybridCiphertext;
    \\
    \\typedef struct {
    \\    QvHybridEncapsKey ek;
    \\    QvHybridDecapsKey dk;
    \\} QvHybridKeyPair;
    \\
    \\typedef struct {
    \\    uint8_t shared_secret[QV_HYBRID_SS_SIZE];
    \\    QvHybridCiphertext ciphertext;
    \\} QvHybridEncapsResult;
    \\
    \\/* ========================================================================== */
    \\/* ML-KEM-768 API                                                              */
    \\/* ========================================================================== */
    \\
    \\/**
    \\ * Generate ML-KEM-768 key pair for key encapsulation.
    \\ *
    \\ * @param keypair Output: generated key pair
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_mlkem768_keygen(QvMlKemKeyPair* keypair);
    \\
    \\/**
    \\ * Encapsulate: generate shared secret and ciphertext.
    \\ *
    \\ * @param ek Input: encapsulation key (public)
    \\ * @param result Output: shared secret and ciphertext
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_mlkem768_encaps(const QvMlKemEncapsKey* ek, QvMlKemEncapsResult* result);
    \\
    \\/**
    \\ * Decapsulate: recover shared secret from ciphertext.
    \\ *
    \\ * @param dk Input: decapsulation key (private)
    \\ * @param ct Input: ciphertext
    \\ * @param shared_secret Output: 32-byte shared secret
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_mlkem768_decaps(const QvMlKemDecapsKey* dk, const QvMlKemCiphertext* ct,
    \\                           uint8_t shared_secret[QV_MLKEM768_SS_SIZE]);
    \\
    \\/* ========================================================================== */
    \\/* ML-DSA-65 API                                                               */
    \\/* ========================================================================== */
    \\
    \\/**
    \\ * Generate ML-DSA-65 key pair with optional deterministic seed.
    \\ *
    \\ * @param keypair Output: generated key pair
    \\ * @param seed Input: optional 32-byte seed (NULL for random)
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_mldsa65_keygen(QvMlDsaKeyPair* keypair, const uint8_t seed[QV_MLDSA65_SEED_SIZE]);
    \\
    \\/**
    \\ * Generate ML-DSA-65 key pair with random seed.
    \\ */
    \\QvError qv_mldsa65_keygen_random(QvMlDsaKeyPair* keypair);
    \\
    \\/**
    \\ * Sign message with ML-DSA-65.
    \\ *
    \\ * @param sk Input: secret key
    \\ * @param message Input: message to sign
    \\ * @param message_len Input: message length
    \\ * @param signature Output: signature
    \\ * @param randomized Input: true for randomized signing
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_mldsa65_sign(const QvMlDsaSecretKey* sk, const uint8_t* message,
    \\                        size_t message_len, QvMlDsaSignature* signature, bool randomized);
    \\
    \\/**
    \\ * Sign message with randomized ML-DSA-65.
    \\ */
    \\QvError qv_mldsa65_sign_randomized(const QvMlDsaSecretKey* sk, const uint8_t* message,
    \\                                   size_t message_len, QvMlDsaSignature* signature);
    \\
    \\/**
    \\ * Sign message with deterministic ML-DSA-65.
    \\ */
    \\QvError qv_mldsa65_sign_deterministic(const QvMlDsaSecretKey* sk, const uint8_t* message,
    \\                                      size_t message_len, QvMlDsaSignature* signature);
    \\
    \\/**
    \\ * Verify ML-DSA-65 signature.
    \\ *
    \\ * @param pk Input: public key
    \\ * @param message Input: signed message
    \\ * @param message_len Input: message length
    \\ * @param signature Input: signature to verify
    \\ * @return QV_SUCCESS if valid, QV_MLDSA_VERIFICATION_FAILED if invalid
    \\ */
    \\QvError qv_mldsa65_verify(const QvMlDsaPublicKey* pk, const uint8_t* message,
    \\                          size_t message_len, const QvMlDsaSignature* signature);
    \\
    \\/* ========================================================================== */
    \\/* Hybrid API                                                                  */
    \\/* ========================================================================== */
    \\
    \\/**
    \\ * Generate hybrid key pair (ML-KEM-768 + X25519).
    \\ *
    \\ * @param keypair Output: generated key pair
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_hybrid_keygen(QvHybridKeyPair* keypair);
    \\
    \\/**
    \\ * Hybrid encapsulation: generate combined shared secret.
    \\ *
    \\ * @param ek Input: encapsulation key
    \\ * @param result Output: shared secret and ciphertext
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_hybrid_encaps(const QvHybridEncapsKey* ek, QvHybridEncapsResult* result);
    \\
    \\/**
    \\ * Hybrid decapsulation: recover combined shared secret.
    \\ *
    \\ * @param dk Input: decapsulation key
    \\ * @param ct Input: ciphertext
    \\ * @param shared_secret Output: 32-byte shared secret
    \\ * @return QV_SUCCESS on success, error code on failure
    \\ */
    \\QvError qv_hybrid_decaps(const QvHybridDecapsKey* dk, const QvHybridCiphertext* ct,
    \\                         uint8_t shared_secret[QV_HYBRID_SS_SIZE]);
    \\
    \\/* ========================================================================== */
    \\/* Utility Functions                                                           */
    \\/* ========================================================================== */
    \\
    \\/**
    \\ * Securely zero memory (prevents compiler optimization).
    \\ */
    \\void qv_secure_zero(uint8_t* ptr, size_t len);
    \\
    \\/**
    \\ * Constant-time comparison (prevents timing attacks).
    \\ */
    \\bool qv_constant_time_eq(const uint8_t* a, const uint8_t* b, size_t len);
    \\
    \\/**
    \\ * Get library version string.
    \\ */
    \\const char* qv_version(void);
    \\
    \\/* ========================================================================== */
    \\/* Size Query Functions                                                        */
    \\/* ========================================================================== */
    \\
    \\size_t qv_mlkem768_ek_size(void);
    \\size_t qv_mlkem768_dk_size(void);
    \\size_t qv_mlkem768_ct_size(void);
    \\size_t qv_mlkem768_ss_size(void);
    \\size_t qv_mldsa65_pk_size(void);
    \\size_t qv_mldsa65_sk_size(void);
    \\size_t qv_mldsa65_sig_size(void);
    \\size_t qv_hybrid_ek_size(void);
    \\size_t qv_hybrid_dk_size(void);
    \\size_t qv_hybrid_ct_size(void);
    \\size_t qv_hybrid_ss_size(void);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#endif /* QUANTUM_VAULT_H */
;

// ============================================================================
// Tests
// ============================================================================

test "ML-KEM-768 FFI round-trip" {
    var keypair: QvMlKemKeyPair = undefined;
    try std.testing.expectEqual(QvError.success, qv_mlkem768_keygen(&keypair));

    var encaps_result: QvMlKemEncapsResult = undefined;
    try std.testing.expectEqual(QvError.success, qv_mlkem768_encaps(&keypair.ek, &encaps_result));

    var decaps_secret: [MLKEM768_SS_SIZE]u8 = undefined;
    try std.testing.expectEqual(QvError.success, qv_mlkem768_decaps(&keypair.dk, &encaps_result.ciphertext, &decaps_secret));

    try std.testing.expect(std.mem.eql(u8, &encaps_result.shared_secret, &decaps_secret));
}

test "ML-DSA-65 FFI sign/verify" {
    var keypair: QvMlDsaKeyPair = undefined;
    try std.testing.expectEqual(QvError.success, qv_mldsa65_keygen_random(&keypair));

    const message = "Test message for ML-DSA-65";
    var signature: QvMlDsaSignature = undefined;
    try std.testing.expectEqual(QvError.success, qv_mldsa65_sign_deterministic(&keypair.sk, message.ptr, message.len, &signature));

    try std.testing.expectEqual(QvError.success, qv_mldsa65_verify(&keypair.pk, message.ptr, message.len, &signature));

    // Wrong message should fail
    const wrong_message = "Wrong message";
    try std.testing.expectEqual(QvError.mldsa_verification_failed, qv_mldsa65_verify(&keypair.pk, wrong_message.ptr, wrong_message.len, &signature));
}

test "Hybrid FFI round-trip" {
    var keypair: QvHybridKeyPair = undefined;
    try std.testing.expectEqual(QvError.success, qv_hybrid_keygen(&keypair));

    var encaps_result: QvHybridEncapsResult = undefined;
    try std.testing.expectEqual(QvError.success, qv_hybrid_encaps(&keypair.ek, &encaps_result));

    var decaps_secret: [HYBRID_SS_SIZE]u8 = undefined;
    try std.testing.expectEqual(QvError.success, qv_hybrid_decaps(&keypair.dk, &encaps_result.ciphertext, &decaps_secret));

    try std.testing.expect(std.mem.eql(u8, &encaps_result.shared_secret, &decaps_secret));
}

test "Size query functions" {
    try std.testing.expectEqual(@as(usize, 1184), qv_mlkem768_ek_size());
    try std.testing.expectEqual(@as(usize, 2400), qv_mlkem768_dk_size());
    try std.testing.expectEqual(@as(usize, 1088), qv_mlkem768_ct_size());
    try std.testing.expectEqual(@as(usize, 32), qv_mlkem768_ss_size());

    try std.testing.expectEqual(@as(usize, 1952), qv_mldsa65_pk_size());
    try std.testing.expectEqual(@as(usize, 4032), qv_mldsa65_sk_size());
    try std.testing.expectEqual(@as(usize, 3309), qv_mldsa65_sig_size());

    try std.testing.expectEqual(@as(usize, 1216), qv_hybrid_ek_size());
    try std.testing.expectEqual(@as(usize, 2432), qv_hybrid_dk_size());
    try std.testing.expectEqual(@as(usize, 1120), qv_hybrid_ct_size());
    try std.testing.expectEqual(@as(usize, 32), qv_hybrid_ss_size());
}

test "Utility functions" {
    var data = [_]u8{ 1, 2, 3, 4, 5 };
    qv_secure_zero(&data, data.len);
    try std.testing.expect(std.mem.eql(u8, &data, &[_]u8{ 0, 0, 0, 0, 0 }));

    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    const c = [_]u8{ 1, 2, 4 };
    try std.testing.expect(qv_constant_time_eq(&a, &b, 3));
    try std.testing.expect(!qv_constant_time_eq(&a, &c, 3));
}
