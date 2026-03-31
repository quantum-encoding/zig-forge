# Migration Card: `std/os/linux/powerpc.zig`

## 1) Concept

This file provides PowerPC architecture-specific system call implementations and type definitions for Linux systems. It contains low-level inline assembly wrappers for making direct Linux system calls on PowerPC processors, handling the PowerPC-specific calling convention and register usage patterns. The file implements the fundamental syscall interface that higher-level OS abstractions build upon.

Key components include:
- Syscall wrappers (`syscall0` through `syscall6`) that handle varying numbers of arguments
- Specialized functions for thread creation (`clone`) and signal handling (`restore`, `restore_rt`)
- PowerPC-specific type definitions and the `Stat` structure for file metadata
- VDSO (Virtual Dynamic Shared Object) constants for optimized system calls

## 2) The 0.11 vs 0.16 Diff

**No significant API migration changes detected.** This file contains architecture-specific low-level system call implementations that remain stable across Zig versions:

- **No allocator changes**: These are raw system call wrappers that don't allocate memory
- **No I/O interface changes**: Functions operate at the system call level, not the stdlib I/O layer
- **No error handling changes**: All syscalls return raw `u32` values (Linux convention where negative values indicate errors)
- **Stable API structure**: The syscall pattern (`syscall0`, `syscall1`, etc.) remains consistent

The only notable change is the use of `@intFromEnum(number)` instead of the deprecated `@enumToInt(number)` pattern, but this doesn't affect the public API signature.

## 3) The Golden Snippet

```zig
const std = @import("std");
const SYS = std.os.linux.SYS;

// Example: Using syscall1 to call getpid on PowerPC Linux
pub fn example_getpid() u32 {
    return std.os.linux.powerpc.syscall1(.getpid, 0);
}

// Example: Using the Stat structure
pub fn example_stat_usage() void {
    const stat_info: std.os.linux.powerpc.Stat = undefined;
    // stat_info would be populated by a stat syscall
    _ = stat_info.atime();
    _ = stat_info.mtime();
    _ = stat_info.ctime();
}
```

## 4) Dependencies

- `std` - Main standard library import
- `builtin` - Compiler builtin functions and target information
- `std.os.linux.SYS` - Linux system call number definitions

**Note**: This is a stable, architecture-specific implementation file. The public APIs (syscall functions and type definitions) remain consistent across Zig versions, making migration straightforward for PowerPC Linux targets.