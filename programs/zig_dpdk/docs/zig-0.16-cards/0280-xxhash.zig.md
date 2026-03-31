# Migration Card: std/hash/xxhash.zig

## 1) Concept

This file implements the XXHash family of non-cryptographic hash algorithms in Zig, specifically providing 32-bit, 64-bit, and XXH3 (64-bit) variants. The implementation offers both one-shot hashing functions for convenience and streaming interfaces for incremental hashing of large data. Each hash type (`XxHash32`, `XxHash64`, `XxHash3`) is implemented as a struct with `init()`, `update()`, and `final()` methods for streaming hashing, plus a static `hash()` function for one-shot computation.

Key components include:
- **XxHash32**: 32-bit hash with seed support and streaming capability
- **XxHash64**: 64-bit hash with seed support and streaming capability  
- **XxHash3**: Modern 64-bit hash with SIMD optimizations, seed support, and streaming capability
- **Accumulator patterns**: Internal state management for processing data in blocks
- **Comprehensive test suite**: Validates correctness against known test vectors

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependencies**: All hash structs are stack-allocated and don't require memory allocators
- **Direct struct initialization**: Uses simple `init(seed)` pattern rather than factory functions with allocators
- **Fixed-size internal buffers**: Pre-allocated buffers eliminate dynamic memory needs

### I/O Interface Changes
- **Generic input types**: `update()` methods accept `anytype` parameters, allowing flexible input types
- **No stream interfaces**: Uses direct byte array processing rather than Zig's I/O stream patterns
- **Memory-oriented API**: Focused on `[]const u8` and generic slice operations

### Error Handling Changes
- **No error returns**: All public functions return hash values directly (u32/u64)
- **Panic-free design**: Uses assertions and compile-time checks rather than error unions
- **Pure computation**: Hash operations cannot fail in normal usage

### API Structure Changes
- **Consistent init/update/final pattern**: All three hash types follow the same streaming API
- **Seed-based initialization**: `init(seed)` rather than parameter structs
- **One-shot convenience**: Static `hash(seed, input)` functions alongside streaming API

## 3) The Golden Snippet

```zig
const std = @import("std");
const xxhash = std.hash.xxhash;

// One-shot hashing
const data = "hello world";
const hash64 = xxhash.XxHash64.hash(0, data);
const hash32 = xxhash.XxHash32.hash(0, data);
const hash3 = xxhash.XxHash3.hash(0, data);

// Streaming hashing
var hasher = xxhash.XxHash64.init(42);
hasher.update("hello");
hasher.update(" ");
hasher.update("world");
const streamed_hash = hasher.final();
```

## 4) Dependencies

- **std.mem**: Heavy usage for `readInt`, `bytesAsSlice`, `bytesAsSlice`, and memory operations
- **std.math**: Used for `rotl` (rotate left) operations
- **builtin**: For `cpu.arch.endian()` and architecture detection
- **std.testing**: For test assertions and validation
- **std.debug**: For runtime assertions

The file has minimal external dependencies and is designed to be self-contained within the standard library's hash module.