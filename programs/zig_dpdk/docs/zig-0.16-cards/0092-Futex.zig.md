# Migration Card: std.Thread.Futex

## 1) Concept

This file provides a cross-platform futex (fast userspace mutex) implementation for Zig's standard library. A futex is a low-level synchronization primitive that allows threads to efficiently block (`wait`) and unblock (`wake`) based on changes to a 32-bit memory address. The key innovation is that threads only block if the memory address contains an expected value, preventing race conditions where a `wake` could happen before a `wait`.

The implementation provides OS-specific backends for Windows, Linux, macOS, FreeBSD, OpenBSD, DragonFlyBSD, WebAssembly, and a fallback pthread-based implementation for other POSIX systems. It also includes a `Deadline` utility for managing timeouts in futex operations.

## 2) The 0.11 vs 0.16 Diff

**No Breaking API Changes Detected**

The public API (`wait`, `timedWait`, `wake`, and `Deadline`) follows consistent patterns with Zig 0.16:

- **No explicit allocator requirements**: All operations work directly with atomic values without memory allocation
- **No I/O interface changes**: Pure synchronization API without file/stream dependencies
- **Error handling**: `timedWait` uses specific `error{Timeout}` rather than generic error sets
- **API structure**: Consistent with Zig's atomic and threading patterns - no init/factory functions needed

The implementation differences are internal:
- Uses `std.atomic.Value(u32)` instead of raw pointers for type safety
- Platform-specific backends handle OS differences transparently
- `Deadline` helper provides timeout management without changing core futex API

## 3) The Golden Snippet

```zig
const std = @import("std");
const Futex = std.Thread.Futex;

// Basic futex usage for cross-thread signaling
var shared_value = std.atomic.Value(u32).init(0);

// Thread 1: Wait for value to change from 0
if (shared_value.load(.seq_cst) == 0) {
    Futex.wait(&shared_value, 0);
}

// Thread 2: Update value and wake waiting threads
shared_value.store(1, .seq_cst);
Futex.wake(&shared_value, 1); // Wake one waiter

// Timed wait with deadline
var deadline = Futex.Deadline.init(100 * std.time.ns_per_ms);
var futex_word = std.atomic.Value(u32).init(0);

while (true) {
    deadline.wait(&futex_word, 0) catch break; // Exit on timeout
}
```

## 4) Dependencies

- `std.atomic` - Core atomic operations
- `std.os` - Platform-specific system calls (windows, linux, darwin modules)
- `std.time` - Timeout handling and duration conversions
- `std.posix` - POSIX API functions (pthread, errno)
- `std.debug` - Assertions
- `std.testing` - Test utilities
- `std.Thread` - Thread spawning for tests
- `std.Treap` - Internal data structure for POSIX implementation

**Note**: This is a stable low-level synchronization primitive. The public API maintains backward compatibility while the internal implementations adapt to platform capabilities.