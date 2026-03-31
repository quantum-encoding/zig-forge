# KangarooTwelve Cryptographic Hash Migration Card

## 1) Concept

This file implements the KangarooTwelve (K12) cryptographic hash function, which is a fast, secure hash built on the Keccak permutation (same primitive as SHA-3). It provides tree-hashing capabilities with optional parallel processing for large inputs. The implementation includes two security variants: KT128 (128-bit security) and KT256 (256-bit security).

Key components:
- **MultiSliceView**: Zero-copy view over multiple slices for efficient data handling
- **TurboSHAKE**: Core permutation function with SIMD-optimized parallel processing
- **Tree hashing**: Automatic tree mode for inputs larger than 8KB chunks
- **Incremental hashing**: Streaming API for large data processing
- **Parallel processing**: Multi-threaded hashing for inputs over 2MB

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`hashParallel`** functions now require explicit `Allocator` parameter for temporary buffers
- **Multi-threaded processing** uses allocator for chaining value buffers and scratch space
- **No allocator** required for sequential `hash` function or incremental API

### I/O Interface Changes
- **`hashParallel`** requires `std.Io` object for thread management via `Io.Group.async()`
- **Dependency injection** pattern for I/O operations in parallel processing
- **Sequential processing** remains I/O-independent

### Error Handling Changes
- **Generic error types**: Functions return `!void` or `![]u8` without specific error sets
- **Allocation errors** propagated through `anyerror!` in internal functions
- **No panics** in public API - all errors handled through return types

### API Structure Changes
- **Factory pattern**: `KTHash()` builds complete hash API types
- **Options struct**: Configuration via `Options` with customization strings
- **Incremental API**: `init()`, `update()`, `final()` pattern for streaming
- **Parallel API**: Separate `hashParallel` function with explicit allocator/Io

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto = std.crypto;

// Sequential hashing (no allocator required)
var output: [32]u8 = undefined;
try crypto.kangarootwelve.KT128.hash("Hello, World!", &output, .{});

// Parallel hashing for large inputs (requires allocator and Io)
const allocator = std.heap.page_allocator;
const io = std.io.getStdIo();
var large_output: [64]u8 = undefined;
const large_data = try allocator.alloc(u8, 3 * 1024 * 1024); // 3MB
defer allocator.free(large_data);
// ... fill large_data ...
try crypto.kangarootwelve.KT128.hashParallel(large_data, &large_output, .{}, allocator, io);

// Incremental hashing
var hasher = crypto.kangarootwelve.KT128.init(.{ .customization = "my_domain" });
hasher.update("Hello");
hasher.update(", ");
hasher.update("World!");
hasher.final(&output);
```

## 4) Dependencies

- **`std.mem`**: Memory operations, allocator interface
- **`std.crypto`**: Cryptographic primitives, random bytes
- **`std.Io`**: I/O operations for parallel processing
- **`std.Thread`**: CPU count detection for parallelization
- **`std.simd`**: SIMD vector operations for performance
- **`std.atomic`**: Cache line alignment
- **`std.math`**: Bit rotation operations
- **`std.testing`**: Test utilities and allocator