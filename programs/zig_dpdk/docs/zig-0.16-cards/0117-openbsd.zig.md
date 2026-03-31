# Migration Card: OpenBSD System Bindings

## 1) Concept
This file provides Zig bindings for OpenBSD-specific system calls and constants. It serves as an interface layer between Zig code and OpenBSD's C library functions, exposing platform-specific functionality like process tracing (`ptrace`), security promises (`pledge`), file unveiling (`unveil`), authentication systems, and network socket options. The file contains direct C extern declarations, constant definitions, and type definitions specific to OpenBSD's API surface.

Key components include:
- System call wrappers (ptrace, pledge, unveil, futex)
- Authentication and login capability functions
- Process and thread management utilities
- Network socket option constants (IP, IPV6, IPTOS)
- OpenBSD-specific error codes and hardware constants

## 2) The 0.11 vs 0.16 Diff
This file contains direct C bindings rather than Zig-style APIs, so most migration patterns don't apply. However, key observations:

- **No Allocator Requirements**: All functions are direct C externs with no memory management abstractions
- **No I/O Interface Changes**: Uses traditional C-style file descriptors and system calls
- **Error Handling**: Returns C integer error codes directly, no Zig error unions
- **API Structure**: Pure C binding pattern - no init/open factory functions

The primary migration consideration is that these are low-level C bindings that remain stable across Zig versions, as they directly mirror the OpenBSD C ABI.

## 3) The Golden Snippet
```zig
const std = @import("std");
const openbsd = std.c.openbsd;

pub fn main() !void {
    // Use pledge to restrict process capabilities
    const result = openbsd.pledge("stdio", null);
    if (result != 0) {
        return error.PledgeFailed;
    }
    
    // Get current thread ID
    const thread_id = openbsd.getthrid();
    std.debug.print("Thread ID: {}\n", .{thread_id});
    
    // Use unveil to restrict filesystem access
    _ = openbsd.unveil("/tmp", "rw");
    _ = openbsd.unveil(null, null); // Lock unveil permissions
}
```

## 4) Dependencies
- `std` (root import)
- `std.debug` (for assertions)
- `std.math` (for maxInt)
- `builtin` (for target OS detection)
- `std.c` (for C type definitions)
- `std.posix` (for iovec types)

This file has minimal Zig-level dependencies since it primarily provides C bindings. The heavy dependencies are on the underlying OpenBSD C library functions.