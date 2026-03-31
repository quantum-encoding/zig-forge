//! Hybrid ML-KEM-768 + X25519 safe wrappers
//!
//! Provides safe Rust wrappers for the hybrid key encapsulation mechanism that combines
//! post-quantum ML-KEM-768 with classical X25519 for defense-in-depth.

use std::mem::MaybeUninit;

use crate::bindings::{self, *};
use crate::error::{QvError, Result};
use crate::secure::SecureBytes;

/// Hybrid encapsulation key (public key)
///
/// This combines an ML-KEM-768 public key with an X25519 public key.
#[derive(Clone)]
pub struct HybridEncapsKey {
    inner: QvHybridEncapsKey,
}

impl HybridEncapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_EK_SIZE]) -> Self {
        Self {
            inner: QvHybridEncapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_EK_SIZE] {
        &self.inner.bytes
    }

    /// Encapsulate a shared secret for this public key
    ///
    /// This performs both ML-KEM encapsulation and X25519 key agreement,
    /// combining the results with SHA3-256.
    pub fn encaps(&self) -> Result<HybridEncapsResult> {
        let mut result = MaybeUninit::<QvHybridEncapsResult>::uninit();
        let code = unsafe { bindings::qv_hybrid_encaps(&self.inner, result.as_mut_ptr()) };
        QvError::from_code(code)?;
        let result = unsafe { result.assume_init() };
        Ok(HybridEncapsResult {
            shared_secret: SecureBytes::from_array(result.shared_secret),
            ciphertext: HybridCiphertext {
                inner: result.ciphertext,
            },
        })
    }
}

impl AsRef<[u8]> for HybridEncapsKey {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// Hybrid decapsulation key (private key)
///
/// This type is automatically zeroed when dropped.
#[derive(Clone)]
pub struct HybridDecapsKey {
    inner: QvHybridDecapsKey,
}

impl HybridDecapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_DK_SIZE]) -> Self {
        Self {
            inner: QvHybridDecapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_DK_SIZE] {
        &self.inner.bytes
    }

    /// Decapsulate a ciphertext to recover the shared secret
    ///
    /// This performs both ML-KEM decapsulation and X25519 key agreement,
    /// combining the results with SHA3-256.
    pub fn decaps(&self, ciphertext: &HybridCiphertext) -> Result<SecureBytes<QV_HYBRID_SS_SIZE>> {
        let mut shared_secret = [0u8; QV_HYBRID_SS_SIZE];
        let code = unsafe {
            bindings::qv_hybrid_decaps(&self.inner, &ciphertext.inner, &mut shared_secret)
        };
        QvError::from_code(code)?;
        Ok(SecureBytes::from_array(shared_secret))
    }
}

impl Drop for HybridDecapsKey {
    fn drop(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.inner.bytes.as_mut_ptr(), QV_HYBRID_DK_SIZE);
        }
    }
}

/// Hybrid key pair
pub struct HybridKeyPair {
    /// Encapsulation key (public)
    pub ek: HybridEncapsKey,
    /// Decapsulation key (private)
    pub dk: HybridDecapsKey,
}

impl HybridKeyPair {
    /// Generate a new hybrid key pair
    pub fn generate() -> Result<Self> {
        let mut keypair = MaybeUninit::<QvHybridKeyPair>::uninit();
        let code = unsafe { bindings::qv_hybrid_keygen(keypair.as_mut_ptr()) };
        QvError::from_code(code)?;
        let keypair = unsafe { keypair.assume_init() };
        Ok(Self {
            ek: HybridEncapsKey { inner: keypair.ek },
            dk: HybridDecapsKey { inner: keypair.dk },
        })
    }

    /// Get the encapsulation key (public key)
    pub fn encaps_key(&self) -> &HybridEncapsKey {
        &self.ek
    }

    /// Get the decapsulation key (private key)
    pub fn decaps_key(&self) -> &HybridDecapsKey {
        &self.dk
    }
}

/// Hybrid ciphertext
#[derive(Clone)]
pub struct HybridCiphertext {
    inner: QvHybridCiphertext,
}

impl HybridCiphertext {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_CT_SIZE]) -> Self {
        Self {
            inner: QvHybridCiphertext { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_CT_SIZE] {
        &self.inner.bytes
    }
}

impl AsRef<[u8]> for HybridCiphertext {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// Result of hybrid encapsulation
pub struct HybridEncapsResult {
    /// The combined shared secret (32 bytes)
    pub shared_secret: SecureBytes<QV_HYBRID_SS_SIZE>,
    /// The ciphertext to send to the recipient
    pub ciphertext: HybridCiphertext,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");
        assert_eq!(keypair.ek.as_bytes().len(), QV_HYBRID_EK_SIZE);
        assert_eq!(keypair.dk.as_bytes().len(), QV_HYBRID_DK_SIZE);
    }

    #[test]
    fn test_encaps_decaps() {
        // Generate key pair
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");

        // Encapsulate
        let encaps_result = keypair.ek.encaps().expect("encaps should succeed");

        // Decapsulate
        let shared_secret = keypair
            .dk
            .decaps(&encaps_result.ciphertext)
            .expect("decaps should succeed");

        // Verify shared secrets match
        assert_eq!(
            encaps_result.shared_secret.as_bytes(),
            shared_secret.as_bytes()
        );
    }

    #[test]
    fn test_key_roundtrip() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");

        // Export and reimport encaps key
        let ek_bytes = keypair.ek.as_bytes();
        let ek2 = HybridEncapsKey::from_bytes(ek_bytes);

        // Encaps with reimported key should work
        let result = ek2.encaps().expect("encaps should succeed");
        let ss = keypair.dk.decaps(&result.ciphertext).expect("decaps should succeed");
        assert_eq!(result.shared_secret.as_bytes(), ss.as_bytes());
    }

    #[test]
    fn test_ciphertext_size() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");
        let result = keypair.ek.encaps().expect("encaps should succeed");

        // Hybrid ciphertext = ML-KEM ciphertext (1088) + X25519 public key (32) = 1120
        assert_eq!(result.ciphertext.as_bytes().len(), QV_HYBRID_CT_SIZE);
        assert_eq!(QV_HYBRID_CT_SIZE, 1120);
    }
}
