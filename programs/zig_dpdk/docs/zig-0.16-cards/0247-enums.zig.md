# Migration Card: `std/enums.zig`

## 1) Concept

This file provides comprehensive utilities for working with Zig enums, including type-safe data structures and conversion functions. It contains utilities for converting between enums and integers, creating enum-indexed data structures (arrays, sets, maps), and working with enum metadata. Key components include `EnumSet` for bitfield-backed enum sets, `EnumMap` for sparse enum-keyed maps, `EnumArray` for dense enum-indexed arrays, and various helper functions for enum introspection and manipulation.

The module handles both exhaustive and non-exhaustive enums, providing optimized implementations for dense enums while supporting sparse enums through mapping tables. It's designed for zero-allocation, comptime-friendly operations that work with both runtime and compile-time enum values.

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected.** The public functions maintain consistent signatures:

- **No explicit allocator requirements**: All data structures (`EnumSet`, `EnumMap`, `EnumArray`) are stack-allocated with comptime-known sizes
- **No I/O interface changes**: This is a pure data structure/utility module without I/O dependencies
- **No error handling changes**: Functions use optionals (`?E`, `?[:0]const u8`) and comptime errors rather than error sets
- **Consistent initialization patterns**: Uses struct initialization with field names matching enum values

The main language-level change is the use of newer builtins:
- `@enumFromInt`/`@intFromEnum` instead of deprecated casting patterns
- `@field(E, field_name)` for field access

## 3) The Golden Snippet

```zig
const std = @import("std");
const EnumSet = std.enums.EnumSet;

const Direction = enum { up, down, left, right };

test "EnumSet usage" {
    var directions = EnumSet(Direction).initEmpty();
    directions.insert(.up);
    directions.insert(.right);
    
    try std.testing.expect(directions.contains(.up));
    try std.testing.expect(!directions.contains(.down));
    
    // Initialize with specific values
    const diagonal = EnumSet(Direction).init(.{
        .up = true,
        .right = true,
        .down = false,
        .left = false,
    });
    try std.testing.expect(diagonal.contains(.up));
}
```

## 4) Dependencies

- `std.debug` (for `assert`)
- `std.testing` (for test utilities)
- `std.math` (for integer operations and bounds checking)
- `std.mem` (for sorting in `EnumIndexer`)
- `std.fmt` (for compile-time string formatting in error messages)

**Note**: This module has minimal runtime dependencies and is primarily composed of comptime utilities and data structure implementations.