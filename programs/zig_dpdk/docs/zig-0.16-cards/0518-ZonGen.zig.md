# Migration Card: Zig ZON Generator (ZonGen.zig)

## 1) Concept

This file implements a ZON (Zig Object Notation) generator that converts Zig AST (Abstract Syntax Tree) into ZOIR (Zig Object Intermediate Representation). It's responsible for parsing and validating ZON data structures, which are a subset of Zig syntax used for serialization and configuration.

The key components include:
- The main `ZonGen` struct that holds generation state (nodes, string table, error tracking)
- Public `generate` function that transforms an AST into ZOIR format
- String literal parsing utilities (`strLitSizeHint`, `parseStrLit`)
- Comprehensive error handling for ZON-specific validation rules

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory pattern**: The main entry point `generate()` takes an explicit `Allocator` parameter and returns `Allocator.Error!Zoir`
- **No default allocator**: All memory management requires explicit allocator passing
- **Owned slices**: Returned `Zoir` contains owned slices that caller must free

### I/O Interface Changes
- **Writer dependency injection**: `parseStrLit()` takes a `*Writer` parameter for output
- **No global I/O**: All I/O operations are abstracted through writer interfaces
- **Allocating writer**: Internal use of `Writer.Allocating` for string building

### Error Handling Changes
- **Specific error sets**: Functions return specific error sets like `Allocator.Error` and `Writer.Error`
- **No generic errors**: Error handling is precise with allocation and I/O errors separated
- **Compile error tracking**: Comprehensive error collection with notes and offsets

### API Structure Changes
- **Factory function**: `generate()` creates and manages the generator internally
- **No init/deinit**: Generator lifecycle is managed within the `generate()` call
- **Options struct**: Configuration through `Options` struct with default values

## 3) The Golden Snippet

```zig
const std = @import("std");
const Ast = std.zig.Ast;
const ZonGen = std.zig.ZonGen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Parse ZON source into AST
    const source = ".{ .field = \"value\", .number = 42 }";
    const tree = try std.zig.parse(allocator, source);
    defer tree.deinit(allocator);
    
    // Generate ZOIR from AST
    const options = ZonGen.Options{ .parse_str_lits = true };
    const zoir = try ZonGen.generate(allocator, tree, options);
    defer zoir.deinit(allocator);
    
    // Use the generated ZOIR...
}
```

## 4) Dependencies

- `std.mem` (as `mem`) - Memory operations and allocator types
- `std.hash_map` - String table implementation
- `std.ArrayListUnmanaged` - Dynamic arrays without built-in allocator
- `std.HashMapUnmanaged` - Hash maps without built-in allocator  
- `std.math.big` - Big integer support for number literals
- `std.zig.Ast` - Abstract Syntax Tree types
- `std.zig.Zoir` - Zig Object Intermediate Representation types
- `std.zig.string_literal` - String literal parsing utilities
- `std.zig.number_literal` - Number literal parsing utilities