# Migration Card: `std/heap/debug_allocator.zig`

## 1) Concept

This file implements a debugging allocator for Zig's standard library. It's designed to be used in Debug mode to help detect memory management issues like double frees, memory leaks, and use-after-free errors. The allocator captures stack traces on allocation and free operations, never reuses memory addresses to help detect dangling pointers, and provides comprehensive leak detection.

Key components include:
- Configuration system with compile-time options for stack traces, memory limits, thread safety, and debugging features
- Dual allocation strategy: small allocations are bucketed by power-of-two sizes, while large allocations are handled directly by the backing allocator
- Comprehensive metadata tracking including stack traces, allocation sizes, and alignment information
- Thread-safe operation with configurable mutex types

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The allocator follows the standard allocator interface pattern with `allocator()` method returning an `Allocator` interface
- Backing allocator is configurable via struct field rather than initialization parameter
- Uses the new `mem.Alignment` type instead of raw alignment integers

**I/O Interface Changes:**
- Uses dependency injection for stack trace formatting through `std.Io.tty.Config`
- No direct I/O dependencies in the core allocator interface

**Error Handling Changes:**
- Uses the standard `mem.Allocator.Error` type (which is `error{OutOfMemory}`)
- Error handling follows the standard Zig allocator pattern with optional returns

**API Structure Changes:**
- Factory pattern: `DebugAllocator(config)` returns a type, then instantiate with `init` or field initialization
- Uses `rawAlloc`, `rawResize`, `rawRemap`, `rawFree` interface for backing allocator operations
- Memory alignment uses `mem.Alignment` enum rather than raw integers

## 3) The Golden Snippet

```zig
const std = @import("std");

// Create a debug allocator with default configuration
var debug_allocator = std.heap.DebugAllocator(.{}){};
defer std.debug.assert(debug_allocator.deinit() == .ok);

// Get the allocator interface
const allocator = debug_allocator.allocator();

// Use like any standard allocator
const memory = try allocator.alloc(u8, 100);
defer allocator.free(memory);

// Can also use with create/destroy pattern
const obj = try allocator.create(struct { value: i32 });
defer allocator.destroy(obj);
```

## 4) Dependencies

- `std.mem` - Core memory operations and allocator interface
- `std.math` - Mathematical operations and power-of-two calculations  
- `std.debug` - Stack trace capture and formatting
- `std.log` - Logging for debugging output
- `std.Io.tty` - Terminal configuration for stack trace display
- `std.Thread` - Thread safety (when enabled)
- `std.heap.page_allocator` - Default backing allocator
- `std.builtin` - Builtin types and stack trace definitions

This is a public API file that developers would use for debugging memory issues in their applications.