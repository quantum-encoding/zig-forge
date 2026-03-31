# Migration Card: `std.os.linux`

## 1) Concept

This file provides low-level Linux system call interfaces and constants for the Zig standard library. It serves as the foundation for Linux-specific system interactions, offering:

- Direct syscall wrappers (e.g., `open`, `read`, `write`, `mmap`)
- Architecture-specific definitions and constants
- Linux-specific data structures (e.g., `Stat`, `epoll_event`, `io_uring_params`)
- Error handling through the `E` enum namespace
- System call number definitions across different CPU architectures

The file abstracts Linux kernel interfaces while maintaining direct access to raw system calls, making it suitable for both high-level abstractions and low-level system programming.

## 2) The 0.11 vs 0.16 Diff

**Key Migration Changes:**

1. **Explicit Flag Types**: Many system calls now use packed structs instead of raw integers for flags:
   - `O` struct for open flags instead of `u32`
   - `MAP` struct for mmap flags instead of `u32`
   - `FUTEX_OP` struct for futex operations
   - `CLONE` constants use proper flag types

2. **Error Handling**: All syscalls return `usize` with error checking via `E.init()` pattern:
   ```zig
   const result = syscall3(.read, fd, buf, count);
   const err = E.init(result);
   if (err != .SUCCESS) return error;
   ```

3. **Memory Allocation**: Syscalls like `mmap` don't require explicit allocators - they work directly with system memory management.

4. **I/O Interface**: File operations use descriptor-based I/O with consistent error handling through the `E` enum.

5. **Struct Initialization**: Many constants are now proper Zig structs rather than C-style defines:
   ```zig
   const flags = O{ .RDWR = true, .CREAT = true };
   ```

## 3) The Golden Snippet

```zig
const std = @import("std");
const linux = std.os.linux;

pub fn main() !void {
    // Open a file using Linux syscall with packed struct flags
    const path = "test.txt\x00";
    const flags = linux.O{ .RDWR = true, .CREAT = true };
    const mode = linux.S.IRUSR | linux.S.IWUSR;
    
    const fd_result = linux.open(@ptrCast(path), flags, mode);
    const err = linux.E.init(fd_result);
    if (err != .SUCCESS) {
        std.debug.print("Open failed: {}\n", .{err});
        return error.OpenFailed;
    }
    const fd = @as(i32, @intCast(fd_result));
    
    // Write data using syscall
    const data = "Hello, Linux!\n";
    const write_result = linux.write(fd, @ptrCast(data), data.len);
    if (linux.E.init(write_result) != .SUCCESS) {
        std.debug.print("Write failed\n", .{});
    }
    
    // Close file
    _ = linux.close(fd);
}
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std` (root import)
- `std.debug` (for `assert`)
- `std.elf` (for ELF structures and auxv handling)
- `std.posix` (for POSIX types like `iovec`, `winsize`)
- Architecture-specific modules (e.g., `linux/x86_64.zig`, `linux/aarch64.zig`)
- `linux/vdso.zig` (for VDSO optimization)
- `std.dynamic_library` (for dynamic linking support)

**Key Architecture-Specific Dependencies:**
- CPU architecture modules provide syscall number definitions
- Endianness handling for 32/64-bit parameter passing
- VDSO optimization for frequently used syscalls like `clock_gettime`

This module forms the foundation for Zig's Linux system programming capabilities and integrates deeply with architecture-specific implementations while providing a consistent cross-architecture API.