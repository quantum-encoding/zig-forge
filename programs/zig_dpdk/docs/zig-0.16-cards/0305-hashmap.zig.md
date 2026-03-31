```markdown
# Migration Card: std.json.ArrayHashMap

## 1) Concept

This file implements a JSON-serializable hash map wrapper around `std.StringArrayHashMapUnmanaged`. It provides a thin abstraction layer that implements JSON parsing, parsing from existing JSON values, and JSON stringification for hash maps with string keys. The primary use case is for handling JSON objects with arbitrary data keys instead of comptime-known struct field names, making it useful for dynamic JSON schemas where field names aren't known at compile time.

The key components include:
- A generic `ArrayHashMap(T)` type constructor that wraps `std.StringArrayHashMapUnmanaged(T)`
- JSON parsing from token streams (`jsonParse`)
- JSON parsing from existing `Value` objects (`jsonParseFromValue`)  
- JSON serialization via `jsonStringify`
- Proper memory management with explicit `deinit`

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- All functions require explicit `Allocator` parameter injection
- `deinit` now takes allocator as parameter: `deinit(self: *@This(), allocator: Allocator)`
- Factory functions (`jsonParse`, `jsonParseFromValue`) require allocator parameter

**I/O Interface Changes:**
- JSON parsing uses dependency injection via `source: anytype` parameter accepting token streams
- JSON stringification uses `jws: anytype` parameter for output stream
- Both interfaces follow generic "duck typing" patterns rather than concrete types

**Error Handling:**
- Uses specific error types like `error.UnexpectedToken` and `error.DuplicateField`
- Error handling is explicit with `try` and `!` return types
- `errdefer` used for cleanup on error paths

**API Structure:**
- Factory pattern: `jsonParse` returns initialized instance rather than separate init
- Consistent naming: `jsonParseFromValue` for parsing from existing JSON values
- Memory ownership: caller must call `deinit` to clean up

## 3) The Golden Snippet

```zig
const std = @import("std");
const json = std.json;

const MyHashMap = json.ArrayHashMap(i32);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse JSON into hash map
    const json_input = 
        \\{"key1": 42, "key2": 100, "key3": -5}
    ;
    
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();
    
    var tree = try parser.parse(json_input);
    defer tree.deinit();
    
    var map = try MyHashMap.jsonParseFromValue(allocator, tree.root, .{});
    defer map.deinit(allocator);

    // Use the map
    if (map.map.get("key1")) |value| {
        std.debug.print("key1: {}\n", .{value});
    }

    // Stringify back to JSON
    try std.json.stringify(map, .{}, std.io.getStdOut().writer());
}
```

## 4) Dependencies

- `std.mem.Allocator` - Memory allocation interface
- `std.StringArrayHashMapUnmanaged` - Backing hash map implementation  
- Internal JSON modules: `static.zig`, `dynamic.zig` - JSON parsing internals
- `std.testing` - Test framework (via test block)
```