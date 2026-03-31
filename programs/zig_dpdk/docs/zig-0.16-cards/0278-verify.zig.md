# Migration Card: std/hash/verify.zig

## 1) Concept
This file provides hash verification utilities for testing hash function implementations. It contains two main public functions: `smhasher` for generating SMHasher-compatible verification codes, and `iterativeApi` for testing iterative hash APIs. The file includes helper functions that handle both seeded and seedless hash functions through compile-time introspection of function signatures.

Key components include:
- `smhasher`: Generates verification codes using the SMHasher test pattern
- `iterativeApi`: Validates that iterative hash APIs produce consistent results
- Helper functions that adapt to different hash function signatures (with/without seeds)

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected** - this file follows patterns that remain consistent between Zig 0.11 and 0.16:

- **No explicit allocator requirements**: All operations use stack buffers, no dynamic allocation
- **No I/O interface changes**: Pure computational functions with no I/O dependencies
- **Generic error handling**: `iterativeApi` returns error union with specific error types (`error.IterativeHashWasNotIdempotent`, `error.IterativeHashDidNotMatchDirect`)
- **API structure**: Uses generic comptime parameters rather than init/open patterns
- **Type-safe casting**: Uses `@intCast` and `@truncate` for explicit type conversions

The public API signatures are compatible with both versions:
```zig
pub fn smhasher(comptime hash_fn: anytype) u32
pub fn iterativeApi(comptime Hash: anytype) !void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const verify = std.hash.verify;

// Test a hash function with SMHasher verification
const my_hash = struct {
    pub fn hash(buf: []const u8) u32 {
        var result: u32 = 0;
        for (buf) |byte| {
            result = result ^% byte;
            result = result *% 0x01000193;
        }
        return result;
    }
};

test "smhasher verification" {
    const code = verify.smhasher(my_hash.hash);
    // Use the verification code for testing
}
```

## 4) Dependencies

- `std.mem` - Used for `writeInt` operation in hash verification
- No heavy external dependencies - self-contained hash testing utilities

**Note**: This file provides testing utilities rather than production hash APIs, so migration impact is minimal.