# Migration Card: `std/debug.zig`

## 1) Concept

This file is the Zig Standard Library's debugging utilities module, providing core functionality for runtime debugging, error handling, and diagnostic information. It serves as the central hub for debug-related operations including:

- **Panic handling** with configurable panic handlers and stack trace generation
- **Stack unwinding** and trace capture across multiple platforms and architectures  
- **Debug information** abstraction through the `SelfInfo` interface for symbol resolution and source location mapping
- **Memory safety assertions** and runtime safety checks
- **Hex dumping** utilities for memory inspection
- **Signal/segfault handling** for crash diagnostics

The module abstracts target-specific debug information access behind a unified interface while providing extensive stack tracing capabilities that work across different object formats (ELF, Mach-O, COFF, etc.).

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **SelfInfo lifecycle**: `SelfInfo` now requires explicit initialization/deinitialization with allocators
  - `SelfInfo.init` (no allocator) → `SelfInfo.init` (factory pattern)
  - `SelfInfo.deinit(si: *SelfInfo, gpa: Allocator) void` (explicit cleanup)
- **Debug info operations**: All symbol lookup and module operations require allocator injection
  - `getSymbol(si: *SelfInfo, gpa: Allocator, address: usize) SelfInfoError!Symbol`
  - `getModuleName(si: *SelfInfo, gpa: Allocator, address: usize) SelfInfoError![]const u8`
  - `unwindFrame(si: *SelfInfo, gpa: Allocator, context: *UnwindContext) SelfInfoError!usize`

### I/O Interface Changes
- **Stderr management**: New dependency injection pattern for terminal output
  - `lockStderrWriter(buffer: []u8) struct { *Writer, tty.Config }` 
  - `unlockStderrWriter() void` (explicit resource management)
- **Writer-based API**: Stack trace printing now uses injected writers instead of direct file operations
  - `writeCurrentStackTrace(options: StackUnwindOptions, writer: *Writer, tty_config: tty.Config) Writer.Error!void`
  - `writeStackTrace(st: *const StackTrace, writer: *Writer, tty_config: tty.Config) Writer.Error!void`

### Error Handling Changes
- **Specific error sets**: Debug info operations use dedicated `SelfInfoError` instead of generic error handling
- **Structured unwinding errors**: Stack iterator returns `switch_to_fp` with specific error context instead of silent failures

### API Structure Changes
- **Factory pattern**: `SelfInfo` uses `init` factory instead of direct struct initialization
- **Options struct**: Stack unwinding uses `StackUnwindOptions` struct instead of multiple parameters
- **Explicit context**: CPU context handling through `CpuContextPtr` type abstraction
- **Configurable tracing**: `ConfigurableTrace` type replaces simpler trace mechanisms

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() void {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF };
    
    // Lock stderr for safe output
    var buffer: [64]u8 = undefined;
    const stderr_writer, const tty_config = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    
    // Dump hex with proper error handling
    std.debug.dumpHexFallible(stderr_writer, tty_config, &bytes) catch |err| {
        std.debug.print("Failed to dump hex: {}\n", .{err});
    };
    
    // Capture and print stack trace
    var trace_buffer: [16]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &trace_buffer);
    std.debug.dumpStackTrace(&trace);
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` - Memory operations and allocator interfaces
- `std.Io` - I/O abstractions and writer patterns  
- `std.fs` - File system operations for debug info access
- `std.posix` - Platform-specific signal and system call handling
- `std.os.windows` - Windows-specific debug and exception handling
- `std.math` - Mathematical operations for address calculations
- `std.builtin` - Compiler-builtin types and target information

**Secondary Dependencies:**
- `std.net` - Not directly used in this file
- `std.heap` - Used indirectly through allocator patterns
- `std.Thread` - Thread synchronization in panic handling
- `std.Progress` - Terminal progress management integration