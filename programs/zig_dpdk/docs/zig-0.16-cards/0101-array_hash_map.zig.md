# ArrayHashMap Migration Analysis

## 1) Concept

This file implements an array-backed hash map data structure that preserves insertion order. It provides two main variants: `ArrayHashMap` (managed version that stores an allocator) and `ArrayHashMapUnmanaged` (unmanaged version that requires passing an allocator to each function). The key innovation is using a MultiArrayList for storage while maintaining a separate index structure for efficient lookups when the map grows beyond a small size.

The main components include:
- **ArrayHashMap/ArrayHashMapUnmanaged**: Primary hash map types with configurable key/value types, context, and hash storage
- **AutoArrayHashMap/AutoArrayHashMapUnmanaged**: Convenience types with automatic hash/equality functions
- **StringArrayHashMap**: Specialized version for string keys
- **IndexHeader**: Internal structure for managing the lookup index
- **Entry/KV types**: Access patterns for map elements

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Managed vs Unmanaged split**: Clear separation between `ArrayHashMap` (stores allocator) and `ArrayHashMapUnmanaged` (requires allocator parameter)
- **Factory functions**: `init()` and `initContext()` for managed version vs direct initialization for unmanaged
- **Allocator propagation**: All memory operations explicitly require allocator in unmanaged version

### Context-Based Hashing & Equality
- **Explicit context parameters**: Most operations have `Context` and `Adapted` variants
- **Compile-time context validation**: Functions check context size and provide helpful error messages
- **Flexible adaptation**: `getOrPutAdapted`, `getEntryAdapted`, etc. allow custom lookup contexts

### API Structure Changes
- **Enhanced capacity management**: `ensureTotalCapacityContext`, `ensureUnusedCapacityContext`
- **Multiple removal strategies**: `swapRemove` vs `orderedRemove` with context variants
- **Advanced operations**: `reIndexContext`, `sortContext`, `setKeyContext` for direct manipulation

### Error Handling
- **Explicit error sets**: Most operations return `Allocator.Error` (`Oom` alias)
- **Capacity assertions**: `AssumeCapacity` variants for when allocation is guaranteed
- **Safety locking**: `pointer_stability` mechanism to detect invalid pointer access

## 3) The Golden Snippet

```zig
const std = @import("std");

// Create a managed string-to-integer map
var map = std.array_hash_map.StringArrayHashMap(i32).init(std.heap.page_allocator);
defer map.deinit();

// Insert values
try map.put("apple", 5);
try map.put("banana", 3);
try map.put("cherry", 8);

// Get or insert with context
const result = try map.getOrPut("banana");
if (result.found_existing) {
    result.value_ptr.* += 1; // Increment existing value
} else {
    result.value_ptr.* = 1;  // Initialize new value
}

// Iterate in insertion order
var it = map.iterator();
while (it.next()) |entry| {
    std.debug.print("{}: {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
}

// Remove an element
_ = map.swapRemove("apple");
```

## 4) Dependencies

- **std.mem** - Memory operations, allocator interface
- **std.debug** - Assertions and safety checking
- **std.math** - Bit operations and math utilities  
- **std.hash.Wyhash** - Default hashing algorithm
- **std.testing** - Test framework (test-only)
- **std.sort** - Sorting algorithms (for sort operations)

The file has minimal external dependencies, primarily relying on core memory and utility modules, making it a foundational data structure in the Zig standard library.