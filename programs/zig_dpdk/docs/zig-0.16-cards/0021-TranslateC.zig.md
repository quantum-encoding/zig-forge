# Migration Card: std.Build.Step.TranslateC

## 1) Concept

This file implements a Zig build system step for translating C code to Zig code using the `zig translate-c` command. It provides a programmatic interface to configure and execute C-to-Zig translation as part of a build process. The key components include configuration for include directories, C macros, target architecture, optimization settings, and integration with the Zig build system's dependency tracking.

The TranslateC step manages the translation process by constructing the appropriate command-line arguments for the Zig compiler's translate-c functionality and handles output file generation. It integrates with the build system's module system, allowing translated C code to be used as Zig modules in other parts of the build.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- Uses `std.array_list.Managed` (new in 0.16) instead of `std.ArrayList` for collections
- All allocators are obtained from the build system (`owner.allocator`) rather than passed explicitly
- Memory management follows the build system's ownership model

**I/O Interface Changes:**
- Uses `std.Build.LazyPath` abstraction for file paths instead of raw strings
- Path dependencies managed through `addStepDependencies()` calls
- Output handled via `std.Build.GeneratedFile` with lazy evaluation

**API Structure Changes:**
- Factory pattern: `create()` method instead of direct struct initialization
- Module creation: `addModule()` for public modules and `createModule()` for private modules
- Configuration through `Options` struct rather than individual parameters
- Path management through `LazyPath` abstraction with dependency tracking

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOptions(.{});

    const translate_c = std.Build.Step.TranslateC.create(b, .{
        .root_source_file = .{ .path = "src/library.c" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .use_clang = true,
    });

    translate_c.addIncludePath(.{ .path = "include" });
    translate_c.addSystemIncludePath(.{ .path = "/usr/include" });
    translate_c.defineCMacro("VERSION", "1.0.0");

    const c_module = translate_c.addModule("c_library");
    
    const exe = b.addExecutable(.{
        .name = "app",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    exe.addModule("c_library", c_module);
    b.installArtifact(exe);
}
```

## 4) Dependencies

- `std` (base imports)
- `std.Build` (build system core)
- `std.Build.Step` (step infrastructure)
- `std.Build.LazyPath` (path abstraction)
- `std.fs` (file system operations)
- `std.array_list` (managed collections - new in 0.16)
- `std.builtin` (compiler intrinsics and modes)