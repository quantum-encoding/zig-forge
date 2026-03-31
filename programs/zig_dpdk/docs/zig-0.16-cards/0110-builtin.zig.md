# Migration Card: `std/builtin.zig`

## 1) Concept

This file defines the core types and values provided by the Zig language itself. It serves as the interface between the Zig compiler and standard library, containing compiler-internal data structures that must be kept in sync with the compiler implementation. The file provides fundamental type definitions for Zig's type system, calling conventions, atomic operations, optimization modes, and various low-level language constructs.

Key components include type system definitions (`Type` union with all Zig type variants), calling convention specifications for all supported architectures, atomic operation enums, optimization modes, and compiler backend information. This is essentially the language's self-description mechanism - Zig code can introspect Zig's own type system through these definitions.

## 2) The 0.11 vs 0.16 Diff

This file contains compiler-internal definitions rather than user-facing APIs with migration patterns. The changes are primarily additive and structural:

- **No explicit allocator requirements**: These are compiler-internal types, not memory-managed APIs
- **No I/O interface changes**: This file deals with language primitives, not I/O
- **No error handling changes**: Error types are defined but not used in function signatures
- **API structure consistency**: The types maintain consistent structure as compiler-internal definitions

The primary differences from 0.11 are architectural additions:
- Expanded `CallingConvention` with many new architecture-specific variants
- Enhanced `Type` system with more detailed type information
- Added `CompilerBackend` enum for stage2 compiler identification
- Extended `AddressSpace` with GPU and specialized memory spaces

## 3) The Golden Snippet

```zig
const std = @import("std");

// Using builtin types for compile-time reflection
const MyStruct = struct {
    data: i32,
};

pub fn main() void {
    const type_info = @typeInfo(MyStruct);
    
    // Access builtin type information
    std.debug.print("Type is struct with {} fields\n", .{type_info.Struct.fields.len});
    
    // Use builtin calling convention
    const my_func: fn() void = myFunction;
    _ = my_func;
}

fn myFunction() callconv(.C) void {
    // Function using C calling convention
}
```

## 4) Dependencies

- **`std.zig`** (root standard library import)
- **`builtin`** (compiler-provided builtin module)
- **`root`** (user's root source file for overrides)
- **`std/builtin/assembly.zig`** (assembly-related builtins)

This file has minimal external dependencies since it defines the language primitives themselves. The imports are primarily for compiler coordination and user override capabilities (like custom panic handlers).