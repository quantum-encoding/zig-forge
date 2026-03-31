//! ML-DSA-65 (FIPS 204) safe wrappers
//!
//! Provides safe Rust wrappers for the ML-DSA-65 post-quantum digital signature algorithm.

use std::mem::MaybeUninit;

use crate::bindings::{self, *};
use crate::error::{QvError, Result};

/// ML-DSA-65 public key
#[derive(Clone)]
pub struct MlDsaPublicKey {
    inner: QvMlDsaPublicKey,
}

impl MlDsaPublicKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_PK_SIZE]) -> Self {
        Self {
            inner: QvMlDsaPublicKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_PK_SIZE] {
        &self.inner.bytes
    }

    /// Verify a signature
    pub fn verify(&self, message: &[u8], signature: &MlDsaSignature) -> Result<()> {
        let code = unsafe {
            bindings::qv_mldsa65_verify(
                &self.inner,
                message.as_ptr(),
                message.len(),
                &signature.inner,
            )
        };
        QvError::from_code(code)
    }

    /// Verify a signature, returning bool instead of Result
    pub fn verify_bool(&self, message: &[u8], signature: &MlDsaSignature) -> bool {
        self.verify(message, signature).is_ok()
    }
}

impl AsRef<[u8]> for MlDsaPublicKey {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// ML-DSA-65 secret key
///
/// This type is automatically zeroed when dropped.
#[derive(Clone)]
pub struct MlDsaSecretKey {
    inner: QvMlDsaSecretKey,
}

impl MlDsaSecretKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_SK_SIZE]) -> Self {
        Self {
            inner: QvMlDsaSecretKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_SK_SIZE] {
        &self.inner.bytes
    }

    /// Sign a message with randomization (hedged signature)
    pub fn sign(&self, message: &[u8]) -> Result<MlDsaSignature> {
        self.sign_with_mode(message, true)
    }

    /// Sign a message deterministically
    pub fn sign_deterministic(&self, message: &[u8]) -> Result<MlDsaSignature> {
        self.sign_with_mode(message, false)
    }

    /// Sign a message with explicit randomization mode
    fn sign_with_mode(&self, message: &[u8], randomized: bool) -> Result<MlDsaSignature> {
        let mut signature = MaybeUninit::<QvMlDsaSignature>::uninit();
        let code = unsafe {
            bindings::qv_mldsa65_sign(
                &self.inner,
                message.as_ptr(),
                message.len(),
                signature.as_mut_ptr(),
                randomized,
            )
        };
        QvError::from_code(code)?;
        let signature = unsafe { signature.assume_init() };
        Ok(MlDsaSignature { inner: signature })
    }
}

impl Drop for MlDsaSecretKey {
    fn drop(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.inner.bytes.as_mut_ptr(), QV_MLDSA65_SK_SIZE);
        }
    }
}

/// ML-DSA-65 key pair
pub struct MlDsaKeyPair {
    /// Public key
    pub pk: MlDsaPublicKey,
    /// Secret key
    pub sk: MlDsaSecretKey,
}

impl MlDsaKeyPair {
    /// Generate a new key pair from random seed
    pub fn generate() -> Result<Self> {
        Self::generate_from_seed(None)
    }

    /// Generate a key pair from a specific seed (for deterministic key generation)
    pub fn generate_from_seed(seed: Option<&[u8; QV_MLDSA65_SEED_SIZE]>) -> Result<Self> {
        let mut keypair = MaybeUninit::<QvMlDsaKeyPair>::uninit();
        let seed_ptr = seed.map(|s| s as *const _).unwrap_or(std::ptr::null());
        let code = unsafe { bindings::qv_mldsa65_keygen(keypair.as_mut_ptr(), seed_ptr) };
        QvError::from_code(code)?;
        let keypair = unsafe { keypair.assume_init() };
        Ok(Self {
            pk: MlDsaPublicKey { inner: keypair.pk },
            sk: MlDsaSecretKey { inner: keypair.sk },
        })
    }

    /// Get the public key
    pub fn public_key(&self) -> &MlDsaPublicKey {
        &self.pk
    }

    /// Get the secret key
    pub fn secret_key(&self) -> &MlDsaSecretKey {
        &self.sk
    }
}

/// ML-DSA-65 signature
#[derive(Clone)]
pub struct MlDsaSignature {
    inner: QvMlDsaSignature,
}

impl MlDsaSignature {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_SIG_SIZE]) -> Self {
        Self {
            inner: QvMlDsaSignature { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_SIG_SIZE] {
        &self.inner.bytes
    }
}

impl AsRef<[u8]> for MlDsaSignature {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        assert_eq!(keypair.pk.as_bytes().len(), QV_MLDSA65_PK_SIZE);
        assert_eq!(keypair.sk.as_bytes().len(), QV_MLDSA65_SK_SIZE);
    }

    #[test]
    fn test_sign_verify() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Hello, quantum world!";

        // Sign
        let signature = keypair.sk.sign(message).expect("signing should succeed");

        // Verify
        keypair
            .pk
            .verify(message, &signature)
            .expect("verification should succeed");
    }

    #[test]
    fn test_sign_verify_deterministic() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Deterministic signature test";

        // Sign deterministically
        let sig1 = keypair
            .sk
            .sign_deterministic(message)
            .expect("signing should succeed");
        let sig2 = keypair
            .sk
            .sign_deterministic(message)
            .expect("signing should succeed");

        // Deterministic signatures should be identical
        assert_eq!(sig1.as_bytes(), sig2.as_bytes());

        // Verify
        keypair.pk.verify(message, &sig1).expect("verification should succeed");
    }

    #[test]
    fn test_verify_wrong_message() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Original message";
        let wrong_message = b"Wrong message";

        let signature = keypair.sk.sign(message).expect("signing should succeed");

        // Verification should fail with wrong message
        assert!(keypair.pk.verify(wrong_message, &signature).is_err());
    }

    #[test]
    fn test_deterministic_keygen() {
        let seed = [42u8; QV_MLDSA65_SEED_SIZE];

        let kp1 = MlDsaKeyPair::generate_from_seed(Some(&seed)).expect("keygen should succeed");
        let kp2 = MlDsaKeyPair::generate_from_seed(Some(&seed)).expect("keygen should succeed");

        // Same seed should produce same keys
        assert_eq!(kp1.pk.as_bytes(), kp2.pk.as_bytes());
        assert_eq!(kp1.sk.as_bytes(), kp2.sk.as_bytes());
    }

    #[test]
    fn test_key_roundtrip() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Roundtrip test message";

        // Export and reimport public key
        let pk_bytes = keypair.pk.as_bytes();
        let pk2 = MlDsaPublicKey::from_bytes(pk_bytes);

        // Sign with original key, verify with reimported key
        let signature = keypair.sk.sign(message).expect("signing should succeed");
        pk2.verify(message, &signature).expect("verification should succeed");
    }
}
