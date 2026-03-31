# Plan: zig_chaos_rocket — Safety-Critical Chaos Engineering in Zig

## Concept

A simulated rocket launch system that recreates every category of software failure that has destroyed real spacecraft, killed people, or cost billions — then demonstrates that Zig catches every single one at compile time or handles it gracefully at runtime.

**The program name is `zig_chaos_rocket`.** It simulates a full rocket launch from ignition to orbit insertion, with a chaos engine that injects faults modeled on real-world disasters. The system must survive everything thrown at it because Zig's language-level safety guarantees make the failure classes structurally impossible.

**The narrative**: "These bugs destroyed a $500M rocket, killed 346 people, and lost a Mars mission. Here's what happens when you write the same systems in Zig."

---

## Real-World Failures Recreated

Each fault injection scenario is modeled on an actual disaster:

| ID | Real Incident | Year | Cost | Root Cause | Zig Prevention |
|----|--------------|------|------|------------|----------------|
| ARIANE | Ariane 5 Flight 501 | 1996 | $370M | 64-bit float → 16-bit int overflow | `@intCast` traps on overflow; `std.math.cast` returns null |
| MCO | Mars Climate Orbiter | 1999 | $327M | Metric/imperial unit mismatch | Comptime unit types — wrong unit = compile error |
| THERAC | Therac-25 | 1985-87 | 6 lives | Race condition bypassed safety interlock | No data races in safe Zig; `@atomicStore`/`@atomicLoad` |
| PATRIOT | Patriot Missile | 1991 | 28 lives | Floating-point clock drift (0.34s after 100hrs) | Demonstrated with integer-tick monotonic clock |
| MCAS | Boeing 737 MAX | 2018-19 | 346 lives | Single sensor, no bounds check on authority | Exhaustive error handling — `try`/`catch` on all sensor reads |
| KNIGHT | Knight Capital | 2012 | $440M | Untested old code path activated | Dead code elimination — unreachable paths are compile errors |
| STARLINER | Boeing Starliner OFT | 2019 | Mission fail | Stale timer polled 11hrs before launch | Integer overflow on mission elapsed time |
| MPL | Mars Polar Lander | 1999 | $165M | Spurious sensor noise interpreted as touchdown | Validated sensor input with range/rate checks |
| QANTAS | Qantas Flight 72 | 2008 | Near-miss | Corrupted memory in ADIRU caused nosedive | Out-of-bounds access = panic in Zig; slice bounds checking |
| Y2K | Y2K Bug | 2000 | $100B+ remediation | 2-digit year overflow | Zig integer overflow is detectable; no silent wraparound |

---

## Architecture

```
programs/zig_chaos_rocket/
  build.zig
  build.zig.zon
  LICENSE
  README.md
  src/
    main.zig                    — Entry point: launch sequence orchestrator
    
    # Rocket simulation core
    sim/
      vehicle.zig               — Rocket vehicle state (position, velocity, mass, attitude)
      physics.zig               — Flight dynamics: thrust, drag, gravity, atmosphere model
      guidance.zig              — Guidance computer: trajectory targeting, steering commands
      navigation.zig            — Inertial navigation system (INS): sensor fusion, state estimation
      propulsion.zig            — Engine model: thrust curves, fuel consumption, throttle
      staging.zig               — Stage separation sequencing and jettison logic
      telemetry.zig             — Telemetry stream: downlink formatting, data encoding
      flight_controller.zig     — Flight control system: PID loops, actuator commands
      timeline.zig              — Mission timeline: T-minus countdown, milestone events

    # Sensor subsystem (with fault injection points)
    sensors/
      imu.zig                   — Inertial Measurement Unit: accelerometer + gyroscope
      gps.zig                   — GPS receiver simulation
      barometric.zig            — Barometric altimeter
      aoa.zig                   — Angle of Attack sensor (Boeing MCAS scenario)
      temperature.zig           — Thermal sensors (engine, skin, propellant)
      fuel_gauge.zig            — Fuel level and flow rate sensors
      radar_alt.zig             — Radar altimeter (landing scenario)
      sensor_bus.zig            — Sensor data bus with voter/arbitration logic

    # Safety-critical type system
    units/
      units.zig                 — Comptime unit system: Newton, PoundForce, Meter, Foot, etc.
      conversions.zig           — Explicit, auditable unit conversions
      checked_math.zig          — Overflow-checked arithmetic with error returns
      fixed_point.zig           — Fixed-point arithmetic for deterministic computation

    # Chaos engine (fault injector)
    chaos/
      engine.zig                — Chaos orchestrator: schedules and triggers fault scenarios
      scenarios.zig             — Predefined fault scenarios (ARIANE, MCO, THERAC, etc.)
      fault_injector.zig        — Low-level fault injection: corrupt memory, flip bits, stall I/O
      race_injector.zig         — Simulated race conditions and timing faults
      fuzzer.zig                — Random input fuzzer: garbage sensor data, malformed packets
      report.zig                — Post-run analysis: what was injected, what was caught, how

    # Display and reporting
    display/
      dashboard.zig             — Real-time TUI dashboard: vehicle state, alerts, faults
      timeline_view.zig         — Mission timeline with fault injection markers
      comparison.zig            — Side-by-side: "what C would do" vs "what Zig does"
```

