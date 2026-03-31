# Migration Card: `std/c/darwin.zig`

## 1) Concept

This file provides Darwin (macOS/iOS) specific C API bindings and constants for Zig's standard library. It serves as the primary interface for accessing macOS-specific system APIs including Mach kernel functions, Grand Central Dispatch, I/O Kit, and other Darwin-exclusive features. The file contains extensive type definitions, constants, and function declarations for low-level system programming on Apple platforms.

Key components include:
- Mach kernel APIs for process/thread management and inter-process communication
- Grand Central Dispatch (GCD) APIs for concurrency
- Darwin-specific error codes and constants
- POSIX spawn and file operations
- Network socket options and protocols
- System tracing and logging APIs (os_log)

## 2) The 0.11 vs 0.16 Diff

This file primarily contains C API bindings and constants, so most changes are structural rather than functional API changes:

**Type System Changes:**
- Extensive use of packed structs and unions for bitfield representations (e.g., `KEVENT.FLAG`, `MACH.RCV`, `MACH.SEND`)
- Stronger type safety with enum-based constants replacing raw integers
- Compile-time assertions for struct layout compatibility

**API Structure Changes:**
- Migration from raw constants to nested namespaces (e.g., `THREAD_NULL` → `THREAD.NULL`)
- Use of `@compileError` directives to guide migration from old constant names
- Structured error handling with `mach_msg_return_t.extractResourceError()`

**External Function Declarations:**
- Consistent use of Zig types in C function signatures
- Proper nullability annotations with `?` type syntax
- Structured parameter types instead of raw pointers

## 3) The Golden Snippet

```zig
const std = @import("std");
const darwin = std.c.darwin;

// Example: Using Grand Central Dispatch semaphores
pub fn useDispatchSemaphore() void {
    const semaphore = darwin.dispatch_semaphore_create(0);
    defer if (semaphore) |s| darwin.dispatch_release(s);
    
    if (semaphore) |s| {
        _ = darwin.dispatch_semaphore_signal(s);
        const result = darwin.dispatch_semaphore_wait(s, .FOREVER);
        // Handle semaphore result...
    }
}

// Example: Getting Mach task information
pub fn getTaskInfo() !void {
    const task = darwin.mach_task_self();
    var info: darwin.mach_task_basic_info = undefined;
    var count = darwin.MACH.TASK.BASIC.INFO_COUNT;
    
    const kr = darwin.task_info(task, darwin.MACH.TASK.BASIC.INFO, &info, &count);
    if (kr != .SUCCESS) {
        return error.TaskInfoFailed;
    }
    // Use task info...
}
```

## 4) Dependencies

This file has minimal Zig-level dependencies but extensive C API dependencies:

**Zig Standard Library Imports:**
- `std` (base imports)
- `std.debug` (for `assert`)
- `std.c` (for cross-platform C constants)
- `std.posix` (for `iovec_const`)
- `std.macho` (for Mach-O header definitions)

**System Framework Dependencies:**
- Mach kernel APIs
- Grand Central Dispatch (libdispatch)
- System Configuration framework
- I/O Kit
- Security framework (Keychain Services)
- Core Foundation (implicit)

**Primary Usage Context:**
This file is typically used by low-level system programming code, process managers, debuggers, and performance monitoring tools targeting Darwin platforms.