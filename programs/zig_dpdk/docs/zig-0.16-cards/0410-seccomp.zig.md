# Migration Analysis: `std/os/linux/seccomp.zig`

## 1) Concept

This file provides low-level Linux Secure Computing (seccomp) facility bindings for Zig. Seccomp allows processes to restrict system call access through Berkeley Packet Filter (BPF) programs. The module defines:

- **Constants and flags** for seccomp modes, operations, filter flags, and return actions
- **System call data structures** like `data` (syscall context) and notification structures (`notif`, `notif_resp`) for supervisor communication
- **I/O control commands** for the seccomp user notification mechanism

The API enables building BPF filters that execute on each system call, allowing fine-grained control over which syscalls are permitted, logged, or blocked. It handles the complex cross-architecture and endianness considerations required for portable seccomp filters.

## 2) The 0.11 vs 0.16 Diff

**No public function signature changes detected.** This is a constants and structures definition module rather than a functional API module. The migration analysis reveals:

- **No allocator requirements**: The module contains only type definitions and constants, no memory allocation functions
- **No I/O interface changes**: Only structure definitions for kernel communication, no file I/O or stream interfaces
- **No error handling changes**: Pure data definitions without error propagation
- **No API structure changes**: No `init`/`open` patterns since this defines kernel ABI structures

The public API consists entirely of:
- `pub const` definitions (MODE, FILTER_FLAG, RET, etc.)
- `pub const` IOCTL operations  
- `pub` external struct definitions (data, notif, notif_resp, etc.)

These represent the Linux kernel ABI and remain stable across Zig versions.

## 3) The Golden Snippet

```zig
const std = @import("std");
const seccomp = std.os.linux.seccomp;

// Example: Creating a seccomp filter context structure
var ctx: seccomp.data = .{
    .nr = std.os.linux.SYS.getpid,
    .arch = std.os.linux.AUDIT.ARCH.X86_64,
    .instruction_pointer = 0,
    .arg0 = 0,
    .arg1 = 0, 
    .arg2 = 0,
    .arg3 = 0,
    .arg4 = 0,
    .arg5 = 0,
};

// Example: Using seccomp return action constants
const allow_action = seccomp.RET.ALLOW;
const kill_action = seccomp.RET.KILL;
const errno_action = seccomp.RET.ERRNO | @as(u16, 13); // EACCES
```

## 4) Dependencies

- `std.os.linux.ioctl.zig` (via `@import("ioctl.zig")`)

This is a leaf module in the dependency graph with minimal external dependencies, primarily relying on the ioctl subsystem for notification mechanism control operations.