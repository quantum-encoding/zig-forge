# Async Task Scheduler

A work-stealing task scheduler for concurrent Zig applications, with a C FFI
surface (`async_core` static library) and an Android ARM64 cross-compile target.

## Design

- **Work-stealing scheduler** — per-worker Chase-Lev deques with a single-owner
  push/pop invariant, plus a mutex-guarded MPMC injector queue that spawner
  threads (any thread) enqueue into and workers drain in batches.
- **Thread pool** — worker threads owned by the scheduler.
- **Task handles** — atomic task state (`pending`/`running`/`completed`/`cancelled`)
  with a blocking `await`.

## Usage (Zig)

```zig
const scheduler = @import("async_scheduler");

var sched = try scheduler.Scheduler.init(allocator, .{
    .thread_count = 8,
    .queue_size = 4096,
});
defer sched.deinit();

const handle = try sched.spawn(myTask, .{ .arg1 = 42 });
const result = try handle.await();
```

The library is also exposed to other in-tree projects as the `async_scheduler`
module (root `src/main.zig`) and consumed over C via `include/async_core.h`
(the `as_scheduler_*` / `as_task_*` functions in the `async_core` static lib).

## Build

```bash
zig build            # build the async_core static library
zig build test       # run unit + end-to-end scheduler tests
zig build bench      # build and run the benchmark harness
zig build android    # cross-compile async_core for aarch64-linux-android
```

## Benchmarks

`zig build bench` builds `src/bench.zig`, which measures spawn/steal/throughput
on the local machine. Numbers are hardware-dependent — run it to see figures for
your CPU rather than relying on quoted values.
