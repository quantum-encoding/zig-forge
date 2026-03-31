//! Quantum Crypto FFI - Rust Bindings
//!
//! Usage in your Quantum Vault project:
//!
//! 1. Copy this file to: quantum-vault/ffi/quantum_crypto.rs
//!
//! 2. Add to Cargo.toml:
//!    ```toml
//!    [build-dependencies]
//!    cc = "1.0"
//!    ```
//!
//! 3. Create build.rs:
//!    ```rust
//!    fn main() {
//!        println!("cargo:rustc-link-search=native=/path/to/quantum-zig-forge/programs/simd_crypto_ffi/zig-out/lib");
//!        println!("cargo:rustc-link-lib=static=quantum_crypto");
//!    }
//!    ```
//!
//! 4. Use in your code:
//!    ```rust
//!    use quantum_crypto;
//!
//!    let hash = quantum_crypto::sha256(b"hello world");
//!    println!("SHA-256: {}", hex::encode(hash));
//!    ```

use std::ffi::CStr;

// =============================================================================
// FFI Declarations
// =============================================================================

#[link(name = "quantum_crypto", kind = "static")]
extern "C" {
    fn quantum_sha256(input: *const u8, input_len: usize, output: *mut u8) -> i32;
    fn quantum_sha256d(input: *const u8, input_len: usize, output: *mut u8) -> i32;
    fn quantum_blake3(input: *const u8, input_len: usize, output: *mut u8) -> i32;
    fn quantum_hmac_sha256(
        key: *const u8,
        key_len: usize,
        message: *const u8,
        message_len: usize,
        output: *mut u8,
    ) -> i32;
    fn quantum_pbkdf2_sha256(
        password: *const u8,
        password_len: usize,
        salt: *const u8,
        salt_len: usize,
        iterations: u32,
        output: *mut u8,
        output_len: usize,
    ) -> i32;
    fn quantum_secure_zero(ptr: *mut u8, len: usize);
    fn quantum_version() -> *const std::os::raw::c_char;
    fn quantum_get_error(buf: *mut u8, buf_size: usize) -> usize;
}

// =============================================================================
// Safe Rust Wrappers
// =============================================================================

/// Compute SHA-256 hash
///
/// # Examples
///
/// ```
/// let hash = quantum_crypto::sha256(b"hello world");
/// assert_eq!(hash.len(), 32);
/// ```
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    unsafe {
        quantum_sha256(data.as_ptr(), data.len(), output.as_mut_ptr());
    }
    output
}

/// Compute double SHA-256 (used in Bitcoin)
///
/// This is SHA-256(SHA-256(x)), used for:
/// - Block hashing
/// - Transaction IDs
/// - Bitcoin addresses
pub fn sha256d(data: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    unsafe {
        quantum_sha256d(data.as_ptr(), data.len(), output.as_mut_ptr());
    }
    output
}

/// Compute BLAKE3 hash (faster than SHA-256)
///
/// BLAKE3 is significantly faster and provides better security margins.
/// Use for:
/// - File integrity
/// - General-purpose hashing
/// - Seed phrase hashing
pub fn blake3(data: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    unsafe {
        quantum_blake3(data.as_ptr(), data.len(), output.as_mut_ptr());
    }
    output
}

/// Compute HMAC-SHA256
///
/// Used for:
/// - BIP32 HD wallet key derivation
/// - API request signing
/// - Message authentication
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    unsafe {
        quantum_hmac_sha256(
            key.as_ptr(),
            key.len(),
            message.as_ptr(),
            message.len(),
            output.as_mut_ptr(),
        );
    }
    output
}

