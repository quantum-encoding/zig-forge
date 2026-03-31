# Migration Card: UEFI Boot Services

## 1) Concept

This file provides a Zig wrapper for the UEFI Boot Services table, which is a core component of the UEFI firmware specification. Boot Services provide runtime services for memory management, protocol handling, image loading, and event management during the boot phase before the operating system takes control. The key components include:

- A comprehensive `BootServices` struct that wraps the raw UEFI function pointers with type-safe Zig interfaces
- Memory management functions (allocatePages, freePages, allocatePool, freePool)
- Protocol installation and management functions  
- Event handling and timer services
- Image loading and execution functions
- Error handling through Zig error sets mapped from UEFI status codes

## 2) The 0.11 vs 0.16 Diff

This file demonstrates several Zig 0.16 patterns:

**Explicit Error Handling:**
- Functions return error unions with specific error sets (e.g., `AllocatePagesError`, `LoadImageError`)
- Error sets are composed using `||` operator: `uefi.UnexpectedError || error{OutOfResources, InvalidParameter}`
- Raw status codes are converted to Zig errors via `uefi.unexpectedStatus(status)`

**Memory Management Patterns:**
- No explicit allocator parameters - uses UEFI's internal memory management
- Returns slices instead of raw pointers: `![]align(4096) Page` and `![]align(8) u8`
- Alignment requirements are explicit in function signatures

**Type-Safe Protocol Handling:**
- Generic functions that require protocols to declare `guid`: `fn handleProtocol(self: *BootServices, Protocol: type, handle: Handle)`
- Compile-time validation of protocol interfaces
- Varargs functions wrapped with tuple-based interfaces

**API Structure:**
- Consistent naming: raw functions prefixed with `_` (e.g., `_allocatePages`), safe wrappers use clean names
- Union parameters for flexible input: `LoadImageSource` union for buffer vs device path
- Structured return types: `ImageExitData` struct for image execution results

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Allocate memory pages using Boot Services
fn allocateLoaderMemory(bs: *uefi.tables.BootServices) !void {
    const pages = try bs.allocatePages(
        .any,                    // AllocateLocation
        .loader_data,            // MemoryType  
        10,                      // pages count
    );
    defer bs.freePages(pages) catch {};
    
    // Use allocated pages...
}

// Load an EFI image from device path
fn loadKernelImage(bs: *uefi.tables.BootServices, device_path: *uefi.protocol.DevicePath) !uefi.Handle {
    const image_handle = try bs.loadImage(
        false,                   // boot_policy
        uefi.handle,             // parent_image_handle  
        .{ .device_path = device_path }, // LoadImageSource
    );
    return image_handle;
}
```

## 4) Dependencies

- `std.os.uefi` - Core UEFI types and constants
- `std.meta` - For `activeTag` and tuple operations in protocol interfaces
- `std.mem` - Used for `sliceTo` in string handling

The file has deep integration with the UEFI ecosystem through:
- `uefi.tables.*` - Table definitions and memory types
- `uefi.protocol.*` - Protocol interfaces  
- `uefi.Event`, `uefi.Guid`, `uefi.Handle` - Core UEFI types
- `uefi.Status` - Error status handling

This represents a mature, type-safe wrapper around UEFI Boot Services with comprehensive error handling and memory safety guarantees.