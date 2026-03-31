# Migration Analysis: `std/crypto/hash_composition.zig`

## 1) Concept

This file implements hash function composition - specifically, the chaining of two hash functions where the output of the second function becomes the input to the first (H1 o H2). The primary purpose is to provide defense against length-extension attacks in Merkle-Damgård constructions like SHA-256, while maintaining the same API as regular hash functions.

Key components include:
- A generic `Composition` type constructor that takes two hash function types
- Standard hash function interface with `init`, `update`, `final`, and one-shot `hash` methods
- Predefined compositions like `Sha256oSha256`, `Sha384oSha384`, and `Sha512oSha512`

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected** - this file follows consistent patterns:

- **No allocator requirements**: All operations are stack-based without dynamic allocation
- **Simple initialization**: `init()` takes an `Options` struct with nested options for both hash functions
- **Consistent error handling**: All operations are infallible (no error returns)
- **Standard crypto pattern**: Follows the established `init/update/final` pattern common in Zig's crypto APIs

The API structure remains stable with:
- `init(options: Options)` for state initialization
- `update(data: []const u8)` for incremental hashing
- `final(out: *[digest_length]u8)` for result computation
- `hash(data: []const u8, out: *[digest_length]u8, options: Options)` for one-shot operation

## 3) The Golden Snippet

```zig
const std = @import("std");
const Sha256oSha256 = std.crypto.hash_composition.Sha256oSha256;

pub fn main() void {
    const message = "test";
    var hash_result: [Sha256oSha256.digest_length]u8 = undefined;
    
    Sha256oSha256.hash(message, &hash_result, .{});
    // hash_result now contains SHA-256(SHA-256("test"))
}
```

## 4) Dependencies

- `std` (root import)
- `std.crypto.hash.sha2` (via `sha2` alias)

**Note**: This is a utility wrapper that depends on existing hash implementations rather than introducing new cryptographic primitives.