---

## Key Data Structures

### Vehicle State (sim/vehicle.zig)

```zig
pub const VehicleState = struct {
    // Position (Earth-centered, Earth-fixed)
    position_m: Vector3(units.Meter) = .{ .x = 0, .y = 0, .z = 0 },
    velocity_ms: Vector3(units.MeterPerSec) = .{ .x = 0, .y = 0, .z = 0 },
    acceleration_ms2: Vector3(units.MeterPerSecSq) = .{ .x = 0, .y = 0, .z = 0 },

    // Attitude (quaternion)
    attitude: Quaternion = Quaternion.identity(),
    angular_rate_rads: Vector3(units.RadPerSec) = .{ .x = 0, .y = 0, .z = 0 },

    // Mass
    dry_mass_kg: units.Kilogram,
    propellant_mass_kg: units.Kilogram,

    // Flight parameters
    altitude_m: units.Meter = .{ .value = 0 },
    mach: f64 = 0,
    dynamic_pressure_pa: units.Pascal = .{ .value = 0 },
    downrange_m: units.Meter = .{ .value = 0 },

    // Mission clock
    met_ticks: u64 = 0,    // Mission Elapsed Time in monotonic ticks (NOT floating point)
    met_seconds: f64 = 0,  // Derived, for display only — never used for control

    // Stage
    current_stage: u8 = 0,
    stage_ignited: [4]bool = .{ false, false, false, false },

    pub fn totalMass(self: @This()) units.Kilogram {
        return .{ .value = self.dry_mass_kg.value + self.propellant_mass_kg.value };
    }
};
```

### Comptime Unit System (units/units.zig)

**This is the Mars Climate Orbiter prevention.** Wrong unit = compile error. Not a runtime check. Not a convention. A type error.

```zig
/// Comptime-parameterized physical unit type.
/// Force(Newton) and Force(PoundForce) are DIFFERENT TYPES.
/// You cannot add, compare, or assign between them without explicit conversion.
pub fn Quantity(comptime UnitTag: type) type {
    return struct {
        value: f64,

        const Self = @This();
        const Unit = UnitTag;

        pub fn add(a: Self, b: Self) Self {
            return .{ .value = a.value + b.value };
        }

        pub fn scale(self: Self, factor: f64) Self {
            return .{ .value = self.value * factor };
        }

        /// Explicit conversion — the ONLY way to go between unit types
        pub fn convertTo(self: Self, comptime Target: type, comptime factor: f64) Quantity(Target) {
            return .{ .value = self.value * factor };
        }

        // This does NOT compile:
        // pub fn add(a: Quantity(Newton), b: Quantity(PoundForce)) ...
        // Because the types are different. You MUST convert first.
    };
}

// Unit tag types (zero-size, exist only for type discrimination)
pub const Newton = struct {};
pub const PoundForce = struct {};
pub const Meter = struct {};
pub const Foot = struct {};
pub const Kilogram = struct {};
pub const Pound = struct {};
pub const MeterPerSec = struct {};
pub const FeetPerSec = struct {};
pub const Radian = struct {};
pub const Degree = struct {};
pub const Pascal = struct {};
pub const PSI = struct {};
pub const Kelvin = struct {};
pub const Celsius = struct {};
pub const RadPerSec = struct {};
pub const MeterPerSecSq = struct {};
pub const Second = struct {};

// Conversion constants
pub const LBF_TO_NEWTON: f64 = 4.44822;
pub const FOOT_TO_METER: f64 = 0.3048;
pub const PSI_TO_PASCAL: f64 = 6894.76;

// Type aliases for readability
pub const Force = Quantity(Newton);
pub const Distance = Quantity(Meter);
pub const Mass = Quantity(Kilogram);
pub const Velocity = Quantity(MeterPerSec);
pub const Acceleration = Quantity(MeterPerSecSq);
pub const Pressure = Quantity(Pascal);
pub const Temperature = Quantity(Kelvin);
pub const Angle = Quantity(Radian);
pub const AngularRate = Quantity(RadPerSec);
pub const Time = Quantity(Second);
```

