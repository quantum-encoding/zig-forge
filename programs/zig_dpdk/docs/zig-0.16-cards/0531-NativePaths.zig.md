# Migration Card: NativePaths.zig

## 1) Concept

This file provides cross-platform native system path detection for Zig's build system. The `NativePaths` struct discovers and collects system-specific include directories, library directories, framework directories, and rpaths by analyzing environment variables and platform-specific conventions. It handles detection for various operating systems including Linux, macOS, Illumos, Haiku, and Windows, with special support for Nix package manager environments.

Key components include:
- Platform-specific path detection logic
- Environment variable parsing (NIX_CFLAGS_COMPILE, NIX_LDFLAGS, C_INCLUDE_PATH, etc.)
- Framework and SDK detection for Darwin systems
- Warning collection for unrecognized flags and parsing issues

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- The `detect` function requires an explicit `Allocator` parameter as the first argument
- All path collections use `std.ArrayListUnmanaged` with explicit arena allocation
- No default allocator assumptions - all memory management is explicit

**Error Handling Changes:**
- Uses generic error sets (`!NativePaths`, `!void`) rather than specific error types
- Environment variable lookups use proper error handling with switches for different error cases

**API Structure:**
- Factory function pattern: `detect()` creates and initializes the struct
- Method-based API with receiver pattern (`self: *NativePaths`)
- Format variants provided for common operations (`addIncludeDirFmt`, `addLibDirFmt`, etc.)

## 3) The Golden Snippet

```zig
const std = @import("std");
const NativePaths = std.zig.system.NativePaths;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const native_target = &std.Target.current;
    var native_paths = try NativePaths.detect(arena.allocator(), native_target);
    
    // Use the detected paths
    for (native_paths.include_dirs.items) |include_dir| {
        std.debug.print("Include dir: {s}\n", .{include_dir});
    }
    
    for (native_paths.warnings.items) |warning| {
        std.debug.print("Warning: {s}\n", .{warning});
    }
}
```

## 4) Dependencies

- `std.mem` (as `mem`) - for string operations and tokenization
- `std.process` - for environment variable access
- `std.fs.path` - for path joining operations
- `std.zig.system.darwin` - for macOS SDK detection
- `std.posix` - for direct environment variable access on POSIX systems
- `std.Target` - for target information and Linux triple generation
- `std.ArrayListUnmanaged` - for unmanaged array lists with explicit allocators