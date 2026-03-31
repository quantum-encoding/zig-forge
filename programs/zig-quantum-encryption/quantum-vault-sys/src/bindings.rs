//! Raw FFI bindings to Quantum Vault C API
//!
//! These are the unsafe, raw bindings. Use the safe wrappers in other modules.

use std::os::raw::{c_int, c_char};

// ============================================================================
// Size Constants
// ============================================================================

// ML-KEM-768 (FIPS 203)
pub const QV_MLKEM768_EK_SIZE: usize = 1184;
pub const QV_MLKEM768_DK_SIZE: usize = 2400;
pub const QV_MLKEM768_CT_SIZE: usize = 1088;
pub const QV_MLKEM768_SS_SIZE: usize = 32;

// ML-DSA-65 (FIPS 204)
pub const QV_MLDSA65_PK_SIZE: usize = 1952;
pub const QV_MLDSA65_SK_SIZE: usize = 4032;
pub const QV_MLDSA65_SIG_SIZE: usize = 3309;
pub const QV_MLDSA65_SEED_SIZE: usize = 32;

// Hybrid ML-KEM-768 + X25519
pub const QV_HYBRID_EK_SIZE: usize = 1216;
pub const QV_HYBRID_DK_SIZE: usize = 2432;
pub const QV_HYBRID_CT_SIZE: usize = 1120;
pub const QV_HYBRID_SS_SIZE: usize = 32;

// ============================================================================
// Error Codes
// ============================================================================

pub const QV_SUCCESS: c_int = 0;

// General errors (-1 to -9)
pub const QV_INVALID_PARAMETER: c_int = -1;
pub const QV_RNG_FAILURE: c_int = -2;
pub const QV_MEMORY_ERROR: c_int = -3;

// ML-KEM errors (-10 to -19)
pub const QV_MLKEM_INVALID_EK: c_int = -10;
pub const QV_MLKEM_INVALID_DK: c_int = -11;
pub const QV_MLKEM_INVALID_CT: c_int = -12;
pub const QV_MLKEM_ENCAPS_FAILED: c_int = -13;
pub const QV_MLKEM_DECAPS_FAILED: c_int = -14;
pub const QV_MLKEM_KEYGEN_FAILED: c_int = -15;

// ML-DSA errors (-20 to -29)
pub const QV_MLDSA_INVALID_PK: c_int = -20;
pub const QV_MLDSA_INVALID_SK: c_int = -21;
pub const QV_MLDSA_INVALID_SIG: c_int = -22;
pub const QV_MLDSA_SIGNING_FAILED: c_int = -23;
pub const QV_MLDSA_VERIFICATION_FAILED: c_int = -24;
pub const QV_MLDSA_KEYGEN_FAILED: c_int = -25;

// Hybrid errors (-30 to -39)
pub const QV_HYBRID_KEYGEN_FAILED: c_int = -30;
pub const QV_HYBRID_ENCAPS_FAILED: c_int = -31;
pub const QV_HYBRID_DECAPS_FAILED: c_int = -32;
pub const QV_HYBRID_INVALID_PK: c_int = -33;

