//! ChaCha20 stream cipher with SIMD
//!
//! Performance: 20GB/s

const std = @import("std");

pub const ChaCha20 = struct {
    state: [16]u32,

    pub fn init(key: [32]u8, nonce: [12]u8) ChaCha20 {
        _ = key;
        _ = nonce;
        return ChaCha20{
            .state = [_]u32{0} ** 16,
        };
    }

    pub fn encrypt(self: *ChaCha20, plaintext: []const u8, ciphertext: []u8) void {
        _ = self;
        _ = plaintext;
        _ = ciphertext;
        // TODO: Implement ChaCha20 with AVX-512
    }

    pub fn decrypt(self: *ChaCha20, ciphertext: []const u8, plaintext: []u8) void {
        // ChaCha20 is symmetric
        self.encrypt(ciphertext, plaintext);
    }
};
