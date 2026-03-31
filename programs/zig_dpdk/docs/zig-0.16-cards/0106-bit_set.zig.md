# Migration Card: `std/bit_set.zig`

## 1) Concept

This file implements several variants of densely stored integer sets where each integer gets a single bit. Bit sets provide fast presence checks, update operations, and union/intersection operations. The key components include:

- **IntegerBitSet**: Static-sized bit set backed by a single integer, optimal for small sets
- **ArrayBitSet**: Static-sized bit set backed by an array of integers, better for larger sets  
- **StaticBitSet**: Automatically chooses between IntegerBitSet or ArrayBitSet based on requested size
- **DynamicBitSetUnmanaged**: Runtime-sized bit set with manual allocator management
- **DynamicBitSet**: Runtime-sized bit set that stores its allocator

All variants provide consistent operations like set/unset, union/intersection, iteration, and range operations.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **DynamicBitSetUnmanaged**: All functions requiring allocation explicitly take an `Allocator` parameter:
  - `initEmpty(allocator: Allocator, bit_length: usize) !Self`
  - `initFull(allocator: Allocator, bit_length: usize) !Self` 
  - `resize(self: *Self, allocator: Allocator, new_len: usize, fill: bool) !void`
  - `deinit(self: *Self, allocator: Allocator) void`
  - `clone(self: *const Self, new_allocator: Allocator) !Self`

- **DynamicBitSet**: Stores allocator internally but follows same initialization patterns:
  - `initEmpty(allocator: Allocator, bit_length: usize) !Self`
  - `initFull(allocator: Allocator, bit_length: usize) !Self`

### API Structure Changes
- **Consistent initialization**: All bit set types use `initEmpty()` and `initFull()` factory functions rather than direct struct initialization
- **Explicit capacity**: All types provide `capacity()` method to get bit length
- **Range operations**: All types support `setRangeValue(range: Range, value: bool)` for bulk operations
- **Iterator patterns**: All types provide `iterator(options: IteratorOptions)` with configurable iteration direction and set/unset filtering

### Error Handling
- **Allocation functions** return error unions (`!Self` or `!void`) for out-of-memory conditions
- **Bounds checking** uses `assert()` for index validation rather than error returns
- **Type compatibility** between bit sets is checked via `assert()` for operations requiring equal sizes

## 3) The Golden Snippet

```zig
const std = @import("std");
const DynamicBitSet = std.bit_set.DynamicBitSet;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize a dynamic bit set with 100 bits, all unset
    var bits = try DynamicBitSet.initEmpty(allocator, 100);
    defer bits.deinit();

    // Set some bits
    bits.set(5);
    bits.set(42);
    bits.setRangeValue(.{ .start = 10, .end = 20 }, true);

    // Check if bits are set
    std.debug.print("Bit 5 is set: {}\n", .{bits.isSet(5)});
    std.debug.print("Bit 6 is set: {}\n", .{bits.isSet(6)});

    // Count set bits
    std.debug.print("Total set bits: {}\n", .{bits.count()});

    // Iterate over set bits
    var iter = bits.iterator(.{});
    while (iter.next()) |index| {
        std.debug.print("Set bit at index: {}\n", .{index});
    }
}
```

## 4) Dependencies

- **`std.mem`**: Used for `Allocator` type and memory operations
- **`std.math`**: Used for bit manipulation, log2 calculations, and boolean masking
- **`std.debug`**: Used for runtime assertions
- **`std.builtin`**: Used for type introspection and compile-time checks

The file has minimal external dependencies and focuses on core bit manipulation operations, making it relatively self-contained within the standard library's mathematical and memory management modules.