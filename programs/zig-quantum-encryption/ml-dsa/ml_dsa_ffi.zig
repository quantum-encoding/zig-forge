//! C FFI Exports for ML-DSA-65
//!
//! Provides a stable C ABI for integration with Tauri/Rust and other languages.
//! All functions are thread-safe and use explicit memory management.

const std = @import("std");
const ml_dsa = @import("ml_dsa_complete.zig");

// ============================================================================
// Type Aliases for C Interop
// ============================================================================

pub const MlDsaPublicKey = extern struct {
    data: [ml_dsa.PUBLIC_KEY_SIZE]u8,
};

pub const MlDsaSecretKey = extern struct {
    data: [ml_dsa.SECRET_KEY_SIZE]u8,
};

pub const MlDsaSignature = extern struct {
    data: [ml_dsa.SIGNATURE_SIZE]u8,
};

pub const MlDsaKeyPair = extern struct {
    public_key: MlDsaPublicKey,
    secret_key: MlDsaSecretKey,
};

// ============================================================================
// Error Codes
// ============================================================================

pub const MlDsaError = enum(c_int) {
    success = 0,
    invalid_public_key = -1,
    invalid_secret_key = -2,
    invalid_signature = -3,
    signing_failed = -4,
    verification_failed = -5,
    invalid_parameter = -6,
    rng_failure = -7,
};

// ============================================================================
// Key Generation
// ============================================================================

/// Generate an ML-DSA-65 key pair
/// 
/// @param keypair Output buffer for the generated key pair
/// @param seed Optional 32-byte seed (NULL for random generation)
/// @return MlDsaError.success on success, error code otherwise
export fn ml_dsa_65_keygen(
    keypair: *MlDsaKeyPair,
    seed: ?*const [32]u8,
) MlDsaError {
    const result = ml_dsa.keyGen(seed);

    @memcpy(&keypair.public_key.data, &result.pk.data);
    @memcpy(&keypair.secret_key.data, &result.sk.data);

    return .success;
}

/// Generate an ML-DSA-65 key pair with random seed
export fn ml_dsa_65_keygen_random(keypair: *MlDsaKeyPair) MlDsaError {
    return ml_dsa_65_keygen(keypair, null);
}

// ============================================================================
// Signing
// ============================================================================

/// Sign a message using ML-DSA-65
///
/// @param signature Output buffer for the signature
/// @param secret_key The secret key to sign with
/// @param message The message to sign
/// @param message_len Length of the message
/// @param randomized If true, use randomized signing (recommended)
/// @return MlDsaError.success on success, error code otherwise
export fn ml_dsa_65_sign(
    signature: *MlDsaSignature,
    secret_key: *const MlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
    randomized: bool,
) MlDsaError {
    const sk: *const ml_dsa.SecretKey = @ptrCast(secret_key);
    const msg = message[0..message_len];

    if (ml_dsa.sign(sk, msg, randomized)) |sig| {
        @memcpy(&signature.data, &sig.data);
        return .success;
    }

    return .signing_failed;
}

/// Sign a message with randomized signing (recommended)
export fn ml_dsa_65_sign_randomized(
    signature: *MlDsaSignature,
    secret_key: *const MlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
) MlDsaError {
    return ml_dsa_65_sign(signature, secret_key, message, message_len, true);
}

/// Sign a message with deterministic signing
export fn ml_dsa_65_sign_deterministic(
    signature: *MlDsaSignature,
    secret_key: *const MlDsaSecretKey,
    message: [*]const u8,
    message_len: usize,
) MlDsaError {
    return ml_dsa_65_sign(signature, secret_key, message, message_len, false);
}

// ============================================================================
// Verification
// ============================================================================

/// Verify an ML-DSA-65 signature
///
/// @param public_key The public key to verify with
/// @param message The message that was signed
/// @param message_len Length of the message
/// @param signature The signature to verify
/// @return MlDsaError.success if valid, MlDsaError.verification_failed otherwise
export fn ml_dsa_65_verify(
    public_key: *const MlDsaPublicKey,
    message: [*]const u8,
    message_len: usize,
    signature: *const MlDsaSignature,
) MlDsaError {
    const pk: *const ml_dsa.PublicKey = @ptrCast(public_key);
    const sig: *const ml_dsa.Signature = @ptrCast(signature);
    const msg = message[0..message_len];

    if (ml_dsa.verify(pk, msg, sig)) {
        return .success;
    }

    return .verification_failed;
}

// ============================================================================
// Size Constants (Exported as Functions for C Compatibility)
// ============================================================================

export fn ml_dsa_65_public_key_size() usize {
    return ml_dsa.PUBLIC_KEY_SIZE;
}

export fn ml_dsa_65_secret_key_size() usize {
    return ml_dsa.SECRET_KEY_SIZE;
}

export fn ml_dsa_65_signature_size() usize {
    return ml_dsa.SIGNATURE_SIZE;
}

// ============================================================================
// Algorithm Parameters (for documentation/debugging)
// ============================================================================

export fn ml_dsa_65_security_level() c_int {
    return 3; // NIST Security Level 3
}

