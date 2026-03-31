```markdown
# Migration Card: std.Thread.WaitGroup

## 1) Concept

This file implements a WaitGroup synchronization primitive for Zig's standard library. A WaitGroup allows one thread to wait for multiple other threads to complete their work. The key components include atomic state tracking for pending operations, a ResetEvent for blocking/waiting, and methods to start/finish tasks and wait for completion.

The WaitGroup maintains an atomic state that tracks both pending operations (using bit shifting) and waiting status. It provides both regular methods that operate on the WaitGroup struct and stateless variants that work directly with the underlying atomic state and event, offering flexibility for different use cases. The spawnManager function provides a convenient way to spawn threads that automatically manage WaitGroup lifecycle.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator requirements in this API. The WaitGroup is initialized directly without factory functions:
```zig
var wg = WaitGroup{};
```

**I/O Interface Changes**: No I/O dependencies. Uses std.Thread.ResetEvent for synchronization.

**Error Handling Changes**: No error returns in this API. Uses assertions for invariant checking rather than error types.

**API Structure Changes**: 
- Direct struct initialization pattern (no `init()` method)
- Stateless variants (`startStateless`, `finishStateless`, `waitStateless`) provide flexibility for advanced use cases
- `spawnManager` uses `std.Thread.spawn` with configuration struct (`.{}`) rather than direct function call

## 3) The Golden Snippet

```zig
const std = @import("std");
const WaitGroup = std.Thread.WaitGroup;

// Initialize WaitGroup directly
var wg = WaitGroup{};

// Spawn worker threads using spawnManager
wg.spawnManager(workerFunction, .{arg1, arg2});

// Wait for all workers to complete
wg.wait();

// Reset for reuse if needed
wg.reset();

fn workerFunction(arg1: type1, arg2: type2) void {
    // Worker implementation
    // Automatically calls finish() via spawnManager
}
```

## 4) Dependencies

- `std.atomic.Value` - Core atomic operations for state management
- `std.Thread.ResetEvent` - Thread synchronization primitive
- `std.debug.assert` - Runtime invariant checking
- `std.math.maxInt` - Mathematical utilities for bounds checking
```