# Migration Card: `std/crypto/siphash.zig`

## 1) Concept

This file implements the SipHash cryptographic pseudorandom function family, providing both 64-bit and 128-bit output variants. SipHash is designed for speed and security, commonly used for hash table protection against DoS attacks and authentication of short-lived messages in online protocols.

The implementation provides two main public APIs:
- **Type functions** `SipHash64` and `SipHash128` that return configured SipHash types based on compression/finalization round parameters
- **Stateful hashing** through the `SipHash` struct with incremental update/finalize methods
- **Stateless one-shot** operations through the `create` and `toInt` functions

Key components include parameterized round configurations, block processing, and test vectors from the reference implementation.

## 2) The 0.11 vs 0.16 Diff

**No major API signature changes detected.** The public interface follows consistent Zig 0.16 patterns:

- **No explicit allocator requirements** - All operations are stack-based or use caller-provided buffers
- **Direct memory operations** - Uses `@memcpy` and `mem.readInt`/`mem.writeInt` with explicit endianness
- **Stateless factory pattern** - `init()` creates instances without dependencies
- **Buffer-oriented output** - `final()` writes to caller-provided buffer, `finalResult()` returns stack array

Public API structure remains stable:
- `init(key)` → state initialization
- `update(data)` → incremental processing  
- `final(out_buffer)` / `finalResult()` → tag generation
- `create(out, msg, key)` → one-shot operation

## 3) The Golden Snippet

```zig
const std = @import("std");
const SipHash64 = std.crypto.siphash.SipHash64;

test "siphash64 basic usage" {
    const key: [16]u8 = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f".*;
    const message = "test message";
    
    // One-shot hashing
    var out: [8]u8 = undefined;
    SipHash64(2, 4).create(&out, message, &key);
    
    // Incremental hashing
    var hasher = SipHash64(2, 4).init(&key);
    hasher.update(message);
    const result = hasher.finalResult();
    
    // Integer output
    const hash_int = SipHash64(2, 4).toInt(message, &key);
}
```

## 4) Dependencies

- `std.mem` - Memory operations (`readInt`, `writeInt`, `@memcpy`)
- `std.math` - Bit rotation (`rotl`)
- `std.debug` - Assertions (`assert`)
- `std.testing` - Test framework

**Primary crypto dependencies:** Memory manipulation utilities for block processing and integer serialization.