# Migration Card: std.Io.IoUring

## 1) Concept

This file implements an `EventLoop` type that provides an asynchronous I/O runtime using Linux's io_uring interface. It's a core component of Zig's async I/O system that manages fibers (lightweight threads) and schedules I/O operations across multiple worker threads. The key components include:

- `EventLoop`: The main event loop structure that manages threads and fibers
- `Thread`: Worker threads with their own io_uring instances and ready queues
- `Fiber`: Lightweight async tasks that can be suspended and resumed
- `AsyncClosure`: Wrappers around fibers that handle async function execution
- Context switching mechanisms for fiber scheduling

The implementation provides a complete async runtime with work stealing, cancellation support, and integration with Zig's standard I/O interface through a vtable-based API.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`init(el: *EventLoop, gpa: Allocator) !void`** - Requires explicit thread-safe allocator
- **`Fiber.allocate(el: *EventLoop) error{OutOfMemory}!*Fiber`** - Fiber allocation requires event loop with allocator
- All fiber management and thread spawning uses the provided allocator

### I/O Interface Changes
- **VTable-based dependency injection** through `io()` method returning `Io` interface
- **Explicit userdata passing** - All I/O operations receive `userdata: ?*anyopaque` parameter
- **Async operations** use fiber-based scheduling rather than callback-based approaches
- **File operations** (`createFile`, `fileOpen`, `fileClose`, `pread`, `pwrite`) follow the new I/O abstraction

### Error Handling Changes
- **Specific error sets** for each operation rather than generic error types
- **Cancellation support** through `error.Canceled` in all async operations
- **Structured error mapping** from system errors to Zig errors in I/O operations

### API Structure Changes
- **Factory pattern** - EventLoop must be initialized via `init()` before use
- **Resource management** - Explicit `deinit()` for cleanup
- **Async/await pattern** - Uses `async()`, `await()`, `select()`, `cancel()` functions
- **Concurrent execution** - `concurrent()` for spawning async tasks

## 3) The Golden Snippet

```zig
const std = @import("std");
const EventLoop = std.Io.IoUring.EventLoop;

// Initialize event loop with allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var el: EventLoop = undefined;
try el.init(allocator);
defer el.deinit();

// Get I/O interface for async operations
const io = el.io();

// Example: Open and read from a file asynchronously
const file = try io.fileOpen(.{.cwd = std.fs.cwd()}, "example.txt", .{
    .mode = .read_only
});
defer io.fileClose(file);

var buffer: [1024]u8 = undefined;
const bytes_read = try io.pread(file, &buffer, 0);
```

## 4) Dependencies

- `std.mem` - For `Allocator`, `Alignment`, memory operations
- `std.os.linux` - For `IoUring` and io_uring system calls
- `std.Thread` - For `Mutex` and thread management
- `std.posix` - For system call error handling and constants
- `std.debug` - For `assert` debugging
- `std.heap` - For page alignment calculations

This file represents a significant evolution from Zig 0.11's I/O patterns, moving to a more structured, allocator-aware, and fiber-based async runtime with explicit resource management and comprehensive error handling.