export fn ml_dsa_65_security_bits() c_int {
    return 192; // Equivalent to AES-192
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Securely zero memory (prevents compiler optimization)
export fn ml_dsa_secure_zero(ptr: [*]u8, len: usize) void {
    @memset(ptr[0..len], 0);
    // Compiler barrier to prevent optimization
    asm volatile ("" : : "r" (ptr) : "memory");
}

/// Compare two signatures in constant time
export fn ml_dsa_signature_equals(
    sig1: *const MlDsaSignature,
    sig2: *const MlDsaSignature,
) bool {
    var diff: u8 = 0;
    for (0..ml_dsa.SIGNATURE_SIZE) |i| {
        diff |= sig1.data[i] ^ sig2.data[i];
    }
    return diff == 0;
}

// ============================================================================
// C Header Generation Helper
// ============================================================================

pub const C_HEADER =
    \\/* ML-DSA-65 (FIPS 204) C API */
    \\/* Auto-generated from ml_dsa_ffi.zig */
    \\
    \\#ifndef ML_DSA_65_H
    \\#define ML_DSA_65_H
    \\
    \\#include <stddef.h>
    \\#include <stdint.h>
    \\#include <stdbool.h>
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* Key and signature sizes */
    \\#define ML_DSA_65_PUBLIC_KEY_SIZE  1952
    \\#define ML_DSA_65_SECRET_KEY_SIZE  4032
    \\#define ML_DSA_65_SIGNATURE_SIZE   3309
    \\#define ML_DSA_65_SEED_SIZE        32
    \\
    \\/* Error codes */
    \\typedef enum {
    \\    ML_DSA_SUCCESS = 0,
    \\    ML_DSA_INVALID_PUBLIC_KEY = -1,
    \\    ML_DSA_INVALID_SECRET_KEY = -2,
    \\    ML_DSA_INVALID_SIGNATURE = -3,
    \\    ML_DSA_SIGNING_FAILED = -4,
    \\    ML_DSA_VERIFICATION_FAILED = -5,
    \\    ML_DSA_INVALID_PARAMETER = -6,
    \\    ML_DSA_RNG_FAILURE = -7,
    \\} MlDsaError;
    \\
    \\/* Key types */
    \\typedef struct {
    \\    uint8_t data[ML_DSA_65_PUBLIC_KEY_SIZE];
    \\} MlDsaPublicKey;
    \\
    \\typedef struct {
    \\    uint8_t data[ML_DSA_65_SECRET_KEY_SIZE];
    \\} MlDsaSecretKey;
    \\
    \\typedef struct {
    \\    uint8_t data[ML_DSA_65_SIGNATURE_SIZE];
    \\} MlDsaSignature;
    \\
    \\typedef struct {
    \\    MlDsaPublicKey public_key;
    \\    MlDsaSecretKey secret_key;
    \\} MlDsaKeyPair;
    \\
    \\/* Key generation */
    \\MlDsaError ml_dsa_65_keygen(MlDsaKeyPair* keypair, const uint8_t seed[32]);
    \\MlDsaError ml_dsa_65_keygen_random(MlDsaKeyPair* keypair);
    \\
    \\/* Signing */
    \\MlDsaError ml_dsa_65_sign(
    \\    MlDsaSignature* signature,
    \\    const MlDsaSecretKey* secret_key,
    \\    const uint8_t* message,
    \\    size_t message_len,
    \\    bool randomized
    \\);
    \\MlDsaError ml_dsa_65_sign_randomized(
    \\    MlDsaSignature* signature,
    \\    const MlDsaSecretKey* secret_key,
    \\    const uint8_t* message,
    \\    size_t message_len
    \\);
    \\MlDsaError ml_dsa_65_sign_deterministic(
    \\    MlDsaSignature* signature,
    \\    const MlDsaSecretKey* secret_key,
    \\    const uint8_t* message,
    \\    size_t message_len
    \\);
    \\
    \\/* Verification */
    \\MlDsaError ml_dsa_65_verify(
    \\    const MlDsaPublicKey* public_key,
    \\    const uint8_t* message,
    \\    size_t message_len,
    \\    const MlDsaSignature* signature
    \\);
    \\
    \\/* Size queries */
    \\size_t ml_dsa_65_public_key_size(void);
    \\size_t ml_dsa_65_secret_key_size(void);
    \\size_t ml_dsa_65_signature_size(void);
    \\
    \\/* Algorithm info */
    \\int ml_dsa_65_security_level(void);
    \\int ml_dsa_65_security_bits(void);
    \\
    \\/* Utilities */
    \\void ml_dsa_secure_zero(uint8_t* ptr, size_t len);
    \\bool ml_dsa_signature_equals(const MlDsaSignature* sig1, const MlDsaSignature* sig2);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#endif /* ML_DSA_65_H */
;

// ============================================================================
// Tests for FFI Layer
// ============================================================================

test "FFI key generation" {
    var keypair: MlDsaKeyPair = undefined;
    const result = ml_dsa_65_keygen_random(&keypair);
    try std.testing.expectEqual(MlDsaError.success, result);
}

test "FFI sign and verify" {
    var keypair: MlDsaKeyPair = undefined;
    _ = ml_dsa_65_keygen_random(&keypair);

    const msg = "Test message for FFI";
    var signature: MlDsaSignature = undefined;

    const sign_result = ml_dsa_65_sign_randomized(
        &signature,
        &keypair.secret_key,
        msg.ptr,
        msg.len,
    );
    try std.testing.expectEqual(MlDsaError.success, sign_result);

    const verify_result = ml_dsa_65_verify(
        &keypair.public_key,
        msg.ptr,
        msg.len,
        &signature,
    );
    try std.testing.expectEqual(MlDsaError.success, verify_result);
}

test "FFI verify wrong message fails" {
    var keypair: MlDsaKeyPair = undefined;
    _ = ml_dsa_65_keygen_random(&keypair);

    const msg = "Original message";
    var signature: MlDsaSignature = undefined;

    _ = ml_dsa_65_sign_randomized(&signature, &keypair.secret_key, msg.ptr, msg.len);

    const wrong_msg = "Wrong message";
    const verify_result = ml_dsa_65_verify(
        &keypair.public_key,
        wrong_msg.ptr,
        wrong_msg.len,
        &signature,
    );
    try std.testing.expectEqual(MlDsaError.verification_failed, verify_result);
}
