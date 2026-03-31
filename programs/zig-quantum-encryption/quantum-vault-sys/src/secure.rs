//! Secure memory handling utilities
//!
//! Provides secure byte arrays that are zeroed on drop to prevent
//! secret key material from lingering in memory.

use std::fmt;
use std::ops::{Deref, DerefMut};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::bindings;

/// A fixed-size byte array that is securely zeroed when dropped.
///
/// Use this type for storing secret keys and other sensitive data.
/// The memory is automatically zeroed using the library's secure
/// zero function when the value goes out of scope.
#[derive(Clone, ZeroizeOnDrop)]
pub struct SecureBytes<const N: usize> {
    bytes: [u8; N],
}

impl<const N: usize> SecureBytes<N> {
    /// Create a new SecureBytes initialized to zeros.
    pub fn new() -> Self {
        Self { bytes: [0u8; N] }
    }

    /// Create a SecureBytes from a byte array.
    ///
    /// The input array is copied and the original is NOT zeroed.
    /// If you need to zero the original, do it explicitly.
    pub fn from_array(bytes: [u8; N]) -> Self {
        Self { bytes }
    }

    /// Create a SecureBytes from a slice.
    ///
    /// # Panics
    /// Panics if the slice length doesn't match N.
    pub fn from_slice(slice: &[u8]) -> Self {
        assert_eq!(slice.len(), N, "Slice length must match SecureBytes size");
        let mut bytes = [0u8; N];
        bytes.copy_from_slice(slice);
        Self { bytes }
    }

    /// Try to create a SecureBytes from a slice.
    ///
    /// Returns None if the slice length doesn't match N.
    pub fn try_from_slice(slice: &[u8]) -> Option<Self> {
        if slice.len() != N {
            return None;
        }
        let mut bytes = [0u8; N];
        bytes.copy_from_slice(slice);
        Some(Self { bytes })
    }

    /// Get the underlying bytes as a slice.
    pub fn as_bytes(&self) -> &[u8; N] {
        &self.bytes
    }

    /// Get the underlying bytes as a mutable slice.
    pub fn as_bytes_mut(&mut self) -> &mut [u8; N] {
        &mut self.bytes
    }

    /// Get the size of the secure bytes.
    pub const fn len(&self) -> usize {
        N
    }

    /// Returns true if the size is zero.
    pub const fn is_empty(&self) -> bool {
        N == 0
    }

    /// Explicitly zero the memory using the library's secure zero function.
    pub fn secure_zero(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.bytes.as_mut_ptr(), N);
        }
    }

    /// Constant-time equality comparison.
    pub fn ct_eq(&self, other: &Self) -> bool {
        unsafe { bindings::qv_constant_time_eq(self.bytes.as_ptr(), other.bytes.as_ptr(), N) }
    }
}

impl<const N: usize> Default for SecureBytes<N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const N: usize> Deref for SecureBytes<N> {
    type Target = [u8; N];

    fn deref(&self) -> &Self::Target {
        &self.bytes
    }
}

impl<const N: usize> DerefMut for SecureBytes<N> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.bytes
    }
}

impl<const N: usize> AsRef<[u8]> for SecureBytes<N> {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}

impl<const N: usize> AsMut<[u8]> for SecureBytes<N> {
    fn as_mut(&mut self) -> &mut [u8] {
        &mut self.bytes
    }
}

// Don't implement Debug to avoid accidentally logging secrets
impl<const N: usize> fmt::Debug for SecureBytes<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SecureBytes<{}>([REDACTED])", N)
    }
}

// Zeroize implementation (called by ZeroizeOnDrop)
impl<const N: usize> Zeroize for SecureBytes<N> {
    fn zeroize(&mut self) {
        self.secure_zero();
    }
}

/// Type aliases for common secret sizes
pub type SharedSecret = SecureBytes<32>;
pub type Seed = SecureBytes<32>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_secure_bytes_new() {
        let sb: SecureBytes<32> = SecureBytes::new();
        assert_eq!(sb.len(), 32);
        assert!(sb.as_bytes().iter().all(|&b| b == 0));
    }

    #[test]
    fn test_secure_bytes_from_array() {
        let data = [1u8; 32];
        let sb = SecureBytes::from_array(data);
        assert_eq!(sb.as_bytes(), &data);
    }

    #[test]
    fn test_secure_bytes_from_slice() {
        let data = [2u8; 32];
        let sb: SecureBytes<32> = SecureBytes::from_slice(&data);
        assert_eq!(sb.as_bytes(), &data);
    }

    #[test]
    fn test_secure_bytes_try_from_slice() {
        let data = [3u8; 32];
        assert!(SecureBytes::<32>::try_from_slice(&data).is_some());
        assert!(SecureBytes::<16>::try_from_slice(&data).is_none());
    }

    #[test]
    fn test_debug_redacts() {
        let sb: SecureBytes<32> = SecureBytes::new();
        let debug_str = format!("{:?}", sb);
        assert!(debug_str.contains("REDACTED"));
        assert!(!debug_str.contains("0"));
    }
}
