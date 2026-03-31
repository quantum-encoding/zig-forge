# Migration Analysis: `std.debug.cpu_context`

## 1) Concept

This file provides CPU register state definitions for stack unwinding across multiple architectures. It defines architecture-specific context structures that capture register values, with implementations for getting the current CPU context via inline assembly and converting from OS-specific context structures (POSIX signal contexts and Windows CONTEXT). The primary purpose is to support debuggers and stack unwinding by providing a unified interface to CPU register state across different platforms and architectures.

Key components include:
- `Native` type that selects the appropriate CPU context structure for the current architecture
- Conversion functions `fromPosixSignalContext` and `fromWindowsContext` to create native contexts from OS-specific structures
- Architecture-specific context structs (Aarch64, X86, X86_64, etc.) with `current()` methods and DWARF register access

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected.** This file maintains consistent patterns:

- **No allocator requirements**: All functions operate on stack-allocated contexts or pointer conversions
- **No I/O interface changes**: Pure CPU register manipulation without I/O dependencies
- **Error handling consistency**: Uses specific error set `DwarfRegisterError` throughout
- **API structure stability**: Factory functions (`current()`, `fromPosixSignalContext`, `fromWindowsContext`) maintain same patterns

Minor internal changes:
- Uses `@ptrCast(@alignCast(...))` for pointer conversions (consistent with 0.16 safety requirements)
- Uses `@ptrFromInt` instead of deprecated `@intToPtr`
- Architecture-specific context structs remain `extern struct` for inline assembly compatibility

## 3) The Golden Snippet

```zig
const std = @import("std");
const cpu_context = std.debug.cpu_context;

// Get current CPU context for native architecture
const current_ctx = cpu_context.Native.current();

// Access DWARF register bytes (example for x86_64)
if (cpu_context.Native.dwarfRegisterBytes(0)) |rax_bytes| {
    // Use register bytes for unwinding
    std.debug.print("RAX register bytes: {any}\n", .{rax_bytes});
} else |err| switch (err) {
    cpu_context.DwarfRegisterError.InvalidRegister => {},
    cpu_context.DwarfRegisterError.UnsupportedRegister => {},
}
```

## 4) Dependencies

- **std.mem** - Used for array reversal in ARC architecture conversion
- **std.os** - Used for Windows CONTEXT type and Linux signal handling types
- **builtin** - Used for target architecture and OS detection
- **root** - Used for user-override capability via `root.debug.CpuContext`

This file has minimal external dependencies and focuses purely on CPU architecture-specific register handling, making it relatively stable across Zig versions.