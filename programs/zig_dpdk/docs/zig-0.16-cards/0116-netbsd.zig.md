# Migration Card: NetBSD System Bindings

## 1) Concept

This file provides Zig bindings for NetBSD-specific system calls, constants, and data structures. It serves as an interface layer between Zig code and the NetBSD C library/operating system APIs. The file contains:

- External C function declarations for NetBSD-specific APIs like `ptrace`, `_lwp_self`, and `pthread_setname_np`
- System constants for terminal control (TCIFLUSH, TCOFLUSH, etc.)
- Error code enumeration mapping NetBSD error numbers
- Network socket option constants for IP and IPv6 protocols
- System-specific data structures like `_ksiginfo` for signal handling

This is a low-level system interface file that exposes NetBSD kernel and libc functionality to Zig programs.

## 2) The 0.11 vs 0.16 Diff

This file contains C bindings rather than Zig-native APIs, so most migration patterns don't apply directly. However, notable differences from Zig 0.11 patterns include:

- **Type Safety Improvements**: Use of specific integer types like `lwpid_t = i32` and `clock_t` rather than generic integer types
- **Pointer Safety**: Use of `?*anyopaque` for optional void pointers instead of raw `*c_void` or similar
- **Alignment Control**: Explicit alignment specification with `align(@sizeOf(usize))` in the `_ksiginfo` structure
- **String Handling**: Use of `[*:0]const u8` for null-terminated C strings in `pthread_setname_np`

The APIs remain C-style function calls with explicit parameters, maintaining the system call interface pattern rather than adopting Zig's allocator-based or error union patterns.

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() void {
    const current_lwp = std.c._lwp_self();
    std.debug.print("Current LWP ID: {}\n", .{current_lwp});
    
    // Example of using error constants
    if (std.c.E.AGAIN == 35) {
        std.debug.print("EAGAIN error code is 35\n", .{});
    }
    
    // Example of using socket options
    std.debug.print("IP TTL option: {}\n", .{std.c.IP.TTL});
    std.debug.print("IPv6 UNICAST_HOPS option: {}\n", .{std.c.IPV6.UNICAST_HOPS});
}
```

## 4) Dependencies

- `std` (root standard library import)
- `std.c` (for C type definitions like `clock_t`, `pid_t`, `pthread_t`, `sigval_t`, `uid_t`)

This is a leaf node in the dependency graph that primarily depends on core C type definitions from `std.c`.