# Migration Card: `std/hash/auto_hash.zig`

## 1) Concept

This file provides generic automatic hashing functionality for Zig types. It contains a strategy-based hashing system that can handle various data types including primitives, pointers, structs, unions, and containers. The key components are:

- `HashStrategy` enum that defines how pointers should be handled (Shallow, Deep, or DeepRecursive)
- Core `hash` function that dispatches based on type information and strategy
- Helper functions for specific type categories like `hashPointer` and `hashArray`
- `autoHash` function as a convenience wrapper that uses shallow strategy and provides compile-time safety for slices

The system uses Zig's compile-time reflection capabilities to automatically generate appropriate hashing behavior for any supported type without requiring manual implementation.

## 2) The 0.11 vs 0.16 Diff

This file represents a **new addition** to the standard library rather than a migration from existing 0.11 APIs. The public API patterns show modern Zig 0.16 conventions:

**Strategy-based Hashing Pattern:**
```zig
// 0.16 pattern - explicit strategy selection
hash(hasher, value, .Shallow);    // Hash pointers as addresses
hash(hasher, value, .Deep);       // Hash one level of pointer dereference  
hash(hasher, value, .DeepRecursive); // Hash through all pointer chains
```

**Hasher Interface Pattern:**
- Uses dependency injection - accepts any type that implements the hasher interface
- No explicit allocator requirements in the core hashing functions
- Compile-time type introspection for automatic dispatch

**Safety-Oriented Design:**
- `autoHash` function provides compile-time protection against ambiguous slice handling
- Clear error messages for unsupported types via `@compileError`
- Tagged union requirement for hashing unions

## 3) The Golden Snippet

```zig
const std = @import("std");
const auto_hash = std.hash.auto_hash;

// Example: Hashing a struct with different strategies
const Point = struct {
    x: u32,
    y: u32,
    name: []const u8,
};

test "auto_hash usage example" {
    var hasher = std.hash.Wyhash.init(0);
    const point = Point{ .x = 10, .y = 20, .name = "test" };
    
    // Shallow hashing - pointers treated as addresses
    auto_hash.hash(&hasher, point, .Shallow);
    const shallow_hash = hasher.final();
    
    // Reset for deep hashing
    hasher = std.hash.Wyhash.init(0);
    auto_hash.hash(&hasher, point, .Deep);
    const deep_hash = hasher.final();
    
    // The hashes will differ due to different pointer handling
    try std.testing.expect(shallow_hash != deep_hash);
}
```

## 4) Dependencies

- `std.mem` - Used for byte manipulation and memory operations
- `std.meta` - Used for compile-time type introspection (hasUniqueRepresentation, activeTag)
- `std.debug` - Used for assertions
- `std.math` - Used for bit size calculations

**Note:** The file has minimal external dependencies and focuses primarily on compile-time type manipulation and memory operations.