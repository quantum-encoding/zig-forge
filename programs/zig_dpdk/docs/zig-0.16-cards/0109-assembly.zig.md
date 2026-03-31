# Migration Card: `std/builtin/assembly.zig`

## 1) Concept

This file defines architecture-specific register clobber specifications for inline assembly in Zig. The `Clobbers` type is a packed struct that provides a type-safe way to specify which CPU registers and memory locations are modified by inline assembly blocks.

The key component is a large `switch` statement over CPU architectures that returns different packed struct types, each containing boolean fields for all registers and special-purpose registers available on that architecture. Every field defaults to `false`, and developers can set specific registers to `true` to indicate they are clobbered (modified) by the assembly code.

## 2) The 0.11 vs 0.16 Diff

**No migration changes detected for this file.** The `Clobbers` type appears to be a stable API component:

- **No allocator requirements**: This is a pure type definition with no memory allocation
- **No I/O interface changes**: No file or network operations involved
- **No error handling changes**: Pure type definition with no error cases
- **API structure**: Simple struct definition pattern remains consistent

This file defines a **type** rather than functions, so there are no function signatures to migrate. The architecture-specific struct definitions provide compile-time type safety for register clobber specifications across different CPU targets.

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() void {
    // On x86_64, specify which registers are clobbered by inline assembly
    const clobbers: std.builtin.assembly.Clobbers = .{
        .memory = true,    // Assembly may modify memory
        .rax = true,       // RAX register is modified
        .rcx = true,       // RCX register is modified  
        .flags = true,     // Status flags are modified
    };
    
    // The clobbers struct can be used with inline assembly
    // (actual asm usage would depend on specific assembly code)
}
```

## 4) Dependencies

- **`@import("builtin")`** - Core compiler builtins for target architecture detection

This file has minimal dependencies, only requiring the builtin module to detect the current CPU architecture for the type switch. It doesn't import any standard library modules like `std.mem` or `std.net`.

---

**Note**: This file defines a type system for inline assembly clobbers rather than executable functions, so migration patterns common to allocator-based APIs don't apply here.