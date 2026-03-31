# Migration Card: FreeBSD System Interface

## 1) Concept

This file provides FreeBSD-specific system call bindings and type definitions for Zig's standard library. It serves as the low-level interface between Zig code and FreeBSD kernel APIs, containing direct C ABI bindings for system calls like `ptrace`, `sendfile`, and `copy_file_range`, along with FreeBSD-specific data structures like `Stat`, `kinfo_file`, and `cap_rights`.

Key components include FreeBSD-specific system call declarations, error code definitions, socket option constants, and detailed file descriptor information structures used by system monitoring tools. The file is OS-gated with a compile-time assertion to ensure it's only used on FreeBSD systems.

## 2) The 0.11 vs 0.16 Diff

This file contains primarily C ABI bindings rather than Zig-level APIs, so most migration patterns don't apply. However, key observations:

- **No explicit allocator requirements**: All functions are direct C bindings (`extern "c"`) that don't involve Zig memory management
- **No I/O interface changes**: Uses traditional C file descriptors (`fd_t`) rather than Zig's newer I/O abstractions
- **Error handling remains C-style**: Functions return error codes directly or through errno; no Zig error unions
- **API structure unchanged**: These are stable FreeBSD system calls that maintain consistent signatures

The main migration consideration is that this file provides raw C bindings - Zig code using these will need to handle error checking and memory management manually.

## 3) The Golden Snippet

```zig
const std = @import("std");
const freebsd = std.c.freebsd;

// Example using sendfile for zero-copy file transfer
pub fn transferFile(in_fd: freebsd.fd_t, out_fd: freebsd.fd_t) !void {
    var sbytes: freebsd.off_t = undefined;
    const result = freebsd.sendfile(
        in_fd,
        out_fd,
        0,        // offset
        0,        // nbytes (0 = entire file)
        null,     // sf_hdtr
        &sbytes,  // bytes sent
        0,        // flags
    );
    
    if (result == -1) {
        return error.SendfileFailed;
    }
}
```

## 4) Dependencies

- `std.c` (core C type definitions)
- `std.posix` (POSIX I/O vector types)
- `builtin` (OS detection)

This file has minimal Zig-level dependencies as it primarily provides raw C bindings for FreeBSD system interfaces.