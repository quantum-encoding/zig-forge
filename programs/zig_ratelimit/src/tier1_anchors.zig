//! Tier-1 externally-anchored tests for zig_ratelimit.
//!
//! ## Why this file exists
//!
//! zig-forge/CLAUDE.md golden rule §1: a library consumed by money/key/auth
//! touching code must have tests whose inputs **and expected outputs** come
//! from a source the library author did not write. Before this file, every
//! expectation in zig_ratelimit was self-derived — the tests asserted that the
//! implementation did what the implementation does. That is the exact failure
//! shape that let `zig_base58` ship a wrong Base58Check checksum for two months
//! behind 15/15 passing tests.
//!
//! A rate limiter has no published byte-vector KATs the way FIPS 203/204 or
//! Base58Check do. What it does have is **published algorithm definitions with
//! independent, provably-equivalent formulations**. So the anchoring strategy
//! here is the same one used for `zig_jwt`'s verifier (checked against
//! signatures produced by an independent `std.crypto` signer): implement the
//! published reference algorithm in a structurally different form, and require
//! our implementation to agree with it decision-for-decision.
//!
//! ## The two anchors
//!
//! 1. **ITU-T I.371 / ATM Forum TM 4.0 — GCRA(T, τ).** The specification gives
//!    *two* formulations and states they are equivalent: the Virtual Scheduling
//!    Algorithm (tracks a Theoretical Arrival Time) and the Continuous-State
//!    Leaky Bucket Algorithm (tracks a bucket level `X` and a Last Conformance
//!    Time `LCT`). Both are transcribed below from the published pseudocode.
//!    `specVirtualScheduling` and `specContinuousStateLeakyBucket` are first
//!    checked against *each other* — that cross-check validates the oracle
//!    itself, independently of anything in this library — and then our
//!    `GCRA` and `AtomicTokenBucket` are required to match them exactly.
//!
//!    Our limiters take a burst size `B` in requests; the spec takes a
//!    tolerance `τ` in time. The published relation (ATM Forum TM 4.0 MBS
//!    formula `τ = (MBS − 1)(T_s − T)`, at back-to-back arrival, `T → 0`) is
//!    `τ = (B − 1)·T`. That mapping is asserted, not assumed: if our burst
//!    accounting were off by one, the differential tests below would fail.
//!
//! 2. **RFC 2697 — Single Rate Three Color Marker (srTCM).** §2 defines a token
//!    bucket metering rule in normative prose: bucket `Tc` starts at `CBS`, is
//!    incremented `CIR` times per second up to `CBS`, and a packet of `B` bytes
//!    is green iff `Tc − B >= 0`, in which case `Tc` is decremented by `B`.
//!    With `EBS = 0` the excess bucket never admits anything, so srTCM reduces
//!    to exactly the contract of `TokenBucket`: capacity `CBS`, rate `CIR`.
//!    `specSrTCM` transcribes the RFC rule (both buckets, so the transcription
//!    is faithful) and the differential test drives it with `EBS = 0`.
//!
//! All differential tests run on an injected `ManualClock`, so they are
//! deterministic, exact (`expectEqual`, not tolerances), and instant.

const std = @import("std");
const compat = @import("compat.zig");
const ratelimit = @import("lib.zig");

const GCRA = ratelimit.GCRA;
const TokenBucket = ratelimit.TokenBucket;
const AtomicTokenBucket = ratelimit.AtomicTokenBucket;
const ManualClock = compat.ManualClock;

// ============================================================================
// Oracle 1a: ITU-T I.371 Virtual Scheduling Algorithm, GCRA(T, tau)
// ============================================================================
//
// Published pseudocode (arrival of cell k at time t_a(k)):
//
//     if (t_a(k) < TAT - tau)
//         non-conforming;                       // TAT unchanged
//     else
//         TAT = max(TAT, t_a(k)) + T;
//         conforming;
//
// TAT is initialized to the arrival time of the first cell.

