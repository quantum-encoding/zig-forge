# Migration Card: `std/crypto/keccak_p.zig`

## 1) Concept

This file implements the core Keccak permutation functions used in cryptographic hash algorithms like SHA-3. It provides two main components:

- **`KeccakF`**: A type function that returns a Keccak-f permutation implementation for a given state size (f bits). This handles the low-level permutation operations on the Keccak state, including initialization, byte manipulation, and the permutation rounds.

- **`State`**: A higher-level sponge construction that builds on `KeccakF` to provide absorb/squeeze operations for building hash functions. It implements the full sponge duplex with padding, rate/capacity separation, and state transition tracking in debug mode.

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected.** This file follows consistent patterns that work in both Zig 0.11 and 0.16:

- **No explicit allocator requirements**: All operations work on stack-allocated state without dynamic memory allocation
- **No I/O interface changes**: The API uses direct method calls on state objects rather than dependency injection
- **No error handling changes**: Functions use assertions and panics for error conditions (no error unions)
- **Consistent API structure**: Uses `init()` factory pattern that returns initialized state objects

Key public APIs that remain stable:
- `KeccakF(f).init(bytes)` - State initialization from bytes
- `State(f, capacity, rounds).init(bytes, delim)` - Sponge state initialization
- `absorb()`, `squeeze()`, `permute()` - Core operations
- All methods operate directly on `*Self` without allocator parameters

## 3) The Golden Snippet

```zig
const std = @import("std");
const keccak_p = std.crypto.keccak_p;

// Create a Keccak-p[800, 256, 22] state (800-bit state, 256-bit capacity, 22 rounds)
var state = keccak_p.State(800, 256, 22).init(
    [_]u8{0x80} ** 100, // initial state
    0x01                // delimiter byte for padding
);

// Absorb some data
state.absorb("hello world");

// Pad and prepare for squeezing
state.pad();

// Squeeze output
var output: [32]u8 = undefined;
state.squeeze(output[0..]);
```

## 4) Dependencies

- **`std.mem`** - Memory operations, byte swapping, integer reading/writing
- **`std.math`** - Mathematical operations including rotations and logarithms
- **`std.debug`** - Assertions for validation
- **`@import("builtin")`** - Compiler intrinsics for mode detection and endianness

**Note**: This is a low-level cryptographic primitive that depends heavily on `std.mem` for byte-level manipulation and `std.math` for cryptographic operations like bit rotations.