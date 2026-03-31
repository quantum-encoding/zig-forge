# Migration Card: `std.Build.zig`

## 1) Concept

This file defines the main `Build` struct and associated types that form the core of Zig's build system. It provides the public API that developers use in their `build.zig` files to define build steps, compile executables/libraries, manage dependencies, and configure installation paths. Key components include:

- The `Build` struct itself which maintains build configuration state
- Factory functions for creating compilation steps (executables, objects, libraries, tests)
- Dependency management system with lazy dependency loading
- Installation step management
- Target and optimization configuration helpers
- Path resolution and file system abstraction via `LazyPath`

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory pattern dominance**: Most creation functions now follow factory patterns requiring explicit allocator injection through the `Build` instance
- **No standalone init**: The `Build` struct itself is created via `create()` factory function rather than direct struct initialization
- **Arena allocation**: The build system uses arena allocation internally, exposed via `b.allocator`

### I/O Interface Changes
- **Dependency injection**: The `Graph` struct now contains an `io: Io` field for I/O operations
- **Centralized I/O**: File operations are routed through the build graph's I/O interface rather than direct filesystem calls

### API Structure Changes
- **Factory functions**: All step creation uses factory methods on `Build` instance rather than standalone functions
- **Options structs**: Functions like `addExecutable`, `addLibrary`, etc. now take options structs instead of positional parameters
- **LazyPath abstraction**: File paths are now represented via `LazyPath` union that can reference source files, generated files, or dependency files

### Error Handling
- **Specific error types**: Functions like `runAllowFail` return specific error unions rather than generic errors
- **Build validation**: Added `validateUserInputDidItFail()` for centralized error checking

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .source_file = .{ .src_path = "src/main.zig" },
        }),
    });

    b.installArtifact(exe);

    const test_step = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .source_file = .{ .src_path = "src/main.zig" },
        }),
    });

    const run_test = b.addRunArtifact(test_step);
    
    const test_step_group = b.step("test", "Run tests");
    test_step_group.dependOn(&run_test.step);
}
```

## 4) Dependencies

Heavily imported modules that form the dependency graph:

- `std.mem` - Memory allocation and manipulation
- `std.fs` - File system operations
- `std.process` - Process execution and environment
- `std.Target` - Cross-compilation target handling
- `std.ArrayList` - Dynamic array management
- `std.StringHashMap` - String-keyed hash maps
- `std.crypto.hash.sha2.Sha256` - Hashing for cache system
- `std.zig.BuildId` - Build identifier handling

The file also imports several sub-modules:
- `Build/Cache.zig`
- `Build/Step.zig` 
- `Build/Module.zig`
- `Build/Watch.zig`
- `Build/Fuzz.zig`
- `Build/WebServer.zig`
- `Build/abi.zig`