const SpecVirtualScheduling = struct {
    t: i128, // emission interval T
    tau: i128, // limit / burst tolerance
    tat: i128 = 0,
    seen_first: bool = false,

    fn arrive(self: *SpecVirtualScheduling, t_a: i128) bool {
        if (!self.seen_first) {
            self.tat = t_a; // "TAT is initialized to the time of arrival of the first cell"
            self.seen_first = true;
        }
        if (t_a < self.tat - self.tau) return false; // non-conforming
        self.tat = @max(self.tat, t_a) + self.t;
        return true; // conforming
    }
};

// ============================================================================
// Oracle 1b: ITU-T I.371 Continuous-State Leaky Bucket Algorithm, GCRA(T, tau)
// ============================================================================
//
// Published pseudocode (arrival of cell k at time t_a(k)):
//
//     X' = X - (t_a(k) - LCT);
//     if (X' > tau)
//         non-conforming;                       // X and LCT unchanged
//     else
//         X = max(0, X') + T;
//         LCT = t_a(k);
//         conforming;
//
// X is initialized to 0 and LCT to the arrival time of the first cell.
//
// Note this tracks a *bucket level counting down toward zero* — the opposite
// direction from the TAT formulation and from our implementation. That
// structural difference is the whole point: an off-by-one or a sign error in
// our code cannot be mirrored here by construction.

const SpecContinuousStateLeakyBucket = struct {
    t: i128,
    tau: i128,
    x: i128 = 0,
    lct: i128 = 0,
    seen_first: bool = false,

    fn arrive(self: *SpecContinuousStateLeakyBucket, t_a: i128) bool {
        if (!self.seen_first) {
            self.x = 0;
            self.lct = t_a;
            self.seen_first = true;
        }
        const x_prime = self.x - (t_a - self.lct);
        if (x_prime > self.tau) return false; // non-conforming
        self.x = @max(0, x_prime) + self.t;
        self.lct = t_a;
        return true; // conforming
    }
};

// ============================================================================
// Oracle 2: RFC 2697 srTCM (Single Rate Three Color Marker), §2
// ============================================================================
//
// "The token bucket C is initially full, i.e. Tc(0) = CBS ... The token count
//  Tc is incremented by 1 CIR times per second up to CBS ...
//  For a packet of size B bytes:
//     if (Tc - B >= 0)  packet is green and Tc -= B
//     else if (Te - B >= 0)  packet is yellow and Te -= B
//     else packet is red"
//
// Transcribed with both buckets so the transcription is faithful to the RFC;
// the differential test sets EBS = 0, under which srTCM's green/red decision is
// precisely `TokenBucket.tryAcquire`. Refill is expressed continuously — "CIR
// times per second" is the discrete phrasing of the same rate, and the test
// schedule only samples instants where `elapsed * CIR` is an exact f64 integer,
// so the two coincide bit-for-bit.

const SpecSrTCM = struct {
    cir: f64, // committed information rate, tokens/sec
    cbs: f64, // committed burst size
    ebs: f64, // excess burst size
    tc: f64,
    te: f64,
    last_ns: i128,

    fn init(cir: f64, cbs: f64, ebs: f64, now_ns: i128) SpecSrTCM {
        return .{ .cir = cir, .cbs = cbs, .ebs = ebs, .tc = cbs, .te = ebs, .last_ns = now_ns };
    }

    const Color = enum { green, yellow, red };

    fn meter(self: *SpecSrTCM, now_ns: i128, b: f64) Color {
        // Refill: Tc up to CBS, overflow into Te up to EBS.
        const elapsed_sec = @as(f64, @floatFromInt(now_ns - self.last_ns)) / 1_000_000_000.0;
        self.last_ns = now_ns;
        const minted = elapsed_sec * self.cir;
        const tc_room = self.cbs - self.tc;
        if (minted <= tc_room) {
            self.tc += minted;
        } else {
            self.tc = self.cbs;
            self.te = @min(self.ebs, self.te + (minted - tc_room));
        }

        if (self.tc - b >= 0) {
            self.tc -= b;
            return .green;
        }
        if (self.te - b >= 0) {
            self.te -= b;
            return .yellow;
        }
        return .red;
    }
};

