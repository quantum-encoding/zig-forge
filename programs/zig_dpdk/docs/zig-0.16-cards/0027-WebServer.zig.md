# Migration Card: std.Build.WebServer

## 1) Concept

This file implements a web server component for Zig's build system that provides a web-based user interface for monitoring build progress. It serves as the backend for Zig's web UI feature, handling HTTP requests, WebSocket connections for real-time updates, and build status tracking. The server displays build step progress, fuzzing status, time reports, and allows triggering rebuilds from the web interface.

Key components include:
- HTTP server handling static file serving (HTML, CSS, JS, WASM)
- WebSocket protocol for real-time build status updates  
- Build step tracking and status management
- Fuzzing integration with progress reporting
- Time reporting for build step performance analysis

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Allocator injection**: The `WebServer` struct contains a `gpa: Allocator` field and all memory management operations use this injected allocator
- **Factory pattern**: The `init()` function takes an `Options` struct containing the allocator rather than using a global allocator
- **Explicit deinit**: `deinit()` method properly cleans up all allocated resources using the stored allocator

### I/O Interface Changes
- **Dependency injection**: The server requires a `graph.io` field for I/O operations instead of using global I/O
- **Thread pool injection**: Uses `thread_pool: *std.Thread.Pool` passed via options rather than creating its own
- **Clock abstraction**: Uses `Io.Clock` and `Io.Timestamp` instead of direct system time calls

### Error Handling Changes
- **Specific error sets**: `start()` returns `error{AlreadyReported}!void` for precise error handling
- **Error propagation**: Internal functions use proper error propagation rather than panicking

### API Structure Changes
- **Init pattern**: Uses `init(Options)` factory function instead of direct struct initialization
- **Explicit lifecycle**: Clear `init()` → `start()` → `deinit()` lifecycle management
- **Builder pattern**: Options struct with named parameters for configuration

## 3) The Golden Snippet

```zig
const std = @import("std");
const Build = std.Build;

// Initialize the web server
var webserver = Build.WebServer.init(.{
    .gpa = allocator,
    .thread_pool = &thread_pool,
    .ttyconf = tty_config,
    .graph = &build_graph,
    .all_steps = all_steps,
    .root_prog_node = root_progress_node,
    .watch = true,
    .listen_address = net.IpAddress.initIPv4(.{ 127, 0, 0, 1 }, 8080),
    .base_timestamp = Build.WebServer.base_clock.now(io),
});

// Start the server
webserver.start() catch |err| {
    std.log.err("Failed to start web server: {s}", .{@errorName(err)});
    return;
};

// Update build step status during build
webserver.updateStepStatus(compile_step, .running);

// Clean up when done
defer webserver.deinit();
```

## 4) Dependencies

- **std.mem** - Memory allocation and manipulation
- **std.net** - Network operations and TCP server
- **std.http** - HTTP protocol implementation
- **std.Thread** - Thread management and synchronization
- **std.Build** - Build system integration
- **std.Io** - I/O abstraction and clock operations
- **std.Progress** - Progress tracking UI
- **std.fs** - File system operations for serving static files