# Migration Card: `std.Progress`

## 1) Concept

This file implements a thread-safe, lock-free progress tracking system for Zig applications. It provides hierarchical progress nodes that can display real-time progress information to the terminal using either ANSI escape codes or Windows Console API. The API is designed to be non-allocating and non-fallible, making it suitable for use in performance-critical code paths.

Key components include:
- `Progress` - The main progress tracking instance with global state
- `Node` - Represents individual progress units with hierarchical relationships
- Terminal output support with automatic resizing handling
- IPC communication for child process progress tracking
- Thread-safe atomic operations for all progress updates

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator parameter**: The API is explicitly non-allocating and uses static buffers (`node_storage_buffer`, `default_draw_buffer`)
- **Buffer management**: Users provide a `draw_buffer` in `Options` but no dynamic allocation occurs

### I/O Interface Changes
- **File-based I/O**: Uses `std.fs.File` directly for terminal output
- **Writer interface**: Provides `lockStderrWriter()` returning `*std.Io.Writer` for coordinated stderr access
- **Platform-specific implementations**: Separate code paths for ANSI terminals vs Windows Console API

### Error Handling Changes
- **Non-fallible design**: Most public functions are `void` returning and handle errors internally
- **Graceful degradation**: Functions return `Node.none` when progress tracking can't be initialized
- **Atomic operations**: All progress updates use atomic operations for thread safety

### API Structure Changes
- **Factory pattern**: `Progress.start(Options) Node` creates the root node
- **Hierarchical nodes**: `node.start()` creates child nodes with parent relationships
- **Explicit lifecycle**: Must call `node.end()` to complete progress tracking
- **Status management**: `setStatus()` controls global progress state (working, success, failure)

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() void {
    // Initialize progress tracking
    var progress = std.Progress.start(.{
        .root_name = "Processing files",
        .estimated_total_items = 100,
    });
    defer progress.end();

    // Create a child node for a specific task
    var file_task = progress.start("Current file", 10);
    defer file_task.end();

    // Update progress
    for (0..10) |i| {
        // Simulate work
        std.time.sleep(100 * std.time.ns_per_ms);
        
        // Update progress
        file_task.completeOne();
        
        // Optionally update name
        if (i == 5) {
            file_task.setName("Halfway through file");
        }
    }

    // Update global status
    std.Progress.setStatus(.success);
}
```

## 4) Dependencies

- `std.mem` - For memory operations and buffer management
- `std.posix` - For POSIX system calls and signal handling
- `std.os.windows` - For Windows Console API
- `std.Thread` - For update thread and synchronization
- `std.fs.File` - For terminal I/O operations
- `std.process` - For environment variable parsing
- `std.debug` - For assertions and runtime safety checks
- `std.time` - For timing and sleep operations
- `std.fmt` - For string formatting in progress display

The module has conditional dependencies based on the target platform, with Windows-specific code paths and POSIX-specific signal handling and IPC functionality.