# Migration Card: UEFI SimplePointer Protocol

## 1) Concept

This file implements the UEFI SimplePointer protocol interface for Zig, which provides mouse/pointer device functionality in UEFI firmware environments. The protocol allows applications to interact with pointer devices by providing methods to reset the device hardware and retrieve the current pointer state (position and button status).

Key components include:
- The main `SimplePointer` struct containing function pointers for device operations
- Error sets for reset and getState operations with specific UEFI status code mappings
- State and Mode structures that define pointer device characteristics and current state
- UEFI GUID for protocol identification

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Error sets are now explicitly defined using `uefi.UnexpectedError || error{...}` pattern
- `ResetError` and `GetStateError` provide specific error domains instead of generic error types
- Status codes are explicitly matched and converted to Zig errors using `switch` statements

**API Structure Changes:**
- Functions use `callconv(cc)` calling convention explicitly
- Error handling follows the new pattern of returning error unions with specific error sets
- UEFI status codes are converted to Zig errors via pattern matching rather than direct casting

**No Allocator/I/O Changes:**
- This is a low-level UEFI protocol binding, so it doesn't use Zig allocators
- I/O is handled through UEFI system calls, not Zig's standard I/O interfaces

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Assuming you have obtained a SimplePointer protocol instance
fn handlePointer(pointer: *uefi.protocol.SimplePointer) void {
    // Reset the pointer device
    pointer.reset(true) catch |err| {
        // Handle reset error (DeviceError or UnexpectedError)
        return;
    };

    // Get current pointer state
    const state = pointer.getState() catch |err| switch (err) {
        error.NotReady => {
            // Device not ready, try again later
            return;
        },
        error.DeviceError, error.UnexpectedError => {
            // Handle other errors
            return;
        },
    };

    // Use the pointer state
    if (state.left_button) {
        // Left button pressed
    }
    const movement_x = state.relative_movement_x;
    const movement_y = state.relative_movement_y;
}
```

## 4) Dependencies

- `std.os.uefi` - Core UEFI framework
- `std.os.uefi.Event` - UEFI event handling
- `std.os.uefi.Guid` - UEFI GUID handling
- `std.os.uefi.Status` - UEFI status codes
- `std.os.uefi.cc` - UEFI calling conventions

**Primary Dependency:** `std.os.uefi` (UEFI subsystem)