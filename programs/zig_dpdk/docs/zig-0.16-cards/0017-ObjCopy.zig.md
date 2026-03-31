# Migration Card: std.Build.Step.ObjCopy

## 1) Concept

This file implements a build system step for the `objcopy` utility, which is used to manipulate object files during the Zig build process. It provides functionality for copying and transforming binary files, including format conversion (binary, hex, ELF), section manipulation, stripping debug symbols, and setting section flags/alignments.

Key components include:
- Configuration options for format conversion, section extraction, and debug symbol handling
- Support for adding new sections and modifying existing section properties
- Integration with Zig's build system cache and dependency tracking
- Optional extraction of debug sections to separate files

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- No explicit allocator parameter in public API - uses build system's allocator internally
- Factory pattern via `create()` function that takes ownership from build system

**I/O Interface Changes:**
- Uses `std.Build.LazyPath` for input/output file handling instead of raw paths
- Build system dependency injection through `owner` parameter
- Cache-aware file operations with manifest-based change detection

**Error Handling Changes:**
- Internal `make()` function uses Zig 0.16's error handling with `!void` return
- Cache operations and file system interactions use standard error types

**API Structure Changes:**
- Factory function `create()` instead of direct struct initialization
- Options struct pattern for configuration
- Generated file handling through `std.Build.GeneratedFile`

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = .{ .path = "main.zig" },
    });

    // Create objcopy step
    const objcopy_step = std.Build.Step.ObjCopy.create(
        b,
        exe.getEmittedBin(),
        .{
            .basename = "my_app.bin",
            .format = .bin,
            .strip = .debug_and_symbols,
            .compress_debug = true,
        },
    );

    // Add to build dependencies
    b.getInstallStep().dependOn(&objcopy_step.step);
}
```

## 4) Dependencies

- `std.mem` (Allocator type)
- `std.heap` (ArenaAllocator)
- `std.fs` (File system operations)
- `std.Build` (Build system integration)
- `std.elf` (ELF file format handling)
- `std.ArrayListUnmanaged` (Dynamic array management)