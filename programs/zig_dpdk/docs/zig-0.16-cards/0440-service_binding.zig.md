# Migration Card: std/os/uefi/protocol/service_binding.zig

## 1) Concept

This file defines a generic UEFI Service Binding Protocol implementation in Zig. It provides a type constructor function `ServiceBinding` that returns a protocol-specific type when given a GUID. The protocol enables UEFI drivers to manage service instances by creating and destroying child handles that implement specific services.

Key components include:
- A generic protocol structure with function pointers for creating/destroying child services
- Error set definitions for child management operations
- Three main operations: `createChild` (creates new child handle), `addToHandle` (attaches protocol to existing handle), and `destroyChild` (removes child service)

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Uses explicit error sets (`CreateChildError`, `DestroyChildError`) instead of generic error types
- Error sets combine UEFI-specific errors (`InvalidParameter`, `OutOfResources`, etc.) with `uefi.UnexpectedError`
- Error handling via `status.err()` and `uefi.unexpectedStatus()` pattern

**API Structure Changes:**
- No explicit allocator parameters - UEFI protocols manage their own memory internally
- Factory function pattern: `ServiceBinding()` returns a protocol-specific type
- Clear separation between creating new children vs adding to existing handles
- Status-based error handling with Zig error set translation

**Function Signature Patterns:**
- All functions take `*Self` as first parameter (method-style calling)
- No I/O interface changes - pure UEFI protocol calls
- Uses UEFI calling convention (`callconv(cc)`) for function pointers

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Assume we have a specific service GUID
const MyServiceGuid = uefi.Guid{ ... };

// Create protocol type for our specific service
const MyServiceBinding = uefi.protocol.service_binding.ServiceBinding(MyServiceGuid);

fn useServiceBinding(service_binding: *MyServiceBinding) !void {
    // Create a new child service instance
    const child_handle = try service_binding.createChild();
    
    // Use the child service...
    
    // Clean up the child when done
    try service_binding.destroyChild(child_handle);
}
```

## 4) Dependencies

- `std.os.uefi` (core UEFI infrastructure)
- `std.os.uefi.Guid` (protocol identification)
- `std.os.uefi.Handle` (UEFI object handles)
- `std.os.uefi.Status` (UEFI status codes and error handling)

**Primary Dependencies:**
- UEFI base types and protocols
- Status code handling utilities
- Calling convention definitions (`uefi.cc`)