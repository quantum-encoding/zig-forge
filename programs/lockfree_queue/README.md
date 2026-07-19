# Lock-Free Message Queue

Lock-free bounded ring-buffer queues for inter-thread communication in Zig, plus a
zero-dependency C FFI static library (`lockfree_core`).

## Queue Types

- **SPSC**: Single Producer, Single Consumer — wait-free ring buffer (`src/spsc/queue.zig`)
- **MPMC**: Multi Producer, Multi Consumer — Dmitry Vyukov's bounded MPMC algorithm (`src/mpmc/queue.zig`)

Both are **bounded** (fixed capacity, must be a power of two) and use 64-byte cache-line
padding/alignment to prevent false sharing between producers and consumers.

## Features

- Wait-free SPSC / lock-free MPMC algorithms
- Cache-line padding and aligned slots (false-sharing avoidance)
- Explicit atomic memory-ordering (acquire/release/monotonic)
- Zero-dependency C FFI core (`include/lockfree_core.h`) with an Android ARM64 cross-compile target

## Usage (Zig)

```zig
const queue = @import("lockfree_queue");

// Create an SPSC queue with a power-of-two capacity
var q = try queue.Spsc(u64).init(allocator, 1024);
defer q.deinit();

// Producer side
try q.push(42); // error.QueueFull when at capacity

// Consumer side
const value = try q.pop(); // error.QueueEmpty when empty
```

The Zig module is exposed as `lockfree_queue` via `b.addModule`, so other in-tree
programs can depend on it directly.

## Build

```bash
zig build          # build the lockfree_core static library
zig build core     # same, explicit step
zig build android  # cross-compile the core lib for aarch64-linux-android
zig build test     # run the unit + concurrent stress tests (queue + FFI-core layers)
zig build bench -Doptimize=ReleaseFast   # microbenchmarks (SPSC/MPMC rings + FFI path)
```

Performance numbers come from `zig build bench` (there are no hard-coded claims);
the SPSC ring push/pop is wait-free, the MPMC ring is lock-free (a CAS retry loop),
and the C FFI copies each payload through the allocator, so it is not zero-copy.
