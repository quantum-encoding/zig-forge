# Migration Card: DWARF Expression Stack Machine

## 1) Concept

This file implements a DWARF expression stack machine and builder for Zig's debug information handling. DWARF expressions are used in debug information to describe how to compute values or locations of variables, frame base addresses, and other debug-related data. The key components include:

- **StackMachine**: A generic type that evaluates DWARF expressions with configurable address size and endianness
- **Builder**: A companion type for programmatically constructing DWARF expressions
- **Context**: A structure providing execution context (CPU registers, frame information, compilation unit data)
- **Options**: Configuration for address size, endianness, and execution mode

The implementation handles DWARF expression opcodes for literal encodings, register values, stack operations, arithmetic/logical operations, control flow, and type conversions.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **StackMachine.deinit()** now requires explicit allocator: `deinit(self: *Self, allocator: std.mem.Allocator)`
- **StackMachine.run()** requires allocator parameter: `run(self: *Self, expression, allocator, context, initial_value)`
- **StackMachine.step()** requires allocator parameter: `step(self: *Self, stream, allocator, context)`
- Stack operations internally use `std.ArrayListUnmanaged` with explicit allocator management

### I/O Interface Changes
- Uses new `std.Io.Reader` and `std.Io.Writer` interfaces instead of older stream patterns
- Reader methods use `take*` pattern: `takeByte()`, `takeInt()`, `takeLeb128()`, `take()` instead of direct reading
- Writer methods follow consistent error-returning pattern

### Error Handling Changes
- Consolidated error set `Error` includes both DWARF-specific errors and standard library errors
- Error set uses union syntax: `Error = error{...} || std.debug.cpu_context.DwarfRegisterError || error{...}`
- More specific error types like `error.IncompleteExpressionContext` replace generic error returns

### API Structure Changes
- Generic `StackMachine(comptime options: Options)` pattern replaces runtime configuration
- Context-driven execution with structured `Context` parameter
- Builder pattern with compile-time validation of opcode validity in call frame context

## 3) The Golden Snippet

```zig
const std = @import("std");
const dwarf_expr = std.debug.Dwarf.expression;

pub fn evaluateDwarfExpression(allocator: std.mem.Allocator) !void {
    const options = dwarf_expr.Options{
        .addr_size = @sizeOf(usize),
        .endian = .little,
    };
    
    var stack_machine = dwarf_expr.StackMachine(options){};
    defer stack_machine.deinit(allocator);
    
    const context = dwarf_expr.Context{
        .format = .@"32",
        .cpu_context = null,
        .cfa = 0x1000,
    };
    
    // Example: Push CFA + 0x10
    const expression = [_]u8{
        dwarf_expr.OP.call_frame_cfa,  // Push CFA value
        dwarf_expr.OP.const1u, 0x10,   // Push constant 0x10  
        dwarf_expr.OP.plus,            // Add them
    };
    
    const result = try stack_machine.run(
        &expression, 
        allocator, 
        context, 
        null
    );
    
    if (result) |value| {
        std.debug.print("Result: 0x{x}\n", .{value.generic});
    }
}
```

## 4) Dependencies

- **std.mem**: Memory operations, endian handling, array list management
- **std.leb**: LEB128 encoding/decoding for DWARF operands
- **std.dwarf**: DWARF constants and format definitions
- **std.debug.Dwarf**: DWARF-specific types and register handling
- **std.debug.cpu_context**: CPU register context for expression evaluation
- **std.Io**: Reader/Writer interfaces for expression parsing
- **std.math**: Arithmetic operations with overflow checking
- **std.testing**: Test framework (test block only)

This file represents a sophisticated DWARF expression implementation that requires careful memory management and integrates deeply with Zig's debug information system.