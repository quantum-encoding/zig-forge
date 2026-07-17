//! SIMD Cryptographic Library
//!
//! AVX-512 accelerated crypto primitives

pub const hash = @import("hash/sha256.zig");
pub const blake3 = @import("hash/blake3.zig");
pub const cipher = @import("cipher/chacha20.zig");

/// Bitcoin transaction / SPV / BIP32 building blocks (pure-Zig, no libc).
/// Exposed here so downstream Zig projects can consume the library surface
/// directly via `@import("simd_crypto").bitcoin`.
pub const bitcoin = struct {
    pub const transaction = @import("bitcoin/transaction.zig");
    pub const tx_builder = @import("bitcoin/tx_builder.zig");
    pub const coin_select = @import("bitcoin/coin_select.zig");
    pub const bip32 = @import("bitcoin/bip32.zig");
    pub const spv = @import("bitcoin/spv.zig");
};

pub const Sha256 = hash.Sha256;
pub const Blake3 = blake3.Blake3;
pub const ChaCha20 = cipher.ChaCha20;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(bitcoin);
}
