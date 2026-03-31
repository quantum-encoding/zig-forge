# Migration Card: std.Thread.Semaphore

## 1) Concept

This file implements a thread synchronization primitive - a counting semaphore. A semaphore maintains a counter of permits that threads can acquire (wait) or release (post). When a thread attempts to acquire a permit but the counter is zero, it blocks until another thread releases a permit.

Key components include:
- `permits`: The counter tracking available permits
- `mutex`: Protects access to the permits counter
- `cond`: Condition variable for thread signaling
- Core operations: `wait()` (acquire), `post()` (release), and `timedWait()` (acquire with timeout)

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this semaphore implementation maintains stable patterns:

- **No allocator requirements**: Semaphore uses direct struct initialization (`Semaphore{}`) without heap allocation
- **No I/O interface changes**: Pure thread synchronization primitive using Mutex and Condition
- **Error handling stability**: `timedWait` maintains its specific `error{Timeout}` return type
- **API structure consistency**: All functions operate directly on semaphore instances without factory patterns

The API remains consistent with Zig's "no hidden allocations" philosophy and direct struct usage pattern.

## 3) The Golden Snippet

```zig
const std = @import("std");

// Initialize semaphore with 1 permit (binary semaphore/mutex)
var sem = std.Thread.Semaphore{ .permits = 1 };

fn worker() void {
    // Acquire permit - blocks if no permits available
    sem.wait();
    defer sem.post(); // Release permit when done
    
    // Critical section
    std.debug.print("Working in critical section\n", .{});
}

pub fn main() !void {
    const thread = try std.Thread.spawn(.{}, worker, .{});
    
    // Main thread also uses the semaphore
    sem.wait();
    defer sem.post();
    
    std.debug.print("Main thread in critical section\n", .{});
    
    thread.join();
}
```

## 4) Dependencies

- `std.Thread.Mutex` - Mutual exclusion for permit counter
- `std.Thread.Condition` - Thread signaling for wait/notify
- `std.time.Timer` - Timeout measurement in `timedWait`
- `std.testing` - Test framework (test-only)
- `builtin` - Feature detection (single-threaded check in tests)

**Note**: This is a stable synchronization primitive with minimal external dependencies beyond core thread primitives.