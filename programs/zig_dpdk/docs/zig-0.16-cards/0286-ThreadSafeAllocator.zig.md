# Migration Card: std.heap.ThreadSafeAllocator

## 1) Concept

This file implements a thread-safe wrapper for non-thread-safe allocators in Zig's standard library. The `ThreadSafeAllocator` struct wraps any existing allocator and adds synchronization via a mutex to make it safe for concurrent use across multiple threads.

Key components include:
- A `child_allocator` field that holds the underlying allocator to be wrapped
- A `mutex` (std.Thread.Mutex) that provides thread synchronization
- An `allocator()` method that returns a thread-safe Allocator interface
- Vtable implementations (alloc, resize, remap, free) that wrap the child allocator's operations with proper locking

## 2) The 0.11 vs 0.16 Diff

**Allocator Interface Changes:**
- Uses the new raw allocator interface (`rawAlloc`, `rawResize`, `rawRemap`, `rawFree`) instead of the old `alloc`, `resize`, `free` methods
- The vtable pattern is now explicit with `.alloc`, `.resize`, `.remap`, `.free` function pointers
- Alignment parameters now use `std.mem.Alignment` type instead of `u29`

**API Structure:**
- Factory pattern: `allocator()` method returns a configured Allocator interface rather than direct struct usage
- Context passing via `*anyopaque` with proper pointer casting using `@ptrCast(@alignCast(ctx))`
- Explicit mutex locking with `defer` pattern for guaranteed unlocking

**Error Handling:**
- Uses the newer raw allocator interface that returns nullable pointers and booleans rather than error sets
- Return address parameters (`ra`, `ret_addr`) are now required for better debugging

## 3) The Golden Snippet

```zig
const std = @import("std");
const ThreadSafeAllocator = std.heap.ThreadSafeAllocator;

// Wrap a non-thread-safe allocator
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var thread_safe_arena = ThreadSafeAllocator{ .child_allocator = arena.allocator() };

// Get the thread-safe interface
const allocator = thread_safe_arena.allocator();

// Use from multiple threads safely
const memory = try allocator.alloc(u8, 100);
defer allocator.free(memory);
```

## 4) Dependencies

- `std.mem` (for `Allocator` and `Alignment`)
- `std.Thread` (for `Mutex`)
- `std.heap` (child allocator implementations)

This file serves as an adapter layer between the core allocator interface and thread synchronization primitives.