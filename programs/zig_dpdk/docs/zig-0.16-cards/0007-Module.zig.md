# Migration Card: std.Build.Module

## 1) Concept

This file defines the `Module` struct, which represents a Zig module in the build system context. A module can be a Zig source file, a collection of C files, or a combination of various source types with specific compilation settings. The module manages:
- Source files (Zig, C, assembly, resource files)
- Import dependencies between modules
- Compilation flags and target-specific settings
- Linking configurations (libraries, frameworks, object files)
- Include directories and search paths

Key components include the module's import table, compilation target settings, optimization modes, and various linking and compilation options that can be inherited from parent modules or explicitly set.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- No explicit allocator parameters in public APIs - uses `std.Build`'s allocator internally
- Factory pattern: `Module.create()` takes a `*std.Build` owner and `CreateOptions`
- Struct initialization via `Module.init()` with union parameter for different creation strategies

**I/O Interface Changes:**
- Heavy use of `LazyPath` abstraction for file system operations
- Dependency injection through `std.Build` owner reference
- `appendZigProcessFlags()` method for building compiler arguments

**Error Handling Changes:**
- Most functions use `@panic("OOM")` instead of error returns
- Allocation failures are handled via panic rather than propagated errors
- `try` only used in `appendZigProcessFlags()` which returns `!void`

**API Structure Changes:**
- Factory function: `Module.create()` vs direct struct initialization
- Options struct pattern: `CreateOptions` for module creation
- Builder pattern methods: `addImport()`, `addCSourceFile()`, `linkSystemLibrary()`, etc.
- Strong typing for compilation settings via enums and optionals

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create main module
    const main_module = std.Build.Module.create(b, .{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add C source files
    main_module.addCSourceFiles(.{
        .root = .{ .path = "src" },
        .files = &.{"helper.c"},
        .flags = &.{"-Wall"},
    });

    // Add system library dependency
    main_module.linkSystemLibrary("z", .{
        .needed = true,
        .use_pkg_config = .yes,
    });

    // Create and add imported module
    const utils_module = std.Build.Module.create(b, .{
        .root_source_file = .{ .path = "lib/utils.zig" },
    });
    main_module.addImport("utils", utils_module);
}
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.Build` (core build system)
- `std.Build.LazyPath` (path abstraction)
- `std.Build.Step` (build step infrastructure)
- `std.ArrayList` (dynamic arrays)
- `std.StringArrayHashMapUnmanaged` (string-keyed maps)
- `std.array_list.Managed` (managed array lists)
- `std.debug` (assertions)
- `std.fs.path` (path operations in C source validation)
- `std.zig.target` (target detection for system libraries)
- `std.Target` (target specifications)
- `std.dwarf` (debug format handling)

**Build System Integration:**
- Deep integration with `std.Build` step dependency graph
- Uses `std.Build` allocator for all memory allocations
- Coordinates with `Step.Compile` for object file dependencies