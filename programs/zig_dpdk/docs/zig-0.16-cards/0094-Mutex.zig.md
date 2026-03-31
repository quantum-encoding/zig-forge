# Migration Card: std.Thread.Mutex

## 1) Concept

This file implements a cross-platform mutex synchronization primitive for Zig's standard library. A mutex enforces atomic access to shared code regions (critical sections) by ensuring only one thread can hold the lock at any time. The implementation provides multiple backends optimized for different platforms: Windows SRWLOCK, Darwin os_unfair_lock, Futex-based implementation for Linux/other systems, and a single-threaded implementation for builds without threading.

Key components include the main `Mutex` struct with `tryLock`, `lock`, and `unlock` methods, platform-specific implementations (WindowsImpl, DarwinImpl, FutexImpl), debug implementations with deadlock detection, and a recursive mutex variant exported via `Mutex.Recursive`.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected** - the mutex interface remains stable:

- **No explicit allocator requirements**: Mutex can be statically initialized without allocators
- **Consistent function signatures**: `tryLock() -> bool`, `lock() -> void`, `unlock() -> void` patterns unchanged
- **No I/O interface changes**: Pure synchronization primitive without file/network dependencies
- **Error handling unchanged**: Functions don't return error sets - `tryLock` returns boolean, `lock` blocks indefinitely
- **API structure stable**: Simple struct with direct methods, no factory functions or complex initialization

The implementation uses conditional compilation to select optimal backends but maintains identical public API across all platforms.

## 3) The Golden Snippet

```zig
const std = @import("std");
const Mutex = std.Thread.Mutex;

// Initialize mutex directly (no allocator required)
var mutex = Mutex{};
var shared_data: u32 = 0;

// Usage pattern 1: tryLock with conditional execution
if (mutex.tryLock()) {
    defer mutex.unlock();
    shared_data += 1;
}

// Usage pattern 2: blocking lock with defer
mutex.lock();
defer mutex.unlock();
shared_data *= 2;
```

## 4) Dependencies

- `std.debug.assert` - runtime assertions
- `std.Thread` - thread ID and futex operations  
- `std.atomic.Value` - atomic operations for state management
- `std.os.windows` - Windows-specific SRWLOCK implementation
- `std.c` - Darwin-specific os_unfair_lock implementation

**Note**: This is a core synchronization primitive with minimal dependencies, primarily using platform-specific atomic and threading primitives.