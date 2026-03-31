# Migration Card: std.json.static

## 1) Concept

This file provides static JSON parsing functionality for Zig's standard library. It contains type-safe JSON parsing functions that convert JSON data into strongly-typed Zig structures at compile time. The key components include:

- **ParseOptions**: Configuration struct controlling parsing behavior (duplicate fields, unknown fields, allocation strategies, number parsing)
- **Parsed wrapper**: Memory management wrapper that bundles parsed values with their arena allocator
- **Multiple parsing entry points**: Functions for parsing from JSON strings (`parseFromSlice`), token streams (`parseFromTokenSource`), and pre-parsed JSON values (`parseFromValue`)
- **Type-driven parsing**: Recursive parsing system that handles Zig primitives, structs, enums, unions, arrays, slices, and pointers

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **All functions now require explicit allocator parameter**: Every public function takes `allocator: Allocator` as first parameter
- **ArenaAllocator integration**: `Parsed(T)` type manages arena lifecycle with explicit `deinit()` method
- **Memory strategy control**: `ParseOptions.allocate` field determines when to allocate vs reference input buffers

### I/O Interface Changes
- **Generic token source**: `parseFromTokenSource` accepts any scanner/reader type via `anytype` parameter
- **Dependency injection**: Scanner/reader instances must be passed explicitly rather than created internally
- **Resource management**: Callers must manage scanner lifecycle with explicit `deinit()` calls

### Error Handling Changes
- **Generic error sets**: `ParseError(Source)` generates error sets dynamically based on token source type
- **Comprehensive error coverage**: Error sets include parsing, allocation, and source-specific errors
- **Distinct value parsing errors**: `ParseFromValueError` separates errors for parsing from pre-parsed JSON values

### API Structure Changes
- **Safe vs leaky variants**: Functions come in pairs (`parseFromSlice`/`parseFromSliceLeaky`) for different memory management strategies
- **Explicit initialization**: No implicit allocators - all memory management must be explicit
- **Structured parsing flow**: Clear separation between token scanning and value parsing phases

## 3) The Golden Snippet

```zig
const std = @import("std");
const json = std.json;

const User = struct {
    name: []const u8,
    age: u32,
    active: bool = true,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_data = 
        \\{"name": "Alice", "age": 30, "active": false}
    ;

    const options = json.ParseOptions{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    };

    const parsed = try json.parseFromSlice(User, allocator, json_data, options);
    defer parsed.deinit();

    std.debug.print("Name: {s}, Age: {}, Active: {}\n", .{
        parsed.value.name,
        parsed.value.age, 
        parsed.value.active,
    });
}
```

## 4) Dependencies

- **std.mem** (Allocator, memory operations)
- **std.heap.ArenaAllocator** (arena-based memory management)
- **std.array_list.Managed** (dynamic array implementation)
- **std.fmt** (number parsing: parseFloat, parseInt)
- **std.meta** (type introspection and enum operations)
- **std.json.Scanner** (token scanning layer)
- **std.json.dynamic** (Value, Array types for dynamic parsing)