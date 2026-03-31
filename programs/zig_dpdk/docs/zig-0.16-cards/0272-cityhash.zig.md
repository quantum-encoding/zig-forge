# Migration Analysis: `std/hash/cityhash.zig`

## 1) Concept

This file implements Google's CityHash algorithm in Zig, providing both 32-bit and 64-bit non-cryptographic hash functions. The implementation contains two main public structs: `CityHash32` for 32-bit hashing and `CityHash64` for 64-bit hashing, each with their own optimized hash functions that handle different input length ranges efficiently.

The key components are the hash functions that process byte slices through various length-optimized algorithms, using bit manipulation operations like rotation and mixing to create well-distributed hash values. The implementation includes helper functions for fetching data from memory with proper endianness handling and internal mixing functions derived from Murmur3 hash principles.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected.** This is a pure computational hash library with stateless functions:

- **No allocator requirements**: All functions operate directly on input slices without memory allocation
- **No I/O interfaces**: Pure computational functions with no file or network dependencies
- **No error handling**: All functions return primitive integers (u32/u64) directly
- **Simple API structure**: Static functions on structs, no initialization patterns

The public API signatures remain simple and compatible:
- `CityHash32.hash([]const u8) u32`
- `CityHash64.hash([]const u8) u64`
- `CityHash64.hashWithSeed([]const u8, u64) u64`
- `CityHash64.hashWithSeeds([]const u8, u64, u64) u64`

## 3) The Golden Snippet

```zig
const std = @import("std");
const CityHash32 = std.hash.cityhash.CityHash32;
const CityHash64 = std.hash.cityhash.CityHash64;

test "cityhash basic usage" {
    const data = "hello world";
    
    const hash32 = CityHash32.hash(data);
    const hash64 = CityHash64.hash(data);
    const hash64_with_seed = CityHash64.hashWithSeed(data, 12345);
    const hash64_with_seeds = CityHash64.hashWithSeeds(data, 12345, 67890);
    
    std.debug.print("32-bit hash: {}\n", .{hash32});
    std.debug.print("64-bit hash: {}\n", .{hash64});
}
```

## 4) Dependencies

- **`std.mem`**: Used for `readInt` operations with little-endian byte order
- **`std.testing`**: Used exclusively in test code for verification
- **Internal `verify.zig`**: Test verification module (not part of public API)

This is a self-contained hash implementation with minimal dependencies, primarily relying on basic memory operations and testing utilities.