# Migration Card: std/os/uefi/protocol/graphics_output.zig

## 1) Concept

This file implements the UEFI Graphics Output Protocol (GOP) interface, which provides basic graphics capabilities in UEFI environments. It defines the core structures and functions for managing display modes, pixel formats, and block transfer (blt) operations for graphics output. The protocol allows querying available graphics modes, setting active display modes, and performing pixel buffer operations for screen rendering.

Key components include the main `GraphicsOutput` struct that wraps the protocol's function table, the `Mode` structure containing display configuration information, pixel format definitions (`PixelFormat`, `PixelBitmask`, `BltPixel`), and the `BltOperation` enum for different transfer operations. This is a low-level UEFI protocol binding that provides direct access to graphics hardware through the UEFI firmware interface.

## 2) The 0.11 vs 0.16 Diff

**No significant API migration changes detected** - this appears to be a stable UEFI protocol binding:

- **No allocator requirements**: All operations work with existing UEFI protocol instances and don't require memory allocation
- **No I/O interface changes**: Uses direct UEFI function pointer calls with stable calling convention (`callconv(cc)`)
- **Error handling stability**: Error sets are protocol-specific and follow consistent patterns (`uefi.UnexpectedError || error{...}`)
- **API structure unchanged**: Functions directly wrap UEFI protocol methods without factory patterns

The API maintains the same structure as it's fundamentally a binding to the UEFI specification rather than a Zig-standard library abstraction.

## 3) The Golden Snippet

```zig
const uefi = std.os.uefi;
const GraphicsOutput = uefi.protocol.GraphicsOutput;

// Assuming we have a GraphicsOutput protocol instance
var gop: *GraphicsOutput = ...; // Obtained from UEFI boot services

// Query information about mode 0 (current mode)
const mode_info = try gop.queryMode(0);

// Set a new graphics mode
try gop.setMode(1);

// Perform a video fill operation (clear screen)
try gop.blt(
    null, // No buffer for fill operation
    GraphicsOutput.BltOperation.blt_video_fill,
    0, 0, // Source coordinates (ignored for fill)
    0, 0, // Destination coordinates  
    1920, 1080, // Width and height
    0 // Delta (pitch) - ignored for fill
);
```

## 4) Dependencies

- `std.os.uefi` (core UEFI infrastructure)
- `std.os.uefi.Guid` (protocol identification)
- `std.os.uefi.Status` (error status handling)
- `std.os.uefi.cc` (calling convention definitions)

**Note**: This is a UEFI protocol binding that depends heavily on the UEFI subsystem and follows the UEFI specification rather than Zig standard library conventions.