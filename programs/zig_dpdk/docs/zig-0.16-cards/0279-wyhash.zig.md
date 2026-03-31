# Migration Card: std/hash/wyhash.zig

## 1) Concept

This file implements the Wyhash hash algorithm, a fast non-cryptographic hash function. It provides both a streaming API for incremental hashing and a one-shot convenience function. The key components include:

- The `Wyhash` struct that maintains hash state with internal buffers and counters
- Streaming methods (`init`, `update`, `final`) for processing data in chunks
- A static `hash` function for one-time hashing of complete data
- Internal helper functions for the core Wyhash algorithm operations like mixing and multiplication

The implementation handles edge cases carefully, particularly around final block processing and maintaining compatibility with the reference Wyhash implementation.

## 2) The 0.11 vs 0.16 Diff

This hash implementation shows minimal breaking changes between versions:

- **No explicit allocator requirements**: The API remains allocation-free, using stack buffers internally
- **No I/O interface changes**: The hash interface is simple - process bytes and return u64
- **No error handling changes**: All functions either return `void` or `u64` directly
- **API structure consistency**: The `init/update/final` pattern remains unchanged

The main migration consideration is that this follows Zig's standard hash interface pattern, which has remained stable. The public API signatures are:
- `init(seed: u64) Wyhash` - no allocator parameter
- `update(self: *Wyhash, input: []const u8) void` - mutable self pointer
- `final(self: *Wyhash) u64` - mutable self pointer, returns hash value
- `hash(seed: u64, input: []const u8) u64` - static convenience function

## 3) The Golden Snippet

```zig
const std = @import("std");
const Wyhash = std.hash.Wyhash;

// One-shot hashing
const hash1 = Wyhash.hash(42, "hello world");

// Streaming hashing
var hasher = Wyhash.init(42);
hasher.update("hello");
hasher.update(" ");
hasher.update("world");
const hash2 = hasher.final();

// Verify both methods produce same result
std.debug.assert(hash1 == hash2);
```

## 4) Dependencies

- `std.mem` - Used for `readInt` in internal `read` function
- `std.debug` - Used for assertions in `smallKey` and `final1` functions
- `std.testing` - Used for test framework and `expectEqual`

The file has minimal dependencies, primarily using core memory operations and testing utilities, making it lightweight and self-contained.