### Checked Math (units/checked_math.zig)

**This is the Ariane 5 prevention.** Integer overflow = explicit error, not silent corruption.

```zig
/// Safe cast from f64 to i16, returning error instead of undefined behavior.
/// The exact operation that destroyed Ariane 5.
pub fn floatToI16(value: f64) error{Overflow}!i16 {
    if (value > @as(f64, std.math.maxInt(i16)) or
        value < @as(f64, std.math.minInt(i16))) {
        return error.Overflow;
    }
    return @intFromFloat(value);
}

/// Safe cast between integer sizes.
/// In Zig, @intCast is safety-checked in Debug/ReleaseSafe modes.
/// In C, this is silent truncation.
pub fn safeCast(comptime T: type, value: anytype) error{Overflow}!T {
    return std.math.cast(T, value) orelse error.Overflow;
}

/// Checked addition that returns error on overflow instead of wrapping.
pub fn checkedAdd(comptime T: type, a: T, b: T) error{Overflow}!T {
    return std.math.add(T, a, b) catch error.Overflow;
}

/// Checked multiplication.
pub fn checkedMul(comptime T: type, a: T, b: T) error{Overflow}!T {
    return std.math.mul(T, a, b) catch error.Overflow;
}
```

### Sensor Bus with Voting (sensors/sensor_bus.zig)

**This is the Boeing MCAS prevention.** Never trust a single sensor. Triple-redundant with voting.

```zig
pub fn TripleRedundantSensor(comptime T: type) type {
    return struct {
        readings: [3]?T = .{ null, null, null },
        labels: [3][]const u8 = .{ "A", "B", "C" },
        tolerance: f64,    // maximum allowed deviation between sensors

        const Self = @This();

        pub const VoteResult = union(enum) {
            consensus: T,                               // all three agree
            majority: struct { value: T, outlier: u8 }, // 2 agree, 1 disagrees
            disagreement: void,                         // no consensus
            insufficient: void,                         // fewer than 2 readings
        };

        /// Vote on sensor readings. Returns consensus value or error detail.
        /// Boeing MCAS used a SINGLE sensor. This requires 2-of-3 agreement.
        pub fn vote(self: *const Self) VoteResult {
            var valid_count: u8 = 0;
            var valid_indices: [3]u8 = undefined;
            for (self.readings, 0..) |reading, i| {
                if (reading != null) {
                    valid_indices[valid_count] = @intCast(i);
                    valid_count += 1;
                }
            }

            if (valid_count < 2) return .insufficient;

            // Compare pairs for agreement within tolerance
            // ... (majority voting logic)
        }

        /// Inject a fault into sensor N (for chaos testing)
        pub fn injectFault(self: *Self, sensor_idx: u8, fault: SensorFault) void {
            switch (fault) {
                .stuck => {},                   // reading never changes
                .bias => |b| self.readings[sensor_idx].? += b,
                .noise => |n| self.readings[sensor_idx].? += randomNoise(n),
                .dead => self.readings[sensor_idx] = null,
                .inverted => self.readings[sensor_idx].? *= -1,
                .max_saturated => self.readings[sensor_idx] = std.math.floatMax(f64),
            }
        }
    };
}

pub const SensorFault = union(enum) {
    stuck: void,
    bias: f64,
    noise: f64,
    dead: void,
    inverted: void,
    max_saturated: void,
};
```

