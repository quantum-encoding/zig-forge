# Migration Card: std.debug.SelfInfo/Windows.zig

## 1) Concept

This file implements Windows-specific debug information handling for the Zig standard library's self-debugging capabilities. It provides functionality for symbol lookup, stack unwinding, and module information retrieval on Windows platforms. The key components include:

- **SelfInfo**: Main struct managing loaded modules and debug information with thread-safe access
- **Module**: Represents a loaded executable/DLL with its debug information (DWARF or PDB)
- **UnwindContext**: Handles Windows-specific stack unwinding using RtlVirtualUnwind
- **DebugInfo**: Internal structure managing COFF, DWARF, and PDB debug formats

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- `deinit(si: *SelfInfo, gpa: Allocator) void` - Requires explicit allocator
- `getSymbol(si: *SelfInfo, gpa: Allocator, io: Io, address: usize) Error!std.debug.Symbol` - Allocator + I/O injection
- `getModuleName(si: *SelfInfo, gpa: Allocator, address: usize) Error![]const u8` - Explicit allocator
- `unwindFrame(si: *SelfInfo, gpa: Allocator, context: *UnwindContext) Error!usize` - Allocator parameter
- Module loading functions require allocator for arena management

### I/O Interface Changes
- `getSymbol` injects `io: Io` parameter for file operations
- `loadDebugInfo` uses `io: Io` for PDB file reading
- File operations use dependency injection pattern with threaded I/O

### Error Handling Changes
- Uses specific `std.debug.SelfInfoError` error set
- Complex error handling with fallbacks between PDB and DWARF formats
- Error propagation through `Error!` return types

### API Structure Changes
- `init` as a compile-time constant rather than function
- `deinit` methods require explicit allocator
- Factory pattern for debug info loading with error handling

## 3) The Golden Snippet

```zig
const std = @import("std");
const SelfInfo = std.debug.SelfInfo.Windows.SelfInfo;

// Initialize self info
var si: SelfInfo = SelfInfo.init;
defer si.deinit(std.heap.page_allocator);

// Get symbol for an address
const io = std.io;
const symbol = try si.getSymbol(
    std.heap.page_allocator,
    io,
    @returnAddress(),
);

// Use the symbol information
std.debug.print("Symbol: {s}\n", .{symbol.name});
```

## 4) Dependencies

```zig
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dwarf = std.debug.Dwarf;
const Pdb = std.debug.Pdb;
const coff = std.coff;
const fs = std.fs;
const windows = std.os.windows;
const builtin = @import("builtin");
```

**Primary Dependencies:**
- `std.mem` (Allocator)
- `std.io` (I/O operations)
- `std.os.windows` (Windows API)
- `std.fs` (File system operations)
- `std.debug` (Dwarf, Pdb types)
- `std.coff` (COFF format parsing)