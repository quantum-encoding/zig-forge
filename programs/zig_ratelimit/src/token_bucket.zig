//! Token Bucket Rate Limiter
//!
//! Classic rate limiting algorithm where tokens are added at a fixed rate
//! and requests consume tokens. Allows bursts up to bucket capacity.
//!
//! Example:
//! ```zig
//! var limiter = TokenBucket.init(100, 10); // 100 tokens max, 10 tokens/sec
//! if (limiter.tryAcquire(1)) {
//!     // Request allowed
//! } else {
//!     // Rate limited
//! }
//! ```

const std = @import("std");
const compat = @import("compat.zig");
const numeric = @import("numeric.zig");

// Constructor arguments are clamped rather than rejected — see numeric.zig for
// the rationale and the fail-closed guarantee.
const sanitizeRate = numeric.sanitizeRate;
const sanitizeCapacity = numeric.sanitizeCapacity;
const satToI64 = numeric.satToI64;
const satI128ToI64 = numeric.satI128ToI64;

/// Token Bucket rate limiter
pub const TokenBucket = struct {
    /// Maximum tokens in the bucket (burst capacity)
    capacity: f64,
    /// Tokens added per second
    rate: f64,
    /// Current number of tokens
    tokens: f64,
    /// Last refill timestamp (nanoseconds)
    last_refill: i128,
    /// Time source. Defaults to CLOCK_MONOTONIC; tests inject a `ManualClock`.
    clock: compat.Clock,

    const Self = @This();

    /// Initialize a token bucket
    /// capacity: Maximum tokens (burst size)
    /// rate: Tokens added per second
    pub fn init(capacity: f64, rate: f64) Self {
        return initWithClock(compat.monotonic_clock, capacity, rate);
    }

    /// Initialize against a caller-supplied clock (deterministic testing).
    pub fn initWithClock(clock: compat.Clock, capacity: f64, rate: f64) Self {
        const cap = sanitizeCapacity(capacity);
        return Self{
            .capacity = cap,
            .rate = sanitizeRate(rate), // clamped >0 so timeUntilAvailable never divides by 0
            .tokens = cap, // Start full
            .last_refill = clock.now(),
            .clock = clock,
        };
    }

    /// Initialize with specific starting tokens
    pub fn initWithTokens(capacity: f64, rate: f64, initial_tokens: f64) Self {
        return initWithTokensAndClock(compat.monotonic_clock, capacity, rate, initial_tokens);
    }

    /// Initialize with specific starting tokens against a caller-supplied clock.
    pub fn initWithTokensAndClock(clock: compat.Clock, capacity: f64, rate: f64, initial_tokens: f64) Self {
        const cap = sanitizeCapacity(capacity);
        const start_tokens = if (std.math.isNan(initial_tokens) or initial_tokens < 0) 0 else initial_tokens;
        return Self{
            .capacity = cap,
            .rate = sanitizeRate(rate),
            .tokens = @min(start_tokens, cap),
            .last_refill = clock.now(),
            .clock = clock,
        };
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *Self) void {
        const now = self.clock.now();
        const elapsed_ns = now - self.last_refill;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const new_tokens = elapsed_sec * self.rate;

        self.tokens = @min(self.capacity, self.tokens + new_tokens);
        self.last_refill = now;
    }

    /// Try to acquire tokens (non-blocking)
    /// Returns true if tokens were acquired
    pub fn tryAcquire(self: *Self, tokens: f64) bool {
        self.refill();

        if (self.tokens >= tokens) {
            self.tokens -= tokens;
            return true;
        }
        return false;
    }

    /// Try to acquire a single token
    pub fn tryAcquireOne(self: *Self) bool {
        return self.tryAcquire(1.0);
    }

    /// Check if tokens are available without consuming them
    pub fn check(self: *Self, tokens: f64) bool {
        self.refill();
        return self.tokens >= tokens;
    }

    /// Get current available tokens
    pub fn available(self: *Self) f64 {
        self.refill();
        return self.tokens;
    }

    /// Get time until specified tokens will be available (in nanoseconds)
    pub fn timeUntilAvailable(self: *Self, tokens: f64) i64 {
        self.refill();

        if (self.tokens >= tokens) {
            return 0;
        }

        const needed = tokens - self.tokens;
        const wait_sec = needed / self.rate;
        // Saturating: `rate` is clamped to MIN_RATE, so a large `needed` still
        // reaches ~1e24 ns — past i64 — which would be illegal behaviour in a
        // bare @intFromFloat.
        return satToI64(wait_sec * 1_000_000_000.0);
    }

    /// Force set token count (useful for testing or reset)
    pub fn setTokens(self: *Self, tokens: f64) void {
        self.tokens = @min(tokens, self.capacity);
        self.last_refill = self.clock.now();
    }

    /// Reset to full capacity
    pub fn reset(self: *Self) void {
        self.tokens = self.capacity;
        self.last_refill = self.clock.now();
    }

    /// Get current fill ratio (0.0 to 1.0)
    pub fn fillRatio(self: *Self) f64 {
        self.refill();
        return self.tokens / self.capacity;
    }
};

