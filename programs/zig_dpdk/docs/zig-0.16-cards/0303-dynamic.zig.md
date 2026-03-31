# Migration Card: std.json.dynamic.zig

## 1) Concept

This file implements dynamic JSON parsing capabilities for Zig's standard library. It provides a `Value` union type that can represent any JSON value type (null, boolean, numbers, strings, arrays, objects) along with parsing and serialization functionality. The key components include:

- `Value`: A tagged union that can hold any JSON data type including nested structures
- `ObjectMap`: A string-keyed hash map for JSON objects  
- `Array`: A managed array list for JSON arrays
- Parsing functions that handle the complete JSON grammar including nested structures and duplicate field handling

The module supports both approximate floating-point number parsing and exact number string preservation, giving developers control over numeric precision through parsing options.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`jsonParse` function**: Now explicitly requires an `Allocator` as the first parameter
- **Container initialization**: `ObjectMap.init(allocator)` and `Array.init(allocator)` show the pattern where allocators must be explicitly provided rather than using global/default allocators
- **Memory management**: Stack management uses `Array.init(allocator)` showing the move away from implicit allocation

### Error Handling Changes
- **Generic error types**: `ParseError(@TypeOf(source.*))` shows the use of generic error sets that depend on the token source type
- **Explicit error cases**: Error handling for duplicate fields with `error.DuplicateField` and specific parsing errors

### API Structure Changes
- **Factory pattern**: `Value.parseFromNumberSlice()` demonstrates the pattern of static factory functions rather than direct union initialization
- **Parser injection**: The `jsonParse` method takes a generic `source` parameter that follows a specific token stream interface pattern

## 3) The Golden Snippet

```zig
const std = @import("std");
const json = std.json;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse JSON into dynamic Value
    const json_source = 
        \\{"name": "test", "values": [1, 2, 3], "active": true}
    ;
    
    var token_stream = json.TokenStream.init(json_source);
    const options = json.ParseOptions{
        .allocator = allocator,
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = false,
        .max_value_len = null,
        .parse_numbers = true,
    };
    
    const value = try json.Value.jsonParse(allocator, &token_stream, options);
    
    // Use the parsed value
    value.dump();
}
```

## 4) Dependencies

- **`std.mem`**: Used for `Allocator` type and memory management
- **`std.heap`**: Used for `ArenaAllocator` in allocation patterns
- **`std.json`**: Core JSON functionality and re-exports
- **`std.array_list`**: Used for `Managed` array implementation
- **`std.StringArrayHashMap`**: Used for JSON object implementation
- **`std.debug`**: Used for assertions and debugging output
- **`std.fmt`**: Used for number parsing in `parseFromNumberSlice`
- **`std.math`**: Used for floating-point validation

The dependency graph shows this module is central to JSON processing, bridging between low-level parsing (Scanner) and high-level static parsing (static.zig).