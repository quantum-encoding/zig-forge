# Migration Card: `std/crypto/timing_safe.zig`

## 1) Concept

This file provides constant-time cryptographic operations designed to prevent timing side-channel attacks. It contains utilities for comparing, adding, and subtracting data in constant time, regardless of input values. The key components include array/vector comparison functions, big integer arithmetic operations (addition/subtraction) for serialized integers, and memory classification functions for marking sensitive data.

The primary purpose is to ensure cryptographic operations execute in predictable time to prevent information leakage through timing analysis. This is critical for security-sensitive operations like MAC verification, signature checking, and cryptographic arithmetic where timing differences could reveal secret information.

## 2) The 0.11 vs 0.16 Diff

**No breaking API signature changes detected.** The public interface maintains compatibility:

- **No explicit allocator requirements**: All functions operate on provided slices/arrays without memory allocation
- **No I/O interface changes**: Functions work directly with memory buffers
- **Error handling unchanged**: Uses boolean returns and `std.math.Order` enum rather than error sets
- **API structure consistent**: No init/open pattern changes

**Internal implementation notes:**
- Uses newer casting syntax (`@as(T, @bitCast(value))`) which was already standard in 0.11
- Leverages `@truncate`, `@addWithOverflow`, `@subWithOverflow` builtins consistently
- Uses `std.meta.Int` for type-safe integer width calculations

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto = std.crypto;

// Compare two MACs in constant time
const mac1 = [_]u8{0x12, 0x34, 0x56, 0x78};
const mac2 = [_]u8{0x12, 0x34, 0x56, 0x79};

const are_equal = crypto.timing_safe.eql([4]u8, mac1, mac2);
std.debug.print("MACs are equal: {}\n", .{are_equal}); // false

// Compare big integers in constant time  
const big_num1 = [_]u8{0x01, 0x02, 0x03};
const big_num2 = [_]u8{0x01, 0x02, 0x04};
const order = crypto.timing_safe.compare(u8, &big_num1, &big_num2, .big);
std.debug.print("Comparison result: {}\n", .{order}); // Order.lt
```

## 4) Dependencies

- `std.debug` - for assertions
- `std.builtin` - for `Endian` type
- `std.math` - for `Order` enum
- `std.meta` - for `Int` type construction
- `std.crypto.random` - used in tests only
- `std.valgrind.memcheck` - for secret memory marking (conditional on Valgrind)

**Note**: This is a stable cryptographic utility module with no public API changes between 0.11 and 0.16. The migration impact is minimal - developers can continue using the same function signatures.