# LibCInstallation.zig Migration Card

## 1) Concept

This file defines a `LibCInstallation` struct and associated functionality for discovering, parsing, and managing C standard library installations across different platforms. It handles the complex task of locating libc headers, runtime libraries, and startup objects for various operating systems including Windows, macOS, Linux, BSD variants, Haiku, and Illumos.

Key components include:
- A struct containing optional paths to libc directories (include, system include, CRT, MSVC libs, etc.)
- Functions to parse libc configuration files and discover native installations
- Platform-specific detection logic using C compiler queries and system SDK discovery
- C runtime object resolution for different linking modes and target configurations

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `parse(allocator: Allocator, libc_file: []const u8, target: *const std.Target)`
- `findNative(args: FindNativeOptions)` where `FindNativeOptions` contains `allocator: Allocator`
- `deinit(self: *LibCInstallation, allocator: Allocator)`
- All functions that return strings require explicit allocator parameters

**I/O Interface Changes:**
- `render(self: LibCInstallation, out: *std.Io.Writer)` uses dependency injection for output
- File operations use `std.fs` module with explicit error handling

**Error Handling Changes:**
- Specific error enum `FindError` with detailed error cases
- Platform-specific error variants (`WindowsSdkNotFound`, `DarwinSdkNotFound`, etc.)
- Compiler execution errors handled explicitly

**API Structure Changes:**
- Options struct pattern: `FindNativeOptions` bundles configuration
- Factory function pattern: `parse()` and `findNative()` create instances
- Explicit cleanup: `deinit()` method for memory management

## 3) The Golden Snippet

```zig
const std = @import("std");
const LibCInstallation = std.zig.LibCInstallation;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse from configuration file
    const libc_install = try LibCInstallation.parse(allocator, "libc.txt", &std.Target.native);
    defer libc_install.deinit(allocator);

    // Render configuration to stdout
    const stdout = std.io.getStdOut().writer();
    try libc_install.render(stdout);

    // Or find native installation
    const native_libc = try LibCInstallation.findNative(.{
        .allocator = allocator,
        .target = &std.Target.native,
        .verbose = true,
    });
    defer native_libc.deinit(allocator);
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` (Allocator, tokenization, memory operations)
- `std.fs` (File system operations, path joining)
- `std.process` (Child process execution, environment variables)
- `std.Target` (Cross-compilation target information)
- `std.zig.system.darwin` (macOS SDK detection)
- `std.zig.WindowsSdk` (Windows SDK discovery)
- `std.Build.Cache` (Path handling for build system)

**Platform Detection:**
- `builtin.target` (Compile-time target information)
- Conditional compilation for Windows, Darwin, Haiku, etc.