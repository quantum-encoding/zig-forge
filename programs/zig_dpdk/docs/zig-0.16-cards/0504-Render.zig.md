# Migration Card: `std/zig/Ast/Render.zig`

## 1) Concept

This file implements an AST renderer for Zig source code, responsible for converting Zig Abstract Syntax Tree (AST) nodes back into formatted source code. It handles all Zig language constructs including functions, variables, control flow, expressions, and declarations. The renderer supports configurable fixups for modifying the output, such as renaming identifiers, omitting nodes, replacing expressions with strings, and handling unused variable declarations.

Key components include:
- The `Render` struct that maintains rendering state (allocator, auto-indenting stream, AST, fixups)
- The `Fixups` struct for configuring output modifications
- Comprehensive expression and statement rendering functions for all Zig syntax
- Auto-indenting stream for proper code formatting
- Comment and documentation rendering support

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Allocator injection**: The `Render` struct requires an explicit `gpa: Allocator` field
- **Factory function pattern**: `renderTree()` is a factory function that takes explicit `gpa: Allocator` parameter
- **Memory management**: `Fixups.deinit()` requires explicit allocator parameter for cleanup

### I/O Interface Changes
- **Writer injection**: Uses `std.Io.Writer` interface with dependency injection
- **Auto-indenting stream**: Wraps the underlying writer with automatic indentation logic
- **Error propagation**: All rendering functions return `Error!void` where `Error` includes `OutOfMemory` and `WriteFailed`

### Error Handling Changes
- **Specific error types**: Uses concrete error set `Error` rather than generic `anyerror`
- **Transitive error handling**: Properly propagates underlying writer failures

### API Structure Changes
- **Initialization pattern**: Uses struct initialization rather than separate init functions
- **Fixups configuration**: `Fixups` struct follows Zig 0.16 patterns with explicit deinit methods
- **Container-based rendering**: Uses enum parameters like `Container` to handle different container types

## 3) The Golden Snippet

```zig
const std = @import("std");
const Ast = std.zig.Ast;

// Parse some Zig source
var source =
    \\pub fn main() void {
    \\    const x = 42;
    \\}
;
var tree = try std.zig.Ast.parse(std.heap.page_allocator, source, .zig);
defer tree.deinit(std.heap.page_allocator);

// Set up fixups (optional)
var fixups = Ast.Render.Fixups{};
defer fixups.deinit(std.heap.page_allocator);

// Render the AST to a writer
var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
defer buffer.deinit();

try Ast.Render.renderTree(
    std.heap.page_allocator,
    &buffer.writer(),
    tree,
    fixups,
);

// buffer.items now contains the formatted source code
```

## 4) Dependencies

- `std.mem` (as `mem`, `Allocator`)
- `std.zig.Ast` (core AST types and parsing)
- `std.zig.Token` (token definitions and utilities)
- `std.zig.primitives` (primitive type handling)
- `std.Io.Writer` (output interface)
- `std.meta` (type reflection utilities)
- `std.debug.assert` (debug assertions)
- `std.AutoHashMapUnmanaged` (fixups storage)
- `std.StringArrayHashMapUnmanaged` (identifier renaming)