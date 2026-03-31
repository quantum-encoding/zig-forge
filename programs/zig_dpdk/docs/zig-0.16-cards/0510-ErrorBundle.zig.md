# ErrorBundle.zig Migration Analysis

## 1) Concept

ErrorBundle is a data structure for collecting, storing, and rendering compilation errors in Zig. It supports incremental compilation by storing errors in a structured format that can be created and destroyed appropriately across different compilation phases. The key components include:

- **ErrorBundle**: The main immutable structure containing error messages and source locations
- **Wip (Work-in-Progress)**: A mutable builder pattern for incrementally constructing error bundles
- **Structured error data**: Contains error messages, source locations, notes, reference traces, and compile log output
- **Rendering system**: Formats errors with color support, source code context, and reference traces

The file provides a comprehensive error reporting system that handles everything from basic error messages to complex multi-note errors with full source context.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`deinit` method**: Now requires explicit allocator parameter
  ```zig
  // 0.16 pattern
  eb.deinit(allocator);
  ```
- **Wip initialization**: Factory pattern with explicit allocator
  ```zig
  var wip: ErrorBundle.Wip = undefined;
  try wip.init(allocator);
  ```

### I/O Interface Changes
- **Writer dependency injection**: `renderToWriter` takes a `*Writer` pointer
  ```zig
  // 0.16 pattern - pointer to writer
  try bundle.renderToWriter(options, &writer, tty_config);
  ```
- **TTY configuration**: Color handling through `Io.tty.Config` parameter

### Error Handling Changes
- **Specific error types**: `renderToWriter` returns `(Writer.Error || std.posix.UnexpectedError)` union
- **Allocator errors**: Wip methods return `Allocator.Error` explicitly

### API Structure Changes
- **Wip builder pattern**: Replaces direct struct initialization for complex error construction
- **Ownership transfer**: `toOwnedBundle` method for finalizing Wip construction
- **Capacity management**: `AssumeCapacity` variants for performance-critical paths

## 3) The Golden Snippet

```zig
const std = @import("std");
const ErrorBundle = std.zig.ErrorBundle;

// Create an error bundle
var wip: ErrorBundle.Wip = undefined;
try wip.init(std.heap.page_allocator);
defer wip.deinit();

// Add an error with source location
const src_path = try wip.addString("main.zig");
const source_line = try wip.addString("const x: i32 = \"hello\";");
const msg = try wip.addString("expected type 'i32', found '*const [5:0]u8'");

const src_loc = try wip.addSourceLocation(.{
    .src_path = src_path,
    .line = 2,
    .column = 14,
    .span_start = 10,
    .span_main = 14,
    .span_end = 15,
    .source_line = source_line,
});

try wip.addRootErrorMessage(.{
    .msg = msg,
    .src_loc = src_loc,
});

// Finalize the bundle
const bundle = try wip.toOwnedBundle("");
defer bundle.deinit(std.heap.page_allocator);

// Render to stderr
bundle.renderToStdErr(.{}, .auto);
```

## 4) Dependencies

- **std.mem** (Allocator type)
- **std.io** (Writer, TTY configuration)
- **std.debug** (assertions, stderr writer locking)
- **std.posix** (UnexpectedError for I/O operations)
- **std.zig** (Zir, Ast for compiler integration)

This file represents a core compiler infrastructure component with stable public APIs that developers would use for error reporting and compilation error handling.