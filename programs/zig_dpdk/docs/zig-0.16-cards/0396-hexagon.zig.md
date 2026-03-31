# Migration Card: Zig 0.16 Hexagon System Call Interface

## 1) Concept

This file provides low-level system call interface implementations specifically for the Hexagon architecture on Linux. It contains inline assembly wrappers for making Linux system calls with 0-6 arguments, along with type definitions and structures needed for system call interactions.

The key components include:
- `syscall0` through `syscall6` functions for making system calls with varying numbers of arguments
- A custom `clone` implementation for thread creation with Hexagon-specific assembly
- Type definitions for system call parameters and return values (blksize_t, nlink_t, etc.)
- A `Stat` structure definition for file metadata with accessor methods

## 2) The 0.11 vs 0.16 Diff

This file contains architecture-specific low-level system call interfaces that follow consistent patterns across Zig versions. The key observations:

**No Major API Changes Detected:**
- All functions maintain the same signature patterns (direct system call wrappers)
- No allocator requirements introduced (these are bare metal system calls)
- No I/O interface changes (direct register-based parameter passing)
- Error handling remains primitive (raw u32 returns, no error sets)
- No init/open pattern changes (these are direct function calls)

**Assembly Interface Consistency:**
- Uses stable inline assembly syntax with register constraints
- Maintains the same parameter passing conventions
- `@intFromEnum()` usage for system call numbers is consistent with Zig's enum handling

## 3) The Golden Snippet

```zig
const std = @import("std");
const linux = std.os.linux;

// Example: Using syscall1 to get current process ID
// (Assuming SYS.getpid exists in the Hexagon SYS enum)
pub fn getCurrentPid() u32 {
    return linux.hexagon.syscall1(linux.SYS.getpid, 0);
}

// Example: Using the Stat structure
pub fn printFileSize(stat: linux.hexagon.Stat) void {
    std.debug.print("File size: {}\n", .{stat.size});
}
```

## 4) Dependencies

- `std` - Primary standard library import
- `builtin` - Compiler builtin functions and target information
- `std.os.linux.SYS` - System call number definitions
- `std.os.linux.timespec` - Time specification structure
- `std.os.linux.uid_t/gid_t` - User/group ID types

**Note:** This is a platform-specific implementation file that provides low-level system call interfaces. While it contains public APIs, they are architecture-specific and unlikely to be used directly by most applications. The migration impact is minimal as these are stable low-level interfaces.