//! Error types for Quantum Vault operations
//!
//! Provides safe Rust error types that map to the C API error codes.

use std::os::raw::c_int;
use thiserror::Error;

use crate::bindings::*;

/// Result type for Quantum Vault operations
pub type Result<T> = std::result::Result<T, QvError>;

/// Error types for Quantum Vault operations
#[derive(Error, Debug, Clone, Copy, PartialEq, Eq)]
pub enum QvError {
    // General errors
    #[error("Invalid parameter")]
    InvalidParameter,

    #[error("Random number generation failed")]
    RngFailure,

    #[error("Memory allocation error")]
    MemoryError,

    // ML-KEM errors
    #[error("Invalid ML-KEM encapsulation key")]
    MlKemInvalidEk,

    #[error("Invalid ML-KEM decapsulation key")]
    MlKemInvalidDk,

    #[error("Invalid ML-KEM ciphertext")]
    MlKemInvalidCt,

    #[error("ML-KEM encapsulation failed")]
    MlKemEncapsFailed,

    #[error("ML-KEM decapsulation failed")]
    MlKemDecapsFailed,

    #[error("ML-KEM key generation failed")]
    MlKemKeygenFailed,

    // ML-DSA errors
    #[error("Invalid ML-DSA public key")]
    MlDsaInvalidPk,

    #[error("Invalid ML-DSA secret key")]
    MlDsaInvalidSk,

    #[error("Invalid ML-DSA signature")]
    MlDsaInvalidSig,

    #[error("ML-DSA signing failed")]
    MlDsaSigningFailed,

    #[error("ML-DSA signature verification failed")]
    MlDsaVerificationFailed,

    #[error("ML-DSA key generation failed")]
    MlDsaKeygenFailed,

    // Hybrid errors
    #[error("Hybrid key generation failed")]
    HybridKeygenFailed,

    #[error("Hybrid encapsulation failed")]
    HybridEncapsFailed,

    #[error("Hybrid decapsulation failed")]
    HybridDecapsFailed,

    #[error("Invalid hybrid public key")]
    HybridInvalidPk,

    // Unknown error
    #[error("Unknown error code: {0}")]
    Unknown(c_int),
}

impl From<c_int> for QvError {
    fn from(code: c_int) -> Self {
        match code {
            QV_INVALID_PARAMETER => QvError::InvalidParameter,
            QV_RNG_FAILURE => QvError::RngFailure,
            QV_MEMORY_ERROR => QvError::MemoryError,

            QV_MLKEM_INVALID_EK => QvError::MlKemInvalidEk,
            QV_MLKEM_INVALID_DK => QvError::MlKemInvalidDk,
            QV_MLKEM_INVALID_CT => QvError::MlKemInvalidCt,
            QV_MLKEM_ENCAPS_FAILED => QvError::MlKemEncapsFailed,
            QV_MLKEM_DECAPS_FAILED => QvError::MlKemDecapsFailed,
            QV_MLKEM_KEYGEN_FAILED => QvError::MlKemKeygenFailed,

            QV_MLDSA_INVALID_PK => QvError::MlDsaInvalidPk,
            QV_MLDSA_INVALID_SK => QvError::MlDsaInvalidSk,
            QV_MLDSA_INVALID_SIG => QvError::MlDsaInvalidSig,
            QV_MLDSA_SIGNING_FAILED => QvError::MlDsaSigningFailed,
            QV_MLDSA_VERIFICATION_FAILED => QvError::MlDsaVerificationFailed,
            QV_MLDSA_KEYGEN_FAILED => QvError::MlDsaKeygenFailed,

            QV_HYBRID_KEYGEN_FAILED => QvError::HybridKeygenFailed,
            QV_HYBRID_ENCAPS_FAILED => QvError::HybridEncapsFailed,
            QV_HYBRID_DECAPS_FAILED => QvError::HybridDecapsFailed,
            QV_HYBRID_INVALID_PK => QvError::HybridInvalidPk,

            _ => QvError::Unknown(code),
        }
    }
}

impl QvError {
    /// Convert FFI result code to Result
    pub fn from_code(code: c_int) -> std::result::Result<(), Self> {
        if code == QV_SUCCESS {
            Ok(())
        } else {
            Err(Self::from(code))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_conversion() {
        assert_eq!(QvError::from(QV_SUCCESS), QvError::Unknown(0));
        assert_eq!(QvError::from(QV_INVALID_PARAMETER), QvError::InvalidParameter);
        assert_eq!(QvError::from(QV_RNG_FAILURE), QvError::RngFailure);
        assert_eq!(QvError::from(QV_MLKEM_KEYGEN_FAILED), QvError::MlKemKeygenFailed);
        assert_eq!(QvError::from(QV_MLDSA_VERIFICATION_FAILED), QvError::MlDsaVerificationFailed);
        assert_eq!(QvError::from(QV_HYBRID_DECAPS_FAILED), QvError::HybridDecapsFailed);
        assert_eq!(QvError::from(-100), QvError::Unknown(-100));
    }

    #[test]
    fn test_from_code() {
        assert!(QvError::from_code(QV_SUCCESS).is_ok());
        assert!(QvError::from_code(QV_INVALID_PARAMETER).is_err());
    }
}
