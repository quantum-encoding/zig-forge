# Resilience Patterns

> Hard rules extracted from `programs/zig_chaos_rocket`. Each rule names a
> historical software disaster, the structural bug that caused it, and the
> Zig 0.16 construct that makes the same bug a compile error or a checked
> runtime error instead of a silent kill.
>
> This is execution guidance for coding agents. When in doubt, **prefer the
> construct that turns the bug into a type error**.

Each rule is also a scanner concern. Where `programs/zig_lens` can catch
violations automatically, the rule lists the rule id; the rest require
human review during code audits.

---

## The MCO Rule — Don't put physics in a raw float

**Mars Climate Orbiter — September 23, 1999 — $327M lost.**
Lockheed Martin's ground software sent thrust commands in pound-force.
NASA's nav software interpreted them as newtons (a 4.45× error). The
spacecraft entered Mars atmosphere too low and broke up. The number on the
wire was the same. Only the *unit* differed, and there was no way for the
type system to know.

**Rule:** Domain quantities (force, distance, mass, velocity, pressure,
temperature, currency, etc.) are **never** raw `f64`. They are
`Quantity(UnitTag)` — a comptime-parameterized struct where the tag is a
zero-size type that exists *only* to make the compiler reject mismatched
operations.

```zig
// units/units.zig — the reference implementation:
pub fn Quantity(comptime UnitTag: type) type {
    return struct {
        value: f64,
        pub const Unit = UnitTag;
        // add(), sub(), scale(), clamp() — all operate on the SAME
        // Quantity(T). Crossing types requires explicit convertTo().
    };
}

pub const Newton     = struct {};
pub const PoundForce = struct {};

pub const Force = Quantity(Newton);
```

`Force.add(force_lbf)` doesn't fail at runtime — it fails to compile.
The only way across the unit boundary is `convertTo(Target, factor)`,
which forces the programmer to think about *which* conversion they
are performing and source the constant from somewhere auditable (NIST).

**Apply when:** any value that has a unit in the physical or domain
world (newtons, meters, USD, milliseconds-of-wall-clock, basis points,
shares, satoshis). The cost is one `Quantity(...)` wrapper and a handful
of method calls; the payoff is structural impossibility of unit-mismatch
bugs.

**Scanner coverage:** `FLOAT-OBSESSION` (medium, advisory) — flags
`f32`/`f64` near identifiers that look like physical or financial
quantities. Doesn't replace human review; signals "did you mean
`Quantity(...)` here?"

---

## The Patriot Rule — Time and money are integers, not floats

**Patriot missile, Dhahran — February 25, 1991 — 28 soldiers killed.**
The Patriot's clock counted tenths of a second in 24-bit fixed-point
floating arithmetic. `0.1` is not exactly representable in binary; the
representation error was about 9.5×10⁻⁸ seconds per tick. After 100 hours
of uptime, the accumulated drift was 0.34 seconds — enough that the
range gate missed the incoming Scud by ~600 meters.

**Rule:** Anything that *accumulates* — wall clock, mission elapsed
time, account balances, order quantities, total cost, position counters
— uses **integer ticks in base units**. Floating point appears at most at
the input boundary (sensor reading, JSON deserialization) and the output
boundary (display, log line). It never appears in the storage type.

```zig
// sim/vehicle.zig — the reference implementation:
pub const VehicleState = struct {
    // Mission clock — INTEGER TICKS, not floating point (Patriot lesson)
    met_ticks: u64 = 0,
    ticks_per_second: u64 = 1000,   // 1ms resolution

    pub fn metSeconds(self: *const VehicleState) f64 {
        // DISPLAY ONLY — never use for control logic
        return @as(f64, @floatFromInt(self.met_ticks))
             / @as(f64, @floatFromInt(self.ticks_per_second));
    }
};
```

Note the comment on `metSeconds`. The float is **explicitly tagged as
display-only**. Control logic compares `met_ticks` directly as `u64`.
A drift bug like the Patriot's would require the integer counter itself
to drift, which it can't.

