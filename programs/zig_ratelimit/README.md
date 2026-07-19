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

## Time source

Every limiter reads time through an injectable `Clock`. The default is
`CLOCK_MONOTONIC` — never a wall clock, because a time source an attacker or a
misbehaving NTP client can move backwards does not limit anything.

Each type has an `initWithClock` companion to the plain `init`, so time-dependent
behaviour can be tested deterministically and instantly instead of by sleeping:

```zig
var mc = ratelimit.ManualClock{};
var limiter = ratelimit.TokenBucket.initWithClock(mc.clock(), 10, 100); // 100/sec

_ = limiter.tryAcquire(10);
mc.advanceMs(10);                       // exactly one token refills
try expectEqual(@as(f64, 1), limiter.available());
```

## Configuration validation

Constructors are infallible (they return the limiter, not an error union) and
**clamp** invalid configuration rather than trapping: a `rate` of 0, a negative
capacity, `NaN`, `inf`, or a zero window are all clamped to a safe value. Every
clamp is fail-closed — a clamped limiter admits *less* traffic, never more.
See `src/numeric.zig` for the exact bounds.

## Thread safety

Only `AtomicTokenBucket` is safe to share between threads. It is implemented as
a lock-free GCRA over a **single** atomic word, so its whole state commits in one
CAS. The other types require external synchronisation.

## Testing

`src/tier1_anchors.zig` holds the externally-anchored tests required by
`zig-forge/CLAUDE.md` golden rule §1 — expectations that do not come from this
implementation:

- **ITU-T I.371 / ATM Forum TM 4.0 GCRA(T, τ).** Both published formulations
  (Virtual Scheduling and Continuous-State Leaky Bucket) are transcribed, checked
  against each other, and then required to match `GCRA` and `AtomicTokenBucket`
  decision-for-decision over an adversarial arrival schedule.
- **RFC 2697 srTCM §2.** The RFC's token-bucket metering rule is transcribed and,
  with `EBS = 0`, required to match `TokenBucket` green/red for green/allow.

`AtomicTokenBucket` additionally carries a multi-threaded over-admission stress
test (8 threads × 50k acquires) in `src/token_bucket.zig`.

## Build

Requires Zig 0.16.0.

```sh
zig build            # build the library + demo/bench executables
zig build test       # run the unit tests
zig build run        # run the demo executable
zig build bench      # run the benchmark executable
```
