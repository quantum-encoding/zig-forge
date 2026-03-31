# Migration Card: std.os.uefi.protocol.AbsolutePointer

## 1) Concept
This file implements the UEFI Absolute Pointer Protocol interface for Zig, which provides access to absolute pointing devices like touchscreens in UEFI environments. The main component is the `AbsolutePointer` extern struct that wraps the UEFI protocol, exposing methods to reset the device and retrieve its current state. The protocol includes support for devices that provide absolute coordinates (X, Y, Z) and button state information.

Key components include the main protocol struct with its reset and state query methods, coordinate range configuration via the `Mode` struct, and current device state tracking through the `State` struct. The implementation follows UEFI's C ABI with proper calling conventions and GUID-based protocol identification.

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected for this UEFI protocol wrapper:**

- **Error Handling**: Uses typed error sets (`ResetError`, `GetStateError`) that combine UEFI status codes with Zig errors, maintaining compatibility
- **No Allocator Changes**: This is a direct UEFI protocol wrapper - no memory allocation is required for the public API
- **I/O Interface**: Maintains UEFI's native event-based input model via `wait_for_input` event
- **API Structure**: Simple method-based interface (`reset`, `getState`) consistent with 0.11 patterns
- **Calling Convention**: Explicit `callconv(cc)` preserved for UEFI compatibility

The implementation follows established UEFI protocol patterns that remain stable across Zig versions, focusing on C ABI compatibility rather than Zig-specific idioms.

## 3) The Golden Snippet

```zig
const AbsolutePointer = std.os.uefi.protocol.AbsolutePointer;

// Assuming protocol instance obtained via UEFI boot services
var pointer: *AbsolutePointer = ...;

// Reset the pointer device
try pointer.reset(true);

// Get current pointer state
const state = try pointer.getState();

// Use the coordinates and button state
const x = state.current_x;
const y = state.current_y; 
const z = state.current_z;
const is_touching = state.active_buttons.touch_active;
```

## 4) Dependencies

- `std.os.uefi` - Core UEFI types and utilities
- `std.os.uefi.Event` - UEFI event handling
- `std.os.uefi.Guid` - Protocol identification
- `std.os.uefi.Status` - UEFI status code handling

This is a leaf node in the dependency graph - it depends only on core UEFI infrastructure without importing higher-level std modules like allocators or networking.