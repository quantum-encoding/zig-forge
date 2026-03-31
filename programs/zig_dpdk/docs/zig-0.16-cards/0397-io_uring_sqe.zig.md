# Migration Card: `std/os/linux/io_uring_sqe.zig`

## 1) Concept

This file defines the `io_uring_sqe` (Submission Queue Entry) structure for Linux's io_uring asynchronous I/O interface. It contains a low-level extern struct definition that maps directly to the kernel's io_uring SQE data structure, along with numerous helper methods for initializing SQEs for different types of I/O operations.

The key components include:
- The `io_uring_sqe` extern struct with fields matching the kernel ABI
- Over 40 `prep_*` methods that initialize SQEs for operations like read, write, accept, connect, poll, and filesystem operations
- Helper methods like `link_next()` for creating linked SQEs and `set_flags()` for setting SQE flags

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this file maintains the same public interface patterns:

- **No explicit allocator requirements**: All `prep_*` functions operate on existing SQE pointers without memory allocation
- **No I/O interface changes**: Functions take raw file descriptors and pointers directly
- **No error handling changes**: All functions return `void` and don't use error sets
- **Consistent API structure**: All functions follow the pattern `prep_operation(sqe: *io_uring_sqe, ...)` with no `init` vs `open` divergence

**Key observations:**
- Uses `@intFromPtr()` instead of deprecated `@ptrToInt()`
- Uses `@intCast()` for explicit integer conversions
- Uses `@bitCast()` for type-punning conversions (e.g., in `__io_uring_set_target_fixed_file`)
- Leverages `std.mem.nativeToLittle()` for endian-aware poll mask handling

## 3) The Golden Snippet

```zig
const std = @import("std");
const linux = std.os.linux;

// Initialize an io_uring_sqe for a read operation
var sqe: linux.io_uring_sqe = undefined;
const fd = 4; // Some file descriptor
var buffer: [4096]u8 = undefined;

linux.io_uring_sqe.prep_read(&sqe, fd, &buffer, 0);
```

## 4) Dependencies

**Primary dependencies:**
- `std.os.linux` - For all Linux-specific constants, types, and system call definitions
- `std.mem` - Used for `nativeToLittle()` in poll operations

**Secondary dependencies through std.os.linux:**
- `std.posix` - For `iovec`, `msghdr`, socket types, and file operations
- System-specific types: `fd_t`, `socket_t`, `mode_t`, `sockaddr`, etc.

**Note:** This is a low-level system interface file that depends heavily on the Linux kernel ABI and POSIX system interfaces.