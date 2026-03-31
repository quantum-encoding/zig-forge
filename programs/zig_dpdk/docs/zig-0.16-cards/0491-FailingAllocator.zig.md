# Migration Card: FailingAllocator.zig

## 1) Concept

This file implements a testing allocator that intentionally fails after a specified number of allocations or resize operations. It's designed to help developers test how their code handles out-of-memory conditions by providing controlled failure points. The key components include configurable failure thresholds for allocation and resize operations, internal state tracking for allocated/freed bytes, and stack trace capture when failures are induced.

The allocator wraps an existing internal allocator and provides the standard `std.mem.Allocator` interface, making it transparent to code that expects a regular allocator while allowing precise control over when memory operations should fail.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- Uses the new allocator interface with explicit VTable pattern (`{.alloc, .resize, .remap, .free}`)
- Requires explicit internal allocator injection via `init()` function
- Factory pattern with `allocator()` method that returns a configured `mem.Allocator`

**I/O Interface Changes:**
- Uses the newer allocator VTable signature with `anyopaque` context pointers
- Implements `rawAlloc`, `rawResize`, `rawRemap`, `rawFree` pattern instead of older allocator methods
- Context casting uses `@ptrCast(@alignCast(ctx))` pattern

**API Structure Changes:**
- Constructor pattern: `init(internal_allocator, config)` + `allocator()` method chain
- Direct struct initialization replaced with factory method pattern
- Config struct with default values for failure thresholds

## 3) The Golden Snippet

```zig
const std = @import("std");
const FailingAllocator = std.testing.FailingAllocator;

test "basic usage" {
    var failing_allocator_state = FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    const failing_alloc = failing_allocator_state.allocator();

    const a = try failing_alloc.create(i32);
    defer failing_alloc.destroy(a);
    const b = try failing_alloc.create(i32);
    defer failing_alloc.destroy(b);
    try std.testing.expectError(error.OutOfMemory, failing_alloc.create(i32));
}
```

## 4) Dependencies

- `std.mem` (primary dependency for Allocator interface)
- `std.debug` (for stack trace functionality)
- `std.math` (for maxInt constants)
- `std.testing` (used in tests, but not in public API)

This file provides public testing utilities that developers would use to test memory failure scenarios in their applications.