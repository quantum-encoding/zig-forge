# Migration Card: std.Thread.Condition

## 1) Concept
This file implements condition variables for thread synchronization in Zig's standard library. Condition variables work in conjunction with Mutexes to efficiently block threads until certain conditions are met, atomically releasing the mutex during blocking and re-acquiring it upon wakeup. The key components include:

- The main `Condition` struct that provides the public API
- Platform-specific implementations (Windows, Futex-based, and single-threaded)
- Core operations: `wait()`, `timedWait()`, `signal()`, and `broadcast()`
- Thread coordination primitives that follow the typical monitor pattern

The implementation handles the complexity of cross-platform thread synchronization while providing a clean, unified interface for Zig developers.

## 2) The 0.11 vs 0.16 Diff

**No Breaking API Changes Identified**

The public API for `std.Thread.Condition` remains largely unchanged from Zig 0.11 patterns:

- **No explicit allocator requirements**: Condition variables are statically initialized (`Condition{}`) and don't require heap allocation
- **No I/O interface changes**: This is pure thread synchronization, not I/O
- **Error handling unchanged**: `timedWait()` continues to return `error{Timeout}` as in previous versions
- **API structure consistent**: The same four main functions (`wait`, `timedWait`, `signal`, `broadcast`) with identical signatures

The implementation details have evolved (particularly the Futex-based implementation), but the public-facing API maintains backward compatibility.

## 3) The Golden Snippet

```zig
const std = @import("std");
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

var m = Mutex{};
var c = Condition{};
var predicate = false;

fn consumer() void {
    m.lock();
    defer m.unlock();

    while (!predicate) {
        c.wait(&m);
    }
}

fn producer() void {
    {
        m.lock();
        defer m.unlock();
        predicate = true;
    }
    c.signal();
}

pub fn main() !void {
    const thread = try std.Thread.spawn(.{}, producer, .{});
    consumer();
    thread.join();
}
```

## 4) Dependencies

- **std.Thread.Mutex** - Core dependency for mutual exclusion
- **std.Thread.Futex** - Low-level synchronization primitive (non-Windows platforms)
- **std.os** - Platform-specific system calls (Windows CONDITION_VARIABLE)
- **std.debug** - For runtime assertions
- **std.testing** - Test framework utilities
- **std.time** - Time constants (ns_per_ms, ns_per_s) for timeout handling

**Note**: The dependency graph shows this module is part of Zig's threading subsystem and relies heavily on platform-specific synchronization primitives through the OS layer.