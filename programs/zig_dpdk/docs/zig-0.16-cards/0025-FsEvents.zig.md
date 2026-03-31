# Migration Card: `std.Build.Watch.FsEvents`

## 1) Concept

This file implements a file-system watching mechanism for macOS using the FSEventStream API from the CoreServices framework. It provides recursive directory monitoring capabilities that overcome the file descriptor limitations of kqueue-based approaches. The implementation dynamically loads CoreServices symbols to avoid compile-time framework dependencies and uses GCD (Grand Central Dispatch) for event handling with explicit semaphore-based synchronization.

Key components include:
- Dynamic symbol resolution for CoreServices framework functions
- Arena-based path management for watched files and directories
- Recursive directory watching with path deduplication
- Integration with Zig's build system steps for dependency tracking
- Semaphore-based waiting mechanism for file change notifications

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
All public functions now require explicit allocator parameters:
- `deinit(fse: *FsEvents, gpa: Allocator)`
- `setPaths(fse: *FsEvents, gpa: Allocator, steps: []const *std.Build.Step)`
- `wait(fse: *FsEvents, gpa: Allocator, timeout_ns: ?u64)`

### Error Handling Changes
Specific error sets instead of generic errors:
- `init()` returns `error{OpenFrameworkFailed, MissingCoreServicesSymbol}`
- `wait()` returns `error{OutOfMemory, StartFailed}`

### Memory Management Patterns
- Arena allocator pattern with explicit state promotion/demotion
- String hash maps with unmanaged memory (`std.StringArrayHashMapUnmanaged`)
- Explicit cleanup of dynamically allocated resources

### API Structure
- Factory pattern: `init()` returns initialized instance
- Explicit resource management: `deinit()` for cleanup
- Stateful operations with retained context between calls

## 3) The Golden Snippet

```zig
const std = @import("std");
const FsEvents = std.Build.Watch.FsEvents;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Initialize FsEvents watcher
    var fse = try FsEvents.init();
    defer fse.deinit(allocator);

    // Set up build steps to watch (example with empty steps)
    const steps: []const *std.Build.Step = &.{};
    try fse.setPaths(allocator, steps);

    // Wait for file changes with 1 second timeout
    const timeout_ns: ?u64 = 1_000_000_000;
    const result = try fse.wait(allocator, timeout_ns);
    
    switch (result) {
        .dirty => std.debug.print("Files changed!\n", .{}),
        .timeout => std.debug.print("Timeout reached\n", .{}),
    }
}
```

## 4) Dependencies

- `std.mem` - Memory allocation and manipulation
- `std.heap` - Arena allocator management
- `std.fs` - Filesystem path operations
- `std.process` - Current working directory retrieval
- `std.DynLib` - Dynamic library loading for CoreServices
- `std.Build` - Build system integration
- `std.log` - Debug logging infrastructure

The implementation heavily relies on path manipulation, dynamic symbol resolution, and integration with Zig's build system step dependency tracking.