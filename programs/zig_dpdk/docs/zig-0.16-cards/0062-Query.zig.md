# Migration Card: `std.Target.Query`

## 1) Concept

This file defines the `Query` struct, which is a configuration object for target specification in Zig's build system and cross-compilation infrastructure. It contains all the same data as `Target` but introduces the concept of "the native target" with meaningful defaults. Key components include CPU architecture/model/features, OS specifications, ABI settings, and version ranges for various target components.

The main purpose is to provide a flexible way to specify compilation targets through parsing target triples (like "x86_64-linux-gnu") and CPU feature strings, then converting these queries into concrete `Target` objects. It handles both native target detection and cross-compilation target specification.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`zigTriple`**: Now requires explicit allocator parameter for string formatting
- **`serializeCpuAlloc`**: Factory function that takes allocator and returns allocated string
- **`allocDescription`**: Takes explicit allocator parameter for description generation

### API Structure Changes
- **Factory functions**: `parse()` static method instead of constructor pattern
- **Memory management**: Functions returning strings now explicitly take allocators
- **Error handling**: Specific error types like `error.UnknownArchitecture`, `error.UnknownCpuFeature`

### Pattern Changes
- No `init()` constructor - uses `parse()` factory method
- String formatting functions require explicit allocator injection
- Query objects are value types, not requiring allocation for basic usage

## 3) The Golden Snippet

```zig
const std = @import("std");
const Query = std.Target.Query;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Parse target specification
    const query = try Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = "x86_64+sse-sse2-avx-cx8",
    });
    
    // Generate zig triple string (requires allocator in 0.16)
    const triple = try query.zigTriple(allocator);
    defer allocator.free(triple);
    
    std.debug.print("Target triple: {s}\n", .{triple});
}
```

## 4) Dependencies

- `std.mem` (memory operations, string splitting)
- `std.Target` (target specification types)
- `std.ArrayList` (dynamic string building)
- `std.SemanticVersion` (version parsing and comparison)
- `std.meta` (enum string conversion)
- `std.fmt` (number parsing)
- `builtin` (native target detection)

The file has moderate dependencies focused on string processing, target specification types, and memory management for string formatting operations.