// ============================================================================
// Type Definitions
// ============================================================================

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlKemEncapsKey {
    pub bytes: [u8; QV_MLKEM768_EK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlKemDecapsKey {
    pub bytes: [u8; QV_MLKEM768_DK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlKemKeyPair {
    pub ek: QvMlKemEncapsKey,
    pub dk: QvMlKemDecapsKey,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlKemCiphertext {
    pub bytes: [u8; QV_MLKEM768_CT_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlKemEncapsResult {
    pub shared_secret: [u8; QV_MLKEM768_SS_SIZE],
    pub ciphertext: QvMlKemCiphertext,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlDsaPublicKey {
    pub bytes: [u8; QV_MLDSA65_PK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlDsaSecretKey {
    pub bytes: [u8; QV_MLDSA65_SK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlDsaKeyPair {
    pub pk: QvMlDsaPublicKey,
    pub sk: QvMlDsaSecretKey,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvMlDsaSignature {
    pub bytes: [u8; QV_MLDSA65_SIG_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvHybridEncapsKey {
    pub bytes: [u8; QV_HYBRID_EK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvHybridDecapsKey {
    pub bytes: [u8; QV_HYBRID_DK_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvHybridKeyPair {
    pub ek: QvHybridEncapsKey,
    pub dk: QvHybridDecapsKey,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvHybridCiphertext {
    pub bytes: [u8; QV_HYBRID_CT_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QvHybridEncapsResult {
    pub shared_secret: [u8; QV_HYBRID_SS_SIZE],
    pub ciphertext: QvHybridCiphertext,
}

// ============================================================================
// External Functions
// ============================================================================

extern "C" {
    // ML-KEM-768 API
    pub fn qv_mlkem768_keygen(keypair: *mut QvMlKemKeyPair) -> c_int;
    pub fn qv_mlkem768_encaps(ek: *const QvMlKemEncapsKey, result: *mut QvMlKemEncapsResult) -> c_int;
    pub fn qv_mlkem768_decaps(
        dk: *const QvMlKemDecapsKey,
        ct: *const QvMlKemCiphertext,
        shared_secret: *mut [u8; QV_MLKEM768_SS_SIZE],
    ) -> c_int;

    // ML-DSA-65 API
    pub fn qv_mldsa65_keygen(keypair: *mut QvMlDsaKeyPair, seed: *const [u8; QV_MLDSA65_SEED_SIZE]) -> c_int;
    pub fn qv_mldsa65_sign(
        sk: *const QvMlDsaSecretKey,
        message: *const u8,
        message_len: usize,
        signature: *mut QvMlDsaSignature,
        randomized: bool,
    ) -> c_int;
    pub fn qv_mldsa65_sign_randomized(
        sk: *const QvMlDsaSecretKey,
        message: *const u8,
        message_len: usize,
        signature: *mut QvMlDsaSignature,
    ) -> c_int;
    pub fn qv_mldsa65_sign_deterministic(
        sk: *const QvMlDsaSecretKey,
        message: *const u8,
        message_len: usize,
        signature: *mut QvMlDsaSignature,
    ) -> c_int;
    pub fn qv_mldsa65_verify(
        pk: *const QvMlDsaPublicKey,
        message: *const u8,
        message_len: usize,
        signature: *const QvMlDsaSignature,
    ) -> c_int;

    // Hybrid API
    pub fn qv_hybrid_keygen(keypair: *mut QvHybridKeyPair) -> c_int;
    pub fn qv_hybrid_encaps(ek: *const QvHybridEncapsKey, result: *mut QvHybridEncapsResult) -> c_int;
    pub fn qv_hybrid_decaps(
        dk: *const QvHybridDecapsKey,
        ct: *const QvHybridCiphertext,
        shared_secret: *mut [u8; QV_HYBRID_SS_SIZE],
    ) -> c_int;

    // Utility functions
    pub fn qv_secure_zero(ptr: *mut u8, len: usize);
    pub fn qv_constant_time_eq(a: *const u8, b: *const u8, len: usize) -> bool;
    pub fn qv_version() -> *const c_char;

    // Size query functions
    pub fn qv_mlkem768_ek_size() -> usize;
    pub fn qv_mlkem768_dk_size() -> usize;
    pub fn qv_mlkem768_ct_size() -> usize;
    pub fn qv_mlkem768_ss_size() -> usize;
    pub fn qv_mldsa65_pk_size() -> usize;
    pub fn qv_mldsa65_sk_size() -> usize;
    pub fn qv_mldsa65_sig_size() -> usize;
    pub fn qv_hybrid_ek_size() -> usize;
    pub fn qv_hybrid_dk_size() -> usize;
    pub fn qv_hybrid_ct_size() -> usize;
    pub fn qv_hybrid_ss_size() -> usize;
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_size_constants() {
        // Verify size constants match the C header
        assert_eq!(QV_MLKEM768_EK_SIZE, 1184);
        assert_eq!(QV_MLKEM768_DK_SIZE, 2400);
        assert_eq!(QV_MLKEM768_CT_SIZE, 1088);
        assert_eq!(QV_MLKEM768_SS_SIZE, 32);

        assert_eq!(QV_MLDSA65_PK_SIZE, 1952);
        assert_eq!(QV_MLDSA65_SK_SIZE, 4032);
        assert_eq!(QV_MLDSA65_SIG_SIZE, 3309);

        assert_eq!(QV_HYBRID_EK_SIZE, 1216);
        assert_eq!(QV_HYBRID_DK_SIZE, 2432);
        assert_eq!(QV_HYBRID_CT_SIZE, 1120);
        assert_eq!(QV_HYBRID_SS_SIZE, 32);
    }

    #[test]
    fn test_struct_sizes() {
        assert_eq!(std::mem::size_of::<QvMlKemEncapsKey>(), QV_MLKEM768_EK_SIZE);
        assert_eq!(std::mem::size_of::<QvMlKemDecapsKey>(), QV_MLKEM768_DK_SIZE);
        assert_eq!(std::mem::size_of::<QvMlKemCiphertext>(), QV_MLKEM768_CT_SIZE);

        assert_eq!(std::mem::size_of::<QvMlDsaPublicKey>(), QV_MLDSA65_PK_SIZE);
        assert_eq!(std::mem::size_of::<QvMlDsaSecretKey>(), QV_MLDSA65_SK_SIZE);
        assert_eq!(std::mem::size_of::<QvMlDsaSignature>(), QV_MLDSA65_SIG_SIZE);

        assert_eq!(std::mem::size_of::<QvHybridEncapsKey>(), QV_HYBRID_EK_SIZE);
        assert_eq!(std::mem::size_of::<QvHybridDecapsKey>(), QV_HYBRID_DK_SIZE);
        assert_eq!(std::mem::size_of::<QvHybridCiphertext>(), QV_HYBRID_CT_SIZE);
    }
}