// ============================================================================
// Deterministic arrival schedules
// ============================================================================
//
// Offsets in nanoseconds from t=0. Deliberately adversarial: a saturating
// back-to-back burst, an exact-boundary arrival (one emission interval to the
// nanosecond), an arrival one nanosecond early, a long idle that must refill
// the bucket to capacity but never beyond, and a second burst after the idle.

const schedule_ns = [_]i128{
    0,          0,          0,          0,          0, // instantaneous burst of 5
    1,          2,          3, // still burst-adjacent
    10_000_000, // +10ms  (exactly one emission interval at 100/s)
    19_999_999, // one nanosecond short of the next interval
    20_000_000, // exactly on the next interval
    20_000_001,
    25_000_000,
    30_000_000,
    500_000_000, // long idle: bucket must refill to capacity, not past it
    500_000_000,
    500_000_000,
    500_000_000,
    500_000_000,
    500_000_000, // one past capacity
    500_000_001,
    1_000_000_000,
    1_000_000_000,
    2_500_000_000, // second long idle
    2_500_000_000,
    2_500_000_000,
};

/// Run our `GCRA` over the schedule, returning the conform/reject decisions.
fn runOurGcra(allocator: std.mem.Allocator, rate: f64, burst: f64) ![]bool {
    var mc = ManualClock{};
    var limiter = GCRA.initWithClock(mc.clock(), rate, burst);
    const out = try allocator.alloc(bool, schedule_ns.len);
    for (schedule_ns, 0..) |t_a, i| {
        mc.ns = t_a;
        out[i] = limiter.tryAcquire();
    }
    return out;
}

/// Run our `AtomicTokenBucket` (unit requests) over the schedule.
fn runOurAtomicBucket(allocator: std.mem.Allocator, rate: f64, capacity: f64) ![]bool {
    var mc = ManualClock{};
    var limiter = AtomicTokenBucket.initWithClock(mc.clock(), capacity, rate);
    const out = try allocator.alloc(bool, schedule_ns.len);
    for (schedule_ns, 0..) |t_a, i| {
        mc.ns = t_a;
        out[i] = limiter.tryAcquireOne();
    }
    return out;
}

/// Run the published I.371 oracles over the schedule, asserting the two
/// formulations agree with each other before returning their verdict.
fn runSpecGcra(allocator: std.mem.Allocator, t: i128, tau: i128) ![]bool {
    var vs = SpecVirtualScheduling{ .t = t, .tau = tau };
    var lb = SpecContinuousStateLeakyBucket{ .t = t, .tau = tau };
    const out = try allocator.alloc(bool, schedule_ns.len);
    for (schedule_ns, 0..) |t_a, i| {
        const a = vs.arrive(t_a);
        const b = lb.arrive(t_a);
        // The spec asserts these two formulations are equivalent. If they ever
        // disagree, the oracle is broken and no conclusion about our code holds.
        try std.testing.expectEqual(a, b);
        out[i] = a;
    }
    return out;
}

// ============================================================================
// Anchor tests — I.371 GCRA
// ============================================================================

test "anchor: I.371 virtual-scheduling and continuous-state-leaky-bucket forms agree" {
    // Validates the oracle against itself across a range of (T, tau) before it
    // is used to judge our implementation.
    const allocator = std.testing.allocator;
    const intervals = [_]i128{ 1_000_000, 10_000_000, 125_000_000, 1_000_000_000 };
    const bursts = [_]i128{ 1, 2, 3, 5, 10 };
    for (intervals) |t| {
        for (bursts) |b| {
            const tau = (b - 1) * t;
            const decisions = try runSpecGcra(allocator, t, tau);
            allocator.free(decisions);
        }
    }
}

test "anchor: our GCRA matches published I.371 GCRA(T, tau) decision-for-decision" {
    const allocator = std.testing.allocator;

    // Rates chosen so T = 1e9/rate is an exact integer nanosecond count, and
    // bursts >= 1 (tau = (B-1)T is only meaningful for a burst of at least one).
    const rates = [_]f64{ 100, 8, 1000, 2 };
    const bursts = [_]f64{ 1, 2, 5, 10 };

    for (rates) |rate| {
        for (bursts) |burst| {
            const t: i128 = @intFromFloat(1_000_000_000.0 / rate);
            const tau: i128 = @as(i128, @intFromFloat(burst - 1)) * t;

            const ours = try runOurGcra(allocator, rate, burst);
            defer allocator.free(ours);
            const spec = try runSpecGcra(allocator, t, tau);
            defer allocator.free(spec);

            try std.testing.expectEqualSlices(bool, spec, ours);
        }
    }
}

