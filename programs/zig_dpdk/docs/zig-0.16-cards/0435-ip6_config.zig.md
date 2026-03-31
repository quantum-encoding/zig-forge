# Migration Card: std/os/uefi/protocol/ip6_config.zig

## 1) Concept

This file defines the UEFI IPv6 Configuration Protocol interface for Zig. It provides a wrapper around the UEFI IP6_CONFIG protocol, which manages IPv6 network configuration settings for UEFI network interfaces. The key components include:

- The main `Ip6Config` extern struct that wraps the raw UEFI protocol function pointers
- Type-safe wrapper functions for protocol operations: `setData`, `getData`, `registerDataNotify`, and `unregisterDataNotify`
- Comprehensive error sets for each operation that map UEFI status codes to Zig error types
- Data type definitions for IPv6 configuration parameters including interface info, policies, manual addresses, and gateway/DNS settings

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this file maintains the same public interface patterns:

- **No allocator requirements**: All operations are in-place without dynamic allocation
- **I/O interface unchanged**: Direct UEFI protocol calls without dependency injection
- **Error handling preserved**: Uses the same error set pattern mapping UEFI status codes
- **API structure consistent**: Factory functions not required; direct protocol usage

The public API differences from traditional Zig patterns:
- Uses `comptime` parameters in `setData` and `getData` for type-safe union tag handling
- Leverages `std.meta.Tag` and `std.meta.TagPayload` for compile-time type resolution
- Maintains UEFI-specific calling conventions with `callconv(cc)`

## 3) The Golden Snippet

```zig
const uefi = std.os.uefi;
const ip6_config: *const uefi.protocol.Ip6Config = ...; // Obtained from UEFI system table

// Get current interface information
const interface_info = try ip6_config.getData(.interface_info);

// Set duplicate address detection transmit count
const dad_transmits = uefi.protocol.Ip6Config.DupAddrDetectTransmits{ 
    .dup_addr_detect_transmits = 3 
};
try ip6_config.setData(.dup_addr_detect_transmits, &dad_transmits);
```

## 4) Dependencies

- `std.meta` - Used for compile-time reflection with `Tag` and `TagPayload`
- `std.os.uefi` - Core UEFI types and protocols
- `std.os.uefi.protocol.Ip6` - IPv6 protocol dependency for address types

**Note**: This is a UEFI protocol binding file that follows established patterns without requiring migration changes from 0.11 to 0.16.