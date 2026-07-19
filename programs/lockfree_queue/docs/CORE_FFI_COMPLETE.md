# Lock-Free Queue Core — C FFI

**Status**: In production use by `quantum_vault` via the `lfq_spsc_*` C ABI.

The **Lock-Free Queue Core** exposes the SPSC (Single Producer, Single Consumer)
ring buffer as a **zero-dependency C FFI** for low-latency inter-thread
communication. The Zig library also ships an MPMC (Multi Producer, Multi
Consumer) ring, but only the SPSC queue is currently wrapped in the C ABI.

---

## What the numbers actually are

There is a real benchmark now (`src/bench.zig`, run via `zig build bench`).
Earlier revisions of this document quoted a fixed "100M+ msg/sec / <50ns" with
no benchmark behind them and a "104/105 C tests passed" summary for a C test
suite that does not exist in the tree. Both have been removed. Run the
benchmark to get numbers for your own hardware:

```bash
zig build bench -Doptimize=ReleaseFast   # Debug numbers are meaningless
```

Representative figures (Apple Silicon, ReleaseFast — **yours will differ**):

| Path | Latency | Throughput | Notes |
|------|---------|------------|-------|
| SPSC ring, single-thread hot loop | ~0.5 ns/pair | ~1.8 B pairs/s | wait-free, everything in L1 |
| MPMC ring, single-thread uncontended | ~10 ns/pair | ~100 M pairs/s | lock-free CAS path |
| SPSC 1 producer / 1 consumer | ~8 ns/msg | ~130 M msg/s | 2 threads, the real SPSC use case |
| FFI copy path (`lfq_spsc_push`/`pop`) | ~10 ns/pair | ~100 M pairs/s | dominated by malloc+free per message |

The SPSC ring push/pop is genuinely **wait-free** (bounded steps, no retry
loop). The MPMC ring is **lock-free** (a CAS retry loop — not wait-free). The C
FFI copies each payload through the C allocator (one `malloc` per push, one
`free` per pop), so its end-to-end latency is allocator-bound rather than the
raw ring's few-nanosecond cost. It is not zero-copy.

---

## What's included

```
┌─────────────────────────────────────────────────────────────┐
│  Lock-Free Queue Core API (src/lockfree_core.zig)           │
│                                                             │
│  SPSC byte-buffer queue over spsc/queue.zig                 │
│    - Cache-line aligned head/tail (prevents false sharing)  │
│    - Wait-free push/pop on the ring                         │
│    - Power-of-2 capacity with efficient masked indexing     │
│    - Per-message copy through the C allocator               │
│                                                             │
│  C ABI:                                                     │
│    - lfq_spsc_create(capacity, buffer_size)                 │
│    - lfq_spsc_push(queue, data, len)                        │
│    - lfq_spsc_pop(queue, data_out, len, size_out)           │
│    - lfq_spsc_stats / is_empty / is_full / len              │
│    - lfq_error_string / lfq_version / lfq_performance_info   │
└─────────────────────────────────────────────────────────────┘
```

**Not exposed over the C ABI:** the MPMC ring (`src/mpmc/queue.zig`) exists and
is tested, but there are no `lfq_mpmc_*` exports yet. Also excluded by design:
networking, file I/O, global state.

**Capacity semantics:** the SPSC ring reserves one slot to distinguish full
from empty, so a queue created with `capacity = N` holds at most `N − 1`
messages. `capacity` in `LFQ_Stats` reports `N`.

---

## Memory

- **Queue instance**: `QueueContext` + a ring of `capacity` `Message` records.
- **Per-message allocation**: each `lfq_spsc_push` allocates `len` bytes via the
  C allocator and copies the payload in; each `lfq_spsc_pop` copies out and
  frees. There is no preallocated buffer pool.
- **Alignment**: 64-byte cache-line alignment on the ring head/tail counters.

---

## API Reference

### SPSC Queue

```c
// Create queue: 256 slots, max 1KB per message
LFQ_SpscQueue* queue = lfq_spsc_create(256, 1024);

// Producer thread
const char* msg = "Hello, World!";
LFQ_Error err = lfq_spsc_push(queue, (const uint8_t*)msg, strlen(msg));
if (err == LFQ_QUEUE_FULL) {
    // Handle backpressure
}

// Consumer thread
uint8_t buf[1024];
size_t size;
err = lfq_spsc_pop(queue, buf, sizeof(buf), &size);
if (err == LFQ_SUCCESS) {
    printf("Got: %.*s\n", (int)size, buf);
}

// Get stats
LFQ_Stats stats;
lfq_spsc_stats(queue, &stats);
printf("Queue: %zu/%zu messages\n", stats.length, stats.capacity);

// Cleanup
lfq_spsc_destroy(queue);
```

`lfq_spsc_push` returns `LFQ_INVALID_PARAM` if `data` is NULL, `len` is 0, or
`len > buffer_size`. `lfq_spsc_pop` returns `LFQ_INVALID_PARAM` if `data_out` or
`size_out` is NULL. Both return `LFQ_INVALID_HANDLE` for a NULL queue. If the
output buffer is smaller than the message, the copy is truncated but `size_out`
reports the true message length.

---

## Build

```bash
zig build              # build liblockfree_core.a (host)
zig build core         # same, explicit step
zig build android      # cross-compile for aarch64-linux-android
zig build test         # unit + concurrent stress tests
zig build bench -Doptimize=ReleaseFast   # microbenchmarks
```

### Compile a C application

```bash
gcc -o app app.c \
    -I/path/to/include \
    -L/path/to/zig-out/lib \
    -llockfree_core \
    -lpthread
```

The static library has no external dependencies beyond libc/pthread.

---

## Tests

All tests are Zig tests run by `zig build test` (there is no separate C test
harness). Coverage:

- **SPSC ring** (`src/spsc/queue.zig`): full/empty/wraparound/capacity-boundary,
  FIFO order, non-power-of-2 rejection, plus a **concurrent producer/consumer
  stress test** pushing 1,000,000 sequenced values across two threads and
  asserting strict FIFO order and a Gauss-sum checksum.
- **MPMC ring** (`src/mpmc/queue.zig`): turn-cycle correctness, full/empty,
  capacity boundary, plus an **N×M stress test** (4 producers × 4 consumers over
  a 1024-slot queue) asserting exactly-once delivery via a per-value seen-count
  array and a multiset-sum checksum.
- **C FFI** (`src/lockfree_core.zig`): create/destroy (incl. NULL-safe destroy),
  invalid parameters, push/pop roundtrip, queue-empty, queue-full at the
  reserve-one boundary, statistics, and the helper/version strings.

Run the stress tests under an optimized build as well — memory-ordering bugs
hide when the optimizer is off:

```bash
zig build test -Doptimize=ReleaseFast
```

---

## Thread Safety

- **SPSC**: safe for exactly one producer thread + one consumer thread on a
  given queue; the underlying ring push/pop is wait-free.
- **Multiple queues**: independent queues are safe from independent threads.
- **Do not** drive a single SPSC queue from multiple producers or multiple
  consumers — use the MPMC ring for that (Zig-only for now).

---

## Consumers

- `quantum_vault/src-tauri/src/core/lockfree.rs` — full Rust binding over all 11
  `lfq_*` exports, linked as `static=lockfree_core`.

Any change to exported symbol names, signatures, `LFQ_Stats` layout, or
`LFQ_Error` values must be mirrored in that binding and the `.a` rebuilt for
host + Android + iOS (on macOS, remember `scripts/repack-for-xcode.sh`).

---

**Maintained by**: Quantum Encoding Forge
**License**: MIT
**Version**: 1.0.0-core
