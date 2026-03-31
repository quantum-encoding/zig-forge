# Migration Card: ArrayListReverse.zig

## 1) Concept

This file implements `ArrayListReverse`, a specialized dynamic array that grows backwards in memory. It's designed for ASN.1 DER encoding where nested prefix length fields need to be counted efficiently. The data structure is laid out with capacity at the beginning and data growing from the end towards the beginning, enabling O(n) processing of nested structures instead of O(n^depth).

Key components include:
- A backward-growing buffer managed by prepend operations
- Memory management through an explicit allocator
- Methods for capacity management, data prepending, and final slice extraction

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `init()` takes an explicit `Allocator` parameter and returns a value type
- All memory operations (`ensureCapacity`, `prependSlice`, `toOwnedSlice`) use the stored allocator
- Factory pattern with `init()` rather than direct struct initialization

**Error Handling Changes:**
- Functions like `ensureCapacity`, `prependSlice`, and `toOwnedSlice` return `Allocator.Error`
- Specific error type `Error = Allocator.Error` rather than generic error sets
- Explicit error propagation with `try` keyword

**API Structure Changes:**
- Clear separation between `init()` (setup) and `deinit()` (cleanup)
- `toOwnedSlice()` transfers ownership and clears internal state
- `clearAndFree()` for explicit memory release without destroying the structure

## 3) The Golden Snippet

```zig
const std = @import("std");
const ArrayListReverse = std.crypto.codecs.asn1.der.ArrayListReverse;

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    
    var list = ArrayListReverse.init(allocator);
    defer list.deinit();
    
    // Prepend data in reverse order
    try list.prependSlice(&.{ 4, 5, 6 });
    try list.prependSlice(&.{ 1, 2, 3 });
    
    // Take ownership of the final slice
    const result = try list.toOwnedSlice();
    defer allocator.free(result);
    
    // result now contains [1, 2, 3, 4, 5, 6]
}
```

## 4) Dependencies

- `std.mem` (for `Allocator` type)
- `std.debug` (for `assert` debugging)
- `std.testing` (for test infrastructure)

**Note:** This module is part of the crypto/ASN.1 DER codec subsystem and primarily depends on core memory allocation utilities rather than high-level I/O or networking modules.