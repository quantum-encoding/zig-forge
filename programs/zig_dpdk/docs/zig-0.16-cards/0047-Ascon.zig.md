# Migration Card for `std.Random.Ascon`

## 1) Concept
This file implements a Cryptographically Secure Pseudo-Random Number Generator (CSPRNG) based on the Ascon permutation. It provides a forward-secure PRNG with a smaller state size compared to alternatives like ChaCha, making it suitable for constrained environments. The key components include:
- State initialization with a secret seed
- Entropy injection capabilities
- Random byte generation
- Integration with Zig's standard Random interface

The implementation uses the Ascon(128,12,8) permutation and follows the Reverie construction, providing cryptographic security guarantees.

## 2) The 0.11 vs 0.16 Diff
This module shows minimal migration impact from 0.11 to 0.16 patterns:

- **No explicit allocator requirements**: The API uses stack-based initialization (`init()`) rather than allocator-based factory functions
- **Direct state management**: The `Self` struct contains the permutation state directly, with no heap allocation
- **Consistent error handling**: No error types are used in the public API - all operations are infallible
- **Simple initialization pattern**: Uses `init(secret_seed)` with fixed-size array parameter rather than complex factory patterns

The API structure remains largely unchanged from what would be expected in 0.11, with the notable exception of using the newer `std.crypto.core.Ascon` permutation interface.

## 3) The Golden Snippet
```zig
const std = @import("std");
const AsconRng = std.Random.Ascon;

// Initialize with a secret seed
var seed: [AsconRng.secret_seed_length]u8 = undefined;
// ... fill seed with secure random data ...
var rng = AsconRng.init(seed);

// Generate random bytes
var buffer: [100]u8 = undefined;
rng.fill(&buffer);

// Use with std.Random interface
var random = rng.random();
const random_int = random.int(u32);
```

## 4) Dependencies
- `std` - Root standard library import
- `std.mem` - For memory operations (via `mem` alias)
- `std.crypto.core.Ascon` - Core cryptographic permutation
- `std.Random` - For the Random interface integration

The module has minimal dependencies, primarily relying on the cryptographic core and basic memory utilities.