# Migration Card: std/Random/ChaCha.zig

## 1) Concept
This file implements a Cryptographically Secure Pseudorandom Number Generator (CSPRNG) based on the ChaCha8 stream cipher with forward security. The key components include a ChaCha8 cipher state, entropy mixing through `addEntropy`, and random byte generation via the `fill` method. The implementation follows the fast-key-erasure pattern to ensure forward security by periodically refreshing the internal state.

The module provides a `std.Random` interface wrapper and handles the cryptographic details of maintaining a secure random state. It's designed for applications requiring high-quality random number generation with security properties.

## 2) The 0.11 vs 0.16 Diff
**No significant public API signature changes detected.** The public interface remains stable:

- **Initialization**: `init()` takes a fixed-size secret seed array without allocator requirements
- **No I/O dependencies**: Pure cryptographic operations without file/system dependencies
- **Error handling**: All operations are infallible (return `void` or direct values)
- **API structure**: Simple constructor pattern with mutable instance methods

The implementation uses newer builtins (`@memcpy`, `@memset`) but these don't affect the public API surface.

## 3) The Golden Snippet
```zig
const std = @import("std");
const ChaCha = std.Random.ChaCha;

// Initialize with secret seed
var secret_seed: [ChaCha.secret_seed_length]u8 = undefined;
// ... populate seed with secure random data ...
var rng = ChaCha.init(secret_seed);

// Generate random bytes
var buffer: [100]u8 = undefined;
rng.fill(&buffer);

// Use as std.Random interface
var random = rng.random();
const random_value = random.int(u64);
```

## 4) Dependencies
- `std.crypto.stream.chacha.ChaCha8IETF` (primary cryptographic primitive)
- `std.mem` (memory operations via builtins)
- `std.Random` (interface compatibility)

**Note**: This module has minimal external dependencies and focuses on cryptographic primitives rather than system I/O or memory management patterns.