# Migration Card: std.mem.Allocator

## 1) Concept

This file defines the standard memory allocation interface for Zig - the core `Allocator` type that serves as the foundation for all memory management in Zig programs. It implements a vtable-based interface pattern where the `Allocator` struct contains a type-erased pointer and a virtual function table with four core operations: `alloc`, `resize`, `remap`, and `free`.

Key components include:
- The `Allocator` struct with `ptr` and `vtable` fields for polymorphism
- The `VTable` struct defining the four fundamental allocation operations
- High-level convenience functions like `create`, `destroy`, `alloc`, `free`, `resize`, `remap`, and `realloc`
- Utility functions like `dupe` and `dupeZ` for copying slices
- A `failing` allocator instance that always returns OutOfMemory

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The allocator is now passed explicitly as the first parameter to all functions (consistent pattern)
- Factory functions like `create` and `alloc` require explicit allocator instances rather than global allocators

**API Structure Changes:**
- Enhanced alignment handling with new `Alignment` type replacing raw integers
- Added `remap` operation in vtable for efficient in-place resizing with relocation
- `allocWithOptions` and `allocWithOptionsRetAddr` provide flexible allocation with alignment and sentinel support
- `reallocAdvanced` function added with explicit return address parameter

**Error Handling Changes:**
- All allocation functions return `Error!T` where `Error = error{OutOfMemory}`
- Consistent error handling pattern across all allocation operations
- Zero-sized types handled specially with compile-time address calculations

**Return Address Integration:**
- All vtable operations and many public functions now accept `ret_addr: usize` parameters
- `@returnAddress()` used extensively for better debugging and profiling

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a single item
    const item = try allocator.create(i32);
    defer allocator.destroy(item);
    item.* = 42;

    // Allocate a slice
    const slice = try allocator.alloc(u8, 100);
    defer allocator.free(slice);

    // Allocate with sentinel
    const sentinel_slice = try allocator.allocSentinel(u8, 10, 0);
    defer allocator.free(sentinel_slice);

    // Resize allocation
    if (allocator.resize(slice, 150)) {
        // Resize succeeded in-place
    } else {
        // Need to use realloc for relocation
        const new_slice = try allocator.realloc(slice, 150);
        // use new_slice...
    }
}
```

## 4) Dependencies

- `std.mem` - Core memory operations (sliceAsBytes, bytesAsSlice, alignment utilities)
- `std.math` - Mathematical operations (multiplication with overflow checking, Log2Int)
- `std.debug` - Assertions for debugging
- `builtin` - Compiler intrinsics and target information

The file serves as a fundamental dependency for virtually all Zig code that performs dynamic memory allocation, making it one of the most imported modules in the standard library.