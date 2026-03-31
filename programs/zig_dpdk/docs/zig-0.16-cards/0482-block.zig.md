# Migration Card: std/sort/block.zig

## 1) Concept

This file implements a stable, in-place block sorting algorithm (WikiSort) for the Zig standard library. It's a sophisticated sorting algorithm that provides O(n) best-case and O(n*log(n)) worst-case performance while using only O(1) memory (no allocator required). The key components include:

- **Block sorting algorithm**: A complex merge-based sort that uses internal buffers and clever partitioning
- **Range-based operations**: Uses `Range` struct to manage subarray boundaries throughout the sorting process
- **Multiple merge strategies**: Implements `mergeInPlace`, `mergeInternal`, and `mergeExternal` for different scenarios
- **Iterator pattern**: Uses an `Iterator` struct to manage the partitioning of the input array into progressively larger blocks

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected.** This is an internal implementation file with the following characteristics:

- **No explicit allocator requirements**: The algorithm is designed to work without any memory allocation, using only stack-based cache
- **No I/O interface changes**: This is a pure computation module with no file or network operations
- **No error handling changes**: The function doesn't return errors - it's a void function that operates in-place
- **No public API structure changes**: The main `block` function follows the same pattern as other stdlib sort functions

The public function signature follows the established Zig 0.16 pattern:
```zig
pub fn block(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void
```

This matches the standard library pattern for comparison-based sorting algorithms, where the caller provides the type, slice, context, and comparison function.

## 3) The Golden Snippet

```zig
const std = @import("std");

fn lessThan(context: void, a: i32, b: i32) bool {
    _ = context;
    return a < b;
}

pub fn main() void {
    var items = [_]i32{3, 1, 4, 1, 5, 9, 2, 6};
    
    // Use the block sort algorithm
    std.sort.block(i32, &items, {}, lessThan);
    
    // items is now sorted: [1, 1, 2, 3, 4, 5, 6, 9]
}
```

## 4) Dependencies

The file has the following key dependencies:

- **std.mem**: Used extensively for `swap`, `rotate`, and memory operations
- **std.math**: Used for `floorPowerOfTwo` and `sqrt` calculations
- **std.sort**: Uses `insertion` sort from the parent module for small ranges
- **builtin**: Used for debug mode assertions

The dependency graph shows this is a core algorithm module that depends primarily on fundamental memory and math operations rather than higher-level I/O or system interfaces.

---

**Note**: This file represents an internal implementation of a sorting algorithm rather than a public-facing API. The migration impact is minimal as it follows established stdlib patterns and doesn't expose allocator-dependent or I/O-dependent interfaces that would require significant changes from 0.11 to 0.16.