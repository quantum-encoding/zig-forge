# Migration Card: std.Build.Step.UpdateSourceFiles

## 1) Concept

This file implements a Zig build system step (`UpdateSourceFiles`) that writes files to the package's source directory. It's designed for developer utilities that intentionally modify source files (like code generators), rather than being part of the normal build process. The step can write files either from raw byte content or by copying existing files.

Key components include:
- `UpdateSourceFiles` struct containing the build step and output file definitions
- `OutputSourceFile` struct defining the destination path and content source (bytes or file copy)
- Factory function `create()` and content addition methods `addCopyFileToSource()`/`addBytesToSource()`

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- Uses dependency injection through `std.Build` owner's allocator (`b.allocator`)
- No direct allocator parameters in public APIs - allocator accessed via build context

**I/O Interface Changes:**
- Uses new `std.Io` interface via `b.graph.io` dependency injection
- File operations use `Io.Dir.updateFile()` with new API adaptation pattern
- Directory creation uses `b.build_root.handle.makePath()` with error handling

**Error Handling Changes:**
- Uses `step.fail()` with formatted error messages for build system integration
- Error messages use new format specifiers (`{f}` for build root, `{t}` for error traces)
- File operations return comprehensive error context

**API Structure Changes:**
- Step creation follows factory pattern with `create(owner: *std.Build)`
- File sources use `std.Build.LazyPath` abstraction
- Input tracking via `step.inputs.populated()` and `step.addWatchInput()`

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Create update step
    const update_step = std.Build.Step.UpdateSourceFiles.create(b);
    
    // Add files to update in source directory
    update_step.addBytesToSource(
        "// Generated content\npub const version = \"1.0.0\";", 
        "src/generated.zig"
    );
    
    update_step.addCopyFileToSource(
        .{ .path = "templates/base.txt" }, 
        "src/copied.txt"
    );
    
    // Add step to build pipeline if needed
    b.getInstallStep().dependOn(&update_step.step);
}
```

## 4) Dependencies

- `std` (core standard library)
- `std.Io` (new I/O abstraction layer)
- `std.Build.Step` (build step infrastructure)
- `std.fs` (file system operations)
- `std.ArrayList` (dynamic arrays)

**Critical Dependencies:**
- `std.Build.LazyPath` (build system file abstraction)
- `std.Io.Dir` (new directory I/O interface)
- Build root directory handle (`b.build_root.handle`)