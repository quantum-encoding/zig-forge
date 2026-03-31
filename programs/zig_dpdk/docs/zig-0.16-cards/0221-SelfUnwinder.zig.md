# Migration Card: `std.debug.Dwarf.SelfUnwinder`

## 1) Concept

This file implements a stack unwinder using DWARF debug information for stack frame traversal. The `SelfUnwinder` type evolves a CPU context through stack frames by applying DWARF Call Frame Information (CFI) register rules, performing what's known as "virtual unwinding." It serves as a valid implementation of `std.debug.SelfInfo.UnwindContext`.

Key components include:
- `SelfUnwinder`: Main struct holding CPU state, program counter, and DWARF virtual machines
- `CacheEntry`: Caches computed CFI rules to avoid recomputation during frequent unwinding
- Public API for initializing, computing rules, and stepping through stack frames

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `deinit(unwinder: *SelfUnwinder, gpa: Allocator)` - Requires explicit allocator for cleanup
- `computeRules(unwinder: *SelfUnwinder, gpa: Allocator, ...)` - Allocator needed for CFI virtual machine operations
- `next(unwinder: *SelfUnwinder, gpa: Allocator, ...)` - Allocator required for expression evaluation

**Error Handling Changes:**
- `next()` returns `std.debug.SelfInfoError!usize` - Specific error type rather than generic errors
- Error translation in `next()` converts low-level DWARF errors into higher-level debug info errors
- Uses exhaustive error switching with explicit error set mapping

**API Structure:**
- Factory pattern: `init(cpu_context)` returns initialized struct rather than separate open/init
- Clean separation between rule computation (`computeRules`) and application (`next`)
- Cache-based optimization pattern for performance-critical unwinding operations

## 3) The Golden Snippet

```zig
const std = @import("std");
const debug = std.debug;

// Initialize with current CPU context
var cpu_context = try debug.captureNativeContext();
var unwinder = debug.Dwarf.SelfUnwinder.init(&cpu_context);
defer unwinder.deinit(std.heap.page_allocator);

// Compute rules for current frame
var cache_entry = try unwinder.computeRules(
    std.heap.page_allocator,
    &dwarf_unwind_info,
    load_offset,
    null,
);

// Step to next frame
const return_address = try unwinder.next(std.heap.page_allocator, &cache_entry);
```

## 4) Dependencies

- `std.mem` (via `Allocator` type)
- `std.debug` (CPU context, DWARF parsing)
- `std.math` (checked arithmetic for offset calculations)
- `builtin` (target architecture information)

This module has deep dependencies on the DWARF debugging format implementation and architecture-specific CPU context handling.