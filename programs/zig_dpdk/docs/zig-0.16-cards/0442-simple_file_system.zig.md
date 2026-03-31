# Migration Card: UEFI Simple File System Protocol

## 1) Concept

This file implements the UEFI Simple File System Protocol, which provides access to file systems on UEFI-compatible devices. The key component is the `SimpleFileSystem` extern struct that represents the protocol interface, containing a function pointer for opening volumes and a public method `openVolume()` that wraps the low-level UEFI call with proper error handling.

The protocol follows UEFI's standard pattern where a struct contains function pointers that implement the actual protocol methods, with Zig wrapper functions providing type safety and proper error translation. The file defines the specific GUID that identifies this protocol in the UEFI system.

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- The `openVolume()` function uses a strongly-typed error set `OpenVolumeError` that combines UEFI-specific errors with `uefi.UnexpectedError`
- Error mapping is explicit with a switch statement that converts UEFI status codes to Zig error types
- No generic error types - all possible error cases are explicitly defined

**API Structure:**
- Factory function pattern: `openVolume()` is an instance method that returns a `*File` protocol interface
- No allocator parameters - UEFI protocols manage their own memory
- The function signature follows the pattern of returning error unions with protocol-specific error sets

**Interface Patterns:**
- Uses UEFI's dependency injection through protocol GUID-based discovery
- Wraps low-level C-style function pointers with type-safe Zig methods
- Maintains UEFI calling conventions (`callconv(cc)`) for interoperability

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

fn exampleUsage(simple_fs: *const uefi.protocol.SimpleFileSystem) void {
    // Open the root directory volume
    const root_dir = simple_fs.openVolume() catch |err| switch (err) {
        error.NoMedia => {
            // Handle no media case
            return;
        },
        error.AccessDenied => {
            // Handle access denied
            return;
        },
        else => |e| {
            // Handle other errors
            return;
        },
    };
    
    // root_dir is now a *File that can be used for file operations
    defer _ = root_dir.close();
}
```

## 4) Dependencies

- `std.os.uefi` (core UEFI infrastructure)
- `std.os.uefi.protocol.File` (file protocol dependency)
- `std.os.uefi.Status` (UEFI status code handling)
- `std.os.uefi.Guid` (protocol identification)
- `std.os.uefi.cc` (calling convention definitions)