For money: store the smallest unit (cents, satoshis, basis points) as
`i64` / `u64`. `financial_engine/order_sender.zig:renderDecimal` is the
reference — `Decimal` is `i128` fixed-point with 9 fractional digits.
Conversion to `[]u8` for the JSON wire is a `try` operation, not a
silent precision loss.

**Apply when:** anything monotone, anything financial, anything
involving "how long has X been running." The compiler can't enforce
this — it has to be a code-review reflex.

**Scanner coverage:** `FLOAT-OBSESSION` (medium, advisory) — flags
`f32`/`f64` near identifiers containing `time`, `clock`, `tick`,
`balance`, `amount`, `price`, `qty`. Will miss e.g. `accumulated_drift`
or `total_loss` — those need human eyes.

---

## The Ariane Rule — No blind casts

**Ariane 5 Flight 501 — June 4, 1996 — $370M lost.**
The inertial reference system performed a 64-bit float to 16-bit signed
integer conversion on the horizontal bias variable. On Ariane 4 the
value stayed within `i16`'s range; on Ariane 5 the value was 32,768.5.
Ada raised `OPERAND_ERROR`. The handler shut down the SRI. The
redundant SRI ran the same code and crashed too. The rocket lost
guidance 37 seconds into flight and self-destructed.

The bias variable had originally been protected. The protection was
**removed to meet a CPU budget** based on an Ariane-4-era analysis that
no one re-ran for Ariane 5.

**Rule:** Never `@intCast`, `@floatCast`, or `@intFromFloat` on a value
that could come from the environment (sensor, network, file, FFI
boundary, user input, accumulated state of unknown range). Use
`std.math.cast(T, value)` — which returns `?T` and forces the caller to
handle the overflow — or guard the cast with an explicit bounds check
on the line immediately above.

```zig
// units/checked_math.zig — the reference implementation:

/// Safe cast from f64 to i16 — the EXACT operation that destroyed Ariane 5.
pub fn floatToI16(value: f64) error{Overflow}!i16 {
    if (!std.math.isFinite(value)) return error.Overflow;
    if (value > maxI16_as_f64 or value < minI16_as_f64) return error.Overflow;
    return @intFromFloat(value);
}

/// Generic safe cast.
pub fn safeCast(comptime T: type, value: anytype) error{Overflow}!T {
    return std.math.cast(T, value) orelse error.Overflow;
}
```

Same principle for arithmetic — `checkedAdd`, `checkedSub`, `checkedMul`,
`checkedDiv` return `error{Overflow}` instead of wrapping or
SIGFPE-ing. In safety-critical paths the wrapping `+%` / `-%` / `*%`
operators are forbidden — they are the C bug expressed in Zig syntax.

**Apply when:** the source of the value crosses any trust boundary —
sensor sample, network frame, FFI input, JSON-parsed number, file
content, anything the function did not produce itself in a bounded
range. The pattern is `try safeCast(T, x)` or `std.math.cast(T, x) orelse
return error.X`. Bare `@intCast`/`@intFromFloat` is for values whose
range you control inside the function.

**Scanner coverage:** `BLIND-CAST` (medium, advisory) — flags
`@intCast` / `@floatCast` / `@intFromFloat` / `@ptrFromInt` on lines
that don't appear to have a bounds check nearby. Advises
`std.math.cast`. Will miss casts where the bounds check is in a caller
or a prior helper.

---

## The MCAS Rule — No single point of failure in a control decision

**Boeing 737 MAX — October 29, 2018 + March 10, 2019 — 346 dead.**
The Maneuvering Characteristics Augmentation System read angle-of-attack
from **one** sensor (alternating left or right by aircraft). When that
sensor failed stuck at 21° nose-up, MCAS commanded the stabilizer down
repeatedly. The 737 MAX had two AoA sensors physically installed; MCAS
used one. The "AoA disagree" indicator was a paid optional extra.

**Rule:** Any control decision that can move actuators, change trading
state, modify financial balances, or shut down a system must require
**2-of-3 agreement** from independent inputs. A single sensor / source
that can drive the decision is the bug. The cost of the second and
third channel is part of the cost of the feature; it is not a
configuration question.

