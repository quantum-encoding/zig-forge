# Migration Card: std.Thread

## 1) Concept
This file provides Zig's standard library threading API, serving as a cross-platform abstraction for kernel thread management and concurrency primitives. It represents a kernel thread handle and acts as a namespace for thread operations like spawning, joining, detaching, and thread-local storage management.

Key components include:
- `Thread` type representing a thread handle with methods for lifecycle management
- `ResetEvent` for thread-safe boolean synchronization with blocking operations
- Platform-specific implementations for Windows, POSIX, Linux, and WASI
- Thread naming, CPU count detection, and thread ID functionality
- Related concurrency primitives imported from submodules (Mutex, Semaphore, Condition, etc.)

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Thread spawning now requires explicit allocator**: The `SpawnConfig` struct includes an `allocator: ?std.mem.Allocator` field (defaults to null)
- **WASI threads mandate allocator**: WASI implementation requires `config.allocator` to be non-null, unlike other platforms

### API Structure Changes
- **Thread spawning pattern changed**: From direct function call to configuration-based approach:
  - 0.11: `try std.Thread.spawn(func, args)`
  - 0.16: `try std.Thread.spawn(.{}, func, args)` or with custom config

### Error Handling Changes
- **Specific error sets per operation**: 
  - `SetNameError` for thread naming operations
  - `GetNameError` for retrieving thread names  
  - `SpawnError` for thread creation
  - `CpuCountError` for CPU detection
  - `YieldError` for thread yielding

### Function Signature Changes
```zig
// OLD (0.11 pattern - inferred)
pub fn spawn(comptime function: anytype, args: anytype) SpawnError!Thread

// NEW (0.16 pattern - explicit config)
pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread
```

## 3) The Golden Snippet

```zig
const std = @import("std");

fn worker(args: struct { id: u32, data: *u32 }) void {
    std.debug.print("Thread {} starting\n", .{args.id});
    args.data.* += args.id;
    std.debug.print("Thread {} finished\n", .{args.id});
}

pub fn main() !void {
    var data: u32 = 0;
    
    // Spawn thread with default configuration
    const thread = try std.Thread.spawn(.{}, worker, .{ .id = 42, .data = &data });
    
    // Wait for thread completion
    thread.join();
    
    std.debug.print("Final data: {}\n", .{data});
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` - Memory operations and alignment
- `std.posix` - POSIX system calls
- `std.os.windows` - Windows-specific APIs
- `std.debug` - Assertions and debugging
- `std.math` - Mathematical operations
- `std.fmt` - String formatting
- `std.unicode` - Character encoding conversions
- `std.fs` - File system operations (for thread naming on Linux)

**Platform-Specific Dependencies:**
- `std.c` - C standard library bindings (pthreads)
- Platform-specific atomic operations and futex APIs
- System call interfaces for each supported OS