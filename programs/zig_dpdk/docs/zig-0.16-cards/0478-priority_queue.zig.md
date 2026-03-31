# Migration Card: `std/priority_queue.zig`

## 1) Concept

This file implements a generic priority queue data structure in Zig's standard library. It's a heap-based priority queue that can be configured as either a min-heap or max-heap depending on the provided comparison function. The key components include:

- A generic `PriorityQueue` type that takes three compile-time parameters: the element type `T`, a context type `Context`, and a comparison function `compareFn`
- Standard heap operations including `add`, `remove`, `peek`, and capacity management
- Support for both value-based and context-based comparison functions
- Iterator support for non-destructive traversal of elements (though not in priority order)

The priority queue maintains elements in a binary heap structure where the highest priority element (determined by the comparison function) is always at the root and can be efficiently removed.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory pattern**: The `init` function requires an explicit allocator parameter: `init(allocator: Allocator, context: Context) Self`
- **Owned slice constructor**: `fromOwnedSlice` also requires explicit allocator: `fromOwnedSlice(allocator: Allocator, items: []T, context: Context) Self`
- **Memory management**: All memory operations delegate to the stored allocator instance

### API Structure Changes
- **Consistent initialization**: Uses `init` pattern rather than separate constructors
- **Explicit context passing**: The comparison function receives a context parameter, enabling both context-free (`void` context) and context-aware comparisons
- **Capacity management**: Methods like `ensureTotalCapacity`, `ensureUnusedCapacity`, and `shrinkAndFree` provide fine-grained memory control

### Error Handling
- **Specific error types**: Methods like `add`, `ensureTotalCapacity` return concrete error sets (primarily allocation errors)
- **Option types**: `removeOrNull` and `peek` use option types for safe empty queue handling

## 3) The Golden Snippet

```zig
const std = @import("std");

// Define comparison function
fn lessThan(context: void, a: u32, b: u32) std.math.Order {
    _ = context;
    return std.math.order(a, b);
}

// Create priority queue type
const PQ = std.PriorityQueue(u32, void, lessThan);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Initialize queue with allocator and context
    var queue = PQ.init(allocator, {});
    defer queue.deinit();

    // Add elements
    try queue.add(54);
    try queue.add(12);
    try queue.add(7);

    // Peek at highest priority element
    if (queue.peek()) |value| {
        std.debug.print("Next element: {}\n", .{value}); // Prints: 7
    }

    // Remove elements in priority order
    while (queue.removeOrNull()) |value| {
        std.debug.print("{}\n", .{value}); // Prints: 7, 12, 54
    }
}
```

## 4) Dependencies

- `std.mem` - For `Allocator` type and memory management
- `std.math` - For `Order` enum and comparison utilities
- `std.debug` - For `assert` function used in internal validation

The priority queue has minimal dependencies, primarily relying on memory allocation and mathematical ordering, making it a lightweight but essential data structure in Zig's standard library.