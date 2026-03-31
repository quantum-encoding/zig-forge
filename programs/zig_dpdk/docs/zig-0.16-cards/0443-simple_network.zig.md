# Migration Card: UEFI Simple Network Protocol

## 1) Concept

This file implements Zig bindings for the UEFI (Unified Extensible Firmware Interface) Simple Network Protocol. It provides a low-level network interface for UEFI environments, allowing basic network operations like packet transmission/reception, MAC address management, and network statistics collection. The key components include:

- The main `SimpleNetwork` extern struct that wraps the UEFI protocol with function pointers for all network operations
- Comprehensive error handling with specific error sets for each operation
- Supporting types like `MacAddress`, `Mode`, `Statistics`, `Packet`, and various configuration enums and structs
- Safe Zig wrappers around the raw UEFI function pointers with proper error translation

## 2) The 0.11 vs 0.16 Diff

This is a UEFI protocol binding file that follows consistent patterns across Zig versions:

**Error Handling Changes:**
- Uses explicit error sets per function (e.g., `StartError`, `TransmitError`) rather than generic error types
- Error sets are composed using the `||` operator with `uefi.UnexpectedError` and protocol-specific errors
- Each function has a `switch` statement that maps UEFI status codes to Zig errors

**API Structure Consistency:**
- All methods are instance methods on `*SimpleNetwork` pointers
- No allocator parameters - this is low-level UEFI system programming
- Consistent naming with UEFI specification (start/stop, initialize/reset, transmit/receive)

**Key Migration Notes:**
- The error handling pattern is more explicit and type-safe compared to 0.11
- Function signatures remain largely unchanged as they mirror UEFI specification
- The main migration work would be adapting to the new error set composition syntax

## 3) The Golden Snippet

```zig
const std = @import("std");
const uefi = std.os.uefi;

// Assuming we have a SimpleNetwork protocol instance
fn example_usage(sn: *uefi.protocol.SimpleNetwork) !void {
    // Start the network interface
    try sn.start();
    
    // Initialize with default buffer sizes
    try sn.initialize(0, 0);
    
    // Get network statistics
    const stats = try sn.statistics(false);
    std.debug.print("Received frames: {}\n", .{stats.rx_total_frames});
    
    // Transmit a packet
    const packet_data = "Hello UEFI Network!";
    try sn.transmit(0, packet_data, null, null, null);
    
    // Receive a packet
    var recv_buffer: [1500]u8 = undefined;
    const received_packet = try sn.receive(&recv_buffer);
    std.debug.print("Received {} bytes\n", .{received_packet.buffer.len});
    
    // Clean shutdown
    try sn.shutdown();
    try sn.stop();
}
```

## 4) Dependencies

```zig
const std = @import("std");
const uefi = std.os.uefi;
const Event = uefi.Event;
const Guid = uefi.Guid;
const Status = uefi.Status;
const cc = uefi.cc;
const Error = Status.Error;
```

**Primary Dependencies:**
- `std.os.uefi` - Core UEFI infrastructure
- UEFI base types: `Event`, `Guid`, `Status`
- UEFI calling convention: `cc`

**Dependency Graph Impact:**
- Heavy reliance on UEFI subsystem
- No standard allocator dependencies
- No network stack dependencies beyond UEFI
- Platform-specific to UEFI firmware environments