/// Thread-safe Token Bucket, reformulated as a single-word lock-free GCRA.
///
/// ## Why not the classic (tokens, last_refill) pair?
/// A token bucket has two pieces of mutable state: the current token count and
/// the timestamp that count was last refilled from. Updating both atomically
/// requires either a lock or a single wide word — you cannot CAS two separate
/// atomics as a unit. The previous implementation tried, with two independent
/// `cmpxchgWeak`s, and **ignored the second CAS's failure**
/// (`_ = last_refill_ns.cmpxchgWeak(...)`). When the tokens-CAS committed but
/// the last-refill-CAS failed (a spurious weak failure, or another thread had
/// advanced `last`), the elapsed interval `[last, now]` was credited to the
/// token count *without* advancing `last_refill_ns`, so the very next call
/// credited the same interval again — unbounded over-admission (rate-limit
/// bypass) under contention. This is exactly the variant whose whole purpose is
/// thread safety, and it is consumed by auth-adjacent code.
///
/// ## The fix: GCRA over one atomic word
/// A token bucket of `capacity` tokens refilling at `rate` tokens/sec is
/// mathematically equivalent to the Generic Cell Rate Algorithm with a single
/// scalar of state — the Theoretical Arrival Time (`tat`) in nanoseconds:
///
///   * emission interval  T   = 1e9 / rate      (ns to regenerate one token)
///   * burst tolerance     tau = capacity * T    (ns of "credit" a full bucket has)
///
/// A request for `n` tokens at monotonic time `now`:
///   tat_eff = max(tat, now)          // a full/idle bucket is pinned to `now`
///   new_tat = tat_eff + n*T
///   admit iff  new_tat - now <= tau  // equivalently: enough tokens remain
///   on admit, commit  tat := new_tat
///
/// Because the entire state is one i64, it is updated with a single
/// `cmpxchgWeak` loop — no torn state, no second CAS, no double-credit. On a
/// rejected request no store happens at all. This is the standard lock-free
/// GCRA formulation (redis-cell / Go `throttled`).
///
/// The public API — `init(capacity, rate)`, `tryAcquire(tokens)`,
/// `tryAcquireOne()`, `available()` — is unchanged, so consumers need no edits.
pub const AtomicTokenBucket = struct {
    /// Maximum tokens (burst capacity, sanitized to [0, MAX_CAPACITY]).
    capacity: f64,
    /// Tokens per second (sanitized to a strictly-positive finite value).
    rate: f64,
    /// Emission interval T = 1e9/rate, nanoseconds per token. Always finite, >0.
    period_ns: f64,
    /// Burst tolerance tau = capacity * period_ns, nanoseconds. Always finite, >=0.
    tolerance_ns: f64,
    /// The whole mutable state: Theoretical Arrival Time in ns (monotonic clock).
    /// `tat <= now` means the bucket is full. Single atomic word => single CAS.
    tat_ns: std.atomic.Value(i64),
    /// Time source. Defaults to CLOCK_MONOTONIC; tests inject a `ManualClock`.
    clock: compat.Clock,

    const Self = @This();

    pub fn init(capacity: f64, rate: f64) Self {
        return initWithClock(compat.monotonic_clock, capacity, rate);
    }

    /// Initialize against a caller-supplied clock (deterministic testing).
    pub fn initWithClock(clock: compat.Clock, capacity: f64, rate: f64) Self {
        const cap = sanitizeCapacity(capacity);
        const r = sanitizeRate(rate);
        const period = 1_000_000_000.0 / r; // finite: r is clamped > 0
        const now = satI128ToI64(clock.now());
        return Self{
            .capacity = cap,
            .rate = r,
            .period_ns = period,
            // Saturating: cap*period can exceed i64/f64-exact range when a
            // large burst meets the clamped MIN_RATE.
            .tolerance_ns = cap * period,
            // Start full: tat == now => bucket at capacity.
            .tat_ns = std.atomic.Value(i64).init(now),
            .clock = clock,
        };
    }

    /// Thread-safe token acquisition using a single-word CAS loop (GCRA).
    /// Returns true iff `tokens` were admitted; on rejection no state changes.
    pub fn tryAcquire(self: *Self, tokens: f64) bool {
        // Non-positive / non-finite cost: nothing to charge — trivially admitted.
        if (!(tokens > 0) or !std.math.isFinite(tokens)) return true;
        const increment = tokens * self.period_ns; // finite, >= 0

        while (true) {
            const now = satI128ToI64(self.clock.now());
            const now_f: f64 = @floatFromInt(now);
            const tat = self.tat_ns.load(.acquire);
            const tat_eff: i64 = @max(tat, now);
            const new_tat_f = @as(f64, @floatFromInt(tat_eff)) + increment;

            // Would this request push the arrival time beyond the burst
            // tolerance? If so, reject WITHOUT mutating state.
            if (new_tat_f - now_f > self.tolerance_ns) {
                return false;
            }

            const new_tat = satToI64(new_tat_f);
            if (self.tat_ns.cmpxchgWeak(tat, new_tat, .acq_rel, .acquire) == null) {
                return true;
            }
            // CAS lost the race (contended or spurious) — reload and retry.
        }
    }

    pub fn tryAcquireOne(self: *Self) bool {
        return self.tryAcquire(1.0);
    }

    /// Refill-aware available token count (read-only snapshot, no CAS).
    /// Unlike the old implementation this accounts for tokens regenerated since
    /// the last acquire, matching single-threaded `TokenBucket.available()`.
    pub fn available(self: *Self) f64 {
        const now = satI128ToI64(self.clock.now());
        const tat = self.tat_ns.load(.acquire);
        // Time-debt beyond `now` maps to tokens currently "in flight".
        const deficit_ns: f64 = @floatFromInt(@max(tat, now) - now);
        const used = deficit_ns / self.period_ns;
        return @max(0.0, @min(self.capacity, self.capacity - used));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "token bucket basic" {
    var bucket = TokenBucket.init(10, 1); // 10 tokens, 1/sec

    // Should have full capacity
    try std.testing.expect(bucket.tryAcquire(10));

    // Now empty
    try std.testing.expect(!bucket.tryAcquire(1));
}

test "token bucket partial acquire" {
    // Deterministic: the previous version asserted `available() <= 5.1` against
    // the real clock with a rate of 100/s, so it flaked whenever more than 1ms
    // elapsed between two statements — a genuine CI-under-load hazard. With an
    // injected clock the remaining count is exact.
    var mc = compat.ManualClock{};
    var bucket = TokenBucket.initWithClock(mc.clock(), 10, 100);

    try std.testing.expect(bucket.tryAcquire(5));
    try std.testing.expectEqual(@as(f64, 5), bucket.available());
    try std.testing.expect(bucket.tryAcquire(5));
    try std.testing.expectEqual(@as(f64, 0), bucket.available());
}

test "token bucket reset" {
    var bucket = TokenBucket.init(10, 1);
    _ = bucket.tryAcquire(10);
    try std.testing.expect(!bucket.tryAcquire(1));

    bucket.reset();
    try std.testing.expect(bucket.tryAcquire(10));
}

test "atomic token bucket basic" {
    var bucket = AtomicTokenBucket.init(10, 1);

    try std.testing.expect(bucket.tryAcquire(10));
    try std.testing.expect(!bucket.tryAcquire(1));
}

test "atomic token bucket exact burst then reject" {
    // Rate so low that refill over the ~microseconds of this test is ~0 tokens,
    // isolating the burst-capacity behaviour: a full bucket admits exactly
    // `capacity` unit requests, then rejects.
    var bucket = AtomicTokenBucket.init(5, 0.001); // ~1 token per 1000 s
    var admitted: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        if (bucket.tryAcquireOne()) admitted += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), admitted);
    // available() must read ~0 after draining the burst.
    try std.testing.expect(bucket.available() < 1.0);
}

