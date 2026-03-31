# Migration Card: `std.zig.system`

## 1) Concept

This file provides cross-platform system detection and target resolution capabilities for the Zig standard library. Its primary purpose is to detect native system characteristics (CPU architecture, OS version, ABI, dynamic linker) and resolve target queries by filling in missing information through system inspection. The file also handles external execution environment detection (QEMU, Rosetta, Wine, etc.) for running cross-compiled binaries.

Key components include:
- `getExternalExecutor()` - Determines the best execution method (native, emulator, etc.) for cross-target execution
- `resolveTargetQuery()` - The main API that takes a partial target specification and fills in detected native system information
- ELF file parsing utilities for detecting ABI and glibc versions
- OS-specific detection logic for Linux, Windows, macOS, and various BSD systems

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
No explicit allocator parameters in public APIs. The file relies on the new `std.Io` interface for I/O operations rather than direct allocator injection.

### I/O Interface Changes
**Major change**: The `resolveTargetQuery` function now requires an `std.Io` parameter instead of direct file operations:

```zig
// 0.16 pattern
pub fn resolveTargetQuery(io: Io, query: Target.Query) DetectError!Target

// 0.11 would have used direct file operations or different error handling
```

This represents the new dependency injection pattern for I/O in Zig 0.16, where all file/stream operations go through the `Io` interface.

### Error Handling Changes
The error sets are specific and comprehensive:

```zig
pub const DetectError = error{
    FileSystem,
    SystemResources,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    DeviceBusy,
    OSVersionDetectionFail,
    Unexpected,
    ProcessNotFound,
} || Io.Cancelable;
```

This replaces more generic error handling patterns from 0.11 with explicit, domain-specific error types.

### API Structure Changes
The main API follows an "init/query" pattern rather than factory functions:

```zig
// Query-based resolution instead of factory creation
var query = Target.Query{ .cpu_arch = .x86_64 };
const resolved_target = try std.zig.system.resolveTargetQuery(io, query);
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const system = std.zig.system;

// Resolve a target query with system detection
pub fn example() !void {
    var io = std.io; // Get the I/O interface
    
    const query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    };
    
    const target = try system.resolveTargetQuery(io, query);
    
    // Use the resolved target
    std.debug.print("Detected ABI: {s}\n", .{@tagName(target.abi)});
    if (target.dynamic_linker.get()) |dl| {
        std.debug.print("Dynamic linker: {s}\n", .{dl});
    }
}
```

## 4) Dependencies

Heavily imported modules that form the dependency graph:

- `std.mem` - Memory operations and string manipulation
- `std.fs` - File system operations  
- `std.posix` - POSIX system calls and constants
- `std.Target` - Target specification and query types
- `std.elf` - ELF file format parsing
- `std.Io` - New I/O interface abstraction (critical for 0.16 migration)
- `std.debug` - Assertions and debugging utilities

Platform-specific dependencies:
- `std.zig.system.windows` - Windows-specific detection
- `std.zig.system.darwin` - macOS/darwin-specific detection  
- `std.zig.system.linux` - Linux-specific detection
- `std.zig.system.NativePaths` - Native path resolution utilities