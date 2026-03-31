# Migration Card: ConfigHeader.zig

## 1) Concept

This file implements a configuration header generation step for Zig's build system. It provides functionality to generate C-style header files (`config.h`) and NASM assembly configuration files from various template formats including Autoconf, CMake, or from scratch. The main component is the `ConfigHeader` struct which represents a build step that processes configuration values and generates appropriate header files with macros, defines, and variable substitutions.

Key components include:
- `ConfigHeader` struct managing the build step and configuration values
- Support for multiple input styles (autoconf_undef, autoconf_at, cmake, blank, nasm)
- Type-safe value system for different configuration data types (booleans, integers, strings, etc.)
- Template substitution engines for different configuration file formats

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The API uses dependency injection through the build system's allocator rather than requiring explicit allocator parameters
- `create()` function takes a `*std.Build` owner which provides the allocator context
- Internal hash maps and string operations use the build system's allocator

**I/O Interface Changes:**
- Uses `std.Io.Writer` for output generation with allocating writer patterns
- File operations use `std.Build.LazyPath` abstraction for build system integration
- Input template reading uses arena allocation with size limits

**Error Handling Changes:**
- Uses step-based error reporting through `step.fail()` and `step.addError()`
- Template parsing errors are collected and reported through the build step system
- Error types are specific to configuration generation failures

**API Structure Changes:**
- Factory pattern with `create()` function taking `Options` struct
- `getOutputFile()` method replaces deprecated `getOutput()` method
- Value addition uses type-safe `addValue()` with compile-time type checking
- Bulk value addition via `addValues()` with struct introspection

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Create a config header step
    const config_header = std.Build.Step.ConfigHeader.create(b, .{
        .style = .blank,
        .include_path = "config.h",
    });

    // Add configuration values
    config_header.addValue("ENABLE_FEATURE", bool, true);
    config_header.addValue("BUILD_VERSION", i64, 42);
    config_header.addValue("APP_NAME", []const u8, "MyApplication");
    config_header.addValue("DEBUG_MODE", bool, false);

    // Use the generated header in a compile step
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("main.zig"),
    });
    exe.addConfigHeader(config_header);
    exe.installConfigHeader(config_header, "config.h");

    b.installArtifact(exe);
}
```

## 4) Dependencies

- `std.mem` - Memory allocation and management
- `std.Io` - I/O operations and Writer interface
- `std.fs` - File system operations
- `std.Build` - Build system integration
- `std.StringArrayHashMap` - String-based hash map for configuration values
- `std.zig.fmtString` - String formatting utilities
- `std.DynamicBitSetUnmanaged` - Bit set operations for tracking usage