---

## Chaos Engine (chaos/)

### Fault Scenario Definitions (chaos/scenarios.zig)

Each scenario is a struct that defines when to inject, what to inject, and what the real-world consequence was.

```zig
pub const Scenario = struct {
    id: []const u8,                     // "ARIANE", "MCO", "THERAC", etc.
    name: []const u8,                   // "Ariane 5 Flight 501"
    year: u16,
    cost: []const u8,                   // "$370M" or "346 lives"
    root_cause: []const u8,             // Human-readable description
    c_behavior: []const u8,             // What C/C++ does: "silent truncation", "undefined behavior"
    zig_behavior: []const u8,           // What Zig does: "compile error", "runtime panic", "error return"
    trigger_met: u64,                   // Mission elapsed time (ticks) to inject fault
    inject: FaultInjection,             // What fault to inject
    severity: Severity,
};

pub const Severity = enum { catastrophic, critical, major, minor };

pub const FaultInjection = union(enum) {
    /// Ariane 5: overflow on float→int cast in navigation
    integer_overflow: struct {
        subsystem: Subsystem,
        variable: []const u8,
        inject_value: f64,          // Value that overflows when cast to i16
    },

    /// Mars Climate Orbiter: wrong unit type passed to function
    unit_mismatch: struct {
        expected_unit: []const u8,  // "Newton"
        actual_unit: []const u8,    // "PoundForce"
        magnitude: f64,
    },

    /// Therac-25: race condition between operator input and beam configuration
    race_condition: struct {
        thread_a_action: []const u8,
        thread_b_action: []const u8,
        window_ns: u64,             // Race window in nanoseconds
    },

    /// Patriot: floating-point time drift
    time_drift: struct {
        clock_source: []const u8,
        drift_per_hour_sec: f64,    // 0.0000001 sec/tick * 100hrs = 0.34 sec
        accumulated_hours: f64,
    },

    /// Boeing MCAS: single sensor failure with no cross-check
    sensor_failure: struct {
        sensor_id: u8,
        fault_type: SensorFault,
        authority_limit_exceeded: bool,
    },

    /// Knight Capital: dead code path activated
    dead_code_activation: struct {
        function_name: []const u8,
        last_tested: []const u8,    // "never" or date
    },

    /// Starliner: stale timer read from booster hours before launch
    stale_data: struct {
        data_age_seconds: u64,
        subsystem: Subsystem,
    },

    /// Mars Polar Lander: spurious sensor spike during descent
    spurious_sensor: struct {
        sensor_type: []const u8,
        spike_magnitude: f64,
        spike_duration_ticks: u32,
    },

    /// Qantas 72: corrupted memory in navigation computer
    memory_corruption: struct {
        address_offset: usize,
        corruption_bytes: [8]u8,
    },

    /// Generic: buffer overflow attempt
    buffer_overflow: struct {
        target_buffer: []const u8,
        overflow_bytes: usize,
    },

    /// Generic: null pointer dereference
    null_deref: struct {
        subsystem: Subsystem,
    },

    /// Generic: use-after-free
    use_after_free: struct {
        subsystem: Subsystem,
    },

    /// Generic: divide by zero
    divide_by_zero: struct {
        subsystem: Subsystem,
        variable: []const u8,
    },

    /// Y2K-style: integer overflow on timestamp
    timestamp_overflow: struct {
        bits: u8,       // 16, 32, or 64
        current_value: u64,
    },
};
```

### Chaos Orchestrator (chaos/engine.zig)

