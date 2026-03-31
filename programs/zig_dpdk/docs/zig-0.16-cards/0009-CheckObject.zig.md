# Migration Card: CheckObject.zig

## 1) Concept

This file implements a build system step for validating object files and other binary formats (Mach-O, ELF, WebAssembly) against expected patterns. It provides a testing framework for binary file analysis within Zig's build system, allowing developers to verify specific content in compiled outputs like symbol tables, headers, and section data.

Key components include:
- `CheckObject` struct representing the build step with configurable checks
- Multiple check types (exact match, contains, not present, extract, compute comparisons)
- Format-specific dumpers for Mach-O, ELF, and WebAssembly that parse and format binary data
- Variable extraction system for capturing and comparing numeric values from binary content

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- Factory pattern with explicit allocator: `create()` function takes owner's allocator via `owner.allocator`
- All internal collections use managed arrays with explicit allocators: `std.array_list.Managed`
- Memory allocation consistently passed through step hierarchy

**I/O Interface Changes:**
- Uses `std.Io.Writer` and `std.Io.Reader` abstractions throughout
- Format-specific dumpers implement consistent writer interfaces
- File reading uses `src_path.root_dir.handle.readFileAllocOptions` with explicit allocator

**Error Handling Changes:**
- Specific error types for parsing failures (e.g., `error.InvalidMagicNumber`)
- Step-level error reporting via `step.fail()` with formatted messages
- Structured error contexts for debugging binary parsing issues

**API Structure Changes:**
- Factory creation: `CheckObject.create()` returns allocated instance
- Builder pattern for checks with `checkStart()` followed by specific check methods
- Lazy path integration for dynamic path resolution in checks

## 3) The Golden Snippet

```zig
// In build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "main.zig" },
    });

    // Create check object step for the executable
    const check = std.Build.Step.CheckObject.create(b, exe.getEmittedBin(), .elf);
    
    // Set up checks
    check.checkInHeaders();
    check.checkExact("header");
    check.checkContains("entry");
    
    check.checkInSymtab();
    check.checkExtract("main {addr}");
    check.checkComputeCompare("addr 0x1000 +", .{
        .op = .gte,
        .value = .{ .literal = 0x2000 }
    });

    // Add to build dependencies
    b.getInstallStep().dependOn(&check.step);
}
```

## 4) Dependencies

- `std.mem` - Memory operations and allocators
- `std.fs` - File system operations
- `std.elf` - ELF format parsing
- `std.macho` - Mach-O format parsing  
- `std.math` - Mathematical comparisons
- `std.Build` - Build system integration
- `std.Io` - I/O abstractions (Writer/Reader)
- `std.wasm` - WebAssembly format support
- `std.debug` - Assertions
- `std.array_list` - Managed collections

**Primary Dependencies:** `std.mem`, `std.fs`, `std.elf`, `std.macho`, `std.Build`