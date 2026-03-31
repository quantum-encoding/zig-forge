//! ML-KEM-768 (FIPS 203) safe wrappers
//!
//! Provides safe Rust wrappers for the ML-KEM-768 post-quantum key encapsulation mechanism.

use std::mem::MaybeUninit;

use crate::bindings::{self, *};
use crate::error::{QvError, Result};
use crate::secure::SecureBytes;

/// ML-KEM-768 encapsulation key (public key)
#[derive(Clone)]
pub struct MlKemEncapsKey {
    inner: QvMlKemEncapsKey,
}

impl MlKemEncapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLKEM768_EK_SIZE]) -> Self {
        Self {
            inner: QvMlKemEncapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLKEM768_EK_SIZE] {
        &self.inner.bytes
    }

    /// Encapsulate a shared secret for this public key
    pub fn encaps(&self) -> Result<MlKemEncapsResult> {
        let mut result = MaybeUninit::<QvMlKemEncapsResult>::uninit();
        let code = unsafe { bindings::qv_mlkem768_encaps(&self.inner, result.as_mut_ptr()) };
        QvError::from_code(code)?;
        let result = unsafe { result.assume_init() };
        Ok(MlKemEncapsResult {
            shared_secret: SecureBytes::from_array(result.shared_secret),
            ciphertext: MlKemCiphertext {
                inner: result.ciphertext,
            },
        })
    }
}

impl AsRef<[u8]> for MlKemEncapsKey {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// ML-KEM-768 decapsulation key (private key)
///
/// This type is automatically zeroed when dropped.
#[derive(Clone)]
pub struct MlKemDecapsKey {
    inner: QvMlKemDecapsKey,
}

impl MlKemDecapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLKEM768_DK_SIZE]) -> Self {
        Self {
            inner: QvMlKemDecapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLKEM768_DK_SIZE] {
        &self.inner.bytes
    }

    /// Decapsulate a ciphertext to recover the shared secret
    pub fn decaps(&self, ciphertext: &MlKemCiphertext) -> Result<SecureBytes<QV_MLKEM768_SS_SIZE>> {
        let mut shared_secret = [0u8; QV_MLKEM768_SS_SIZE];
        let code = unsafe {
            bindings::qv_mlkem768_decaps(&self.inner, &ciphertext.inner, &mut shared_secret)
        };
        QvError::from_code(code)?;
        Ok(SecureBytes::from_array(shared_secret))
    }
}

impl Drop for MlKemDecapsKey {
    fn drop(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.inner.bytes.as_mut_ptr(), QV_MLKEM768_DK_SIZE);
        }
    }
}

/// ML-KEM-768 key pair
pub struct MlKemKeyPair {
    /// Encapsulation key (public)
    pub ek: MlKemEncapsKey,
    /// Decapsulation key (private)
    pub dk: MlKemDecapsKey,
}

impl MlKemKeyPair {
    /// Generate a new key pair
    pub fn generate() -> Result<Self> {
        let mut keypair = MaybeUninit::<QvMlKemKeyPair>::uninit();
        let code = unsafe { bindings::qv_mlkem768_keygen(keypair.as_mut_ptr()) };
        QvError::from_code(code)?;
        let keypair = unsafe { keypair.assume_init() };
        Ok(Self {
            ek: MlKemEncapsKey { inner: keypair.ek },
            dk: MlKemDecapsKey { inner: keypair.dk },
        })
    }

    /// Get the encapsulation key (public key)
    pub fn encaps_key(&self) -> &MlKemEncapsKey {
        &self.ek
    }

    /// Get the decapsulation key (private key)
    pub fn decaps_key(&self) -> &MlKemDecapsKey {
        &self.dk
    }
}

/// ML-KEM-768 ciphertext
#[derive(Clone)]
pub struct MlKemCiphertext {
    inner: QvMlKemCiphertext,
}

impl MlKemCiphertext {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLKEM768_CT_SIZE]) -> Self {
        Self {
            inner: QvMlKemCiphertext { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLKEM768_CT_SIZE] {
        &self.inner.bytes
    }
}

impl AsRef<[u8]> for MlKemCiphertext {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// Result of ML-KEM-768 encapsulation
pub struct MlKemEncapsResult {
    /// The shared secret (32 bytes)
    pub shared_secret: SecureBytes<QV_MLKEM768_SS_SIZE>,
    /// The ciphertext to send to the recipient
    pub ciphertext: MlKemCiphertext,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen() {
        let keypair = MlKemKeyPair::generate().expect("keygen should succeed");
        assert_eq!(keypair.ek.as_bytes().len(), QV_MLKEM768_EK_SIZE);
        assert_eq!(keypair.dk.as_bytes().len(), QV_MLKEM768_DK_SIZE);
    }

    #[test]
    fn test_encaps_decaps() {
        // Generate key pair
        let keypair = MlKemKeyPair::generate().expect("keygen should succeed");

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
        let keypair = MlKemKeyPair::generate().expect("keygen should succeed");

        // Export and reimport encaps key
        let ek_bytes = keypair.ek.as_bytes();
        let ek2 = MlKemEncapsKey::from_bytes(ek_bytes);

        // Encaps with reimported key should work
        let result = ek2.encaps().expect("encaps should succeed");
        let ss = keypair.dk.decaps(&result.ciphertext).expect("decaps should succeed");
        assert_eq!(result.shared_secret.as_bytes(), ss.as_bytes());
    }
}