```zig
pub const ChaosEngine = struct {
    allocator: std.mem.Allocator,
    scenarios: []const Scenario,
    active_faults: std.ArrayList(ActiveFault),
    rng: std.Random.DefaultPrng,
    mode: ChaosMode,
    fault_log: std.ArrayList(FaultLogEntry),

    pub const ChaosMode = enum {
        off,                    // Clean run, no faults
        scripted,               // Run predefined scenarios in sequence
        random,                 // Random fault injection at random times
        stress,                 // Maximum chaos: all faults, all the time
        specific,               // Single named scenario
    };

    pub fn init(allocator: std.mem.Allocator, mode: ChaosMode, seed: u64) ChaosEngine
    pub fn tick(self: *@This(), met: u64, vehicle: *VehicleState) void
    pub fn injectFault(self: *@This(), fault: FaultInjection) FaultResult
    pub fn getReport(self: *@This()) ChaosReport

    pub const FaultResult = struct {
        injected: bool,
        caught_by: CaughtBy,
        detail: []const u8,
    };

    pub const CaughtBy = enum {
        compile_time,           // Would not compile (unit mismatch, dead code)
        runtime_safety,         // Zig safety check (overflow, bounds, null)
        error_handling,         // Error union caught and handled
        type_system,            // Type mismatch prevented the operation
        redundancy,             // Sensor voting / redundant computation detected
        assertion,              // Explicit assert in safety-critical code
        not_applicable,         // Fault class doesn't exist in Zig
    };
};
```

### Fuzzer (chaos/fuzzer.zig)

**True fuzzing mode** — generate completely random inputs and verify the system never exhibits undefined behavior.

```zig
pub const Fuzzer = struct {
    rng: std.Random.DefaultPrng,
    iterations: u64,
    crashes: u64,
    panics_caught: u64,
    errors_handled: u64,

    /// Fuzz the sensor bus with random data
    pub fn fuzzSensors(self: *@This(), sensors: *SensorBus) FuzzResult {
        // Generate random sensor readings including:
        // - NaN, Inf, -Inf
        // - Max/min float values
        // - Subnormal floats
        // - Zero
        // - Negative values for unsigned-expected quantities
        // - Values just above/below valid ranges
    }

    /// Fuzz the telemetry parser with random bytes
    pub fn fuzzTelemetry(self: *@This(), parser: *TelemetryParser) FuzzResult {
        // Generate random byte sequences including:
        // - Truncated messages
        // - Oversized payloads
        // - Invalid checksums
        // - Malformed headers
        // - Embedded null bytes
        // - UTF-8 invalid sequences
    }

    /// Fuzz the guidance computer with random state vectors
    pub fn fuzzGuidance(self: *@This(), guidance: *GuidanceComputer) FuzzResult {
        // Generate random position/velocity/attitude including:
        // - Inside the Earth
        // - Above escape velocity
        // - Inverted attitude
        // - Zero mass
        // - Negative fuel
    }

    pub fn report(self: *@This()) FuzzReport {
        return .{
            .iterations = self.iterations,
            .crashes = self.crashes,          // Should ALWAYS be 0 in Zig
            .panics_caught = self.panics_caught,
            .errors_handled = self.errors_handled,
            .undefined_behavior = 0,         // Structurally impossible in safe Zig
        };
    }
};
```

---

## The TUI Dashboard (display/dashboard.zig)

Real-time display showing the rocket state and fault injection status.

