# Migration Card: `std.debug.Dwarf.Unwind`

## 1) Concept

This file provides stack unwinding functionality using DWARF `.debug_frame` or `.eh_frame` sections. It handles loading and parsing Common Information Entries (CIEs) and Frame Description Entries (FDEs) from debug information, and provides fast program counter lookups to find the appropriate unwind information for a given execution point.

Key components include:
- `Unwind` struct: Main container for unwind state and lookup tables
- `EhFrameHeader`: Parser for `.eh_frame_hdr` section data  
- `CommonInformationEntry` and `FrameDescriptionEntry`: Parsed CIE/FDE data structures
- Binary search algorithms for efficient PC-to-FDE mapping

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`deinit`**: Requires explicit `Allocator` parameter for cleanup
- **`prepare`**: Requires explicit `Allocator` parameter to build lookup tables
- **Internal allocation**: CIE list management uses `std.MultiArrayList` with explicit allocator

### I/O Interface Changes
- **Reader pattern**: Uses `std.Io.Reader` abstraction for byte stream parsing
- **Endian awareness**: All parsing functions require explicit `Endian` parameter
- **Fixed buffer readers**: Internal `Reader.fixed()` pattern for memory-based I/O

### Error Handling Changes
- **Specific error sets**: Returns `error{EndOfStream, InvalidDebugInfo, UnsupportedDwarfVersion, UnsupportedAddrSize}` 
- **No generic errors**: Error types are specific to debug information parsing failures
- **Early validation**: Version checks and format validation before complex parsing

### API Structure Changes
- **Factory functions**: `initEhFrameHdr` and `initSection` as primary constructors
- **Explicit state preparation**: `prepare` method required before `lookupPc` usage
- **Memory ownership**: Caller manages section bytes lifetime, library manages internal tables

## 3) The Golden Snippet

```zig
const std = @import("std");
const Unwind = std.debug.Dwarf.Unwind;

// Initialize with .eh_frame section data
var unwind = Unwind.initSection(.eh_frame, section_vaddr, section_bytes);

// Prepare lookup tables (required before lookupPc)
try unwind.prepare(allocator, 8, .little, true, false);

// Find FDE for program counter
if (try unwind.lookupPc(pc_value, 8, .little)) |fde_offset| {
    // Load the FDE and its CIE
    const cie, const fde = try unwind.getFde(fde_offset, .little);
    
    // Validate PC is actually in FDE range
    if (pc_value >= fde.pc_begin and pc_value < fde.pc_begin + fde.pc_range) {
        // Use FDE/CIE for stack unwinding...
    }
}

// Cleanup
unwind.deinit(allocator);
```

## 4) Dependencies

- `std.mem` (Allocator, MultiArrayList)
- `std.math` (casting, arithmetic operations)
- `std.debug` (assertions, Dwarf base)
- `std.dwarf` (DWARF constants, EH pointer encoding)
- `std.io.Reader` (byte stream parsing)
- `std.builtin.Endian` (endianness handling)