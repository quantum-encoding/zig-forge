# Migration Card: `std.debug.ElfFile`

## 1) Concept

This file provides a helper type for loading and parsing ELF (Executable and Linkable Format) files to extract debug information. The `ElfFile` struct serves as a container for ELF metadata, DWARF debug information, unwind information (.eh_frame, .debug_frame), and symbol tables. Key components include support for both 32-bit and 64-bit ELF files, endianness handling, memory-mapped file management, and debug information search path resolution.

The primary purpose is to enable debuggers and other tools to extract symbolic information, stack unwinding data, and debug symbols from ELF binaries, including handling cases where debug information is stored in separate files via debug links or build IDs.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `deinit(ef: *ElfFile, gpa: Allocator)` - Requires explicit allocator for cleanup
- `searchSymtab(ef: *ElfFile, gpa: Allocator, vaddr: u64)` - Allocator required for symbol table operations
- `load(gpa: Allocator, elf_file: std.fs.File, ...)` - Factory function with explicit allocator

**I/O Interface Changes:**
- Uses `std.fs.File` for file operations instead of file paths
- Memory mapping via `std.posix.mmap` with explicit alignment requirements
- File operations return specific system error types rather than generic I/O errors

**Error Handling Changes:**
- `LoadError` is a specific error set with detailed ELF parsing and system errors
- `searchSymtab` returns a dedicated error set (`error{NoSymtab, NoStrtab, BadSymtab, OutOfMemory}`)
- System-level errors are explicitly enumerated rather than using generic error types

**API Structure Changes:**
- Factory pattern: `load()` returns `ElfFile` instance rather than `init()` methods
- Arena allocator state embedded in struct for lifetime management
- Configuration via `DebugInfoSearchPaths` struct rather than individual parameters

## 3) The Golden Snippet

```zig
const std = @import("std");
const ElfFile = std.debug.ElfFile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const exe_path = "path/to/binary";
    const file = try std.fs.cwd().openFile(exe_path, .{});
    defer file.close();

    const search_paths = ElfFile.DebugInfoSearchPaths.native(exe_path);
    var elf_file = try ElfFile.load(allocator, file, null, &search_paths);
    defer elf_file.deinit(allocator);

    // Look up symbol at address 0x4000
    const symbol = try elf_file.searchSymtab(allocator, 0x4000);
    std.debug.print("Symbol name: {s}\n", .{symbol.name});
}
```

## 4) Dependencies

- `std.mem` (as `Allocator`)
- `std.elf` (ELF structures and constants)
- `std.fs` (file operations)
- `std.posix` (memory mapping and environment variables)
- `std.heap` (arena allocator)
- `std.compress.flate` (compressed section decompression)
- `std.hash.crc` (CRC validation)
- `std.debug.Dwarf` (DWARF debug information handling)