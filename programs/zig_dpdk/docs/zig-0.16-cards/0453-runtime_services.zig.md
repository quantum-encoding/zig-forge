# Migration Analysis: UEFI Runtime Services

## 1) Concept

This file defines the Zig interface for UEFI (Unified Extensible Firmware Interface) Runtime Services, which are firmware-provided services available both before and after the boot process completes. The `RuntimeServices` struct wraps the UEFI runtime services table, providing type-safe Zig functions that call into the underlying UEFI functions with proper error handling.

Key components include:
- Wrapper functions for all UEFI runtime services (time management, variable access, system reset, etc.)
- Comprehensive error sets for each operation type
- Helper types like `VariableNameIterator` for enumerating UEFI variables
- Type definitions for UEFI-specific structures (GUIDs, time, memory descriptors, etc.)

## 2) The 0.11 vs 0.16 Diff

This file demonstrates several Zig 0.16 patterns:

**Error Handling Changes:**
- Uses comprehensive, function-specific error sets (e.g., `GetTimeError`, `SetVariableError`)
- Error sets combine UEFI-specific errors with `uefi.UnexpectedError` for unhandled status codes
- Pattern: `SpecificErrors || uefi.UnexpectedError`

**API Structure Changes:**
- Multiple return values handled via anonymous structs (e.g., `getTime()` returns `struct { Time, TimeCapabilities }`)
- Union types for optional parameters (e.g., `SetWakeupTime` union with `enabled` and `disabled` variants)
- Iterator pattern for variable enumeration (`VariableNameIterator`)

**Memory Safety:**
- Buffer-based APIs requiring pre-allocated memory (no implicit allocator)
- Caller must provide buffers for variable data and names
- Explicit size query functions (`getVariableSize`) before data retrieval

**Type Safety:**
- Strong typing for UEFI-specific concepts (GUID, ResetType, VariableAttributes)
- Packed structs for bitfield representations
- Alignment annotations for UEFI memory structures

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Example: Getting UEFI variable information
fn exampleGetVariable(rs: *const uefi.tables.RuntimeServices) !void {
    const variable_name = "BootOrder";
    const vendor_guid = &uefi.Guid{ ... }; // Actual GUID value
    
    // First get the variable size
    if (try rs.getVariableSize(variable_name, vendor_guid)) |size_info| {
        const var_size = size_info[0];
        const attributes = size_info[1];
        
        // Then read the variable data with properly sized buffer
        var buffer: [1024]u8 = undefined;
        if (try rs.getVariable(variable_name, vendor_guid, buffer[0..var_size])) |var_data| {
            const data = var_data[0];
            const final_attrs = var_data[1];
            // Use variable data...
        }
    }
}

// Example: Iterating through variable names
fn exampleVariableIterator(rs: *const uefi.tables.RuntimeServices) !void {
    var name_buffer: [512]u16 = undefined;
    var iterator = rs.variableNameIterator(&name_buffer);
    
    while (try iterator.next()) |var_name| {
        // Process each variable name
        // iterator.guid contains the vendor GUID for this variable
    }
}
```

## 4) Dependencies

**Primary Dependencies:**
- `std.os.uefi` - Core UEFI types and constants
- `std.os.uefi.tables` - UEFI table definitions

**Key Imported Types:**
- `uefi.Guid`, `uefi.Status`, `uefi.Time`
- `uefi.tables.TableHeader`, `uefi.tables.MemoryDescriptor`
- `uefi.tables.ResetType`, `uefi.tables.CapsuleHeader`

**Builtin Usage:**
- `@alignOf`, `@ptrCast`, `@bitCast` for UEFI memory layout compatibility
- `@FieldType` for generic pointer conversion handling
- `callconv(cc)` for UEFI calling convention preservation