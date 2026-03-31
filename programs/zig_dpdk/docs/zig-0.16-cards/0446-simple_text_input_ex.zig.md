# Migration Card: std/os/uefi/protocol/simple_text_input_ex.zig

## 1) Concept

This file defines the Zig binding for the UEFI Simple Text Input Ex Protocol, which provides extended keyboard input functionality in UEFI environments. The main component is the `SimpleTextInputEx` extern struct that wraps the UEFI protocol interface, offering methods for keyboard input handling including resetting the device, reading keystrokes with extended state information, setting keyboard toggle states, and registering/unregistering key notifications.

The protocol exposes a low-level hardware interface with error handling that maps UEFI status codes to Zig error sets. It includes detailed key state information through nested structs that represent keyboard shift states, toggle states, and input scan codes.

## 2) The 0.11 vs 0.16 Diff

This UEFI protocol binding follows a consistent pattern that differs from typical Zig 0.11 APIs:

- **No Allocator Requirements**: Unlike many Zig 0.16 APIs that require explicit allocators, this UEFI binding uses stack allocation and pointer parameters without memory management
- **Error Handling Pattern**: Uses specific error sets for each operation (`ResetError`, `ReadKeyStrokeError`, etc.) rather than generic error types, mapping UEFI status codes to Zig errors
- **Direct Struct Usage**: No factory functions - protocols are used directly via pointer to extern struct
- **Calling Convention**: Explicit `callconv(cc)` specification for all UEFI function pointers
- **Status-based Error Handling**: All methods return `Status` and use switch statements to convert to Zig error unions

Key signature patterns:
- All methods take `*SimpleTextInputEx` as first parameter (self pointer)
- Error returns are specific to each operation
- Uses raw pointers and external function calls rather than Zig-style resource management

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Assuming we have a SimpleTextInputEx protocol instance
var input_ex: *uefi.protocol.SimpleTextInputEx = ...;

// Read a keystroke with error handling
const key = try input_ex.readKeyStroke();

// Check the key state and input
if (key.state.toggle.caps_lock_active) {
    // Handle caps lock state
    std.debug.print("Caps Lock is active\n", .{});
}

// Use the key input
if (key.input.unicode_char != 0) {
    std.debug.print("Character: {c}\n", .{key.input.unicode_char});
} else {
    std.debug.print("Scan code: 0x{x}\n", .{key.input.scan_code});
}
```

## 4) Dependencies

- `std.os.uefi` (primary dependency)
- `std.os.uefi.Event`
- `std.os.uefi.Guid` 
- `std.os.uefi.Status`
- `std.os.uefi.cc` (calling convention)

This file has minimal standard library dependencies beyond the UEFI subsystem, focusing primarily on UEFI-specific types and protocols.