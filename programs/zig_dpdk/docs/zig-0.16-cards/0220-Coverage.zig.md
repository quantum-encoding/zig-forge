# Migration Card: std.debug.Coverage

## 1) Concept

This file implements a code coverage tracking system that maps program addresses to source code locations using DWARF debug information. The main `Coverage` struct maintains globally-scoped indices for directories and files, storing string data in a centralized buffer while providing thread-safe access via a mutex.

Key components include:
- `Coverage` struct with directories/files maps and string storage
- `String` enum type representing string indices with custom hash/equality contexts  
- `File` struct representing source files with directory indices
- `SourceLocation` struct containing file, line, and column information
- DWARF-based address resolution functionality

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `deinit(cov: *Coverage, gpa: Allocator)` - Cleanup now requires explicit allocator
- `resolveAddressesDwarf()` takes `gpa: Allocator` parameter for internal allocations
- String storage management uses `std.ArrayListUnmanaged` with explicit allocator

**Error Handling Changes:**
- `ResolveAddressesDwarfError = Dwarf.ScanError` - Uses specific DWARF error type rather than generic errors
- Error handling in `resolveAddressesDwarf` uses explicit error switching

**API Structure Changes:**
- No factory functions - uses `init: Coverage` compile-time constant for initialization
- Direct struct initialization pattern rather than `init()` functions
- Memory management separated from initialization

## 3) The Golden Snippet

```zig
const std = @import("std");
const Coverage = std.debug.Coverage;

// Initialize coverage tracking
var coverage = Coverage.init;
defer coverage.deinit(std.heap.page_allocator);

// After DWARF processing, access resolved source locations
if (loc.file != .invalid) {
    const file = coverage.fileAt(loc.file);
    const filename = coverage.stringAt(file.basename);
    std.debug.print("File: {s}, Line: {}, Column: {}\n", .{
        filename, loc.line, loc.column
    });
}
```

## 4) Dependencies

- `std.mem` (Allocator, array hash maps)
- `std.hash.Wyhash` (String hashing)
- `std.debug.Dwarf` (DWARF parsing)
- `std.Thread.Mutex` (Thread safety)
- `std.sort` (Binary search operations)
- `std.math` (Integer constants and ordering)

This file provides public APIs for coverage tracking and source location resolution, making it relevant for migration analysis.