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

// Force the imported shamir module's `test` blocks into any test binary rooted
// at this file (e.g. `zig build test-crypto`). A bare `pub const shamir =
// @import(...)` re-export does NOT pull an imported file's tests — only an
// explicit reference from a `test` block does. Without this, `test-crypto`
// compiled and reported success while running zero tests.
test {
    _ = shamir;
}
