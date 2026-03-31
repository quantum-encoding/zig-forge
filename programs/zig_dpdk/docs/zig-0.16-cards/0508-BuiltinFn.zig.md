# Migration Card: `std/zig/BuiltinFn.zig`

## 1) Concept
This file defines metadata about Zig's builtin functions (`@`-prefixed compiler intrinsics). It serves as a central registry that maps builtin function names to their characteristics, including parameter counts, error behavior, and scope restrictions. The primary components are the `Tag` enum listing all builtin functions, the `BuiltinFn` struct containing metadata about each builtin, and the `list` comptime map that associates builtin names with their properties.

The file provides a structured way to query information about builtin functions programmatically, which is useful for compiler internals, language tooling, and static analysis. Each builtin is characterized by its error evaluation behavior, parameter count, lvalue capability, and function scope restrictions.

## 2) The 0.11 vs 0.16 Diff
This file contains metadata definitions rather than user-facing API functions, so there are no public function signatures that developers would call directly. However, the patterns reflect Zig 0.16's approach to builtin function organization:

- **Builtin Naming Changes**: Several builtins have been renamed to follow more consistent patterns:
  - `@boolToInt` → `@intFromBool`
  - `@enumToInt` → `@intFromEnum` 
  - `@errorToInt` → `@intFromError`
  - `@floatToInt` → `@intFromFloat`
  - `@ptrToInt` → `@intFromPtr`
  - `@intToEnum` → `@enumFromInt`
  - `@intToError` → `@errorFromInt`
  - `@intToFloat` → `@floatFromInt`
  - `@intToPtr` → `@ptrFromInt`

- **Error Handling Metadata**: The `EvalToError` enum explicitly tracks which builtins can return errors, supporting Zig 0.16's more precise error handling.

- **Scope Enforcement**: The `illegal_outside_function` flag enforces that certain builtins like `@frameAddress` and `@returnAddress` can only be used in function scope.

## 3) The Golden Snippet
```zig
const std = @import("std");
const builtin = @import("std").zig.BuiltinFn;

// Look up metadata for a specific builtin function
const add_with_overflow_info = builtin.list.get("@addWithOverflow").?;

// Use the metadata to understand builtin properties
std.debug.print("Parameter count: {}\n", .{add_with_overflow_info.param_count});
std.debug.print("Can return error: {}\n", .{add_with_overflow_info.eval_to_error == .maybe});
std.debug.print("Allows lvalue: {}\n", .{add_with_overflow_info.allows_lvalue});

// Example usage of the builtin itself (not from this file's API)
var result: @Vector(2, u32) = undefined;
const overflow = @addWithOverflow(u32, 10, 20, &result);
```

## 4) Dependencies
- `std` - Base standard library import
- `std.StaticStringMap` - Used for the comptime builtin function registry

**Note**: This file defines metadata about Zig's builtin functions rather than providing user-callable APIs. The migration impact comes from changes to the builtin function names and behaviors themselves, which are documented in this registry but implemented in the compiler.