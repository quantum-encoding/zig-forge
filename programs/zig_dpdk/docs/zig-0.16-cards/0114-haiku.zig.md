# Migration Card: Haiku OS Bindings

## 1) Concept

This file provides Zig bindings for the Haiku operating system's native APIs. It serves as the interface layer between Zig code and Haiku-specific system calls, data structures, and constants. The file contains external function declarations for Haiku kernel operations, system information queries, directory operations, and error code definitions.

Key components include:
- External function bindings to Haiku's kernel API (prefixed with `_kern_*`)
- System information structures (`system_info`, `team_info`, `area_info`, `image_info`)
- Haiku-specific error codes and status types
- Directory operation utilities and network socket options
- Type definitions for Haiku system identifiers (area_id, port_id, etc.)

## 2) The 0.11 vs 0.16 Diff

This file contains low-level OS bindings that follow C ABI patterns, so most migration patterns don't apply:

- **Explicit Allocator requirements**: No allocator patterns present - these are direct OS syscall bindings
- **I/O interface changes**: Uses traditional file descriptor-based I/O without dependency injection
- **Error handling changes**: Returns raw `status_t` (i32) error codes rather than Zig error sets
- **API structure changes**: No `init`/`open` patterns - these are direct C function bindings

The primary migration consideration is that these are **raw C bindings** that don't follow Zig's modern error handling or resource management patterns. Developers would need to wrap these in Zig-friendly interfaces manually.

## 3) The Golden Snippet

```zig
const std = @import("std");
const haiku = std.os.haiku;

pub fn main() !void {
    var sys_info: haiku.system_info = undefined;
    _ = haiku.get_system_info(&sys_info);
    
    std.debug.print("CPU Count: {}\n", .{sys_info.cpu_count});
    std.debug.print("Kernel: {s}\n", .{sys_info.kernel_name});
    
    // Check system memory usage
    const total_memory = sys_info.max_pages * std.mem.page_size;
    const used_memory = sys_info.used_pages * std.mem.page_size;
    std.debug.print("Memory: {}/{} bytes used\n", .{used_memory, total_memory});
}
```

## 4) Dependencies

- `std` (root import)
- `std.debug` (for `assert`)
- `std.math` (for `maxInt`, `minInt`)
- `std.posix` (for `iovec`, `iovec_const`)
- `std.c` (for POSIX types: `fd_t`, `uid_t`, `gid_t`, `dev_t`, `ino_t`, `PATH_MAX`)

This file has minimal Zig standard library dependencies beyond basic type definitions and primarily interfaces with the underlying Haiku C runtime.