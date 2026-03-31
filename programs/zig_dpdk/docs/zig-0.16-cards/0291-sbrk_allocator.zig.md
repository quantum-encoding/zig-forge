# Migration Analysis: `std/heap/sbrk_allocator.zig`

## 1) Concept

This file implements a system-level memory allocator that uses an `sbrk`-style system call for memory management. It's a generic allocator type that takes a platform-specific `sbrk` function pointer as a compile-time parameter. The allocator manages memory using power-of-two size classes with separate free lists for small allocations (up to 64KB) and large allocations. It implements thread safety through a global mutex and provides the standard allocator interface (alloc, resize, remap, free) through a VTable.

Key components include:
- Generic type constructor that takes an `sbrk` function parameter
- Size-class based memory management with separate free lists
- Thread-safe implementation using `std.Thread.Mutex`
- Support for both small allocations (handled in size classes) and large allocations (handled via direct `sbrk` calls)

## 2) The 0.11 vs 0.16 Diff

**Public API Changes:**

1. **Explicit Allocator VTable Pattern**: The allocator uses the new VTable-based interface:
   ```zig
   pub const vtable: Allocator.VTable = .{
       .alloc = alloc,
       .resize = resize,
       .remap = remap,
       .free = free,
   };
   ```
   This replaces the older method-based allocator interface.

2. **Memory Alignment Changes**: Functions now use `mem.Alignment` instead of raw alignment values:
   - `alignment: mem.Alignment` parameter in all allocator functions
   - Uses `alignment.toByteUnits()` instead of direct alignment values

3. **Return Address Parameter**: All allocator functions now include `return_address: usize` parameters for better debugging/tracing.

4. **Pointer Type Changes**: Uses `[*]u8` instead of `[]u8` for allocation returns and `@ptrFromInt`/`@intFromPtr` for pointer-integer conversions.

5. **Error Handling**: Uses `Allocator.Error` type and follows the new allocator error convention where `alloc` returns `?[*]u8` and `resize` returns `bool`.

## 3) The Golden Snippet

```zig
const std = @import("std");

// Platform-specific sbrk implementation
fn my_sbrk(n: usize) usize {
    // Implementation would call actual system sbrk
    return 0; // Simplified
}

test "SbrkAllocator usage" {
    const SbrkAlloc = std.heap.SbrkAllocator(my_sbrk);
    
    // Create allocator instance
    var allocator: SbrkAlloc = .{};
    
    // Use as std.mem.Allocator through vtable
    const allocator_interface: std.mem.Allocator = .{
        .ptr = undefined, // Context not used in this implementation
        .vtable = &SbrkAlloc.vtable,
    };
    
    // The allocator is now ready to use with the standard allocator interface
    _ = allocator_interface;
}
```

## 4) Dependencies

- `std.mem` - Core memory operations, `Allocator` type, alignment handling
- `std.math` - Mathematical operations (`log2`, `ceilPowerOfTwo`, etc.)
- `std.heap` - Page size constants and heap utilities
- `std.Thread` - Mutex for thread safety
- `std.debug` - Assertions for debugging

**Note**: This is a system-level allocator implementation that depends heavily on low-level memory management primitives and mathematical operations for size class calculations.