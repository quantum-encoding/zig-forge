//! Cryptographic module for Quantum Seed Vault
//!
//! Provides Shamir Secret Sharing and related crypto operations.

pub const shamir = @import("crypto/shamir.zig");

// Re-export commonly used types
pub const Share = shamir.Share;
pub const SSS = shamir.SSS;
pub const GF256 = shamir.GF256;
pub const SLIP39 = shamir.SLIP39;
pub const SecureMem = shamir.SecureMem;
pub const ShamirError = shamir.ShamirError;
