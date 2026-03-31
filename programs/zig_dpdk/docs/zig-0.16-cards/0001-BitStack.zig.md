# Migration Card: std.BitStack

## 1) Concept

This file implements a stack data structure that stores individual bits (`u1` values) using a byte array as the underlying storage. The `BitStack` struct efficiently packs bits into bytes to minimize memory usage while providing stack operations (push, pop, peek). It includes both a managed version that handles its own memory allocation via an `ArrayList(u8)`, and standalone functions that work with fixed-size buffers for cases where memory management is handled externally.

Key components include the main `BitStack` struct with its managed byte array, core stack operations (push/pop/peek), and utility functions for working with raw byte buffers directly. The implementation handles bit packing/unpacking operations transparently.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `init(allocator: Allocator) @This()` - Factory function requiring explicit allocator
- `deinit(self: *@This()) void` - Explicit cleanup method
- `ensureTotalCapacity()` and `push()` methods return `Allocator.Error` - Explicit error handling for allocation failures

**API Structure Changes:**
- Factory pattern with `init()` instead of direct struct initialization
- Mandatory `deinit()` call for cleanup
- No default initialization - allocator must be provided at creation

**Error Handling:**
- Memory operations return specific `Allocator.Error` rather than generic errors
- Push operations can fail due to allocation and must be handled with `try`

## 3) The Golden Snippet

```zig
const std = @import("std");
const BitStack = std.BitStack;

pub fn main() !void {
    var stack = BitStack.init(std.heap.page_allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(0);
    try stack.push(1);
    try stack.push(0);

    const top_bit = stack.peek(); // Returns 0
    const popped = stack.pop();   // Returns 0
    
    // Cleanup handled by defer
}
```

## 4) Dependencies

- `std.mem.Allocator` - Memory management interface
- `std.array_list.Managed` - Dynamic array implementation for storage
- `std.testing` - Testing utilities (test-only dependency)

**Primary Dependencies Graph:**
```
BitStack → std.array_list.Managed → std.mem.Allocator
```