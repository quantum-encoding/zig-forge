# Migration Card: std/valgrind/callgrind.zig

## 1) Concept

This file provides a Zig interface for Valgrind's Callgrind profiling tool. It exposes client request functionality that allows programs to interact with Callgrind at runtime to control profiling behavior. The key components include a `ClientRequest` enum defining available operations and wrapper functions for common profiling tasks like dumping statistics, zeroing counters, and toggling instrumentation.

The API enables fine-grained control over Callgrind's profiling capabilities, allowing developers to start/stop instrumentation, manage statistics collection, and trigger profile dumps at specific points in program execution. This is particularly useful for profiling specific code sections while ignoring setup/teardown phases.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected for migration from 0.11 to 0.16:**

- **No allocator requirements**: All functions are stateless and don't require memory allocation
- **No I/O interface changes**: Functions interact directly with Valgrind through low-level client requests
- **No error handling changes**: All functions return `void` and don't use Zig's error handling system
- **No API structure changes**: Simple procedural interface without init/open patterns

The API maintains the same signature patterns:
- All public functions take simple parameters (either no parameters or primitive pointers)
- No factory functions or complex initialization required
- Direct function calls without dependency injection

## 3) The Golden Snippet

```zig
const callgrind = @import("std").valgrind.callgrind;

// Start profiling a specific section
callgrind.startInstrumentation();

// Your code to profile here
// ...

// Dump statistics with a descriptive marker
callgrind.dumpStatsAt("after_expensive_operation");

// Stop profiling to ignore cleanup code
callgrind.stopInstrumentation();
```

## 4) Dependencies

- `std.valgrind` (parent module for Valgrind integration)
- No heavy standard library imports (minimal dependencies)

**Note**: This file relies on the underlying Valgrind tool being present and the program running under `valgrind --tool=callgrind` for the client requests to have any effect.