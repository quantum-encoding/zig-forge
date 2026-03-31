# Migration Card: std/os/uefi/protocol/managed_network.zig

## 1) Concept

This file defines the Zig binding for the UEFI Managed Network Protocol (MNP), which provides packet-level network interface services in UEFI environments. The protocol offers asynchronous network operations including packet transmission, reception, and multicast group management. Key components include the main `ManagedNetwork` struct with its protocol methods, configuration structures like `Config` and `CompletionToken`, and data structures for network packets (`ReceiveData`, `TransmitData`, `Fragment`).

The implementation follows UEFI's C ABI with extern structs and function pointers, providing a type-safe Zig wrapper around the underlying protocol. It includes comprehensive error handling with specific error sets for each operation and supports both IPv4 and IPv6 networking through multicast address translation.

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Each public function now returns a specific error union type (e.g., `GetModeDataError`, `ConfigureError`)
- Error sets combine `uefi.UnexpectedError` with operation-specific errors and common `Status.Error`
- Pattern: `switch (status) { .success => ..., specific_errors => return Error.Specific, else => unexpected }`

**API Structure Consistency:**
- All methods follow consistent naming: lowercase with descriptive names (`getModeData`, `mcastIpToMac`)
- Pointer semantics: `*const ManagedNetwork` for read-only operations, `*ManagedNetwork` for mutable operations
- Return types use Zig structs instead of out parameters where possible (e.g., `GetModeDataData`)

**No Allocator Changes:**
- This protocol doesn't require explicit allocators as it uses UEFI's memory management
- No factory functions - uses direct struct initialization through UEFI service binding

## 3) The Golden Snippet

```zig
const uefi = std.os.uefi;
const ManagedNetwork = uefi.protocol.ManagedNetwork;

// Example: Getting network mode data
fn exampleGetModeData(mnp: *const ManagedNetwork) !void {
    const mode_data = try mnp.getModeData();
    // Use mode_data.mnp_config and mode_data.snp_mode
}

// Example: Configuring the network interface  
fn exampleConfigure(mnp: *ManagedNetwork) !void {
    var config = ManagedNetwork.Config{
        .received_queue_timeout_value = 5000,
        .transmit_queue_timeout_value = 5000,
        .protocol_type_filter = 0x0800, // IPv4
        .enable_unicast_receive = true,
        .enable_multicast_receive = false,
        .enable_broadcast_receive = true,
        .enable_promiscuous_receive = false,
        .flush_queues_on_reset = true,
        .enable_receive_timestamps = false,
        .disable_background_polling = false,
    };
    try mnp.configure(&config);
}
```

## 4) Dependencies

- `std.os.uefi` (core UEFI types and constants)
- `std.os.uefi.protocol.SimpleNetwork` (underlying network protocol)
- `std.os.uefi.Guid`, `std.os.uefi.Event`, `std.os.uefi.Handle`, `std.os.uefi.Status`, `std.os.uefi.Time`, `std.os.uefi.MacAddress` (UEFI base types)
- `std.os.uefi.cc` (calling convention utilities)

**Dependency Graph:** `std.os.uefi` → `std.os.uefi.protocol` → This module depends on `SimpleNetwork` protocol for underlying network operations.