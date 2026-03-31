# Migration Card: illumos.zig

## 1) Concept

This file provides Zig bindings for Illumos-specific system constants, types, and functions. It serves as the interface between Zig code and the Illumos operating system's C API, containing:

- System call definitions and constants for POSIX advisory file operations (`POSIX_FADV`)
- ELF auxiliary vector extensions specific to Illumos (`AT_SUN`)
- Process and thread management types (`taskid_t`, `projid_t`, `zoneid_t`, etc.)
- Network interface structures and ioctl commands (`lifreq`, `SIOCGLIFINDEX`)
- Event port system constants (`PORT_SOURCE`, `FILE_EVENT`)
- IP and IPv6 socket option constants

The file is conditionally compiled to only be available when targeting Illumos, preventing accidental usage on other operating systems.

## 2) The 0.11 vs 0.16 Diff

This file contains primarily C API bindings and constants rather than Zig-style APIs, so most migration patterns don't apply. However, key observations:

**No Explicit Allocator Requirements**: All functions are direct C bindings (`extern "c"`) and don't use Zig allocators.

**No I/O Interface Changes**: The file defines C constants and structures for system interfaces but doesn't implement Zig-style I/O abstractions.

**Error Handling**: C-style error handling with integer return codes (`c_int`) rather than Zig error types.

**API Structure**: Pure C bindings without Zig-style factory functions or initialization patterns.

The main public API consists of:
- `pthread_setname_np(thread: pthread_t, name: [*:0]const u8, arg: ?*anyopaque) c_int`
- `sysconf(sc: c_int) i64`
- Various constants and helper functions for ioctl commands (`IO`, `IOR`, `IOW`, `IOWR`)

## 3) The Golden Snippet

```zig
const std = @import("std");
const illumos = std.c.illumos;

// Setting thread name on Illumos
pub fn setThreadName(thread: std.c.pthread_t, name: []const u8) !void {
    var name_buf: [32:0]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    
    const result = illumos.pthread_setname_np(thread, &name_buf, null);
    if (result != 0) {
        return error.SetNameFailed;
    }
}

// Using POSIX_FADV constants
const posix_fadv = illumos.POSIX_FADV;
const advice = posix_fadv.SEQUENTIAL;

// Using ioctl helper functions
const ioctl_cmd = illumos.IOWR('i', 133, illumos.lifreq);
```

## 4) Dependencies

- `std` (core standard library)
- `builtin` (compiler builtin functions and target information)
- `std.c` (C standard library types and constants)
- `std.debug` (assertion functions)

**Heavy imports from std.c:**
- `std.c.SO` (socket options)
- `std.c.fd_t`, `std.c.gid_t`, `std.c.ino_t`, etc. (POSIX types)
- `std.c.sockaddr`, `std.c.socklen_t` (network types)
- `std.c.timespec` (time structures)