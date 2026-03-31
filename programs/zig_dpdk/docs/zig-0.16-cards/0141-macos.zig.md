# Migration Card: macOS Certificate Bundle Scanner

## 1) Concept

This file implements macOS-specific certificate bundle scanning functionality for Zig's crypto library. It provides a mechanism to rescan system keychains on macOS to discover and parse X.509 certificates from the system's certificate stores. The main purpose is to populate a certificate bundle with system root certificates and trusted certificates from macOS keychain files.

Key components include:
- `rescanMac`: The main public function that reads from system keychain files and processes certificates
- `scanReader`: A helper function that parses the binary keychain format and extracts certificates
- Various struct definitions (`ApplDbHeader`, `ApplDbSchema`, etc.) that define the macOS keychain binary format
- Error handling for certificate parsing and file operations

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `rescanMac` explicitly requires an `Allocator` parameter (`gpa: Allocator`)
- Memory management uses explicit allocator calls: `gpa.alloc()`, `gpa.free()`, `gpa.free(bytes)`
- Certificate bundle bytes are managed with `cb.bytes.shrinkAndFree(gpa, cb.bytes.items.len)`

**I/O Interface Changes:**
- The function takes `io: Io` parameter but currently has a TODO comment: `_ = io; // TODO migrate file system to use std.Io`
- Current implementation still uses `std.fs.cwd().readFileAlloc()` directly
- Uses new `Io.Reader` interface with methods like `takeStruct()`, `takeInt()`, `readSliceAll()`, and `seek` property

**Error Handling Changes:**
- `RescanMacError` is a union of specific error types: `Allocator.Error || fs.File.OpenError || fs.File.ReadError || fs.File.SeekError || Bundle.ParseCertError || error{EndOfStream}`
- Error transformation pattern: `catch |err| switch (err) { error.StreamTooLong => return error.FileTooBig, else => |e| return e }`

**API Structure Changes:**
- Uses `readFileAlloc` with explicit allocator and size limits
- Reader pattern with explicit byte positioning via `reader.seek = ...`
- Enum handling uses `@as(std.c.DB_RECORDTYPE, @enumFromInt(table_header.table_id))`

## 3) The Golden Snippet

```zig
const std = @import("std");
const Bundle = @import("std").crypto.Certificate.Bundle;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var bundle = Bundle{};
    const io = std.Io.default();
    const now = std.Io.Timestamp.now();
    
    try Bundle.macos.rescanMac(&bundle, allocator, io, now);
}
```

## 4) Dependencies

- `std.mem` - Memory operations and allocator types
- `std.fs` - File system operations for reading keychain files
- `std.Io` - New I/O interface for reading and seeking
- `std.debug` - Assertion functions
- `std.c` - Platform-specific constants (DB_RECORDTYPE)
- `../Bundle.zig` - Main certificate bundle implementation

**Note:** The file contains a TODO indicating ongoing migration work to fully adopt the new `std.Io` interface for file system operations.