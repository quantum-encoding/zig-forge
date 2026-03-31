# Migration Card: std.process.Child

## 1) Concept

This file implements cross-platform child process management for Zig's standard library. The `ChildProcess` struct provides a comprehensive interface for spawning, managing, and communicating with child processes across Windows, POSIX, and WASI systems. Key components include:

- **Process Configuration**: Command-line arguments, environment variables, working directory, user/group IDs, and I/O behavior settings
- **Process Lifecycle**: Spawning, waiting, and termination with proper resource cleanup
- **I/O Management**: Configurable stdin/stdout/stderr handling with pipe, inherit, ignore, or close behaviors
- **Cross-Platform Abstraction**: Unified API that handles Windows CreateProcess, POSIX fork/exec, and WASI limitations

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory Pattern**: `ChildProcess.init()` now requires explicit allocator parameter
- **Memory Management**: All child process operations (including `run()`) require explicit allocator injection
- **Resource Cleanup**: Proper allocator-aware cleanup for process resources and output collection

### I/O Interface Changes
- **Dependency Injection**: I/O behavior configured via `stdin_behavior`, `stdout_behavior`, `stderr_behavior` fields using `StdIo` enum
- **File-based Pipes**: Standard I/O streams exposed as `std.fs.File` objects when using `.Pipe` behavior
- **Progress Integration**: Support for progress node injection via `progress_node` field

### Error Handling Changes
- **Specific Error Types**: `SpawnError` union type combines platform-specific errors (POSIX `ExecveError`, Windows `CreateProcessError`) with cross-platform errors
- **Batch Script Validation**: Windows-specific validation for `.bat`/`.cmd` script arguments
- **Early Error Reporting**: `waitForSpawn()` method for detecting spawn errors that occur after fork but before exec

### API Structure Changes
- **Builder Pattern**: Configuration through struct fields rather than multiple init parameters
- **Resource-Oriented**: Explicit ownership of process resources with proper cleanup requirements
- **Convenience Functions**: `run()` method combines spawn, output collection, and wait in one call

## 3) The Golden Snippet

```zig
const std = @import("std");
const ChildProcess = std.process.Child;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Spawn process and collect output
    const result = try ChildProcess.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"echo", "hello world"},
        .max_output_bytes = 1024,
    });

    // Use results
    std.debug.print("Exit code: {}\n", .{result.term.Exited});
    std.debug.print("stdout: {s}\n", .{result.stdout});
    std.debug.print("stderr: {s}\n", .{result.stderr});

    // Cleanup owned memory
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
```

## 4) Dependencies

**Core Dependencies:**
- `std.mem` - Memory allocation and manipulation
- `std.fs` - File system operations and file handles
- `std.process` - Process environment and utilities

**Platform-Specific Dependencies:**
- `std.os.windows` - Windows API bindings
- `std.os.linux` - Linux system calls
- `std.posix` - POSIX system calls

**Utility Dependencies:**
- `std.unicode` - String encoding conversions
- `std.debug` - Assertions
- `std.math` - Integer utilities
- `std.heap` - Arena allocator (in usage patterns)

**I/O Dependencies:**
- `std.io` - Polling and stream management
- `std.ArrayList` - Dynamic buffer management