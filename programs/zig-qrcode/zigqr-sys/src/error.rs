//! Error types for zigqr-sys

use std::fmt;

/// Errors from QR code operations
#[derive(Debug, Clone)]
pub enum QrError {
    /// QR encoding failed (data too large, invalid parameters, etc.)
    EncodingFailed(String),
    /// Rendering failed (SVG, PNG, or RGB generation error)
    RenderFailed(String),
    /// Input data exceeds maximum QR code capacity
    DataTooLarge,
    /// Null pointer returned from library (unknown error)
    NullResult,
}

impl fmt::Display for QrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QrError::EncodingFailed(msg) => write!(f, "QR encoding failed: {}", msg),
            QrError::RenderFailed(msg) => write!(f, "QR rendering failed: {}", msg),
            QrError::DataTooLarge => write!(f, "data exceeds maximum QR code capacity"),
            QrError::NullResult => write!(f, "QR operation returned null"),
        }
    }
}

impl std::error::Error for QrError {}

/// Result type alias for QR operations
pub type Result<T> = std::result::Result<T, QrError>;