```zig
// sensors/sensor_bus.zig — the reference implementation:
pub fn TripleRedundantSensor(comptime T: type) type {
    return struct {
        readings: [3]?T = .{ null, null, null },
        tolerance: f64,

        pub const VoteResult = union(enum) {
            consensus:   T,                                  // all three agree
            majority:    struct { value: T, outlier: u8 },   // 2 agree, 1 outlier
            disagreement: void,                              // no consensus possible
            insufficient: void,                              // fewer than 2 valid
        };

        pub fn vote(self: *const Self) VoteResult { ... }
    };
}
```

The `VoteResult` union is the type system insisting the caller handle
all four outcomes. `disagreement` and `insufficient` are not exceptions
— they are first-class outcomes that propagate up and are visible at
the call site.

The principle generalizes beyond physical sensors: a price feed should
reconcile two independent venues before a trading decision; an
authentication path should require multiple factors; a database
migration should be gated by a second checker.

**Apply when:** the consequence of acting on bad data is unrecoverable
(money moved, missile fired, aircraft stabilizer commanded, kernel
panic). One source is a vulnerability; three is a quorum.

**Scanner coverage:** none — this is an architectural review concern.
A single-source feed driving a control loop looks identical to a
properly-voted feed at the line-of-code level.

---

## Composing the rules

The four rules layer:

```
                  ┌─────────────────────────┐
                  │  MCAS — 2-of-3 voting   │   architectural
                  └────────────┬────────────┘
                               │
                  ┌────────────┴────────────┐
                  │  Ariane — checked casts │   per-conversion
                  └────────────┬────────────┘
                               │
                  ┌────────────┴────────────┐
                  │  Patriot — integer ticks│   per-storage-type
                  └────────────┬────────────┘
                               │
                  ┌────────────┴────────────┐
                  │  MCO — typed quantities │   per-value
                  └─────────────────────────┘
```

Reading bottom-up: every *value* with a unit gets a type wrapper
(MCO); every *accumulator* gets an integer storage (Patriot); every
*conversion* gets a checked cast (Ariane); every *control decision*
gets a voter (MCAS).

Skipping a layer to "save complexity" is exactly the Ariane handler's
"remove the overflow check to save CPU" decision. The cost of the
check has to be paid somewhere. The choice is whether it shows up in
your dev cycle as a type error or in production as a 37-second flight.

---

## Two related rules already in the gate

These predate this document but enforce the same family of invariants:

- **`EQL-FOR-SECRETS`** (high, gating) — signature / HMAC / nonce /
  token comparisons go through `std.crypto.timing_safe.eql` against
  fixed-size arrays, not `std.mem.eql` over slices. Documented in
  [CLAUDE.md](CLAUDE.md). The Ariane Rule with crypto instead of
  arithmetic: leaking the failure mode (timing oracle vs. overflow
  shutdown) is the bug.

- **`CATCH-UNREACHABLE`** (high, gating) — `catch unreachable` on any
  error path that can be hit by hostile or environment-driven input is
  forbidden; propagate via `!T` and let the caller decide. Same
  shape as the Ariane SRI handler that exited the process on
  `OPERAND_ERROR` — the "this can never happen" assertion is the
  attack surface.

---

## When the scanner can't help

The four core rules are listed in increasing order of "the gate can't
catch this":

1. **MCO (typed quantities)** — partially gated by `FLOAT-OBSESSION`
   on suggestive identifier names. Misses any value whose name doesn't
   contain a giveaway word.
2. **Patriot (integer ticks)** — same gating, same gap. A `f64
   accumulated_drift` variable named anything else won't fire.
3. **Ariane (checked casts)** — partially gated by `BLIND-CAST`.
   Misses cross-function flow (bounds check in caller A, cast in
   callee B) and casts whose bounds-check pattern doesn't match the
   regex's expectation.
4. **MCAS (no single-point control)** — not gated at all. Has to be
   caught at code review or architectural review.

Treat the scanner as a tripwire, not a fence. A green `zig-lens
--strict` is "the four explicit anti-patterns we know about did not
fire," not "this code is safe to fly."