test "anchor: AtomicTokenBucket matches published I.371 GCRA (token bucket <-> GCRA equivalence)" {
    // The thread-safe bucket is implemented as a single-word GCRA. This asserts
    // that reformulation is faithful to the published algorithm, not merely
    // self-consistent — the property the two-word-CAS version silently lacked.
    const allocator = std.testing.allocator;

    const rates = [_]f64{ 100, 8, 1000, 2 };
    const capacities = [_]f64{ 1, 2, 5, 10 };

    for (rates) |rate| {
        for (capacities) |capacity| {
            const t: i128 = @intFromFloat(1_000_000_000.0 / rate);
            const tau: i128 = @as(i128, @intFromFloat(capacity - 1)) * t;

            const ours = try runOurAtomicBucket(allocator, rate, capacity);
            defer allocator.free(ours);
            const spec = try runSpecGcra(allocator, t, tau);
            defer allocator.free(spec);

            try std.testing.expectEqualSlices(bool, spec, ours);
        }
    }
}

test "anchor: our two GCRA implementations agree with each other" {
    // GCRA (single-threaded, i128 TAT) vs AtomicTokenBucket (lock-free, i64 TAT
    // + f64 tolerance). Same published algorithm, two different internal
    // representations; they must not diverge.
    const allocator = std.testing.allocator;
    const rates = [_]f64{ 100, 8, 1000, 2 };
    const bursts = [_]f64{ 1, 2, 5, 10 };

    for (rates) |rate| {
        for (bursts) |burst| {
            const a = try runOurGcra(allocator, rate, burst);
            defer allocator.free(a);
            const b = try runOurAtomicBucket(allocator, rate, burst);
            defer allocator.free(b);
            try std.testing.expectEqualSlices(bool, a, b);
        }
    }
}

// ============================================================================
// Anchor tests — RFC 2697 srTCM
// ============================================================================

test "anchor: TokenBucket matches RFC 2697 srTCM green/red metering (EBS = 0)" {
    var mc = ManualClock{};

    const cir: f64 = 100; // tokens/sec
    const cbs: f64 = 10; // burst
    var ours = TokenBucket.initWithClock(mc.clock(), cbs, cir);
    var spec = SpecSrTCM.init(cir, cbs, 0, 0);

    // (offset_ns, packet size). Offsets are multiples of 10ms, so
    // elapsed * CIR is an exact integer in f64 and both sides agree bit-exactly.
    const arrivals = [_]struct { at: i128, size: f64 }{
        .{ .at = 0, .size = 1 }, // full bucket
        .{ .at = 0, .size = 4 },
        .{ .at = 0, .size = 5 }, // exactly drains CBS
        .{ .at = 0, .size = 1 }, // must be red
        .{ .at = 10_000_000, .size = 1 }, // +10ms => exactly 1 token minted
        .{ .at = 10_000_000, .size = 1 }, // red again
        .{ .at = 30_000_000, .size = 2 }, // +20ms => 2 tokens
        .{ .at = 30_000_000, .size = 1 }, // red
        .{ .at = 100_000_000, .size = 7 }, // +70ms => 7 tokens
        .{ .at = 100_000_000, .size = 1 },
        .{ .at = 5_000_000_000, .size = 10 }, // long idle: refills to CBS, not beyond
        .{ .at = 5_000_000_000, .size = 1 }, // ...so this must be red
        .{ .at = 5_100_000_000, .size = 10 }, // +100ms only mints 10 => exactly green
        .{ .at = 5_100_000_000, .size = 1 },
    };

    for (arrivals) |a| {
        mc.ns = a.at;
        const spec_green = spec.meter(a.at, a.size) == .green;
        const ours_ok = ours.tryAcquire(a.size);
        try std.testing.expectEqual(spec_green, ours_ok);
    }
}

