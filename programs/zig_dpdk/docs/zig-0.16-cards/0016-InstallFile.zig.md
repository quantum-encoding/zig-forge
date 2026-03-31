# Migration Card: std.Build.Step.InstallFile

## 1) Concept

This file implements an `InstallFile` build step in Zig's build system. It's responsible for installing a single file to a specified destination directory during the build process. The step handles copying a source file (represented as a `LazyPath`) to an installation directory (`InstallDir`) with a specific relative path name.

Key components include:
- The `InstallFile` struct containing the build step, source file, destination directory, and destination path
- A factory function `create()` that constructs and configures the installation step
- A `make()` function that executes the actual file installation during build execution

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The `create()` function uses `owner.allocator` for memory allocation
- Memory duplication is handled through owner methods: `source.dupe(owner)`, `dir.dupe(owner)`, `owner.dupePath()`

**API Structure Changes:**
- Factory pattern: `InstallFile.create()` instead of direct struct initialization
- Dependency injection: All resources (allocator, paths) are obtained from the `owner` (`*std.Build`)
- Step initialization uses `.init()` with configuration struct rather than direct field assignment

**Error Handling:**
- The `make()` function uses Zig's error union type `!void`
- Error propagation through `try` statements for file operations

## 3) The Golden Snippet

```zig
// Create an InstallFile step within a build script
const install_file = InstallFile.create(
    b, // *std.Build owner
    .{ .path = "src/main.zig" }, // LazyPath source
    .{ .bin = {} }, // InstallDir (binary directory)
    "my-app" // dest_rel_path
);

// Add dependency to install step
b.getInstallStep().dependOn(&install_file.step);
```

## 4) Dependencies

- `std.Build` (build system framework)
- `std.Build.Step` (base step functionality)
- `std.Build.LazyPath` (lazy file path resolution)
- `std.Build.InstallDir` (installation directory handling)
- `std.debug` (assertions)