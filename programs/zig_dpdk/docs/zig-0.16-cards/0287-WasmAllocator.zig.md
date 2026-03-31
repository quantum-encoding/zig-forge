# Migration Card: WasmAllocator.zig

## 1) Concept

This file implements a WebAssembly-specific memory allocator that provides dynamic memory allocation for Zig programs running in WebAssembly environments. The allocator uses a size-class based approach with free lists for efficient memory management, handling both small allocations (up to 64KB) and large allocations (multiple 64KB pages). Key components include global free lists for different size classes, WebAssembly memory growth operations via `@wasmMemoryGrow`, and a virtual function table (`vtable`) that implements the standard `Allocator` interface.

The allocator is specifically designed for WebAssembly targets and enforces single-threaded operation through compile-time checks. It maintains separate allocation strategies for small objects (using fixed-size classes) and large objects (using big page allocations), with both using free lists for reuse of freed memory.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **VTable-based Allocator Pattern**: Uses the new `Allocator.VTable` structure with function pointers (`alloc`, `resize`, `remap`, `free`) instead of method-based interface
- **Context Parameter**: All allocator functions now take `ctx: *anyopaque` as first parameter, though this implementation doesn't use it
- **Memory Alignment**: Uses `mem.Alignment` type instead of raw alignment integers, with `.toByteUnits()` method calls

### I/O Interface Changes
- **No Traditional I/O**: This is a memory allocator, not an I/O component
- **WebAssembly System Interface**: Uses `@wasmMemoryGrow` builtin for memory expansion

### Error Handling Changes
- **Error Type**: Uses `Allocator.Error` alias, maintaining compatibility with standard error handling
- **Nullable Returns**: `alloc` returns `?[*]u8` instead of error union, following the new allocator pattern
- **Boolean Resize**: `resize` returns `bool` instead of error/success codes

### API Structure Changes
- **No Init Function**: The allocator is stateless and uses global variables, so no initialization function is needed
- **Direct VTable Usage**: Consumers create allocators using `Allocator{ .ptr = undefined, .vtable = &vtable }`

## 3) The Golden Snippet

```zig
const std = @import("std");
const WasmAllocator = std.heap.WasmAllocator;

// Create the allocator instance
const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &WasmAllocator.vtable,
};

// Usage example from the test suite
var slice = try allocator.alloc(u8, 1025);
defer allocator.free(slice);

slice[0] = 0x12;
slice[1024] = 0x34;
```

## 4) Dependencies

- `std.mem` - Core memory operations and Allocator interface
- `std.math` - Power-of-two calculations and logarithmic operations  
- `std.wasm` - WebAssembly-specific constants and page size definitions
- `std.debug` - Assertions for debugging (development only)
- `std.testing` - Test utilities (test builds only)

**Note**: The file has compile-time guards ensuring it only compiles for WebAssembly targets and single-threaded environments.