test "atomic token bucket clamps invalid config without crashing" {
    // rate<=0 / capacity<=0 previously trapped (@intFromFloat(inf)) or produced
    // nonsense; now they clamp fail-closed and never panic (Debug or ReleaseFast).
    var b_zero = AtomicTokenBucket.init(0, 0);
    try std.testing.expect(!b_zero.tryAcquireOne()); // capacity 0 => admit nothing

    var b_neg = AtomicTokenBucket.init(-5, -10);
    try std.testing.expect(!b_neg.tryAcquireOne());

    var b_inf = AtomicTokenBucket.init(3, std.math.inf(f64));
    // rate clamped to MIN_RATE; the initial burst of 3 is still admissible.
    try std.testing.expect(b_inf.tryAcquire(3));
    try std.testing.expect(!b_inf.tryAcquireOne());

    var b_nan = AtomicTokenBucket.init(std.math.nan(f64), std.math.nan(f64));
    try std.testing.expect(!b_nan.tryAcquireOne()); // NaN capacity => 0
}

test "atomic token bucket concurrent over-admission bound" {
    // Regression test for the two-word-CAS race (finding #1): under heavy
    // contention the total number of admitted tokens must never exceed the
    // initial burst plus whatever legitimately refilled over the run window.
    // The old implementation could double-credit refill intervals and blow past
    // this bound; the single-word GCRA cannot.
    const Ctx = struct {
        bucket: *AtomicTokenBucket,
        admitted: *std.atomic.Value(u64),
        attempts: u64,

        fn run(ctx: @This()) void {
            var local: u64 = 0;
            var i: u64 = 0;
            while (i < ctx.attempts) : (i += 1) {
                if (ctx.bucket.tryAcquireOne()) local += 1;
            }
            _ = ctx.admitted.fetchAdd(local, .monotonic);
        }
    };

    const capacity: f64 = 1000;
    const rate: f64 = 100; // tokens/sec — small, so refill over the run is tiny
    var bucket = AtomicTokenBucket.init(capacity, rate);
    var admitted = std.atomic.Value(u64).init(0);

    const n_threads = 8;
    const attempts_per_thread: u64 = 50_000; // 400k total acquire attempts

    const start = compat.nowNs();
    var threads: [n_threads]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < n_threads) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .bucket = &bucket,
            .admitted = &admitted,
            .attempts = attempts_per_thread,
        }});
    }
    for (threads[0..spawned]) |t| t.join();
    const elapsed_sec = @as(f64, @floatFromInt(compat.nowNs() - start)) / 1_000_000_000.0;

    const total = admitted.load(.monotonic);
    const total_f: f64 = @floatFromInt(total);

    // Upper bound: initial burst + max possible refill over the whole window.
    // GCRA guarantees each refill interval is credited at most once, so this
    // holds by construction; +2.0 absorbs f64/ns rounding.
    const upper = capacity + rate * elapsed_sec + 2.0;
    try std.testing.expect(total_f <= upper);

    // Lower bound: a full bucket must always yield at least its capacity.
    try std.testing.expect(total >= @as(u64, @intFromFloat(capacity)));
}
