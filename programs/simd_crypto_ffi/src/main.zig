//! Bitcoin wallet crypto core — Zig module surface.
//!
//! This module exposes the audited, externally-anchored Bitcoin building blocks
//! (transaction parse/txid, BIP32 HD derivation, BIP143 signing, SPV, coin
//! selection) so in-tree Zig projects can consume them directly via
//! `@import("simd_crypto").bitcoin`. The C-ABI surface (libquantum_crypto.a,
//! the `quantum_*` exports) lives in `ffi-grok.zig` and is the build root.
//!
//! NOTE: the former `hash/`, `cipher/`, and `Sha256/Blake3/ChaCha20` re-exports
//! were non-functional AVX-512 stubs (update() was a no-op, final() returned all
//! zeros, encrypt() wrote nothing). They were deleted rather than left as a
//! silent-zero-digest landmine — real hashing/AEAD is provided by the FFI layer
//! (which delegates to std.crypto) and by std.crypto directly for Zig callers.

/// Bitcoin transaction / SPV / BIP32 building blocks (pure-Zig, no libc).
pub const bitcoin = struct {
    pub const transaction = @import("bitcoin/transaction.zig");
    pub const tx_builder = @import("bitcoin/tx_builder.zig");
    pub const coin_select = @import("bitcoin/coin_select.zig");
    pub const bip32 = @import("bitcoin/bip32.zig");
    pub const spv = @import("bitcoin/spv.zig");
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(bitcoin);
}
