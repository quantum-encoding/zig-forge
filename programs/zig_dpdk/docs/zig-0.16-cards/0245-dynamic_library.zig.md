# Migration Card: `std.dynamic_library`

## 1) Concept
This file provides cross-platform dynamic library loading and symbol lookup functionality. The main `DynLib` struct abstracts platform-specific implementations, using `ElfDynLib` for Linux/musl systems, `WindowsDynLib` for Windows, and `DlDynLib` for macOS/BSD systems. The library enables loading shared libraries (.so, .dll, .dylib) and looking up exported symbols by name at runtime.

Key components include:
- **DynLib**: The main cross-platform interface with `open/openZ`, `close`, and `lookup` methods
- **Platform-specific implementations**: `ElfDynLib`, `WindowsDynLib`, and `DlDynLib` handling OS-specific loading mechanisms
- **Symbol resolution**: Advanced ELF parsing for Linux systems and standard system APIs for other platforms

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
**No allocator injection** - Unlike many 0.16 APIs, this module doesn't require explicit allocators. Memory management is handled internally using OS-level APIs (`mmap`, `LoadLibrary`, `dlopen`).

### I/O Interface Changes
**Platform-agnostic API** - The main `DynLib` interface provides consistent cross-platform methods:
- `open(path: []const u8) Error!DynLib`
- `openZ(path_c: [*:0]const u8) Error!DynLib`
- `lookup(comptime T: type, name: [:0]const u8) ?T`

### Error Handling Changes
**Unified error sets** - The main API uses a combined error type:
```zig
pub const Error = ElfDynLibError || DlDynLibError || WindowsDynLibError;
```
Platform-specific implementations maintain their own error sets but are unified at the `DynLib` level.

### API Structure Changes
**Consistent initialization pattern** - Uses simple `open()` factory functions rather than separate init/step patterns:
```zig
var lib = try DynLib.open("mylib.so");  // Single-step initialization
defer lib.close();
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const DynLib = std.DynLib;

pub fn main() !void {
    // Load a dynamic library
    var lib = try DynLib.open("libc.so.6");
    defer lib.close();

    // Look up a function symbol
    const puts_fn = lib.lookup(*const fn ([*:0]const u8) callconv(.C) c_int, "puts");
    
    if (puts_fn) |puts| {
        _ = puts("Hello from dynamic library!");
    }
}
```

## 4) Dependencies
- **std.mem** - String operations and memory utilities
- **std.posix** - POSIX system calls (mmap, open, close)
- **std.elf** - ELF file format parsing (Linux-specific)
- **std.os.windows** - Windows API bindings
- **std.fs** - File system operations (path resolution)
- **std.heap** - Page size constants for memory alignment

The module shows minimal dependency injection patterns typical of 0.16, instead relying on direct OS APIs and internal memory management through platform-specific system calls.