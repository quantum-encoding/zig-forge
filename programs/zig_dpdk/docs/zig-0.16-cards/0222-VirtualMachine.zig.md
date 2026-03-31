# Migration Card: `std.debug.Dwarf.Unwind.VirtualMachine`

## 1) Concept

This file implements a virtual machine for evaluating DWARF call frame instructions used in stack unwinding and debugging. The VM processes DWARF frame description entries (FDEs) and common information entries (CIEs) to determine how to unwind the stack at specific program counter addresses. Key components include:

- `RegisterRule` and `CfaRule` unions that define different types of register state preservation rules
- `Row` structures representing the unwinding state at specific code offsets
- `Instruction` parsing and execution logic for DWARF call frame instructions
- State management for tracking current register rules and CFA (Canonical Frame Address) definitions

The VM is used internally by Zig's debug information handling to support stack tracing and exception handling when DWARF debug information is available.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- `deinit(self: *VirtualMachine, gpa: Allocator)` - explicit allocator parameter
- `populateCieLastRow(gpa: Allocator, ...)` - static function requiring allocator
- `runTo(vm: *VirtualMachine, gpa: Allocator, ...)` - allocator parameter for dynamic allocation
- Internal methods like `getOrAddColumn` and `evalInstructions` require allocator

### I/O Interface Changes
- Uses `std.Io.Reader` for instruction parsing instead of older stream interfaces
- Pattern: `var fr: std.Io.Reader = .fixed(instruction_bytes)`
- Reader methods: `takeByte()`, `takeInt()`, `takeLeb128()`, `take()`

### Error Handling
- Uses Zig's error union types (`!void`, `!Row`)
- Specific error cases: `error.InvalidOperation`, `error.InvalidOperand`, `error.UnsupportedAddrSize`
- Error propagation through `try` expressions

### API Structure Changes
- No traditional constructor/destructor pattern - uses direct struct initialization
- State management through `reset()` method rather than re-initialization
- Factory-like static method `populateCieLastRow` for CIE processing

## 3) The Golden Snippet

```zig
const std = @import("std");
const VirtualMachine = std.debug.Dwarf.Unwind.VirtualMachine;

// Initialize and use the VM for stack unwinding
var vm: VirtualMachine = .{};
defer vm.deinit(allocator);

const unwound_row = try vm.runTo(
    allocator,
    target_pc,
    &cie,
    &fde,
    addr_size_bytes,
    endian,
);

// Access the CFA rule and register columns
switch (unwound_row.cfa) {
    .reg_off => |ro| {
        std.debug.print("CFA: register {} + offset {}\n", .{ro.register, ro.offset});
    },
    .expression => |expr| {
        std.debug.print("CFA: expression ({} bytes)\n", .{expr.len});
    },
    .none => {},
}

// Iterate through register rules
for (vm.rowColumns(&unwound_row)) |column| {
    std.debug.print("Register {}: {}\n", .{column.register, column.rule});
}
```

## 4) Dependencies

- `std.mem` - For `Allocator` type and memory management
- `std.Io` - For byte stream reading and instruction parsing
- `std.math` - For integer constants and comparisons
- `std.debug` - For assertions (`assert`)
- Internal: `std.debug.Dwarf.Unwind` - For CIE/FDE types

This module has moderate dependencies and is primarily used internally by Zig's debug information and stack tracing systems.