/// Derive key from password using PBKDF2-SHA256
///
/// Used for BIP39: converting seed phrases to master keys.
///
/// # Arguments
///
/// * `password` - User password or seed phrase
/// * `salt` - Salt value (typically "mnemonic" + passphrase for BIP39)
/// * `iterations` - Number of iterations (recommend 100,000+ for security)
/// * `output_len` - Desired key length in bytes (typically 64 for BIP39)
///
/// # Examples
///
/// ```
/// // BIP39: Derive 512-bit seed from mnemonic
/// let mnemonic = "witch collapse practice feed shame open despair creek road again ice least";
/// let salt = "mnemonic"; // BIP39 uses "mnemonic" + optional passphrase
/// let seed = quantum_crypto::pbkdf2_sha256(mnemonic.as_bytes(), salt.as_bytes(), 2048, 64);
/// ```
pub fn pbkdf2_sha256(password: &[u8], salt: &[u8], iterations: u32, output_len: usize) -> Vec<u8> {
    let mut output = vec![0u8; output_len];
    unsafe {
        quantum_pbkdf2_sha256(
            password.as_ptr(),
            password.len(),
            salt.as_ptr(),
            salt.len(),
            iterations,
            output.as_mut_ptr(),
            output_len,
        );
    }
    output
}

/// Securely zero memory (prevents compiler optimization)
///
/// Use to erase sensitive data like private keys and passwords.
/// This is guaranteed not to be optimized away by the compiler.
///
/// # Safety
///
/// This function uses volatile writes to ensure the memory is actually zeroed.
pub fn secure_zero(data: &mut [u8]) {
    unsafe {
        quantum_secure_zero(data.as_mut_ptr(), data.len());
    }
}

/// Get library version
pub fn version() -> &'static str {
    unsafe {
        let ptr = quantum_version();
        CStr::from_ptr(ptr).to_str().unwrap_or("unknown")
    }
}

/// Get last error message
pub fn get_error() -> Option<String> {
    let mut buf = vec![0u8; 256];
    let len = unsafe { quantum_get_error(buf.as_mut_ptr(), buf.len()) };
    if len > 0 {
        String::from_utf8(buf[..len].to_vec()).ok()
    } else {
        None
    }
}

// =============================================================================
// RAII Wrapper for Secure Memory
// =============================================================================

/// Wrapper that automatically zeros memory on drop
///
/// Use this for sensitive data like private keys.
///
/// # Examples
///
/// ```
/// let mut key = SecureBytes::new(vec![1, 2, 3, 4, 5]);
/// // ... use key ...
/// // Automatically zeroed when dropped
/// ```
pub struct SecureBytes(Vec<u8>);

impl SecureBytes {
    pub fn new(data: Vec<u8>) -> Self {
        Self(data)
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        &mut self.0
    }
}

impl Drop for SecureBytes {
    fn drop(&mut self) {
        secure_zero(&mut self.0);
    }
}

impl std::ops::Deref for SecureBytes {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for SecureBytes {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sha256() {
        let hash = sha256(b"hello world");
        let expected = hex::decode("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9").unwrap();
        assert_eq!(&hash[..], &expected[..]);
    }

    #[test]
    fn test_blake3() {
        let hash = blake3(b"hello world");
        assert_ne!(&hash[..], &[0u8; 32][..]); // Not all zeros
    }

    #[test]
    fn test_hmac() {
        let mac = hmac_sha256(b"secret", b"hello world");
        assert_ne!(&mac[..], &[0u8; 32][..]);
    }

    #[test]
    fn test_secure_zero() {
        let mut data = vec![1, 2, 3, 4, 5];
        secure_zero(&mut data);
        assert_eq!(data, vec![0, 0, 0, 0, 0]);
    }

    #[test]
    fn test_secure_bytes_drop() {
        let mut secure = SecureBytes::new(vec![1, 2, 3, 4, 5]);
        assert_eq!(&secure[..], &[1, 2, 3, 4, 5]);
        drop(secure);
        // Memory should be zeroed (can't test directly as it's freed)
    }

    #[test]
    fn test_version() {
        let ver = version();
        assert!(ver.contains("quantum-crypto"));
    }
}
