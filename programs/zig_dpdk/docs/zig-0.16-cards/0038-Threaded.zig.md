# Migration Card: std.Io.Threaded

## 1) Concept

This file implements a threaded I/O backend for Zig's standard library I/O system. It provides a thread pool that executes I/O operations asynchronously, supporting both file system operations and networking. The key components include:

- `Threaded` struct that manages the thread pool and work queue
- VTable implementation with platform-specific I/O operations (POSIX/Windows/WASI)
- Asynchronous task execution with cancellation support
- Synchronization primitives (mutexes, condition variables) with futex-based implementations
- Network operations including DNS resolution, socket management, and protocol handling

The module serves as a backend for Zig's cross-platform I/O abstraction, providing thread-safe execution of blocking operations while maintaining cancellation support and proper error handling across different operating systems.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- `init()` now requires a thread-safe allocator parameter: `init(gpa: Allocator) Threaded`
- All async operations internally use the provided allocator for task allocation
- `init_single_threaded` uses `Allocator.failing` to avoid allocations

### I/O Interface Changes
- Complete dependency injection via VTable pattern with function pointers
- Platform-specific implementations selected at compile time via `switch (native_os)`
- Two variants: `io()` (full networking) and `ioBasic()` (networking disabled)
- All operations take `userdata: ?*anyopaque` as first parameter (the Threaded instance)

### Error Handling Changes
- Extensive use of `Io.Cancelable!T` error sets for cancellation-aware operations
- Platform-specific error mapping in each operation implementation
- Network operations return `error{NetworkDown}` when unavailable
- Group operations with atomic state tracking for coordinated cancellation

### API Structure Changes
- Factory pattern: `init()` → `io()` → use VTable functions
- Async operations return `?*Io.AnyFuture` (nullable for single-threaded fallback)
- Concurrent operations can return `error.ConcurrencyUnavailable`
- File operations split into streaming vs positional variants
- Network operations have separate IPv4/IPv6 and Unix domain socket paths

## 3) The Golden Snippet

```zig
const std = @import("std");
const Threaded = std.Io.Threaded;

// Initialize threaded I/O with thread-safe allocator
var threaded = Threaded.init(std.heap.page_allocator);
defer threaded.deinit();

// Get I/O interface
const io = threaded.io();

// Example: Open and read a file asynchronously
const file = try io.dirOpenFile(.{ .handle = std.posix.AT.FDCWD }, "/path/to/file", .{ .mode = .read_only });
defer io.fileClose(file);

var buffer: [4096]u8 = undefined;
const bytes_read = try io.fileReadStreaming(file, &.{&buffer});
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` - Memory allocation and manipulation
- `std.posix` - POSIX system calls and constants
- `std.Thread` - Thread management and synchronization
- `std.os.windows` / `ws2_32` - Windows-specific APIs
- `std.os.wasi` - WebAssembly System Interface
- `std.os.linux` - Linux-specific system calls
- `std.debug` - Assertions and debugging
- `std.net` - Network address types and utilities

**Conditional Dependencies:**
- `std.c` (pthreads, ulock functions)
- Platform-specific: `std.os.windows.ntdll`, `std.os.linux` system calls

**Key Type Dependencies:**
- `Allocator` - Memory management
- `Io.VTable` - I/O operation interface
- `std.atomic.Value` - Atomic operations
- Network types: `IpAddress`, `HostName`, socket handles