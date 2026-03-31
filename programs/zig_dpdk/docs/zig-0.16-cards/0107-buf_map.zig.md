# Migration Card: std.buf_map.zig

## 1) Concept

`BufMap` is a string-to-string hash map that automatically manages memory for keys and values. It wraps a `StringHashMap([]const u8)` and provides automatic copying and freeing of string data. The primary use case is when you need a simple key-value store where both keys and values are strings, and you want the map to handle all memory management internally.

Key components include:
- Automatic duplication of keys/values on insertion via `put()`
- Move semantics for already-allocated strings via `putMove()`
- Automatic cleanup of all stored strings when the map is deinitialized
- Standard map operations: get, remove, count, and iteration

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `init(allocator: Allocator)` requires explicit allocator injection
- No factory functions - direct struct initialization with allocator dependency
- All memory operations delegate to the provided allocator

**API Structure Changes:**
- Consistent `init/deinit` pattern for lifecycle management
- `putMove` method for transferring ownership of already-allocated strings
- Iterator pattern remains consistent with `iterator()` method

**Error Handling:**
- `put()` and `putMove()` return `!void` (generic error set)
- Allocation failures propagate through the API
- No specific error types - relies on allocator error propagation

## 3) The Golden Snippet

```zig
const std = @import("std");
const BufMap = std.BufMap;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = BufMap.init(allocator);
    defer env.deinit();

    // Store copied strings
    try env.put("HOME", "/home/user");
    try env.put("PATH", "/usr/bin:/bin");

    // Retrieve values
    if (env.get("HOME")) |home| {
        std.debug.print("Home directory: {s}\n", .{home});
    }

    // Remove entries
    env.remove("PATH");

    // Iterate over remaining entries
    var it = env.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s} = {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}
```

## 4) Dependencies

- `std.mem` (as `mem`) - For allocator interface and memory operations
- `std.StringHashMap` - Core hash map implementation
- `std.testing` - For test utilities (test-only dependency)