# AES-SIV Migration Analysis

## 1) Concept

This file implements AES-SIV (Synthetic Initialization Vector), a deterministic authenticated encryption algorithm defined in RFC 5297. The module provides AES-128-SIV and AES-256-SIV implementations through the `Aes128Siv` and `Aes256Siv` types respectively. 

Key components include:
- **S2V (String to Vector)**: A cryptographic pseudo-random function that derives a synthetic IV from keys and input strings using CMAC
- **Deterministic encryption**: Unlike most modes, identical plaintexts with the same key produce identical ciphertexts
- **Multiple associated data support**: Supports vectors of associated data strings with cryptographic separation
- **Optional nonce**: Can add non-determinism when needed
- **Misuse resistance**: Better security properties than AES-GCM when nonces are reused

## 2) The 0.11 vs 0.16 Diff

This crypto module follows a **functional pattern** rather than object-oriented patterns, showing minimal migration impact:

### Function Signature Analysis:
- **No allocator requirements**: All operations are pure computations without dynamic allocation
- **Direct parameter passing**: Keys, data, and outputs passed directly as parameters
- **Static error types**: Uses specific `AuthenticationError` from `crypto.errors.AuthenticationError`
- **No init/open patterns**: Functions operate directly on the type without instance creation

### Public API Structure:
```zig
// Encryption pattern (unchanged from 0.11)
Aes128Siv.encrypt(ciphertext, &tag, plaintext, ad, nonce, key)

// Decryption pattern (error return added)
Aes128Siv.decrypt(plaintext, ciphertext, tag, ad, nonce, key) AuthenticationError!void
```

### Key Migration Notes:
- **Error handling**: `decrypt` functions now return `AuthenticationError!void` instead of using out parameters
- **Memory safety**: Uses `@memset(m, undefined)` and `crypto.secureZero` for secure cleanup
- **No breaking changes**: Function signatures remain compatible with 0.11 patterns

## 3) The Golden Snippet

```zig
const std = @import("std");
const Aes128Siv = std.crypto.aes_siv.Aes128Siv;

fn example() !void {
    const key: [32]u8 = .{0x11} ** 32; // 256-bit key for AES-128-SIV
    const plaintext = "Hello, AES-SIV!";
    const ad = "associated data";
    const nonce: [16]u8 = .{0x42} ** 16;

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;

    // Encrypt
    Aes128Siv.encrypt(&ciphertext, &tag, plaintext, ad, &nonce, key);

    // Decrypt  
    var decrypted: [plaintext.len]u8 = undefined;
    try Aes128Siv.decrypt(&decrypted, &ciphertext, tag, ad, &nonce, key);

    // Verification
    std.debug.assert(std.mem.eql(u8, plaintext, &decrypted));
}
```

## 4) Dependencies

```zig
const std = @import("std");
const mem = std.mem;
const math = std.math;
const crypto = std.crypto;
const modes = crypto.core.modes;
const Cmac = @import("cmac.zig").Cmac;
const AuthenticationError = crypto.errors.AuthenticationError;
```

**Primary Dependencies:**
- `std.mem` - Memory operations and byte manipulation
- `std.crypto` - Core cryptographic primitives
- `crypto.core.modes` - Block cipher modes (CTR mode)
- `cmac.zig` - CMAC implementation for authentication
- `crypto.timing_safe` - Timing-safe comparisons

**Dependency Graph:**
```
aes_siv.zig → cmac.zig → crypto.core
           → crypto.core.modes 
           → crypto.core.aes (Aes128/Aes256)
```