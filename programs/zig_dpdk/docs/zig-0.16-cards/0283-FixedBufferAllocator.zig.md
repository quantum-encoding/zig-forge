# Migration Card: FixedBufferAllocator

## 1) Concept

This file implements a fixed buffer allocator (also known as a linear allocator or arena allocator) that uses a pre-allocated buffer for all memory allocations. The key components are:

- **FixedBufferAllocator struct**: Contains the underlying buffer and current allocation position (`end_index`)
- **Two allocator interfaces**: Standard `allocator()` for single-threaded use and `threadSafeAllocator()` for concurrent access using atomic operations
- **Memory management functions**: Core allocation, resizing, and freeing operations that work within the fixed buffer bounds
- **Utility methods**: Functions to check ownership of pointers, detect last allocations, and reset the allocator

The allocator operates by linearly advancing through the buffer, making it extremely fast for temporary allocations but limited to the pre-allocated buffer size.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- No factory functions requiring external allocators - uses pre-allocated buffer
- `init()` takes ownership of a pre-existing buffer slice
- Both `allocator()` and `threadSafeAllocator()` return `Allocator` interfaces without requiring external allocators

**I/O Interface Changes:**
- VTable-based allocator pattern using `.vtable = &.{...}` syntax
- Function signatures follow the new `Allocator` interface with `ctx: *anyopaque` parameters
- Alignment uses `mem.Alignment` type instead of raw integers

**Error Handling Changes:**
- Allocation functions return nullable pointers (`?[*]u8`) instead of error unions
- Resize operations return boolean success/failure instead of error sets
- Uses `@ptrCast(@alignCast(ctx))` pattern for type-erased context pointers

**API Structure Changes:**
- Consistent use of `init()` pattern rather than `open()` or factory functions
- Thread-safe variant uses atomic operations and restricts functionality (no resize/remap/free)
- `ownsPtr()` and `ownsSlice()` methods for memory ownership verification

## 3) The Golden Snippet

```zig
const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

// Initialize with a static buffer
var buffer: [1024]u8 = undefined;
var fba = FixedBufferAllocator.init(buffer[0..]);
const allocator = fba.allocator();

// Allocate memory
const slice = try allocator.alloc(u8, 64);
defer allocator.free(slice);

// Use allocated memory
@memset(slice, 0xAA);

// Reset for reuse
fba.reset();
```

## 4) Dependencies

- **std.mem** - Core memory operations, alignment handling, Allocator interface
- **std.debug** - Runtime assertions for debugging
- **std.heap** - Test infrastructure (only in test blocks)

**Primary Dependencies Graph:**
```
FixedBufferAllocator → std.mem → std.debug
                    → std.heap (test only)
```