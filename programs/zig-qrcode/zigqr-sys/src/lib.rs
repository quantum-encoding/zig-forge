//! ZigQR - High-Performance QR Code Generator
//!
//! This crate provides safe Rust bindings to the ZigQR library,
//! a pure Zig implementation of ISO/IEC 18004 QR codes.
//!
//! # Features
//!
//! - **Versions 1-40** with automatic version selection
//! - **3 encoding modes**: numeric, alphanumeric, byte (auto-detected)
//! - **4 error correction levels**: L (~7%), M (~15%), Q (~25%), H (~30%)
//! - **Multiple output formats**: raw matrix, RGB pixels, SVG, PNG
//! - **Zero external dependencies** in the core library
//!
//! # Example
//!
//! ```no_run
//! use zigqr_sys::{QrEncoder, EcLevel};
//!
//! // One-shot PNG generation
//! let png = QrEncoder::new()
//!     .ec_level(EcLevel::H)
//!     .to_png(b"https://example.com")
//!     .unwrap();
//! std::fs::write("qr.png", &png).unwrap();
//!
//! // SVG output
//! let svg = QrEncoder::new()
//!     .to_svg(b"Hello World")
//!     .unwrap();
//!
//! // Two-step: encode then render
//! let matrix = QrEncoder::new()
//!     .ec_level(EcLevel::M)
//!     .encode(b"data")
//!     .unwrap();
//! println!("QR version uses {}x{} modules", matrix.size, matrix.size);
//! let png = matrix.render_png(8, 4).unwrap();
//! ```

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod bindings;
pub mod encoder;
pub mod error;

pub use encoder::{EcLevel, QrEncoder, QrMatrix};
pub use error::{QrError, Result};

use std::ffi::CStr;

/// Get the library version string
pub fn version() -> &'static str {
    unsafe {
        let ptr = bindings::zigqr_version();
        if ptr.is_null() {
            "unknown"
        } else {
            CStr::from_ptr(ptr).to_str().unwrap_or("unknown")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        let v = version();
        assert!(!v.is_empty());
        assert!(v.starts_with("1."));
    }

    #[test]
    fn test_full_flow() {
        // Encode
        let encoder = QrEncoder::new().ec_level(EcLevel::M);
        let matrix = encoder.encode(b"https://example.com").unwrap();
        assert!(matrix.size >= 21);

        // Check module access
        assert!(matrix.get(0, 0)); // finder pattern top-left is always black

        // Render to different formats
        let _svg = matrix.render_svg(4, 4).unwrap();
        let png = matrix.render_png(4, 4).unwrap();
        assert!(!png.is_empty());
    }
}
