# Migration Card: `std/heap/arena_allocator.zig`

## 1) Concept

This file implements an arena allocator that wraps another allocator and provides batch memory management. The key characteristic is that it allows allocating many individual items and then freeing them all at once with `deinit()` or `reset()`. Individual `free()` calls only work for the most recent allocation, making it efficient for temporary allocations that share the same lifetime.

The main components are:
- `ArenaAllocator` struct containing the child allocator and internal state
- `State` struct that can be stored separately for memory optimization
- `ResetMode` enum controlling how `reset()` handles existing capacity
- VTable-based allocator interface with `alloc`, `resize`, `remap`, and `free` functions

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- Uses `init(child_allocator: Allocator)` pattern rather than factory functions
- Allocator is explicitly passed and stored as `child_allocator`
- `allocator()` method returns an `Allocator` interface with proper vtable

**I/O Interface Changes:**
- Uses the new `Alignment` type instead of raw alignment integers
- Implements the vtable-based allocator pattern with `.alloc`, `.resize`, `.remap`, `.free` functions
- Uses `@returnAddress()` for better debugging information

**Error Handling Changes:**
- `reset()` returns `bool` instead of void to indicate success/failure
- Uses `?` optional types for allocation failures rather than error sets
- Consistent with Zig's move toward explicit error handling through return values

**API Structure Changes:**
- `init()`/`deinit()` pattern for lifecycle management
- `allocator()` method provides the interface rather than the struct itself being the allocator
- `reset()` with configurable modes instead of simple reset functionality
- `queryCapacity()` method for introspection

## 3) The Golden Snippet

```zig
const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

test "basic arena usage" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    const allocator = arena.allocator();
    
    // Allocate some memory
    const slice1 = try allocator.alloc(u8, 100);
    const slice2 = try allocator.alloc(u8, 200);
    
    // Reset with capacity retention
    const success = arena.reset(.retain_capacity);
    try std.testing.expect(success);
    
    // Allocate again - uses retained capacity
    const slice3 = try allocator.alloc(u8, 150);
}
```

## 4) Dependencies

- `std.mem` (Allocator, Alignment, memory operations)
- `std.debug` (assertions)
- `std.SinglyLinkedList` (internal buffer management)
- `std.testing` (test utilities)
- `std.Random` (test randomization)

The file has moderate dependencies, primarily relying on core memory management types and data structures.