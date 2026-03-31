# Migration Card: `std.Build.Step.Compile`

## 1) Concept

This file defines the `Compile` step for Zig's build system, representing a single compilation unit that can produce executables, libraries, objects, or tests. It serves as the core component for configuring and executing Zig compiler invocations within build scripts. Key components include:

- Configuration for different compilation targets (executable, library, object, test)
- Linker and compiler flag management
- Header installation and include tree generation
- Dependency tracking between compilation units
- Integration with the broader build system through the `Step` interface

The `Compile` step encapsulates all aspects of a compilation, from source file organization to final binary generation, and provides extensive configuration options for optimization, linking behavior, target-specific features, and cross-compilation settings.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory pattern**: The primary creation method is `Compile.create()` which takes an `Options` struct and returns an allocated `*Compile`
- **Memory management**: All string duplication and data structure initialization requires explicit allocator usage through the build system's allocator
- **Path handling**: Heavy use of `LazyPath` abstraction for deferred path resolution with proper dependency tracking

### I/O Interface Changes
- **Dependency injection**: All file operations go through `LazyPath` instances that must be explicitly added as step dependencies via `addStepDependencies()`
- **Output management**: Generated files are accessed through `getEmitted*()` methods returning `LazyPath` rather than direct file paths
- **Header installation**: New `installHeader()`, `installHeadersDirectory()`, and `installConfigHeader()` methods with proper dependency tracking

### Error Handling Changes
- **Expected errors**: Support for `expect_errors` configuration to validate compilation failures match expected patterns
- **Error bundle integration**: Uses `std.zig.ErrorBundle` for structured error reporting instead of simple error messages
- **PkgConfig integration**: Enhanced error handling for external tool execution with specific error types

### API Structure Changes
- **Module-centric design**: Most compilation configuration has moved to the `root_module` field (type `*Module`) with deprecated forwarding methods
- **Unified creation**: Single `create()` factory method with comprehensive `Options` struct instead of multiple init functions
- **Output accessors**: Methods like `getEmittedBin()`, `getEmittedDocs()`, etc. return `LazyPath` instead of raw paths

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for our application
    const exe_module = b.createModule(.{
        .source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Create the compilation step
    const exe = std.Build.Step.Compile.create(b, .{
        .name = "myapp",
        .root_module = exe_module,
        .kind = .exe,
    });

    // Install header files
    exe.installHeader("include/myheader.h", "myheader.h");
    
    // Configure compilation options
    exe.setVerboseLink(true);
    exe.root_module.link_libc = true;

    // Add to default install step
    b.installArtifact(exe);
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` - Memory allocation and manipulation
- `std.fs` - File system operations
- `std.Build` - Core build system infrastructure
- `std.Build.Step` - Step management and execution
- `std.Build.LazyPath` - Deferred path resolution
- `std.Build.Module` - Module dependency management
- `std.StringHashMap` - String-keyed data structures
- `std.crypto.hash.sha2.Sha256` - Cache hashing
- `std.zig` - Compiler internals and target information

**Build System Integration:**
- `Step` - Base step functionality
- `GeneratedFile` - Output file management
- `InstallDir` - Installation directory handling
- `PkgConfigPkg` - External dependency resolution