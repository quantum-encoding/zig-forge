# IoUring Migration Card

## 1) Concept

This file implements a Zig interface to Linux's io_uring asynchronous I/O subsystem. It provides a high-level wrapper around the Linux kernel's io_uring API, allowing for efficient asynchronous I/O operations including file operations, networking, and various system calls. The key components include:

- **IoUring struct**: Main struct managing submission and completion queues
- **SubmissionQueue**: Handles I/O request submission to the kernel
- **CompletionQueue**: Manages completed I/O operations from the kernel
- **BufferGroup**: Manages application-provided buffers for zero-copy operations

The implementation closely mirrors the liburing C library interface while providing Zig's type safety and error handling.

## 2) The 0.11 vs 0.16 Diff

This file demonstrates several Zig 0.16 patterns:

**Explicit Allocator Requirements:**
- `BufferGroup.init()` requires explicit allocator parameter
- Memory management uses `std.heap.page_size_min` instead of hardcoded values

**I/O Interface Changes:**
- Uses `std.posix` namespace for POSIX functions instead of `std.os`
- Direct Linux system call interface through `std.os.linux`
- File descriptor types use `linux.fd_t` consistently

**Error Handling Changes:**
- Specific error sets per operation (e.g., `error.SubmissionQueueFull`)
- Uses `linux.E` for Linux error codes with `cqe.err()` pattern
- Explicit error conversion via `posix.unexpectedErrno()`

**API Structure Changes:**
- Factory pattern: `IoUring.init()` returns initialized struct
- Explicit deinitialization with `deinit()` method
- Batch operations with `copy_cqes()` instead of single CQE access

## 3) The Golden Snippet

```zig
const std = @import("std");
const IoUring = std.os.linux.IoUring;

// Initialize io_uring with 16 entries
var ring = try IoUring.init(16, 0);
defer ring.deinit();

// Queue a no-op operation
const sqe = try ring.nop(0x1234);

// Submit to kernel
const submitted = try ring.submit();

// Wait for completion
var cqes: [1]std.os.linux.io_uring_cqe = undefined;
const count = try ring.copy_cqes(&cqes, 1);

// Verify completion
std.debug.assert(count == 1);
std.debug.assert(cqes[0].user_data == 0x1234);
std.debug.assert(cqes[0].res == 0);
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.mem` - Memory operations and zero initialization
- `std.posix` - POSIX system calls and constants
- `std.os.linux` - Linux-specific system calls and structures
- `std.debug` - Assertions and debugging
- `std.math` - Power-of-two validation
- `std.heap` - Page size constants

**Key Dependencies:**
- `linux.io_uring_sqe` - Submission queue entry
- `linux.io_uring_cqe` - Completion queue entry
- `linux.io_uring_params` - Setup parameters
- `posix.iovec` - Scatter/gather I/O vectors
- `posix.sockaddr` - Socket address structures

**Conditional Compilation:**
- Linux-only compilation via `builtin.os.tag == .linux`
- Kernel version checks via feature flags