test "anchor: TokenBucket refill never exceeds CBS after arbitrary idle (RFC 2697 cap)" {
    // RFC 2697: "The token count Tc is incremented ... up to CBS." The cap is
    // the security-relevant half of the rule — an uncapped refill is exactly
    // the over-admission the atomic bucket's old double-credit bug produced.
    var mc = ManualClock{};
    var bucket = TokenBucket.initWithClock(mc.clock(), 10, 100);

    try std.testing.expect(bucket.tryAcquire(10)); // drain
    mc.advanceSec(3600); // idle an hour: 360,000 tokens' worth of refill
    try std.testing.expectEqual(@as(f64, 10), bucket.available());
    try std.testing.expect(bucket.tryAcquire(10));
    try std.testing.expect(!bucket.tryAcquireOne());
}

// ============================================================================
// Deterministic behaviour tests (replacing sleep-based, tolerance-based ones)
// ============================================================================

test "deterministic: token bucket refills at exactly the configured rate" {
    var mc = ManualClock{};
    var bucket = TokenBucket.initWithClock(mc.clock(), 10, 100); // 100/sec

    try std.testing.expect(bucket.tryAcquire(10));
    try std.testing.expectEqual(@as(f64, 0), bucket.available());

    mc.advanceMs(10); // 1 token
    try std.testing.expectEqual(@as(f64, 1), bucket.available());
    mc.advanceMs(40); // 4 more
    try std.testing.expectEqual(@as(f64, 5), bucket.available());

    try std.testing.expect(bucket.tryAcquire(5));
    try std.testing.expect(!bucket.tryAcquireOne());
}

test "deterministic: timeUntilAvailable is exact" {
    var mc = ManualClock{};
    var bucket = TokenBucket.initWithClock(mc.clock(), 10, 100); // T = 10ms

    try std.testing.expect(bucket.tryAcquire(10));
    try std.testing.expectEqual(@as(i64, 0), bucket.timeUntilAvailable(0));
    try std.testing.expectEqual(@as(i64, 10_000_000), bucket.timeUntilAvailable(1));
    try std.testing.expectEqual(@as(i64, 50_000_000), bucket.timeUntilAvailable(5));

    mc.advanceMs(30); // 3 tokens back
    try std.testing.expectEqual(@as(i64, 0), bucket.timeUntilAvailable(3));
    try std.testing.expectEqual(@as(i64, 20_000_000), bucket.timeUntilAvailable(5));
}

test "deterministic: leaky bucket drains at exactly the configured leak rate" {
    var mc = ManualClock{};
    var bucket = ratelimit.LeakyBucket.initWithClock(mc.clock(), 5, 100); // 100/sec

    for (0..5) |_| try std.testing.expect(bucket.tryAcquire());
    try std.testing.expect(!bucket.tryAcquire());
    try std.testing.expectEqual(@as(f64, 5), bucket.pending());

    mc.advanceMs(10); // exactly one unit leaks
    try std.testing.expectEqual(@as(f64, 4), bucket.pending());
    try std.testing.expect(bucket.tryAcquire());
    try std.testing.expect(!bucket.tryAcquire());

    mc.advanceMs(50); // fully drains
    try std.testing.expectEqual(@as(f64, 0), bucket.pending());
}

test "deterministic: GCRA burst then exact-interval recovery" {
    var mc = ManualClock{};
    var gcra = GCRA.initWithClock(mc.clock(), 10, 5); // 10/sec => T = 100ms, burst 5

    for (0..5) |_| try std.testing.expect(gcra.tryAcquire());
    try std.testing.expect(!gcra.check());
    try std.testing.expectEqual(@as(i64, 100_000_000), gcra.timeUntilAllowed());

    mc.advanceNs(99_999_999); // one ns short of the emission interval
    try std.testing.expect(!gcra.check());
    try std.testing.expectEqual(@as(i64, 1), gcra.timeUntilAllowed());

    mc.advanceNs(1); // exactly on it
    try std.testing.expectEqual(@as(i64, 0), gcra.timeUntilAllowed());
    try std.testing.expect(gcra.tryAcquire());
    try std.testing.expect(!gcra.tryAcquire());
}

