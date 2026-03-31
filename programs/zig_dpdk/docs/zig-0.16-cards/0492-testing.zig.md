# Migration Card: `std/testing.zig`

## 1) Concept

This file provides the core testing utilities for Zig's standard library. It contains assertion functions, testing allocators, temporary directory management, and utilities for comprehensive test validation. The key components include:

- **Assertion functions**: `expectEqual`, `expectError`, `expectApproxEqAbs`, `expectEqualStrings`, etc.
- **Testing allocators**: Deterministic allocators for memory testing including a failing allocator for OOM testing
- **Test infrastructure**: Global test allocator, I/O instance, random seed, and temporary directory creation
- **Comparison utilities**: Deep equality checking, string comparison with diff output, and type-aware comparison

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Global allocator pattern**: Uses `std.heap.GeneralPurposeAllocator` with custom canary for test isolation
- **Failing allocator**: `FailingAllocator` requires explicit backing allocator injection
- **Memory testing**: `checkAllAllocationFailures` requires explicit backing allocator parameter

### I/O Interface Changes
- **Threaded I/O**: Uses `std.Io.Threaded` instance with dependency injection via `io_instance`
- **Tty configuration**: Colorized output uses `std.Io.tty.Config` detection pattern
- **Reader interfaces**: New `Reader` and `ReaderIndirect` types with vtable-based streaming

### Error Handling Changes
- **Specific error types**: Functions return specific test errors like `error.TestExpectedEqual`, `error.TestUnexpectedError`
- **Error union handling**: `expectError` uses modern error union syntax with `|payload|` and `|error|` capture
- **Deep error checking**: `expectEqualDeep` provides comprehensive error context for complex types

### API Structure Changes
- **Factory functions**: `tmpDir()` replaces manual temporary directory creation
- **Streaming interfaces**: New `Reader` pattern with vtable-based streaming instead of simple buffer readers
- **Allocation testing**: `checkAllAllocationFailures` provides systematic OOM testing framework

## 3) The Golden Snippet

```zig
const std = @import("std");
const testing = std.testing;

test "basic assertions" {
    // Simple equality
    try testing.expectEqual(42, 42);
    
    // String comparison
    try testing.expectEqualStrings("hello", "hello");
    
    // Error checking
    const result = std.fs.cwd().openFile("nonexistent", .{});
    try testing.expectError(error.FileNotFound, result);
    
    // Memory allocation testing
    try testing.checkAllAllocationFailures(testing.allocator, testFunction, .{});
}

fn testFunction(allocator: std.mem.Allocator) !void {
    const slice = try allocator.alloc(u8, 100);
    defer allocator.free(slice);
    // ... test logic
}
```

## 4) Dependencies

- `std.mem` - Memory operations and slicing
- `std.math` - Floating point comparisons and math utilities  
- `std.heap` - Allocator implementations
- `std.fs` - File system operations for temporary directories
- `std.Io` - I/O streaming and TTY configuration
- `std.debug` - Assertions and stack traces
- `std.crypto.random` - Random number generation
- `std.fmt` - String formatting

The file maintains strong dependencies on core memory, I/O, and debugging modules while providing comprehensive testing utilities that work with Zig 0.16's allocator-first and interface-based patterns.