# Migration Card: std.hash_map.zig

## 1) Concept

This file implements a generic hash map data structure for Zig's standard library. It provides both managed and unmanaged versions of hash maps, with the managed version (`HashMap`) storing an allocator internally and the unmanaged version (`HashMapUnmanaged`) requiring explicit allocator passing. The implementation uses open addressing with linear probing and tombstone-based deletion. Key components include automatic hash/equality functions, string-specific variants, and support for custom context types that define hash and equality operations.

The hash map is designed for high performance with high load factors (default 80%) and provides comprehensive functionality including insertion, lookup, deletion, iteration, capacity management, and cloning. It uses Wyhash as the default hash function and provides specialized string handling through `StringHashMap` and `StringHashMapUnmanaged`.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Managed vs Unmanaged split**: The API is split into `HashMap` (stores allocator) and `HashMapUnmanaged` (requires allocator parameter)
- **Context-aware functions**: Most operations now require explicit context passing with `Context` suffix functions
- **Factory patterns**: `init()` and `initContext()` for managed maps vs direct construction for unmanaged

### API Structure Changes
- **Context injection**: All hash/equality operations now go through a context parameter
- **Error handling**: Operations that allocate return `Allocator.Error` instead of generic errors
- **Adapted functions**: Support for pseudo-keys via `Adapted` variants that take custom comparison contexts

### Key Signature Changes
```zig
// 0.16 pattern - explicit context and allocator management
var map = AutoHashMap(u32, u32).init(allocator);
try map.put(key, value);  // Uses stored allocator

// vs unmanaged approach
var map = AutoHashMapUnmanaged(u32, u32){};
try map.put(allocator, key, value);  // Explicit allocator
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const AutoHashMap = std.AutoHashMap;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var map = AutoHashMap(u32, u32).init(allocator);
    defer map.deinit();

    // Basic operations
    try map.put(1, 100);
    try map.put(2, 200);
    
    // Lookup
    if (map.get(1)) |value| {
        std.debug.print("Found value: {}\n", .{value});
    }
    
    // Iteration
    var it = map.iterator();
    while (it.next()) |entry| {
        std.debug.print("Key: {}, Value: {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
    
    // Capacity management
    try map.ensureTotalCapacity(50);
}
```

## 4) Dependencies

- **std.mem** - Memory allocation, alignment, and byte operations
- **std.math** - Power-of-two calculations and mathematical utilities  
- **std.hash** - Hash functions (Wyhash, autoHash)
- **std.debug** - Assertions and safety checking
- **std.meta** - Type reflection and equality checking
- **std.array_list** - Used in string index context implementations

The module has heavy dependency on memory management patterns and relies extensively on `std.mem` for allocator interfaces and memory operations. Hash function dependencies are centralized in `std.hash` with Wyhash as the default implementation.