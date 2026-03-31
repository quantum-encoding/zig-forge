# Migration Card: std/os/uefi/protocol/block_io.zig

## 1) Concept

This file defines the UEFI Block I/O Protocol interface, which provides block-level access to storage devices in UEFI firmware environments. The main component is the `BlockIo` extern struct that wraps the UEFI block I/O protocol, exposing methods for device reset, block reading/writing, and data flushing. It also includes the `BlockMedia` struct that describes storage media properties like block size, capacity, and media characteristics.

The implementation follows UEFI calling conventions and provides Zig-friendly error handling by translating UEFI status codes to Zig error sets. This is a low-level system interface used for UEFI bootloader development and firmware-level storage operations.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator dependencies - all operations work with pre-allocated buffers provided by the caller.

**I/O Interface Changes**: Pure UEFI protocol binding - uses UEFI calling convention (`callconv(cc)`) and follows UEFI service patterns rather than Zig's standard I/O interfaces.

**Error Handling Changes**: Uses comprehensive, operation-specific error sets:
- `ResetError`: Device errors and unexpected status
- `ReadBlocksError`: Device, media, buffer size, and parameter errors  
- `WriteBlocksError`: Write protection, media changes, device, and parameter errors
- `FlushBlocksError`: Device and media availability errors

**API Structure**: Classic UEFI protocol pattern - methods operate directly on protocol instances obtained from UEFI system tables. No factory functions or initialization patterns.

## 3) The Golden Snippet

```zig
// Assuming block_io is obtained from UEFI system table via LocateProtocol
var block_io: *uefi.protocol.BlockIo = ...;

// Read one block from the device
const media_id = block_io.media.media_id;
const block_size = block_io.media.block_size;
var buffer: [block_size]u8 = undefined;

block_io.readBlocks(media_id, 0, &buffer) catch |err| {
    // Handle read error (DeviceError, NoMedia, BadBufferSize, InvalidParameter)
    return;
};

// Use the read data...
```

## 4) Dependencies

- `std.os.uefi` (primary dependency for UEFI types and status handling)
- UEFI protocol system (implicit dependency on UEFI boot services)

This is a UEFI-specific protocol binding with minimal standard library dependencies beyond the UEFI subsystem.