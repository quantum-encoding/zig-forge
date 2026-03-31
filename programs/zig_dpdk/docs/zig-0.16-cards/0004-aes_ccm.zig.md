```markdown
# Migration Card: aes_ccm.zig

## 1) Concept
This file implements AES-CCM (Counter with CBC-MAC) authenticated encryption mode per NIST SP 800-38C and RFC 3610, extended as CCM* to support encryption-only operation (tag_len=0). It defines a generic `AesCcm` function that generates types for AES-128/AES-256 with configurable tag lengths (0,4,6,8,10,12,14,16 bytes) and nonce lengths (7-13 bytes). Predefined public types like `Aes128Ccm8`, `Aes256Ccm16` expose stateless `encrypt`/`decrypt` functions operating on fixed-size key/nonce/tag arrays and in-place plaintext/ciphertext slices, with optional associated data (AD). Internal helpers handle CBC-MAC computation, counter block formatting, and AD length encoding. Extensive tests validate against RFC 3610, NIST SP 800-38C vectors, edge cases (empty messages, multi-block, varying nonces), and CCM* encryption-only mode.

Key components: `AesCcm` generic (validates params at comptime), public encrypt/decrypt APIs, `formatCtrBlock`/`formatB0Block`/`computeCbcMac` internals relying on `cbc_mac.zig` and `crypto.core.modes.ctrSlice`.

## 2) The 0.11 vs 0.16 Diff
This is a new/rewritten CCM implementation in 0.16 std.crypto; no direct 0.11 equivalent (0.11 std.crypto lacked CCM/CCM*). Public APIs are fully stateless—no struct init, no allocators, no factories, no deinit. All ops use fixed-length arrays for key/nonce/tag (e.g., `[key_length]u8`, `[nonce_length]u8`, `[tag_length]u8`) and slices for c/m/ad.

- **encrypt**: `pub fn encrypt(c: []u8, tag: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) void`  
  New: In-place output to `c`/`tag`; asserts `c.len == m.len`; no return value (void); max message length enforced via `L`.

- **decrypt**: `pub fn decrypt(m: []u8, c: []const u8, tag: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) AuthenticationError!void`  
  New: In-place output to `m`; asserts `m.len == c.len`; single generic `AuthenticationError` (constant-time verify); wipes buffers on fail.

No I/O interfaces or DI; pure primitives. Error handling shifted to specific `crypto.errors.AuthenticationError` vs any 0.11 generics. No `init`/`open`; direct type usage (e.g., `Aes128Ccm8.encrypt`). CCM* (tag_len=0) skips auth entirely.

## 3) The Golden Snippet
```zig
const std = @import("std");
const Aes256Ccm8 = @import("aes_ccm.zig").Aes256Ccm8;

pub fn main() !void {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const nonce: [13]u8 = [_]u8{0x11} ** 13;
    const m = "Hello, World! This is a test message.";
    var c: [m.len]u8 = undefined;
    var tag: [Aes256Ccm8.tag_length]u8 = undefined;

    Aes256Ccm8.encrypt(&c, &tag, m, "", nonce, key);

    var m2: [m.len]u8 = undefined;
    try Aes256Ccm8.decrypt(&m2, &c, tag, "", nonce, key);

    std.debug.assert(std.mem.eql(u8, m[0..], &m2));
}
```

## 4) Dependencies
- `std.crypto` (core: `crypto.core.aes.Aes128`/`Aes256`, `crypto.core.modes.ctrSlice`, `crypto.errors.AuthenticationError`, `crypto.timing_safe.eql`, `crypto.secureZero`)
- `std.mem` (memcpy, writeInt, etc.)
- `std.debug.assert`
- `cbc_mac.zig` (`cbc_mac.CbcMac(BlockCipher)`)
- `std.testing`, `std.fmt` (tests only)
```
```