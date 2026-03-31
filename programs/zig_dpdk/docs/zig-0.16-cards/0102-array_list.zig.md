# Migration Card: std/array_list.zig

## 1) Concept

This file implements a generic, dynamically growing array list (vector) for Zig. It provides two main types: `Managed` (deprecated) which stores an allocator internally, and `Aligned` (the current `ArrayList` type) which requires passing an allocator to each operation. The key components include:

- **Managed ArrayList**: Stores allocator internally, provides automatic memory management
- **Aligned/Unmanaged ArrayList**: External allocator management, more flexible memory control
- Core operations: append, insert, remove, resize, capacity management
- Support for sentinel-terminated slices and custom alignment

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Managed → Unmanaged transition**: The `Managed` type is deprecated in favor of `Aligned` (the current `ArrayList`)
- **Allocator parameter injection**: All memory operations now require explicit allocator parameters
- **Factory pattern changes**: From `init()` to `initCapacity(gpa)` with allocator parameter

### Function Signature Changes
**From Managed (0.11 pattern):**
```zig
// Old pattern - allocator stored internally
var list = Managed(u8).init(allocator);
list.append(item);
list.deinit();
```

**To Aligned/ArrayList (0.16 pattern):**
```zig
// New pattern - allocator passed to operations  
var list = ArrayList(u8).initCapacity(allocator, 0);
list.append(allocator, item);
list.deinit(allocator);
```

### Key API Structure Changes
- `Managed.init()` → `Aligned.initCapacity(gpa, num)`
- `append(item)` → `append(gpa, item)`
- `insert(i, item)` → `insert(gpa, i, item)`
- `resize(new_len)` → `resize(gpa, new_len)`
- `deinit()` → `deinit(gpa)`

### Error Handling
- **Consistent error types**: All operations return `Allocator.Error!void` or specific slice types
- **Bounded variants**: New `*Bounded` functions return `error{OutOfMemory}!` for capacity-checked operations
- **Assume capacity variants**: `*AssumeCapacity` functions for pre-allocated scenarios

## 3) The Golden Snippet

```zig
const std = @import("std");
const ArrayList = std.ArrayList;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var list = ArrayList(u8).initCapacity(allocator, 10);
    defer list.deinit(allocator);
    
    try list.append(allocator, 'H');
    try list.appendSlice(allocator, "ello");
    try list.insert(allocator, 1, 'a');
    
    std.debug.print("{s}\n", .{list.items}); // Prints "Hallo"
    
    const owned_slice = try list.toOwnedSlice(allocator);
    defer allocator.free(owned_slice);
}
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.mem` (as `mem`) - Memory operations, allocator interface
- `std.math` (as `math`) - Mathematical operations, bounds checking  
- `std.debug` (as `debug`) - Assertions and debugging utilities
- `std.testing` - Test framework (test-only)

**Core Dependencies:**
- `Allocator = mem.Allocator` - Memory allocation interface
- `ArrayList = std.ArrayList` - Type alias for current implementation
- Memory alignment types and slice operations

**Dependency Graph Impact:**
- Any code using array lists must now propagate allocator parameters
- Migration requires updating all array list operations to pass allocators
- Test code requires significant updates due to API changes