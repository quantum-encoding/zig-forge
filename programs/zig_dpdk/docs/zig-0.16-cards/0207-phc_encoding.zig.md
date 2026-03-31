# Migration Card: PHC Encoding Module

## 1) Concept

This file implements the PHC string format encoding and decoding utilities for cryptographic password hashing. It provides functionality to serialize and deserialize password hash parameters according to the PHC (Password Hashing Competition) string format specification. The key components include a `BinValue` type for handling binary data with maximum size constraints, and functions for converting between structured data and the standardized PHC string representation used by algorithms like Argon2 and scrypt.

The module handles the complex PHC format which includes algorithm identifiers, version numbers, parameters (like iteration counts and memory usage), salt values, and hash outputs, all encoded in a specific delimited format with base64 encoding for binary data.

## 2) The 0.11 vs 0.16 Diff

**No explicit allocator requirements**: The public API (`deserialize`, `serialize`, `calcSize`) does not require an allocator parameter, using stack-based buffers and fixed-size arrays instead.

**I/O interface changes**: The serialization uses the new `std.Io.Writer` interface:
- `serializeTo(params: anytype, out: *std.Io.Writer)` - Takes a writer interface
- `serialize(params: anytype, str: []u8)` - Uses fixed buffer instead of allocator-based strings

**Error handling**: Uses specific error set `Error = std.crypto.errors.EncodingError || error{NoSpaceLeft}` rather than generic error types.

**API structure**: No `init`/`open` patterns - functions work directly with the provided data structures. The `BinValue` type uses factory function `fromSlice()` rather than constructor patterns.

## 3) The Golden Snippet

```zig
const std = @import("std");
const phc = std.crypto.phc_encoding;

// Define your hash result structure
const HashResult = struct {
    alg_id: []const u8,
    alg_version: u16,
    m: usize,
    t: u64,
    p: u32,
    salt: phc.BinValue(16),
    hash: phc.BinValue(32),
};

pub fn example() !void {
    const phc_string = "$argon2id$v=19$m=4096,t=0,p=1$X1NhbHQAAAAAAAAAAAAAAA$bWh++MKN1OiFHKgIWTLvIi1iHicmHH7+Fv3K88ifFfI";
    
    // Deserialize from PHC string
    const result = try phc.deserialize(HashResult, phc_string);
    
    // Serialize back to PHC string
    var buffer: [256]u8 = undefined;
    const serialized = try phc.serialize(result, &buffer);
    
    // Calculate required buffer size
    const required_size = phc.calcSize(result);
}
```

## 4) Dependencies

- `std.mem` - Memory operations and splitting
- `std.fmt` - String formatting and integer parsing  
- `std.meta` - Type introspection and field iteration
- `std.base64` - Base64 encoding/decoding (via `B64Encoder`/`B64Decoder`)
- `std.crypto.errors` - Error definitions
- `std.Io` - Writer interface for output