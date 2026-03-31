//! Quantum Vault Post-Quantum Cryptography Library
//!
//! This crate provides safe Rust bindings to the Quantum Vault library,
//! implementing post-quantum cryptographic algorithms:
//!
//! - **ML-KEM-768** (FIPS 203): Post-quantum key encapsulation mechanism
//! - **ML-DSA-65** (FIPS 204): Post-quantum digital signature algorithm
//! - **Hybrid ML-KEM + X25519**: Defense-in-depth combining post-quantum and classical crypto
//!
//! # Example
//!
//! ```no_run
//! use quantum_vault_sys::{mlkem::MlKemKeyPair, mldsa::MlDsaKeyPair, hybrid::HybridKeyPair};
//!
//! // ML-KEM key encapsulation
//! let kp = MlKemKeyPair::generate().unwrap();
//! let encaps = kp.ek.encaps().unwrap();
//! let shared_secret = kp.dk.decaps(&encaps.ciphertext).unwrap();
//!
//! // ML-DSA digital signatures
//! let signing_kp = MlDsaKeyPair::generate().unwrap();
//! let signature = signing_kp.sk.sign(b"message").unwrap();
//! signing_kp.pk.verify(b"message", &signature).unwrap();
//!
//! // Hybrid encryption (ML-KEM + X25519)
//! let hybrid_kp = HybridKeyPair::generate().unwrap();
//! let hybrid_encaps = hybrid_kp.ek.encaps().unwrap();
//! let hybrid_ss = hybrid_kp.dk.decaps(&hybrid_encaps.ciphertext).unwrap();
//! ```
//!
//! # Security Considerations
//!
//! - All secret keys are automatically zeroed when dropped
//! - Use `SecureBytes` for handling sensitive data
//! - The hybrid scheme provides defense-in-depth against both classical and quantum attacks
//!
//! # Feature Flags
//!
//! - `prebuilt`: Use pre-built libraries instead of building from source

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod bindings;
pub mod error;
pub mod hybrid;
pub mod mlkem;
pub mod mldsa;
pub mod secure;

// Re-export main types at crate root for convenience
pub use error::{QvError, Result};
pub use secure::{SecureBytes, Seed, SharedSecret};

// Re-export key types
pub use hybrid::{HybridCiphertext, HybridDecapsKey, HybridEncapsKey, HybridEncapsResult, HybridKeyPair};
pub use mlkem::{MlKemCiphertext, MlKemDecapsKey, MlKemEncapsKey, MlKemEncapsResult, MlKemKeyPair};
pub use mldsa::{MlDsaKeyPair, MlDsaPublicKey, MlDsaSecretKey, MlDsaSignature};

// Re-export size constants
pub use bindings::{
    // ML-KEM sizes
    QV_MLKEM768_CT_SIZE,
    QV_MLKEM768_DK_SIZE,
    QV_MLKEM768_EK_SIZE,
    QV_MLKEM768_SS_SIZE,
    // ML-DSA sizes
    QV_MLDSA65_PK_SIZE,
    QV_MLDSA65_SEED_SIZE,
    QV_MLDSA65_SIG_SIZE,
    QV_MLDSA65_SK_SIZE,
    // Hybrid sizes
    QV_HYBRID_CT_SIZE,
    QV_HYBRID_DK_SIZE,
    QV_HYBRID_EK_SIZE,
    QV_HYBRID_SS_SIZE,
};

use std::ffi::CStr;

/// Get the library version string
pub fn version() -> &'static str {
    unsafe {
        let ptr = bindings::qv_version();
        if ptr.is_null() {
            "unknown"
        } else {
            CStr::from_ptr(ptr).to_str().unwrap_or("unknown")
        }
    }
}

/// Securely compare two byte slices in constant time
///
/// This function is resistant to timing attacks.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    unsafe { bindings::qv_constant_time_eq(a.as_ptr(), b.as_ptr(), a.len()) }
}

/// Securely zero a mutable byte slice
///
/// This function is resistant to compiler optimization that might
/// remove the zeroing operation.
pub fn secure_zero(data: &mut [u8]) {
    unsafe {
        bindings::qv_secure_zero(data.as_mut_ptr(), data.len());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        let v = version();
        assert!(!v.is_empty());
        assert!(v.contains('.') || v == "unknown");
    }

    #[test]
    fn test_constant_time_eq() {
        let a = [1u8, 2, 3, 4];
        let b = [1u8, 2, 3, 4];
        let c = [1u8, 2, 3, 5];

        assert!(constant_time_eq(&a, &b));
        assert!(!constant_time_eq(&a, &c));
        assert!(!constant_time_eq(&a, &[1, 2, 3])); // Different length
    }

    #[test]
    fn test_secure_zero() {
        let mut data = [42u8; 32];
        secure_zero(&mut data);
        assert!(data.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_mlkem_full_flow() {
        // Alice generates a key pair
        let alice_kp = MlKemKeyPair::generate().expect("keygen failed");

        // Alice sends her public key to Bob
        let alice_pk_bytes = alice_kp.ek.as_bytes();

        // Bob receives Alice's public key and encapsulates a shared secret
        let bob_pk = MlKemEncapsKey::from_bytes(alice_pk_bytes);
        let encaps_result = bob_pk.encaps().expect("encaps failed");

        // Bob sends the ciphertext to Alice
        let ct_bytes = encaps_result.ciphertext.as_bytes();

        // Alice receives the ciphertext and decapsulates to get the shared secret
        let alice_ct = MlKemCiphertext::from_bytes(ct_bytes);
        let alice_ss = alice_kp.dk.decaps(&alice_ct).expect("decaps failed");

        // Both parties now have the same shared secret
        assert_eq!(
            encaps_result.shared_secret.as_bytes(),
            alice_ss.as_bytes()
        );
    }

    #[test]
    fn test_mldsa_full_flow() {
        // Alice generates a signing key pair
        let alice_kp = MlDsaKeyPair::generate().expect("keygen failed");

        // Alice signs a message
        let message = b"Hello, this is a signed message!";
        let signature = alice_kp.sk.sign(message).expect("signing failed");

        // Alice publishes her public key
        let alice_pk_bytes = alice_kp.pk.as_bytes();

        // Bob receives Alice's public key and verifies the signature
        let alice_pk = MlDsaPublicKey::from_bytes(alice_pk_bytes);
        alice_pk.verify(message, &signature).expect("verification failed");

        // Tampering with the message should fail verification
        let tampered = b"Hello, this is a tampered message!";
        assert!(alice_pk.verify(tampered, &signature).is_err());
    }

    #[test]
    fn test_hybrid_full_flow() {
        // Alice generates a hybrid key pair
        let alice_kp = HybridKeyPair::generate().expect("keygen failed");

        // Alice sends her public key to Bob
        let alice_pk_bytes = alice_kp.ek.as_bytes();

        // Bob receives Alice's public key and encapsulates
        let bob_pk = HybridEncapsKey::from_bytes(alice_pk_bytes);
        let encaps_result = bob_pk.encaps().expect("encaps failed");

        // Bob sends the ciphertext to Alice
        let ct_bytes = encaps_result.ciphertext.as_bytes();

        // Alice decapsulates
        let alice_ct = HybridCiphertext::from_bytes(ct_bytes);
        let alice_ss = alice_kp.dk.decaps(&alice_ct).expect("decaps failed");

        // Shared secrets match
        assert_eq!(
            encaps_result.shared_secret.as_bytes(),
            alice_ss.as_bytes()
        );
    }
}
