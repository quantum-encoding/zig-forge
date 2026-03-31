# Migration Card: `std/deque.zig`

## 1) Concept

This file implements a generic double-ended queue (deque) data structure in Zig's standard library. A deque provides O(1) push/pop operations from both ends while maintaining contiguous storage. The implementation uses a ring buffer approach where elements can wrap around the underlying buffer.

Key components include:
- A generic `Deque(T)` type that works with any element type
- Dynamic capacity management with both linear and precise growth strategies
- Support for both allocator-managed and externally-managed buffers
- Iteration support and bounds-checked access methods
- Comprehensive error handling for memory allocation failures

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory functions require allocators**: `initCapacity()` takes an `Allocator` parameter and returns `Allocator.Error!Self`
- **Memory management methods require allocators**: `deinit()`, `ensureTotalCapacity()`, `ensureTotalCapacityPrecise()`, `ensureUnusedCapacity()` all require explicit `Allocator` parameters
- **Push operations require allocators**: `pushFront()` and `pushBack()` take `Allocator` parameters for potential capacity expansion

### I/O Interface Changes
- **No traditional I/O dependencies**: This is a pure data structure without file/network I/O
- **Memory management interface**: Uses `Allocator` abstraction consistently throughout the API

### Error Handling Changes
- **Specific error sets**: Methods that can fail return specific error sets like `error{OutOfMemory}` or `Allocator.Error`
- **Bounded operations**: Separate methods like `pushFrontBounded()` and `pushBackBounded()` that don't allocate but return `error{OutOfMemory}` when capacity is exhausted
- **Assume capacity variants**: Methods like `pushFrontAssumeCapacity()` that assert capacity is available

### API Structure Changes
- **Factory pattern**: `initCapacity()` returns an initialized instance rather than modifying an existing one
- **Explicit cleanup**: `deinit()` method for resource cleanup with allocator parameter
- **Capacity management**: Separate methods for precise vs amortized growth strategies

## 3) The Golden Snippet

```zig
const std = @import("std");
const Deque = std.Deque;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Initialize deque with capacity
    var deque = try Deque(u32).initCapacity(allocator, 4);
    defer deque.deinit(allocator);
    
    // Push items to both ends
    try deque.pushFront(allocator, 1);
    try deque.pushBack(allocator, 2);
    try deque.pushFront(allocator, 0);
    try deque.pushBack(allocator, 3);
    
    // Iterate and process
    var it = deque.iterator();
    while (it.next()) |item| {
        std.debug.print("Item: {}\n", .{item});
    }
    
    // Pop from both ends
    while (deque.popFront()) |item| {
        std.debug.print("Popped: {}\n", .{item});
    }
}
```

## 4) Dependencies

- `std.mem.Allocator` - Memory management abstraction
- `std.debug.assert` - Runtime assertions for preconditions
- `std.ArrayList` - Used for capacity growth calculations
- `std.testing` - Test framework (test-only dependency)
- `std.Random` - Random number generation (test-only dependency)

The primary dependency is `std.mem.Allocator`, which is central to the memory management pattern used throughout the API.