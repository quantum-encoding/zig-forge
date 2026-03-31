//! Safe Rust wrapper for ZigQR with builder pattern

use crate::bindings;
use crate::error::{QrError, Result};
use std::ffi::CStr;

/// Error correction level
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EcLevel {
    /// ~7% recovery
    L,
    /// ~15% recovery (default)
    M,
    /// ~25% recovery
    Q,
    /// ~30% recovery
    H,
}

impl EcLevel {
    fn to_raw(self) -> i32 {
        match self {
            EcLevel::L => bindings::ZIGQR_EC_L,
            EcLevel::M => bindings::ZIGQR_EC_M,
            EcLevel::Q => bindings::ZIGQR_EC_Q,
            EcLevel::H => bindings::ZIGQR_EC_H,
        }
    }
}

/// RAII wrapper for buffers allocated by zigqr
struct ZigQrBuf {
    ptr: *mut u8,
    len: usize,
}

impl ZigQrBuf {
    fn new(ptr: *mut u8, len: usize) -> Self {
        Self { ptr, len }
    }

    fn as_slice(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for ZigQrBuf {
    fn drop(&mut self) {
        if !self.ptr.is_null() && self.len > 0 {
            unsafe {
                bindings::zigqr_free(self.ptr, self.len);
            }
        }
    }
}

/// Raw QR code module matrix
pub struct QrMatrix {
    buf: ZigQrBuf,
    /// Matrix dimension (size x size modules)
    pub size: u32,
}

impl QrMatrix {
    /// Get the raw module data (0=white, 1=black)
    pub fn modules(&self) -> &[u8] {
        self.buf.as_slice()
    }

    /// Get module at (x, y). Returns true for black modules.
    pub fn get(&self, x: u32, y: u32) -> bool {
        if x >= self.size || y >= self.size {
            return false;
        }
        self.buf.as_slice()[(y * self.size + x) as usize] != 0
    }

    /// Render this matrix to RGB pixels
    pub fn render_rgb(&self, module_px: u32, quiet_zone: u32) -> Result<Vec<u8>> {
        let mut len: usize = 0;
        let ptr = unsafe {
            bindings::zigqr_render_rgb(
                self.buf.ptr,
                self.size,
                module_px,
                quiet_zone,
                &mut len,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("RGB render failed"));
        }
        let buf = ZigQrBuf::new(ptr, len);
        Ok(buf.as_slice().to_vec())
    }

    /// Render this matrix to SVG string
    pub fn render_svg(&self, module_px: u32, quiet_zone: u32) -> Result<String> {
        let mut len: usize = 0;
        let ptr = unsafe {
            bindings::zigqr_render_svg(
                self.buf.ptr,
                self.size,
                module_px,
                quiet_zone,
                &mut len,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("SVG render failed"));
        }
        let buf = ZigQrBuf::new(ptr, len);
        Ok(String::from_utf8_lossy(buf.as_slice()).into_owned())
    }

    /// Render this matrix to PNG bytes
    pub fn render_png(&self, module_px: u32, quiet_zone: u32) -> Result<Vec<u8>> {
        let mut len: usize = 0;
        let ptr = unsafe {
            bindings::zigqr_render_png(
                self.buf.ptr,
                self.size,
                module_px,
                quiet_zone,
                &mut len,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("PNG render failed"));
        }
        let buf = ZigQrBuf::new(ptr, len);
        Ok(buf.as_slice().to_vec())
    }
}

/// QR code encoder with builder pattern
///
/// # Example
///
/// ```no_run
/// use zigqr_sys::{QrEncoder, EcLevel};
///
/// let png = QrEncoder::new()
///     .ec_level(EcLevel::H)
///     .module_size(8)
///     .to_png(b"https://example.com")
///     .unwrap();
/// std::fs::write("qr.png", &png).unwrap();
/// ```
pub struct QrEncoder {
    ec_level: EcLevel,
    module_size: u32,
    quiet_zone: u32,
}

impl QrEncoder {
    /// Create a new encoder with default settings (EC=M, module_size=4, quiet_zone=4)
    pub fn new() -> Self {
        Self {
            ec_level: EcLevel::M,
            module_size: 4,
            quiet_zone: 4,
        }
    }

    /// Set error correction level
    pub fn ec_level(mut self, level: EcLevel) -> Self {
        self.ec_level = level;
        self
    }

    /// Set module size in pixels (for rendering)
    pub fn module_size(mut self, size: u32) -> Self {
        self.module_size = size;
        self
    }

    /// Set quiet zone border (in modules)
    pub fn quiet_zone(mut self, zone: u32) -> Self {
        self.quiet_zone = zone;
        self
    }

    /// Encode data to a QR module matrix
    pub fn encode(&self, data: &[u8]) -> Result<QrMatrix> {
        let mut size: u32 = 0;
        let ptr = unsafe {
            bindings::zigqr_encode(
                data.as_ptr(),
                data.len(),
                self.ec_level.to_raw(),
                &mut size,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("Encoding failed"));
        }
        let total = (size as usize) * (size as usize);
        Ok(QrMatrix {
            buf: ZigQrBuf::new(ptr, total),
            size,
        })
    }

    /// Encode data and render directly to SVG string
    pub fn to_svg(&self, data: &[u8]) -> Result<String> {
        let mut len: usize = 0;
        let ptr = unsafe {
            bindings::zigqr_to_svg(
                data.as_ptr(),
                data.len(),
                self.ec_level.to_raw(),
                &mut len,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("SVG generation failed"));
        }
        let buf = ZigQrBuf::new(ptr, len);
        Ok(String::from_utf8_lossy(buf.as_slice()).into_owned())
    }

    /// Encode data and render directly to PNG bytes
    pub fn to_png(&self, data: &[u8]) -> Result<Vec<u8>> {
        let mut len: usize = 0;
        let ptr = unsafe {
            bindings::zigqr_to_png(
                data.as_ptr(),
                data.len(),
                self.ec_level.to_raw(),
                &mut len,
            )
        };
        if ptr.is_null() {
            return Err(get_last_error("PNG generation failed"));
        }
        let buf = ZigQrBuf::new(ptr, len);
        Ok(buf.as_slice().to_vec())
    }
}

impl Default for QrEncoder {
    fn default() -> Self {
        Self::new()
    }
}

fn get_last_error(fallback: &str) -> QrError {
    let msg = unsafe {
        let ptr = bindings::zigqr_get_error();
        if ptr.is_null() {
            fallback.to_string()
        } else {
            CStr::from_ptr(ptr)
                .to_str()
                .unwrap_or(fallback)
                .to_string()
        }
    };
    if msg.is_empty() {
        QrError::NullResult
    } else {
        QrError::EncodingFailed(msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode() {
        let matrix = QrEncoder::new()
            .ec_level(EcLevel::M)
            .encode(b"Hello World")
            .expect("encode should succeed");
        assert!(matrix.size >= 21); // minimum v1
        assert!(matrix.size <= 177); // maximum v40
        assert_eq!(matrix.modules().len(), (matrix.size * matrix.size) as usize);
    }

    #[test]
    fn test_to_svg() {
        let svg = QrEncoder::new()
            .to_svg(b"test")
            .expect("SVG should succeed");
        assert!(svg.starts_with("<svg"));
        assert!(svg.contains("path"));
    }

    #[test]
    fn test_to_png() {
        let png = QrEncoder::new()
            .to_png(b"test")
            .expect("PNG should succeed");
        assert!(png.len() > 50);
        assert_eq!(&png[0..4], &[0x89, 0x50, 0x4E, 0x47]); // PNG signature
    }

    #[test]
    fn test_matrix_render_svg() {
        let matrix = QrEncoder::new().encode(b"test").unwrap();
        let svg = matrix.render_svg(4, 4).expect("render SVG should work");
        assert!(svg.starts_with("<svg"));
    }

    #[test]
    fn test_matrix_render_png() {
        let matrix = QrEncoder::new().encode(b"test").unwrap();
        let png = matrix.render_png(4, 4).expect("render PNG should work");
        assert_eq!(&png[0..4], &[0x89, 0x50, 0x4E, 0x47]);
    }

    #[test]
    fn test_builder_pattern() {
        let encoder = QrEncoder::new()
            .ec_level(EcLevel::H)
            .module_size(8)
            .quiet_zone(2);
        let svg = encoder.to_svg(b"builder test").expect("should work");
        assert!(!svg.is_empty());
    }
}
