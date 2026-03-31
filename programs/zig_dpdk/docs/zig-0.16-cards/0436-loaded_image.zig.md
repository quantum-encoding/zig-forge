# Migration Card: std/os/uefi/protocol/loaded_image.zig

## 1) Concept

This file defines the UEFI Loaded Image Protocol, which provides information about UEFI images (applications, drivers, etc.) that are currently loaded into memory. The protocol allows querying image properties like base address, size, memory type, and load options, and provides functionality to unload images from memory.

Key components include:
- The `LoadedImage` struct representing the protocol interface with fields for image metadata and function pointers
- An `unload` method wrapper around the underlying UEFI function pointer
- GUID definitions for the Loaded Image Protocol and Device Path Protocol

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Uses explicit error sets: `UnloadError = uefi.UnexpectedError || error{InvalidParameter}`
- Error handling via `switch` statement on Status codes rather than implicit conversions
- `uefi.unexpectedStatus()` helper for unexpected status codes

**Function Signature Patterns:**
- Method-style functions on protocol structs: `self: *LoadedImage` as first parameter
- Explicit error unions in public APIs: `UnloadError!void` return type
- UEFI-specific calling convention: `callconv(cc)` for function pointers

**No Allocator Changes:** This is a low-level UEFI protocol wrapper that doesn't involve memory allocation in the Zig sense - memory management is handled by UEFI services.

## 3) The Golden Snippet

```zig
const LoadedImage = std.os.uefi.protocol.LoadedImage;

// Assuming you have a *LoadedImage from UEFI boot services
fn unloadImage(loaded_image: *LoadedImage, image_handle: std.os.uefi.Handle) void {
    loaded_image.unload(image_handle) catch |err| switch (err) {
        error.InvalidParameter => {
            // Handle invalid parameter error
        },
        error.Unexpected => {
            // Handle unexpected UEFI status
        },
    }
}
```

## 4) Dependencies

- `std.os.uefi` (core UEFI infrastructure)
- `std.os.uefi.tables` (SystemTable, MemoryType)
- `std.os.uefi.protocol.DevicePath` (device path protocol)
- `std.os.uefi.Guid`, `std.os.uefi.Handle`, `std.os.uefi.Status` (UEFI primitives)

This file is part of the UEFI protocol graph and depends on core UEFI types and the Device Path protocol.