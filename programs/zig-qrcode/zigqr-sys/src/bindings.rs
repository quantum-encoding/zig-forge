//! Raw FFI bindings to the ZigQR C API
//!
//! These are the unsafe, raw bindings. Use the safe wrappers in [`encoder`].

use std::os::raw::c_char;

/// Error correction level L (~7% recovery)
pub const ZIGQR_EC_L: i32 = 0;
/// Error correction level M (~15% recovery)
pub const ZIGQR_EC_M: i32 = 1;
/// Error correction level Q (~25% recovery)
pub const ZIGQR_EC_Q: i32 = 2;
/// Error correction level H (~30% recovery)
pub const ZIGQR_EC_H: i32 = 3;

extern "C" {
    /// Encode data into a QR module matrix (flat array, 0=white, 1=black).
    pub fn zigqr_encode(
        data: *const u8,
        data_len: usize,
        ec_level: i32,
        size: *mut u32,
    ) -> *mut u8;

    /// Render QR modules to RGB pixel data with 8-byte header.
    pub fn zigqr_render_rgb(
        modules: *const u8,
        size: u32,
        module_px: u32,
        quiet_zone: u32,
        output_len: *mut usize,
    ) -> *mut u8;

    /// Render QR modules to SVG string.
    pub fn zigqr_render_svg(
        modules: *const u8,
        size: u32,
        module_px: u32,
        quiet_zone: u32,
        output_len: *mut usize,
    ) -> *mut u8;

    /// Render QR modules to PNG bytes.
    pub fn zigqr_render_png(
        modules: *const u8,
        size: u32,
        module_px: u32,
        quiet_zone: u32,
        output_len: *mut usize,
    ) -> *mut u8;

    /// One-shot: encode data and render to SVG.
    pub fn zigqr_to_svg(
        data: *const u8,
        data_len: usize,
        ec_level: i32,
        output_len: *mut usize,
    ) -> *mut u8;

    /// One-shot: encode data and render to PNG.
    pub fn zigqr_to_png(
        data: *const u8,
        data_len: usize,
        ec_level: i32,
        output_len: *mut usize,
    ) -> *mut u8;

    /// Free a buffer allocated by zigqr functions.
    pub fn zigqr_free(ptr: *mut u8, len: usize);

    /// Get library version string.
    pub fn zigqr_version() -> *const c_char;

    /// Get last error message.
    pub fn zigqr_get_error() -> *const c_char;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ec_level_constants() {
        assert_eq!(ZIGQR_EC_L, 0);
        assert_eq!(ZIGQR_EC_M, 1);
        assert_eq!(ZIGQR_EC_Q, 2);
        assert_eq!(ZIGQR_EC_H, 3);
    }
}
