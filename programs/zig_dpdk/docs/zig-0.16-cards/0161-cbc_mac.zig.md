# Migration Card: CBC-MAC Implementation

## 1) Concept

This file implements CBC-MAC (Cipher Block Chaining Message Authentication Code), a cryptographic message authentication code construction. It provides both a specific AES-128 implementation (`CbcMacAes128`) and a generic CBC-MAC type constructor that can work with any block cipher.

The key components include:
- A generic `CbcMac` function that returns a CBC-MAC implementation type for any block cipher
- Incremental API with `init`, `update`, and `final` methods for streaming message processing
- A one-shot `create` function for simple use cases
- State management with internal buffer and position tracking for handling partial blocks

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this crypto module follows consistent patterns:

- **No allocator requirements**: All functions work with stack-allocated buffers and don't require memory allocation
- **No I/O interface changes**: Pure computational API without I/O dependencies
- **No error handling changes**: All functions are `void`-returning (no error sets)
- **Consistent API structure**: Uses standard `init/update/final` pattern common in Zig crypto APIs

The API follows Zig 0.16 patterns:
- Factory functions (`CbcMac()`) return types rather than instances
- Stateful context objects with incremental processing
- Buffer parameters use explicit slice types rather than generic pointers

## 3) The Golden Snippet

```zig
const std = @import("std");
const CbcMacAes128 = std.crypto.cbc_mac.CbcMacAes128;

// One-shot MAC computation
const key = [_]u8{0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c};
const message = "Hello, World!";

var mac: [CbcMacAes128.mac_length]u8 = undefined;
CbcMacAes128.create(&mac, message, &key);

// Incremental processing
var ctx = CbcMacAes128.init(&key);
ctx.update("Hello, ");
ctx.update("World!");
ctx.final(&mac);
```

## 4) Dependencies

- `std.crypto` - Core cryptographic primitives
- `std.mem` - Memory operations (used in tests for equality checking)

**Migration Impact**: LOW - No breaking changes, consistent with Zig 0.16 patterns