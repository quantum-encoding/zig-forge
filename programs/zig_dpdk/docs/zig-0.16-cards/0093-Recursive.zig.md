# Migration Analysis: `std.Thread.Mutex.Recursive`

## 1) Concept

This file implements a recursive mutex synchronization primitive for Zig's standard library. A recursive mutex allows the same thread to acquire the lock multiple times without deadlocking, unlike a regular mutex. It's built as an abstraction layer on top of `std.Thread.Mutex` and maintains additional state to track the owning thread ID and lock count.

The key components include:
- Core mutex structure with thread ownership tracking
- `tryLock()` for non-blocking acquisition attempts
- `lock()` for blocking acquisition
- `unlock()` for releasing the lock with proper count management
- Thread ID validation using atomic operations

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes identified** for this specific API. The recursive mutex maintains consistent patterns:

- **No allocator requirements**: Uses direct initialization via `init` constant rather than factory functions
- **Consistent API structure**: Follows the same `lock()`/`tryLock()`/`unlock()` pattern as regular mutex
- **No I/O interface changes**: Pure synchronization primitive without I/O dependencies
- **Error handling unchanged**: `tryLock()` returns boolean, `lock()` is blocking void function

The API remains stable with manual initialization and direct method calls on the struct instance.

## 3) The Golden Snippet

```zig
const std = @import("std");
const RecursiveMutex = std.Thread.Mutex.Recursive;

// Initialize recursive mutex
var mutex = RecursiveMutex.init;

// Lock from current thread (can be called multiple times)
mutex.lock();
mutex.lock(); // Recursive acquisition - no deadlock

// Critical section code here

// Unlock must be called same number of times as lock
mutex.unlock();
mutex.unlock();
```

## 4) Dependencies

- `std.Thread` (for `Mutex`, `Id`, and `getCurrentId()`)
- `std.debug` (for `assert`)
- `std.math` (for `maxInt` used in `invalid_thread_id`)

The primary dependency is `std.Thread` for core threading primitives, with minimal use of other standard library modules for debugging and constants.