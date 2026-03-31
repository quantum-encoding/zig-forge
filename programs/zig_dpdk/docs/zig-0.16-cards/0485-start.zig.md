# Migration Card: std/start.zig

## 1) Concept
This file is the Zig standard library's executable entry point system. It handles platform-specific program initialization and serves as the bridge between the operating system's entry point and the user's `main` function. The file contains architecture-specific assembly code for stack setup, TLS initialization, and calling convention adaptation across different platforms including Linux, Windows, UEFI, WASI, and various freestanding environments.

Key components include:
- Platform-specific entry points (`_start`, `WinMainCRTStartup`, `EfiMain`, etc.)
- Assembly-level stack initialization and ABI compliance
- Program header parsing for PIE relocation and stack size detection
- Main function calling with proper error handling

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
No allocator dependencies found in this low-level entry point code. The file operates at the system level before any heap allocation is available.

### I/O Interface Changes
The file shows updated error reporting patterns:
```zig
// Old pattern (implicit stderr)
// New explicit error logging with stack traces
std.log.err("{s}", .{@errorName(err)});
if (@errorReturnTrace()) |trace| {
    std.debug.dumpStackTrace(trace);
}
```

### Error Handling Changes
Main function error handling has been standardized:
```zig
// Supports multiple main return types with consistent error conversion
const ReturnType = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;
switch (ReturnType) {
    void => { root.main(); return 0; },
    noreturn, u8 => return root.main(),
    else => { // Error union handling
        const result = root.main() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
            return 1;
        };
        return switch (@TypeOf(result)) {
            void => 0, u8 => result,
            else => @compileError(bad_main_ret),
        };
    },
}
```

### API Structure Changes
- **Platform-specific entry points**: Different exported symbols based on target (`_start` for POSIX, `wWinMainCRTStartup` for Windows, `EfiMain` for UEFI)
- **Calling convention enforcement**: Uses `callconv(.withStackAlign(.c, 1))` and architecture-specific conventions
- **Error return trace support**: Conditional stack trace dumping based on platform capabilities

## 3) The Golden Snippet

```zig
// Example of a main function that works with the start.zig system
// This would be in your root file (usually main.zig)

pub fn main() !void {
    // Your application logic here
    std.log.info("Application started", .{});
    
    // Example of error handling that will be properly reported
    try someOperation();
    
    // Successful return
}

fn someOperation() !void {
    return error.OperationFailed;
}

// Alternative main signatures supported:
// pub fn main() void { ... }
// pub fn main() u8 { ... }
// pub fn main() noreturn { ... }
// pub fn main() uefi.Status { ... }        // UEFI specific
// pub fn main() uefi.Error!void { ... }    // UEFI specific
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.os` - OS abstraction layer
- `std.debug` - Debug utilities and stack traces
- `std.elf` - ELF binary format parsing
- `std.posix` - POSIX system calls
- `std.log` - Structured logging

**Platform-Specific Dependencies:**
- `std.os.windows` - Windows API bindings
- `std.os.uefi` - UEFI firmware interface
- `std.os.wasi` - WebAssembly System Interface
- `std.os.linux` - Linux-specific features

**Architecture Support:**
- x86_64, x86, ARM, AArch64, RISC-V, MIPS, PowerPC, SPARC, and many others
- Assembly-level initialization for each supported architecture