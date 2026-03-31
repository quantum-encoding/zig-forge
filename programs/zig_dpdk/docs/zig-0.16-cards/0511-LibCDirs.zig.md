# Migration Card: std/zig/LibCDirs.zig

## 1) Concept

This file provides directory detection functionality for C standard library installations. It's part of Zig's build system infrastructure that helps locate libc headers, framework directories, and sysroots when compiling C code or linking against system libraries. The main component is the `LibCDirs` struct which contains paths to libc include directories, framework directories (for Darwin systems), and optional sysroot information.

Key components include:
- `LibCDirs` struct containing directory lists and configuration
- `detect()` function that determines the appropriate libc directories based on target platform and linking requirements
- Platform-specific detection logic for Windows, Darwin (macOS/iOS), Haiku, and various libc implementations (glibc, musl, FreeBSD, NetBSD)

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- All public functions require explicit `Allocator` parameter (`arena: Allocator`)
- Memory management is explicit with arena allocator pattern throughout
- Return types are value types (`LibCDirs`) rather than allocated pointers

**API Structure Changes:**
- Factory function pattern: `detect()` returns initialized struct directly
- No `init()` vs `open()` distinction - single `detect()` entry point
- Error handling uses specific error sets (`LibCInstallation.FindError`)

**Dependency Injection Patterns:**
- Target information passed as `*const std.Target` rather than global state
- Explicit zig_lib_dir parameter instead of relying on global paths
- Optional libc_installation parameter for custom libc configurations

## 3) The Golden Snippet

```zig
const std = @import("std");
const zig = std.zig;

// Setup
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const target = std.Target.native;
const zig_lib_dir = "/path/to/zig/lib";

// Detect libc directories
const libc_dirs = try zig.LibCDirs.detect(
    arena.allocator(),
    zig_lib_dir,
    &target,
    true,  // is_native_abi
    true,  // link_libc
    null,  // libc_installation (use system default)
);

// Use the detected directories
for (libc_dirs.libc_include_dir_list) |include_dir| {
    std.debug.print("Include dir: {s}\n", .{include_dir});
}
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.mem` (via `Allocator` type)
- `std.fs.path` (directory and path manipulation)
- `std.array_list.Managed` (dynamic array management)
- `std.zig.target` (target platform detection)
- `std.zig.LibCInstallation` (libc installation handling)

**Key Type Dependencies:**
- `std.Target` (cross-compilation target specification)
- `LibCInstallation` (libc installation configuration)
- `DarwinSdkLayout` (macOS/iOS SDK configuration)