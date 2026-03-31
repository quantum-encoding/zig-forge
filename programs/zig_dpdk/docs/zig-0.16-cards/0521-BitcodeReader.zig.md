# Migration Card: std/zig/llvm/BitcodeReader.zig

## 1) Concept

This file implements an LLVM bitcode reader for Zig, providing a streaming parser for LLVM's bitcode format. The main component is the `BitcodeReader` struct that maintains parsing state including bit buffers, block stack, and block information. It reads bitcode through a reader interface and produces a sequence of items representing blocks, records, and block terminators.

Key components include:
- `BitcodeReader`: Main parser structure with state management
- `Block` and `Record`: Core data structures representing bitcode elements  
- `Item` union: Enumerates the different types of elements that can be parsed
- Abbreviation handling for compressed bitcode representation

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `init()` requires explicit allocator parameter: `BitcodeReader.init(allocator, options)`
- `deinit()` method must be called explicitly for cleanup
- All internal collections (stack, block_info) require allocator for initialization

**I/O Interface Changes:**
- Uses dependency injection via `std.Io.Reader` interface
- Reader passed through `InitOptions` struct rather than direct parameter
- Bit-level reading operations implemented on top of byte-oriented reader

**API Structure Changes:**
- Factory pattern with `init()` instead of direct struct initialization
- Options struct pattern: `InitOptions` bundles configuration parameters
- Explicit state management with `deinit()` method
- Streaming iterator pattern with `next()` returning `?Item`

**Error Handling:**
- Specific error types like `error.InvalidMagic`, `error.EndOfStream`, `error.InvalidAbbrevId`
- Error union returns throughout the parsing methods

## 3) The Golden Snippet

```zig
const std = @import("std");
const BitcodeReader = std.zig.llvm.BitcodeReader;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a reader (could be from file, memory, etc.)
    var buffer: [4]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    const reader = fixed_buffer_stream.reader();

    // Initialize bitcode reader
    var bc_reader = BitcodeReader.init(allocator, .{
        .reader = &reader,
        .keep_names = true,
    });
    defer bc_reader.deinit();

    // Check magic header
    try bc_reader.checkMagic(&[4]u8{ 'B', 'C', 0xC0, 0xDE });

    // Parse bitcode items
    while (try bc_reader.next()) |item| {
        switch (item) {
            .start_block => |block| {
                std.debug.print("Start block: {s} (id: {d})\n", .{block.name, block.id});
            },
            .record => |record| {
                std.debug.print("Record: {s} (id: {d})\n", .{record.name, record.id});
            },
            .end_block => |block| {
                std.debug.print("End block: {s} (id: {d})\n", .{block.name, block.id});
            },
        }
    }
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` (Allocator, memory operations)
- `std.heap` (ArenaAllocator for temporary allocations)
- `std.Io` (Reader interface for bitstream input)
- `std.array_list` (Managed arrays for operand storage)
- `std.AutoHashMapUnmanaged` (Block info storage)

**Secondary Dependencies:**
- `std.debug` (assertions)
- `std.math` (bit operations, casting)

The dependency graph shows this is primarily a parsing module that relies heavily on allocator patterns and I/O interfaces, with significant use of collections for state management.