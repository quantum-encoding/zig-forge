# Migration Analysis: `std/hash/murmur.zig`

## 1) Concept

This file implements three variants of the MurmurHash non-cryptographic hash function family: MurmurHash2 (32-bit and 64-bit versions) and MurmurHash3 (32-bit version). Each hash algorithm is exposed as a struct with static methods that can hash byte slices (`[]const u8`) and primitive integers (`u32`, `u64`). The implementations are pure functions that operate on input data and return hash values without requiring any external dependencies or memory allocation.

Key components include:
- **Murmur2_32**: 32-bit MurmurHash2 implementation with methods for hashing bytes and integers
- **Murmur2_64**: 64-bit MurmurHash2 implementation with similar interface
- **Murmur3_32**: 32-bit MurmurHash3 implementation with optimized rotation-based mixing
- All variants provide both default-seeded (`hash()`, `hashUint32()`, `hashUint64()`) and seedable (`hashWithSeed()`, `hashUint32WithSeed()`, `hashUint64WithSeed()`) versions

## 2) The 0.11 vs 0.16 Diff

**No Breaking API Changes Identified**

This hash implementation follows a pure functional pattern that remains stable across Zig versions:

- **No Allocator Requirements**: All functions are pure computations that operate on input data and return hash values directly. No memory allocation or deallocation occurs.
- **No I/O Interface Changes**: The API doesn't involve I/O operations or dependency injection patterns.
- **No Error Handling Changes**: All functions return simple integer results (`u32` or `u64`) without error sets.
- **Consistent API Structure**: The static method pattern (`StructName.function()`) remains unchanged from 0.11 to 0.16.

The implementation uses some Zig 0.16 syntax features internally (like `@truncate` and `@byteSwap`), but these don't affect the public API signatures that developers would use.

## 3) The Golden Snippet

```zig
const std = @import("std");
const murmur = std.hash.murmur;

test "murmur hash example" {
    const data = "hello world";
    
    // Default seed versions
    const hash2_32 = murmur.Murmur2_32.hash(data);
    const hash2_64 = murmur.Murmur2_64.hash(data);
    const hash3_32 = murmur.Murmur3_32.hash(data);
    
    // Custom seed versions
    const custom_seed: u32 = 0x12345678;
    const seeded_hash = murmur.Murmur2_32.hashWithSeed(data, custom_seed);
    
    // Integer hashing
    const int_hash = murmur.Murmur3_32.hashUint32(42);
    
    // Use the hash values as needed...
}
```

## 4) Dependencies

- `std` (base import)
- `builtin` (for target endianness detection via `builtin.target.cpu.arch.endian()`)
- `std.testing` (test framework only)
- `std.hash.verify` (test validation only)

**Note**: The main implementation has minimal dependencies - only `std` and `builtin` for endian handling. The testing dependencies (`testing`, `verify`) are only used in test blocks and don't affect the public API.