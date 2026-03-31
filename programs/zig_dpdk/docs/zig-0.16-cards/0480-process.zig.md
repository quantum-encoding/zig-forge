# Migration Card: `std/process.zig`

## 1) Concept
This file provides cross-platform process management functionality for Zig. It serves as the main entry point for process-related operations including:
- Process control (abort, exit, change directory)
- Environment variable management via `EnvMap`
- Command-line argument parsing with `ArgIterator`
- Process execution with `execv`/`execve`
- System information (memory, user info, file descriptors)

Key components include the `Child` module (imported from `process/Child.zig`), environment variable handling with case-insensitive support on Windows, and platform-specific argument parsing implementations for POSIX, Windows, and WASI systems.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`getCwdAlloc`**: Now requires explicit allocator parameter and returns `GetCwdAllocError` (was previously implicit allocator)
- **`EnvMap.init()`**: Requires explicit allocator parameter for hash map initialization
- **`getEnvMap()`**: Requires explicit allocator and returns owned `EnvMap` that must be `deinit()`ed
- **`getEnvVarOwned()`**: Requires explicit allocator parameter for owned environment variable retrieval
- **`argsWithAllocator()`**: New factory function requiring explicit allocator for cross-platform argument iteration
- **`argsAlloc()`**: Requires explicit allocator for allocating argument array

### I/O Interface Changes
- **`ArgIterator`**: Platform-dependent initialization:
  - Windows/WASI: Requires `initWithAllocator()` with explicit deinit
  - POSIX: Simple `init()` without allocator
- **Environment variable functions**: Platform-specific encoding handling (WTF-8 on Windows)

### Error Handling Changes
- **`getCwdAlloc`**: Returns `GetCwdAllocError = Allocator.Error || posix.GetCwdError`
- **`getEnvMap`**: Returns `GetEnvMapError` with specific error set
- **`getEnvVarOwned`**: Returns `GetEnvVarOwnedError` with allocation and platform-specific errors
- **`execv`/`execve`**: Return `ExecvError` combining allocation and POSIX errors

### API Structure Changes
- **Factory patterns**: `EnvMap.init()`, `ArgIterator.initWithAllocator()` vs direct struct initialization
- **Ownership transfer**: `getEnvMap()` returns owned `EnvMap` requiring `deinit()`
- **Resource management**: `ArgIterator.deinit()` required for Windows/WASI platforms

## 3) The Golden Snippet

```zig
const std = @import("std");
const process = std.process;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get current working directory with allocator
    const cwd = try process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    std.debug.print("CWD: {s}\n", .{cwd});

    // Get environment map
    var env = try process.getEnvMap(allocator);
    defer env.deinit();

    // Access environment variables
    if (env.get("PATH")) |path| {
        std.debug.print("PATH: {s}\n", .{path});
    }

    // Iterate command line arguments
    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    while (args.next()) |arg| {
        std.debug.print("Arg: {s}\n", .{arg});
    }
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` (as `mem`) - Memory operations and allocators
- `std.fs` - File system operations
- `std.posix` - POSIX system calls
- `std.os.windows` - Windows-specific system calls
- `std.unicode` - Unicode encoding conversions (WTF-8/WTF-16)
- `std.hash_map` - HashMap implementation for EnvMap
- `std.math` - Mathematical operations
- `std.heap` - Stack fallback allocators

**Platform-Specific Dependencies:**
- POSIX systems: `std.posix` for system calls
- Windows: `std.os.windows` for Windows API
- WASI: `std.os.wasi` for WebAssembly system interface