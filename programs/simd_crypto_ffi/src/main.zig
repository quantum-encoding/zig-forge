//! SIMD Cryptographic Library
//!
//! AVX-512 accelerated crypto primitives

pub const hash = @import("hash/sha256.zig");
pub const blake3 = @import("hash/blake3.zig");
pub const cipher = @import("cipher/chacha20.zig");

pub const Sha256 = hash.Sha256;
pub const Blake3 = blake3.Blake3;
pub const ChaCha20 = cipher.ChaCha20;

test {
    @import("std").testing.refAllDecls(@This());
}
