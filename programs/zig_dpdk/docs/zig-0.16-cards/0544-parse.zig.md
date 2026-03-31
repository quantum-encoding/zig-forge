# Migration Card: std.zon.parse

## 1) Concept

This file provides runtime parsing of ZON (Zig Object Notation) data into Zig types. ZON is a data serialization format that uses Zig syntax for representing structured data. The module offers multiple entry points for parsing ZON from source strings, from Zoir (Zig Object Intermediate Representation) nodes, or from specific nodes within a Zoir structure.

Key components include:
- **Parser functions**: `fromSlice`/`fromSliceAlloc` for parsing from source strings, `fromZoir`/`fromZoirAlloc` for parsing from Zoir nodes, and node-specific variants
- **Configuration**: `Options` struct for parser behavior (ignoring unknown fields, error cleanup)
- **Error handling**: Comprehensive `Error` union and `Diagnostics` struct for detailed error reporting
- **Memory management**: `free` function for cleaning up allocated ZON values and type system checks for allocation requirements

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory functions**: `fromSliceAlloc`, `fromZoirAlloc`, `fromZoirNodeAlloc` all require explicit `gpa: Allocator` parameter
- **Memory-freeing**: Dedicated `free(gpa: Allocator, value: anytype)` function for cleaning up allocated values
- **Allocation detection**: `requiresAllocator(T: type)` comptime function to determine if a type needs allocation

### API Structure Changes
- **Init vs Open pattern**: Consistent use of `fromSlice` (no allocation) vs `fromSliceAlloc` (with allocation) naming
- **Diagnostics injection**: Optional `diag: *Diagnostics` parameter for detailed error reporting
- **Options struct**: Configuration passed via `Options` struct rather than individual parameters

### Error Handling
- **Specific error sets**: Functions return `error{OutOfMemory, ParseZon}` rather than generic errors
- **Rich diagnostics**: `Diagnostics` struct provides detailed error locations and messages
- **Error iteration**: `iterateErrors()` method for examining multiple parse errors

## 3) The Golden Snippet

```zig
const std = @import("std");
const parse = std.zon.parse;

const Point = struct {
    x: f32,
    y: f32,
};

pub fn main() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const source = ".{ .x = 1.5, .y = 2.5 }";
    
    // Parse without allocation (type doesn't contain pointers)
    const point = try parse.fromSlice(Point, gpa.allocator(), source, null, .{});
    
    // Or parse with allocation for string-containing types
    const StringPoint = struct { name: []const u8, x: f32, y: f32 };
    const source2 = ".{ .name = \"origin\", .x = 0.0, .y = 0.0 }";
    const string_point = try parse.fromSliceAlloc(StringPoint, gpa.allocator(), source2, null, .{});
    defer parse.free(gpa.allocator(), string_point);
}
```

## 4) Dependencies

- **std.mem** - Allocator type and memory utilities
- **std.zig** - Core Zig compiler infrastructure (Ast, Zoir, ZonGen)
- **std.zig.Ast** - Abstract syntax tree handling
- **std.zig.Zoir** - Zig Object Intermediate Representation
- **std.zig.ZonGen** - ZON generation utilities
- **std.debug** - Assertions
- **std.heap** - FixedBufferAllocator for non-allocating paths
- **std.math** - Numeric operations and constants
- **std.fmt** - String formatting
- **std.Io** - Writer interfaces for error formatting