```
┌─── ZIG CHAOS ROCKET ── T+00:37.000 ── STAGE 1 ── CHAOS: SCRIPTED ─────────┐
│                                                                              │
│  VEHICLE STATE                    │  GUIDANCE                                │
│  Alt:   3,700 m  ▲               │  Target Az:  92.4°                       │
│  Vel:   202 m/s  ▲               │  Pitch Cmd:  78.2°                       │
│  Acc:   18.4 m/s²                │  Yaw Cmd:    0.3°                        │
│  Mass:  745,200 kg               │  Steering:   NOMINAL                     │
│  Fuel:  89.2%                    │  Mode:       GRAVITY TURN                │
│  Q:     32,400 Pa                │                                          │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  FAULT INJECTION LOG                                                         │
│                                                                              │
│  T+00:37.000  ⚡ ARIANE: Float64→Int16 overflow in INS horizontal bias      │
│               C/C++: Silent truncation → diagnostic dump → SRI shutdown       │
│               Zig:   error.Overflow returned from checked_math.floatToI16()  │
│               ✅ CAUGHT by error_handling — guidance continues with fallback  │
│                                                                              │
│  T+00:42.100  ⚡ MCO: PoundForce passed where Newton expected                │
│               C/C++: Wrong value used silently → 4.45x thrust error          │
│               Zig:   COMPILE ERROR — type Quantity(PoundForce) ≠             │
│                      Quantity(Newton)                                         │
│               ✅ CAUGHT by type_system — would never reach runtime            │
│                                                                              │
│  T+00:55.000  ⚡ MCAS: AoA sensor A failed (stuck at 21°)                   │
│               C/C++: Single sensor trusted → nose-down command 26 times      │
│               Zig:   TripleRedundant.vote() returned .majority{outlier: 0}   │
│               ✅ CAUGHT by redundancy — faulty sensor isolated               │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  SCORECARD                                                                   │
│  Faults injected: 7    Caught: 7    Missed: 0    Vehicle: NOMINAL            │
│  Compile-time:    2    Runtime:  3    Error handling: 1    Redundancy: 1      │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Comparison Mode (display/comparison.zig)

Side-by-side comparison showing the exact C code that failed vs the Zig equivalent:

```
┌─── ARIANE 5 FLIGHT 501 ── $370M LOST ── JUNE 4, 1996 ──────────────────────┐
│                                                                              │
│  Ada (what flew):                    Zig (what we wrote):                    │
│  ─────────────────                   ─────────────────────                   │
│  P_M_DERIVE(E_BH) :=                const bh = checked_math                 │
│    UC_16S_EN_16NS(                       .floatToI16(horizontal_bias)        │
│      TDB.T_ENTIER_16S(                  catch |err| {                       │
│        (1.0/C_M_LSB_BH) *                   log.warn("BH overflow: {d}",   │
│        G_M_INFO_DERIVE(E_BH)                    .{horizontal_bias});        │
│      )                                       return fallback_navigation();  │
│    );                                    };                                  │
│                                                                              │
│  -- No overflow protection!          // Overflow = error, must be handled    │
│  -- Value: 32,768.5                  // Value: 32,768.5 → error.Overflow     │
│  -- Result: OPERAND ERROR            // Result: fallback nav engaged         │
│  -- SRI shutdown, rocket lost        // Mission continues                    │
│                                                                              │
│  The BH variable protection was      In Zig, you cannot accidentally         │
│  removed to meet 80% CPU target.     discard an error. The compiler          │
│  3 of 7 variables left unprotected.  forces you to handle it.                │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Physics Core + Vehicle Model

**Files**: `sim/vehicle.zig`, `sim/physics.zig`, `sim/propulsion.zig`, `sim/timeline.zig`, `units/units.zig`, `units/checked_math.zig`, `main.zig`, `build.zig`

1. **units.zig**: Comptime unit type system. The foundation everything else builds on. Comprehensive tests proving that unit mismatches are compile errors.

2. **checked_math.zig**: Overflow-checked arithmetic. Include the exact Ariane 5 cast (`floatToI16`) as a documented function with the story in comments.

3. **physics.zig**: Simplified but physically correct rocket dynamics. Gravity model (varies with altitude). Atmospheric density model (exponential decay). Drag model (Cd as function of Mach). Thrust model (varies with atmospheric pressure — vacuum vs sea level Isp).

4. **vehicle.zig**: Vehicle state struct. State integration (Euler initially, RK4 if needed). No floating-point time accumulation — use integer ticks for MET (Patriot lesson).

5. **propulsion.zig**: Engine model. Fuel consumption. Throttle commands. Shutdown sequencing.

6. **timeline.zig**: Mission timeline from T-10s to orbit insertion (~8 minutes). Event scheduling (ignition, liftoff, max-Q, MECO, stage sep, etc.).

7. **main.zig**: Run a clean simulation from launch to orbit with text output. Prove the physics works before adding chaos.

**Verification**:
```bash
zig build run -- --mode clean
# Should print a successful launch timeline to orbit
# Alt, vel, acceleration at each major event should be physically reasonable
```

### Phase 2: Sensor Subsystem + Guidance

**Files**: `sensors/*.zig`, `sim/navigation.zig`, `sim/guidance.zig`, `sim/flight_controller.zig`

1. **sensors/imu.zig**: Simulated IMU generating accelerometer and gyroscope readings from true vehicle state, with configurable noise and bias.

2. **sensors/sensor_bus.zig**: Triple-redundant sensor voting. The MCAS prevention architecture.

