# Migration Card: std/os/windows/ntstatus.zig

## 1) Concept

This file defines the `NTSTATUS` enum, which contains all Windows NT status codes as documented in the Microsoft protocol specifications. It serves as a comprehensive collection of status constants used throughout Windows system programming, providing symbolic names for the numeric status values returned by Windows APIs.

The key component is a single public enum `NTSTATUS` with hundreds of status code constants, each mapped to its corresponding hexadecimal value. The enum includes both success codes (starting with 0x0, 0x4) and error codes (starting with 0x8, 0xC), covering everything from basic operations to specialized subsystem statuses.

## 2) The 0.11 vs 0.16 Diff

**No API Changes Detected**

This file contains only constant definitions and does not expose any public functions that would be subject to Zig 0.16 migration patterns. The analysis reveals:

- **No explicit allocator requirements**: This is a pure enum definition file with no memory allocation
- **No I/O interface changes**: Contains no I/O operations or dependency injection patterns
- **No error handling changes**: Defines status codes but doesn't implement error handling logic
- **No API structure changes**: No functions to compare between init vs open patterns

The file consists entirely of enum constants and their documentation, which remain stable across Zig versions.

## 3) The Golden Snippet

```zig
const std = @import("std");
const ntstatus = std.os.windows.ntstatus;

// Example: Checking for common status codes
pub fn handleNtStatus(status: ntstatus.NTSTATUS) void {
    switch (status) {
        .SUCCESS => std.debug.print("Operation completed successfully\n", .{}),
        .ACCESS_DENIED => std.debug.print("Access denied\n", .{}),
        .FILE_NOT_FOUND => std.debug.print("File not found\n", .{}),
        .INSUFFICIENT_RESOURCES => std.debug.print("Insufficient resources\n", .{}),
        else => std.debug.print("Other status: {}\n", .{status}),
    }
}

// Usage with numeric comparison
pub fn isSuccess(status: ntstatus.NTSTATUS) bool {
    return @intFromEnum(status) < 0x80000000;
}
```

## 4) Dependencies

This file has **no dependencies** - it does not import any Zig standard library modules. It's a self-contained enum definition that can be used independently.

**Note**: This file is typically imported by other Windows-specific modules in the standard library that need to work with NTSTATUS codes, but it doesn't depend on any external modules itself.