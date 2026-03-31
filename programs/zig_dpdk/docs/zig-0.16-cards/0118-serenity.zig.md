# Migration Card: SerenityOS System Bindings

## 1) Concept

This file provides Zig bindings for SerenityOS-specific system calls and constants. It serves as the low-level interface between Zig programs and the SerenityOS kernel API, exposing platform-specific functionality that doesn't exist in standard POSIX. Key components include futex operations for synchronization, performance event monitoring, process management functions, keymap handling, and network socket options specific to SerenityOS.

The file defines constants and function signatures that mirror the SerenityOS kernel API, organized into namespaced structures like `FUTEX`, `PERF_EVENT`, `IP`, and `IPV6`. These bindings enable Zig programs to leverage SerenityOS-specific features while maintaining type safety through Zig's foreign function interface.

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected** - This file contains direct C ABI bindings that remain stable across Zig versions:

- **Pure C ABI Functions**: All functions are `pub extern "c"` declarations with C-compatible signatures
- **No Allocator Changes**: Functions like `anon_create` and `serenity_open` use C-style resource management
- **No I/O Interface Changes**: Uses traditional C-style file descriptors and system calls
- **Error Handling**: Returns C-style error codes (`c_int`) rather than Zig error unions
- **API Structure**: Maintains SerenityOS-specific naming conventions (`serenity_readlink`, `serenity_open`)

The stability is expected since these are direct bindings to the underlying OS C API, which doesn't change with Zig version updates.

## 3) The Golden Snippet

```zig
const std = @import("std");
const serenity = std.c.serenity;

// Example: Using futex for synchronization
var futex_word: u32 = 0;
const timeout = std.c.timespec{ .tv_sec = 1, .tv_nsec = 0 };

// Wait on futex with timeout
const result = serenity.futex_wait(&futex_word, 0, &timeout, std.c.CLOCK.REALTIME, 0);
if (result != 0) {
    // Handle timeout or error
}

// Wake one waiting thread
_ = serenity.futex_wake(&futex_word, 1, 0);
```

## 4) Dependencies

- `std` (core standard library)
- `std.debug` (for assertions)
- `builtin` (for OS detection)
- `std.c` (for POSIX types: `O`, `clockid_t`, `pid_t`, `timespec`)

**Note**: This is a platform-specific binding file that only compiles on SerenityOS (`builtin.os.tag == .serenity`).