3. **sensors/aoa.zig, gps.zig, barometric.zig, etc.**: Individual sensor models.

4. **navigation.zig**: Inertial navigation — integrates IMU readings to estimate position/velocity. Include the Ariane 5 horizontal bias computation with proper overflow checks.

5. **guidance.zig**: Guidance computer — computes steering commands to reach target orbit. Pitch program, gravity turn, closed-loop guidance.

6. **flight_controller.zig**: PID control loops for pitch/yaw/roll. Actuator command limits (authority limiting — the MCAS fix).

**Verification**:
```bash
zig build run -- --mode clean --verbose-sensors
# Should show sensor readings, navigation estimates, guidance commands
# All values physically reasonable
```

### Phase 3: Chaos Engine + Scenario Injection

**Files**: `chaos/engine.zig`, `chaos/scenarios.zig`, `chaos/fault_injector.zig`, `chaos/fuzzer.zig`, `chaos/report.zig`

1. **scenarios.zig**: Define all 10+ real-world failure scenarios as structured data. Include the historical narrative for each.

2. **engine.zig**: Chaos orchestrator. Modes: `off`, `scripted` (run scenarios in order), `random` (random faults at random times), `stress` (everything at once), `specific` (single named scenario).

3. **fault_injector.zig**: Low-level injection. Can corrupt specific struct fields, inject values into sensor readings, trigger timing anomalies. For compile-time catches (unit mismatch, dead code), the injector generates a report of what *would* happen rather than trying to inject (since the fault literally cannot be expressed in valid Zig).

4. **fuzzer.zig**: True fuzzing — random inputs to every subsystem interface. Verify: zero crashes, zero undefined behavior, all errors handled.

5. **report.zig**: Post-run report. For each injected fault: what was injected, when, what caught it (compile-time type system / runtime safety check / error handling / redundancy), what the real-world consequence was, and what Zig's consequence is.

**Verification**:
```bash
# Run all scripted scenarios
zig build run -- --mode scripted
# Should show each fault injected and caught, vehicle survives to orbit

# Run specific scenario
zig build run -- --scenario ARIANE
# Detailed output for the Ariane 5 fault

# Fuzz for 1 million iterations
zig build run -- --mode fuzz --iterations 1000000
# Should report: 0 crashes, 0 undefined behavior

# Maximum chaos
zig build run -- --mode stress --duration 600
# Everything at once for 10 simulated minutes
```

### Phase 4: TUI Dashboard

**Files**: `display/dashboard.zig`, `display/timeline_view.zig`, `display/comparison.zig`

1. **dashboard.zig**: Real-time TUI. Vehicle state on left, guidance on right, fault log scrolling at bottom, scorecard at base. Color-coded: green = nominal, yellow = fault injected, red = would-be-catastrophic (but caught).

2. **timeline_view.zig**: Visual mission timeline with fault injection points marked. Shows T+time for each event.

3. **comparison.zig**: The killer demo feature. Side-by-side code comparison showing the actual Ada/C/C++ that failed alongside the Zig equivalent. Triggered when each scenario executes.

**Verification**:
```bash
zig build run -- --mode scripted --tui
# Full visual dashboard with live fault injection
```

### Phase 5: Benchmarks + Polish

**Files**: Update `main.zig`, add `bench.zig`, `README.md`

1. **Performance benchmark**: How fast can we run the simulation? Target: real-time or faster (8 minutes of sim time in ≤8 minutes wall time). The overhead of safety checks should be measurable but small.

