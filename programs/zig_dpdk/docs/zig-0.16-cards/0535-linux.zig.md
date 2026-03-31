# Migration Card: Linux CPU Detection

## 1) Concept

This file implements Linux-specific CPU detection by parsing `/proc/cpuinfo` and reading CPU registers on various architectures. It provides architecture-specific parsers for SPARC, RISC-V, PowerPC, and ARM/AArch64 systems to detect the native CPU model and features at runtime.

The key component is the `detectNativeCpuAndFeatures` function which serves as the main public API, using a generic `CpuinfoParser` system that delegates to architecture-specific implementations. Each architecture has its own parser implementation that extracts CPU information from the Linux cpuinfo format.

## 2) The 0.11 vs 0.16 Diff

**I/O Interface Changes:**
- The `detectNativeCpuAndFeatures` function now requires an explicit `Io` parameter for dependency injection
- File reading uses `fs.openFileAbsolute` with explicit options struct `.{})` instead of positional parameters
- Reader creation uses `file.reader(io, &buffer)` pattern with explicit I/O interface

**Error Handling Changes:**
- Uses comprehensive error catching with `catch |err| switch (err)` pattern
- Returns `null` on any file operations or parsing failures rather than propagating specific errors
- Maintains fallback behavior for compatibility

**API Structure:**
- The main detection function signature changed to accept I/O interface: `detectNativeCpuAndFeatures(io: Io) ?Target.Cpu`
- File operations use structured configuration `.{})` instead of flags

## 3) The Golden Snippet

```zig
const std = @import("std");
const linux = @import("std/zig/system/linux.zig");

pub fn main() !void {
    const io = std.io;
    
    if (linux.detectNativeCpuAndFeatures(io)) |cpu| {
        std.debug.print("Detected CPU: {s} with architecture {s}\n", .{
            cpu.model.name,
            @tagName(cpu.arch)
        });
    } else {
        std.debug.print("Failed to detect CPU\n", .{});
    }
}
```

## 4) Dependencies

- `std.mem` - For string operations and comparisons
- `std.fs` - For file system access to `/proc/cpuinfo`
- `std.fmt` - For integer parsing from cpuinfo strings
- `std.Target` - For CPU architecture and model definitions
- `std.Io` - For reader interface and I/O operations
- Architecture-specific modules (`arm.zig`) - For CPU model detection logic