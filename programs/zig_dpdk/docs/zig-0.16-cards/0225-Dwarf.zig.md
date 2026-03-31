# Migration Card: `std.debug.Dwarf`

## 1) Concept

This file implements a DWARF debug information parser and decoder for Zig's standard library. It provides functionality to parse, decode, and cache DWARF debugging information from compiled binaries, enabling features like symbol lookup, source location mapping, and stack unwinding. Key components include:

- **DWARF Section Parsing**: Handles various DWARF sections like `.debug_info`, `.debug_abbrev`, `.debug_str`, etc.
- **Compile Unit Management**: Parses and manages compilation units, line number programs, and source location information
- **Symbol Resolution**: Maps addresses to function names and source locations
- **Range Analysis**: Processes address ranges for functions and compilation units
- **Expression Evaluation**: Supports DWARF expression evaluation (via imported submodule)

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory Pattern**: The main initialization uses `open()` method that takes explicit allocator
- **Memory Management**: All deinitialization methods (`deinit()`) require explicit allocator parameter
- **Dynamic Structures**: Heavy use of `ArrayList` with explicit allocator management throughout

### I/O Interface Changes
- **Dependency Injection**: Uses `std.Io.Reader` interface for binary parsing
- **Fixed Reader Pattern**: `Reader = .fixed(data)` pattern used extensively for section parsing
- **Endian-aware Reading**: All parsing functions require explicit endian parameter

### Error Handling Changes
- **Specific Error Sets**: Uses dedicated error sets like `OpenError`, `ScanError` rather than generic errors
- **Debug Info Errors**: Specific error cases for `InvalidDebugInfo` and `MissingDebugInfo`
- **Propagation**: Error handling preserves debug information context through error unions

### API Structure Changes
- **Initialization Pattern**: `open()` method initializes existing struct rather than factory function
- **Explicit Resource Management**: `deinit()` method for cleanup with allocator
- **Stateful Parsing**: Methods maintain internal state rather than pure functional parsing

## 3) The Golden Snippet

```zig
const std = @import("std");
const Dwarf = std.debug.Dwarf;

// Initialize DWARF parser
var dwarf: Dwarf = .{};
defer dwarf.deinit(allocator);

// Set up DWARF sections (must be populated from binary)
dwarf.sections = .{
    .debug_info = .{ .data = debug_info_data, .owned = false },
    .debug_abbrev = .{ .data = debug_abbrev_data, .owned = false },
    .debug_str = .{ .data = debug_str_data, .owned = false },
    .debug_line = .{ .data = debug_line_data, .owned = false },
    // ... other sections as needed
};

// Open and parse DWARF information
try dwarf.open(allocator, .little);

// Look up symbol information for an address
if (const symbol_name = dwarf.getSymbolName(0x4000)) {
    // Use symbol name
}

// Get detailed symbol information
const symbol = try dwarf.getSymbol(allocator, .little, 0x4000);
```

## 4) Dependencies

- **`std.mem`**: Memory operations, allocator interface
- **`std.dwarf`**: DWARF constants and type definitions  
- **`std.math`**: Integer casting and bounds checking
- **`std.ArrayList`**: Dynamic array management
- **`std.builtin.Endian`**: Endianness handling
- **`std.Io`**: Binary reading interface
- **`std.sort`**: Sorting algorithms for range organization
- **`std.fs.path`**: Path joining for source file resolution

The module also imports several submodules:
- `Dwarf/expression.zig`
- `Dwarf/Unwind.zig` 
- `Dwarf/SelfUnwinder.zig`