2. **Comparison benchmark**: Same fault injection in C (using a small C comparison module compiled with Zig's C compiler) — demonstrate that the C version silently corrupts or crashes while Zig catches everything.

3. **README.md**: The full narrative. Table of disasters. How Zig prevents each. Performance data. Instructions for running demos.

4. **Export**: Generate a JSON report suitable for inclusion in investor presentations or documentation.

---

## Compile-Time Demonstrations

Some faults are prevented at compile time — they literally cannot be expressed in valid Zig. For these, we include the code in comments or in a separate `compile_errors/` directory that demonstrates what would happen if you tried:

### Mars Climate Orbiter (unit mismatch)

```zig
// This DOES NOT COMPILE. The unit system prevents it.
// File: compile_errors/mco_demo.zig

const thrust_lbf = Quantity(PoundForce){ .value = 4.45 };
const expected_n = Quantity(Newton){ .value = 0 };

// ERROR: expected type 'Quantity(Newton)', found 'Quantity(PoundForce)'
const total = expected_n.add(thrust_lbf);

// CORRECT: explicit, auditable conversion
const thrust_n = thrust_lbf.convertTo(Newton, units.LBF_TO_NEWTON);
const total = expected_n.add(thrust_n);  // OK
```

### Dead Code (Knight Capital)

```zig
// Zig's unreachable analysis catches dead code paths.
// Unused functions in a switch are compile errors with exhaustive switches.

const TradingMode = enum { production, testing, legacy_DO_NOT_USE };

fn executeTrade(mode: TradingMode) !void {
    switch (mode) {
        .production => try executeProductionTrade(),
        .testing => try executeTestTrade(),
        .legacy_DO_NOT_USE => unreachable,  // If reached: panic with stack trace
    }
}
// In C: the legacy path silently executes. In Zig: unreachable = hard crash with diagnostics.
```

---

## Testing Strategy

1. **Unit tests**: Every calculator, every sensor model, every checked_math function. Known inputs → known outputs.
2. **Scenario tests**: Each of the 10+ disaster scenarios runs independently and verifies the fault is caught.
3. **Fuzz tests**: Random inputs to every public API. Zero crashes after 10M iterations.
4. **Physics validation**: Compare simulation output to known orbital mechanics (Tsiolkovsky equation, Kepler orbits).
5. **Compile-time tests**: `compile_errors/` directory with `@compileError` test cases proving unit mismatches don't compile.
6. **Comparison tests**: C versions of the same code demonstrating the actual failure behavior (buffer overflow, silent truncation, etc.).

---

## Build Targets

```bash
# Clean simulation (no faults)
zig build run -- --mode clean

# All disaster scenarios in sequence with TUI
zig build run -- --mode scripted --tui

# Specific disaster scenario
zig build run -- --scenario ARIANE --tui
zig build run -- --scenario MCO --tui
zig build run -- --scenario MCAS --tui

# Random chaos
zig build run -- --mode random --seed 42 --tui

# Maximum stress
zig build run -- --mode stress --tui

# Fuzzing (headless, maximum throughput)
zig build run -- --mode fuzz --iterations 10000000

# Generate JSON report
zig build run -- --mode scripted --report report.json

# Run all tests
zig build test

# Cross-compile for Orange Pi demo
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

# Build with C comparison module
zig build -Dc-comparison=true
```

---

## Key Design Decisions

1. **Integer MET, not floating-point** — The Patriot missile failure was caused by accumulated floating-point drift in a time counter. Our MET is a u64 tick counter. Period. The f64 `met_seconds` exists only for human display and is NEVER used in control logic.

2. **Comptime unit types, not runtime tags** — The MCO fix isn't "check units at runtime." It's "wrong units don't compile." Zero runtime cost. The compiler does all the work.

3. **Error unions everywhere** — Every function that can fail returns `error{...}!T`. The caller MUST handle the error. You cannot accidentally discard it. This is what Ariane 5's Ada code lacked — the overflow was detected but the handler shut down the computer instead of providing fallback data.

4. **Triple-redundant sensors by default** — Every safety-critical measurement goes through a voting layer. A single sensor failure cannot cause a control action. This is the MCAS architectural fix.

5. **ReleaseSafe, not ReleaseFast** — The demo binary is built with runtime safety checks enabled. This is the point: the safety overhead is small enough to leave on in production. We benchmark both to prove it.

6. **Real physics, simplified but correct** — The simulation needs to be physically plausible or the demo falls flat. Actual gravity-turn ascent, actual staging, actual orbital insertion. Not a toy.

7. **Comparison with actual C code** — The most powerful demo is showing the same fault in C (silent corruption, crash) alongside Zig (caught, handled). Include a small C module compiled with `zig cc` for direct comparison.

8. **Every scenario sourced** — Each disaster scenario includes the real investigation report reference. This isn't hypothetical — these are real bugs that killed real people or destroyed real hardware.
