# Migration Card: std/os/windows/ntdll.zig

## 1) Concept

This file provides direct bindings to the Windows NT Native API (ntdll.dll) functions. It serves as a low-level interface to Windows kernel services that aren't typically exposed through the standard Win32 API. The file contains function declarations for system operations including process/thread management, virtual memory operations, file I/O, synchronization primitives, and system information queries.

Key components include functions for querying process/thread information (`NtQueryInformationProcess`, `NtQueryInformationThread`), file operations (`NtCreateFile`, `NtQueryInformationFile`), virtual memory management (`NtAllocateVirtualMemory`, `NtProtectVirtualMemory`), and synchronization mechanisms (`NtCreateKeyedEvent`, `RtlWaitOnAddress`). These are raw system calls that provide the foundation for higher-level Windows APIs.

## 2) The 0.11 vs 0.16 Diff

This file contains direct Windows API bindings using `pub extern` declarations, which follow a consistent pattern:

- **No explicit allocator requirements**: These are direct system calls that don't use Zig allocators
- **No I/O interface changes**: Functions use Windows HANDLE types and NTSTATUS returns directly
- **Error handling**: All functions return `NTSTATUS` for error reporting, consistent with Windows NT API
- **API structure**: Functions maintain their original Windows API signatures with proper Zig type mappings

The primary migration consideration is the use of `anyopaque` instead of `c_void` or other opaque pointer types, which aligns with Zig's type system evolution. Function signatures remain stable as they mirror the underlying Windows API.

## 3) The Golden Snippet

```zig
const std = @import("std");
const ntdll = std.os.windows.ntdll;

// Query system information example
pub fn querySystemInfo() !void {
    var buffer: [1024]u8 = undefined;
    var return_length: windows.ULONG = undefined;
    
    const status = ntdll.NtQuerySystemInformation(
        .SystemProcessInformation, // SYSTEM_INFORMATION_CLASS
        &buffer,
        @as(windows.ULONG, @intCast(buffer.len)),
        &return_length,
    );
    
    if (status != .SUCCESS) {
        return error.QueryFailed;
    }
    // Process the system information in buffer...
}
```

## 4) Dependencies

- `std.os.windows` - Core Windows type definitions and constants
- Windows type dependencies: `HANDLE`, `NTSTATUS`, `ULONG`, `PVOID`, `OBJECT_ATTRIBUTES`, `IO_STATUS_BLOCK`, etc.
- No explicit memory allocator dependencies (direct system calls)
- Primarily relies on Windows-specific types and calling conventions

**Note**: This file provides low-level Windows NT API bindings that are typically used internally by the Zig standard library rather than directly by application code.