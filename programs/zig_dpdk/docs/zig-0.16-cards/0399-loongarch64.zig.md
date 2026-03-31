# Migration Card: loongarch64.zig

## 1) Concept

This file provides low-level Linux system call interface implementations specifically for the LoongArch64 architecture. It contains inline assembly wrappers for making direct system calls (`syscall0` through `syscall6`), a custom `clone` implementation for thread creation, and architecture-specific type definitions including the `Stat` structure for file metadata. The file serves as the bridge between Zig's standard library and the LoongArch64 Linux kernel ABI, handling register mapping and calling conventions for this particular CPU architecture.

Key components include the syscall family functions that handle 0-6 argument system calls using the LoongArch64 register calling convention (`$r4` through `$r11`), a naked `clone` function that manages thread creation stack setup, and type definitions that match the kernel's expectations for system structures like `Stat`.

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected.** This file contains architecture-specific low-level system interfaces that remain stable:

- **System Call Interface**: All `syscallN` functions maintain identical signatures (SYS enum + u64 arguments → u64 return)
- **No Allocator Changes**: These are raw system call wrappers, no memory allocation patterns present
- **No I/O Interface Changes**: Direct kernel interface, no dependency injection patterns
- **Error Handling**: Returns raw u64 (kernel return values), no error set changes
- **API Structure**: Low-level system interfaces unchanged (`clone`, `Stat` struct)

The only notable change is the use of `@intFromEnum(number)` instead of the deprecated `@enumToInt`, which is consistent across all Zig 0.16 codebases.

## 3) The Golden Snippet

```zig
const std = @import("std");
const SYS = std.os.linux.SYS;

// Example: Using syscall1 to call getpid on LoongArch64
pub fn exampleGetPid() u64 {
    return std.os.linux.loongarch64.syscall1(SYS.getpid, 0);
}

// Example: Using the Stat structure
pub fn exampleStatUsage() void {
    const stat_info: std.os.linux.loongarch64.Stat = undefined;
    _ = stat_info.atime(); // Returns timespec
    _ = stat_info.mtime();
    _ = stat_info.ctime();
}
```

## 4) Dependencies

- `builtin` - For target-specific configuration (unwind_tables, strip_debug_info)
- `std` - Standard library root import
- `std.os.linux.SYS` - System call number definitions

**Note**: This is an architecture-specific implementation file. Most developers should use the higher-level abstractions in `std.os` rather than calling these low-level interfaces directly.