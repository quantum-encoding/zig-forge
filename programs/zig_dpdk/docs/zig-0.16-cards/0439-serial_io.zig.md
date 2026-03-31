# Migration Card: std.os.uefi.protocol.SerialIo

## 1) Concept

This file defines the Zig binding for the UEFI Serial I/O Protocol, which provides access to serial port communication in UEFI environments. The protocol enables basic serial operations like reading, writing, and configuring serial port parameters such as baud rate, parity, and stop bits.

Key components include:
- The main `SerialIo` extern struct that wraps the UEFI protocol interface
- Function wrappers for reset, configuration, and I/O operations
- Error sets specific to each operation type
- Supporting types for parity, stop bits, and mode configuration

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Uses explicit error sets per operation instead of generic error types
- Each function has a dedicated error set (e.g., `ResetError`, `WriteError`)
- Error sets combine UEFI-specific errors with `uefi.UnexpectedError`
- Pattern: `switch` statement on status codes with explicit error mapping

**API Structure Changes:**
- No allocator requirements - this is a direct UEFI protocol wrapper
- I/O functions use slice parameters instead of pointer+length pairs
- Error handling follows Zig 0.16's explicit error set patterns
- Maintains UEFI calling convention (`callconv(cc)`) for compatibility

**Function Signature Changes:**
- `write/read` now take slices (`[]const u8`/`[]u8`) instead of raw pointers
- Error returns are specific to each operation rather than generic Status
- All functions return error unions with operation-specific error sets

## 3) The Golden Snippet

```zig
// Assuming serial_io is obtained from UEFI boot services
var serial: *std.os.uefi.protocol.SerialIo = ...;

// Configure serial port
try serial.setAttribute(
    115200,    // baud_rate
    32,        // receiver_fifo_depth  
    1000,      // timeout (ms)
    SerialIo.ParityType.no_parity,
    8,         // data_bits
    SerialIo.StopBitsType.one_stop_bit
);

// Write data to serial port
const data = "Hello, UEFI!";
const bytes_written = try serial.write(data);

// Read data from serial port  
var buffer: [100]u8 = undefined;
const bytes_read = try serial.read(buffer[0..]);
```

## 4) Dependencies

- `std.os.uefi` (core UEFI types and utilities)
- `std.os.uefi.Guid` (protocol identification)
- `std.os.uefi.Status` (UEFI status codes)
- `std.os.uefi.cc` (calling convention definitions)

This is a pure UEFI protocol binding with no memory allocation dependencies.