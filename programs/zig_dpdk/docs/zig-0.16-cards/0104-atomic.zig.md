# Migration Card: `std/atomic.zig`

## 1) Concept

This file provides atomic operations for Zig's standard library. It implements a generic `Value(T)` type that wraps primitive values to prevent accidental data races, providing thread-safe atomic operations like load, store, compare-and-swap, and various read-modify-write operations. The API serves as a thin, type-safe wrapper around Zig's built-in atomic intrinsics (`@atomicLoad`, `@atomicStore`, `@atomicRmw`, etc.).

Key components include:
- `Value(T)` - a generic atomic wrapper type for any primitive type T
- Atomic memory operations (load, store, swap, cmpxchg, fetchAdd, etc.)
- Bit-level atomic operations (bitSet, bitReset, bitToggle)
- Cross-platform spin loop hints for busy-waiting
- CPU cache line size detection for false sharing prevention

## 2) The 0.11 vs 0.16 Diff

This atomic API follows consistent patterns that have remained stable across Zig versions:

**No Major API Changes Identified:**
- **Initialization**: Uses simple struct initialization pattern (`Value(usize).init(0)`) rather than allocator-based factory functions
- **I/O Patterns**: No I/O dependencies - pure memory operations
- **Error Handling**: Atomic operations don't return error sets - they either succeed or cause undefined behavior on invalid usage
- **API Structure**: Consistent naming (`init`, `load`, `store`, `fetchAdd`, etc.) that aligns with common atomic operation naming

**Key Stability Factors:**
- All operations are `inline` wrappers around Zig's built-in atomic intrinsics
- Memory ordering is compile-time parameterized (`comptime order: AtomicOrder`)
- Type safety maintained through generic `Value(T)` wrapper
- No allocator dependencies - operations work directly on provided memory

## 3) The Golden Snippet

```zig
const std = @import("std");
const atomic = std.atomic;

// Create an atomic counter
var counter = atomic.Value(usize).init(0);

// Thread-safe increment
const previous = counter.fetchAdd(1, .seq_cst);

// Load current value
const current = counter.load(.seq_cst);

// Compare and swap
if (counter.cmpxchgStrong(current, current + 1, .seq_cst, .seq_cst)) |_| {
    // Successfully updated
}
```

## 4) Dependencies

- `std.builtin` - For `AtomicOrder` and `AtomicRmwOp` types
- `std.math` - For `Log2Int` type used in bit operations
- `std.Target` - For CPU architecture detection in `cacheLineForCpu`
- `@import("builtin")` - For target CPU information and architecture detection

**Note**: This file has minimal dependencies and focuses on wrapping compiler intrinsics, making it highly stable across Zig versions.