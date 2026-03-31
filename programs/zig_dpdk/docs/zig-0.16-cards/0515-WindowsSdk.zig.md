# Migration Card: WindowsSdk.zig

## 1) Concept

This file provides Windows SDK and MSVC library discovery functionality for Zig's build system on Windows platforms. It implements registry-based detection of Windows 10/8.1 SDK installations and MSVC library directories, handling the complex Windows registry access patterns and file system enumeration required to locate development tools.

Key components include:
- `WindowsSdk` struct containing discovered SDK installations and MSVC library paths
- `RegistryWtf8` and `RegistryWtf16Le` abstractions for Windows registry access with proper WTF-8/WTF-16 encoding
- `Installation` struct representing a Windows SDK installation with path and version
- `MsvcLibDir` module for locating MSVC library directories through multiple discovery methods

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory functions require allocators**: `WindowsSdk.find()` takes `std.mem.Allocator` parameter
- **Manual memory management**: `free()` method requires explicit allocator for cleanup
- **Ownership transfer**: Caller owns all returned slices and must free them

### Error Handling Changes
- **Specific error sets**: Functions return specific error unions like `error{OutOfMemory, NotFound, PathTooLong}`
- **No generic errors**: Error cases are explicitly enumerated rather than using catch-all error types
- **Error propagation**: Internal functions bubble up specific errors with clear conversion

### API Structure Changes
- **Factory pattern**: `find()` returns initialized struct rather than separate init functions
- **Resource management**: `free()` method pattern for cleanup instead of automatic deinitialization
- **Architecture parameter**: Functions take `std.Target.Cpu.Arch` for platform-specific discovery

## 3) The Golden Snippet

```zig
const std = @import("std");
const WindowsSdk = @import("std/zig/WindowsSdk.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sdk = try WindowsSdk.find(allocator, .x86_64);
    defer sdk.free(allocator);

    if (sdk.windows10sdk) |win10| {
        std.debug.print("Windows 10 SDK: {s} (version {s})\n", .{win10.path, win10.version});
    }
    
    if (sdk.windows81sdk) |win81| {
        std.debug.print("Windows 8.1 SDK: {s} (version {s})\n", .{win81.path, win81.version});
    }
    
    if (sdk.msvc_lib_dir) |lib_dir| {
        std.debug.print("MSVC lib dir: {s}\n", .{lib_dir});
    }
}
```

## 4) Dependencies

- `std.mem` - Memory allocation and management
- `std.fs` - File system operations and directory iteration
- `std.os.windows` - Windows-specific API bindings
- `std.unicode` - WTF-8/WTF-16 encoding conversions
- `std.json` - JSON parsing for MSVC instance discovery
- `std.Target` - CPU architecture definitions
- `std.process` - Environment variable access