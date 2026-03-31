# Migration Card: std/math/nextafter.zig

## 1) Concept
This file implements the `nextAfter` function, which returns the next representable value after `x` in the direction of `y` for both integer and floating-point types. The function handles special cases including NaN values, zero crossings, and subnormal numbers. It provides a mathematical utility for precise floating-point manipulation and integer sequence navigation.

Key components include:
- Main public function `nextAfter` that dispatches to type-specific implementations
- Integer implementation `nextAfterInt` that handles arithmetic progression
- Floating-point implementation `nextAfterFloat` with special handling for 80-bit floats
- Comprehensive test suite covering edge cases and type variations

## 2) The 0.11 vs 0.16 Diff
This is a pure mathematical utility function with no breaking API changes between versions. The public interface remains stable:

**Function Signature Stability:**
- `pub fn nextAfter(comptime T: type, x: T, y: T) T` - Unchanged signature
- No allocator requirements (mathematical function)
- No I/O interface dependencies
- No error handling changes (returns values directly, no error union)
- No structural API changes (no init/open patterns)

**Implementation Details:**
- Uses compile-time type introspection with `@typeInfo`
- Handles both integer and floating-point types uniformly
- Maintains special case handling for edge conditions
- 80-bit float implementation uses structured bit manipulation via `math.F80`

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;

// Get the next representable float value after 1.0 towards 2.0
const next_val = math.nextAfter(f32, 1.0, 2.0);
// next_val = 1.0000001192092896 (next float after 1.0)

// Get the next integer after 5 towards 10  
const next_int = math.nextAfter(i32, 5, 10);
// next_int = 6
```

## 4) Dependencies
- `std.math` - Core mathematical functions and constants
- `std.debug` - Assertion utilities for validation
- `std.testing` - Testing framework for comprehensive test suite
- `std.meta` - Type introspection utilities (used indirectly)

**Note**: This is a mathematical utility function with minimal dependencies, focused on bit manipulation and type-specific arithmetic operations.