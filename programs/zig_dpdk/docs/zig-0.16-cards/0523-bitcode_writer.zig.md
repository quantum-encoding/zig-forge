# Migration Card: LLVM Bitcode Writer

## 1) Concept

This file implements an LLVM bitcode writer for Zig, providing a generic API to encode structured data into the LLVM bitcode format. The core component is a `BitcodeWriter` type that handles low-level bit manipulation, variable-bit-rate (VBR) encoding, and structured block writing with abbreviations for efficient encoding. It supports writing various data types including fixed-width values, 6-bit characters, binary blobs, and arrays of these types.

Key components include:
- `BitcodeWriter`: Main writer type that manages bit buffers and encoding
- `AbbrevOp`: Union type defining different encoding operations for abbreviations
- `BlockWriter`: Nested type for handling structured blocks within the bitcode
- Support for both fixed and runtime-determined bit widths for type encoding

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `init()` requires explicit `std.mem.Allocator` parameter
- `toOwnedSlice()` returns owned memory that must be managed by caller
- `deinit()` method for explicit cleanup of allocated resources

**API Structure Changes:**
- Factory pattern: `BitcodeWriter(types).init(allocator, widths)` creates instances
- Block-based structure with `enterTopBlock()` and `enterSubBlock()` methods
- Explicit error handling with single `Error` type (`error{OutOfMemory}`)

**Memory Management Pattern:**
- Uses `std.array_list.Managed(u32)` for buffer management
- Explicit ownership transfer via `toOwnedSlice()`
- RAII-like pattern with `init()`/`deinit()` pair

## 3) The Golden Snippet

```zig
const std = @import("std");
const BitcodeWriter = @import("std").zig.llvm.bitcode_writer.BitcodeWriter;

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    
    // Define types and their bit widths
    const Types = [_]type{ u32, u16 };
    const widths = [_]u16{ 32, 16 };
    
    // Initialize writer
    var writer = BitcodeWriter(&Types).init(allocator, widths);
    defer writer.deinit();
    
    // Write some data
    try writer.writeBits(@as(u32, 0x12345678), 32);
    try writer.writeVbr(@as(u64, 42), 8);
    try writer.write6BitChar('a');
    
    // Get the encoded data
    const encoded_data = try writer.toOwnedSlice();
    defer allocator.free(encoded_data);
    
    // Use encoded_data...
}
```

## 4) Dependencies

- `std.mem` - Memory operations, alignment, byte order conversion
- `std.array_list` - Managed buffer for bitcode storage
- `std.math` - Mathematical utilities (log2 calculations)
- `std.meta` - Type introspection and field iteration
- `std.debug` - Runtime assertions and debugging