# Migration Card: std.StaticStringMap

## 1) Concept

This file implements `StaticStringMap`, a compile-time optimized string-to-value mapping structure designed for small sets of disparate string keys. The key innovation is that it separates keys by length during initialization and only compares strings of equal length at runtime, making lookups more efficient.

The main components are:
- `StaticStringMap(V)` - The primary type constructor for case-sensitive string maps
- `StaticStringMapWithEql(V, eql)` - A more flexible version that accepts a custom equality function
- Two initialization patterns: `initComptime()` for compile-time initialization and `init()` for runtime allocation
- Support for both normal value types and `void` value types (effectively creating a string set)

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Runtime initialization requires explicit allocator**: The `init()` function now takes an `allocator: mem.Allocator` parameter and returns `!Self` (can fail)
- **Explicit deinitialization**: Added `deinit(self: Self, allocator: mem.Allocator)` method that must be called to free runtime-allocated resources
- **Dual initialization patterns**: Maintains both `initComptime()` (no allocator) and `init()` (with allocator) patterns

### API Structure Changes
- **Consistent factory pattern**: Both `StaticStringMap()` and `StaticStringMapWithEql()` return types that use the same initialization interface
- **Enhanced error handling**: Runtime `init()` now returns error union to handle allocation failures
- **Memory ownership**: Clear separation between compile-time owned maps (no cleanup) and runtime maps (require `deinit`)

### Key Signature Changes
```zig
// 0.16 pattern - explicit allocator and error handling
pub fn init(kvs_list: anytype, allocator: mem.Allocator) !Self
pub fn deinit(self: Self, allocator: mem.Allocator) void

// Compile-time alternative (unchanged from older patterns)
pub inline fn initComptime(comptime kvs_list: anytype) Self
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const StaticStringMap = std.StaticStringMap;

const Color = enum { red, green, blue };

// Compile-time initialization (no allocator needed)
const compile_time_map = StaticStringMap(Color).initComptime(.{
    .{ "red", .red },
    .{ "green", .green }, 
    .{ "blue", .blue },
});

// Runtime initialization (requires allocator and cleanup)
var runtime_map = try StaticStringMap(Color).init(.{
    .{ "red", .red },
    .{ "green", .green },
    .{ "blue", .blue },
}, std.heap.page_allocator);
defer runtime_map.deinit(std.heap.page_allocator);

// Usage (same for both)
const found_color = compile_time_map.get("green");
std.debug.print("Found: {?}\n", .{found_color}); // Output: Found: green
```

## 4) Dependencies

- **std.mem** - Heavy usage for memory operations, sorting, and allocator interface
- **std.math** - Used for bounds calculations and logarithms in comptime initialization
- **std.ascii** - Used in `eqlAsciiIgnoreCase` for case-insensitive comparison
- **std.testing** - Extensive test infrastructure (development dependency)

The module has minimal external dependencies, primarily relying on core memory and math utilities, making it suitable for constrained environments.