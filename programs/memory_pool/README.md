# Memory Pool Allocator

Deterministic, O(1) memory allocators for latency-sensitive systems, built as a
zero-dependency Zig library with a C FFI static-library surface.

## Allocators

- **FixedPool** (`src/pool/fixed.zig`) — single fixed object size backed by a
  free list. `alloc`/`free`/`reset` are O(1) and never fragment. Slot size is
  rounded up to a 16-byte alignment so SIMD / `long double` payloads from C
  callers are correctly aligned.
- **SlabAllocator** (`src/slab/allocator.zig`) — multiple fixed size classes.
- **ArenaAllocator** (`src/arena/bump.zig`) — bump-pointer allocation with batch
  free via `reset`; supports cache-line (64-byte) aligned allocations.

All three allocators are single-threaded; there is no internal locking. Wrap
them per-thread if you need concurrency.

## C FFI

`src/memory_pool_core.zig` exposes a C-ABI static library (`memory_pool_core`)
with the header in `include/`. It has zero external dependencies and links
libc for its allocation backend.

## Usage (Zig)

```zig
const pool = @import("memory_pool");

// Create a pool for 64-byte objects, capacity 1000
var p = try pool.FixedPool.init(allocator, 64, 1000);
defer p.deinit();

const ptr = try p.alloc();
p.free(ptr);
```

## Build

```bash
zig build            # build the C FFI static library
zig build core       # explicit core-library step
zig build android    # cross-compile static lib for aarch64-linux-android
zig build test       # run unit + FFI-layer tests
zig build bench      # build and run the microbenchmarks
```

## Benchmarks

`zig build bench` runs the microbenchmarks in `benchmarks/bench.zig` and prints
measured timings for your machine. No fixed numbers are asserted here — run it
locally to see the results on your target hardware.
