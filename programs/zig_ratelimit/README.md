# zig_ratelimit

A Zig rate-limiting library that provides several classic rate-limiting algorithms behind a small, uniform API.

## Algorithms

The library exposes the following limiter types (see `src/lib.zig`):

- **`TokenBucket`** — allows bursts up to the bucket capacity, refills at a constant rate. `O(1)` memory.
- **`AtomicTokenBucket`** — a thread-safe variant of the token bucket.
- **`LeakyBucket`** — smooths the output rate; requests drain steadily. `O(1)` memory.
- **`GCRA`** — Generic Cell Rate Algorithm for precise burst control. `O(1)` memory.
- **`SlidingWindowLog`** — exact tracking via a timestamp log. `O(n)` memory.
- **`SlidingWindowCounter`** — approximate tracking with fixed memory. `O(1)` memory.
- **`FixedWindowCounter`** — simple counter that resets at fixed intervals. `O(1)` memory.

## Usage

Consume the module named `ratelimit` (exposed by `build.zig` via `b.addModule`):

```zig
const ratelimit = @import("ratelimit");

// Token bucket: burst of 50, refill 100 tokens/sec
var limiter = ratelimit.TokenBucket.init(50, 100);

if (limiter.tryAcquire(1)) {
    // request allowed
} else {
    // rate limited
}
```

Convenience constructors are also available:

```zig
var limiter = ratelimit.createLimiter(50, 100);        // TokenBucket
var atomic = ratelimit.createAtomicLimiter(50, 100);   // AtomicTokenBucket (thread-safe)
```

## Build

Requires Zig 0.16.0.

```sh
zig build            # build the library + demo/bench executables
zig build test       # run the unit tests
zig build run        # run the demo executable
zig build bench      # run the benchmark executable
```