test "deterministic: GCRA with burst 0 admits nothing" {
    // The old `tat == 0` sentinel let the first request through unconditionally,
    // bypassing the tolerance check entirely. A zero burst must admit nothing.
    var mc = ManualClock{};
    var gcra = GCRA.initWithClock(mc.clock(), 10, 0);
    try std.testing.expect(!gcra.tryAcquire());
    mc.advanceSec(10);
    try std.testing.expect(!gcra.tryAcquire());
}

test "deterministic: GCRA at clock origin is not mistaken for uninitialized" {
    // An injected clock reads 0 at t=0, which the old sentinel could not
    // distinguish from "no requests yet" — every request at time 0 took the
    // unconditional-admit branch.
    var mc = ManualClock{};
    var gcra = GCRA.initWithClock(mc.clock(), 10, 2); // burst 2

    try std.testing.expect(gcra.tryAcquire());
    try std.testing.expect(gcra.tryAcquire());
    try std.testing.expect(!gcra.tryAcquire()); // burst exhausted at t=0
}

test "deterministic: sliding window log expires entries on the window boundary" {
    const allocator = std.testing.allocator;
    var mc = ManualClock{};
    var limiter = try ratelimit.SlidingWindowLog.initWithClock(allocator, mc.clock(), 2, 50);
    defer limiter.deinit();

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.check());

    mc.advanceMs(49); // still inside the 50ms window
    try std.testing.expect(!limiter.check());

    mc.advanceMs(2); // both entries now older than the window
    try std.testing.expectEqual(@as(usize, 0), limiter.currentCount());
    try std.testing.expect(limiter.tryAcquire());
}

test "deterministic: fixed window counter resets exactly on the boundary" {
    var mc = ManualClock{};
    var limiter = ratelimit.FixedWindowCounter.initWithClock(mc.clock(), 3, 100);

    for (0..3) |_| try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.check());

    mc.advanceNs(99_999_999);
    try std.testing.expect(!limiter.check()); // window has not elapsed yet

    mc.advanceNs(1); // exactly one window
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expectEqual(@as(u64, 2), limiter.remaining());
}

test "deterministic: sliding window counter rotates and weights windows" {
    var mc = ManualClock{};
    var limiter = ratelimit.SlidingWindowCounter.initWithClock(mc.clock(), 10, 100);

    for (0..10) |_| try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.check());

    // Half way into the next window: previous window is weighted 0.5, so the
    // effective count is 5 and exactly 5 more requests fit.
    mc.advanceMs(150);
    try std.testing.expectApproxEqAbs(@as(f64, 5), limiter.currentRate(), 1e-9);
    for (0..5) |_| try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.check());

    // Two full windows on: everything is forgotten.
    mc.advanceMs(250);
    try std.testing.expectEqual(@as(f64, 0), limiter.currentRate());
    try std.testing.expect(limiter.check());
}

// ============================================================================
// Fail-closed configuration under an injected clock
// ============================================================================

test "clamped configuration never over-admits" {
    // Every clamp in numeric.zig is claimed to be fail-closed. Assert it: a
    // limiter built from nonsensical config must admit at most what a correctly
    // configured one would, and must never trap.
    var mc = ManualClock{};

    var zero_rate = TokenBucket.initWithClock(mc.clock(), 3, 0);
    try std.testing.expect(zero_rate.tryAcquire(3)); // initial burst only
    mc.advanceSec(3600);
    try std.testing.expect(!zero_rate.tryAcquireOne()); // clamped rate => no meaningful refill

    // GCRA with a clamped rate: the burst tolerance would be 1e20 ns without a
    // saturating conversion, which is illegal behaviour in a bare @intFromFloat.
    const g = GCRA.initWithClock(mc.clock(), 0, 100);
    try std.testing.expect(g.emission_interval > 0);
    try std.testing.expect(g.delay_tolerance == std.math.maxInt(i64));

    var neg = TokenBucket.initWithClock(mc.clock(), -10, -1);
    try std.testing.expect(!neg.tryAcquireOne());
}
