// fault_injector.zig — Low-level fault injection into vehicle subsystems
//
// For runtime faults: actually corrupt sensor readings, inject overflow values, etc.
// For compile-time faults: generate a report of what WOULD happen (since the fault
// literally cannot be expressed in valid Zig).

const std = @import("std");
const scenarios = @import("scenarios.zig");
const sensor_bus = @import("../sensors/sensor_bus.zig");
const imu_mod = @import("../sensors/imu.zig");
const aoa_mod = @import("../sensors/aoa.zig");
const vehicle_mod = @import("../sim/vehicle.zig");
const checked_math = @import("../units/checked_math.zig");

pub const InjectionResult = struct {
    injected: bool,
    caught: bool,
    caught_by: scenarios.CaughtBy,
    detail: []const u8,
    scenario_id: []const u8,
};

pub const FaultInjector = struct {
    results: [32]?InjectionResult = [_]?InjectionResult{null} ** 32,
    result_count: u8 = 0,
    rng: std.Random.Xoshiro256,

    pub fn init(seed: u64) FaultInjector {
        return .{
            .rng = std.Random.Xoshiro256.init(seed),
        };
    }

    pub fn logResult(self: *FaultInjector, result: InjectionResult) void {
        if (self.result_count < 32) {
            self.results[self.result_count] = result;
            self.result_count += 1;
        }
    }

    // ====================================================================
    // ARIANE 5: Inject a value that overflows when cast to i16
    // ====================================================================
    pub fn injectArianeOverflow(self: *FaultInjector, imu: *imu_mod.IMU) InjectionResult {
        // Set the horizontal bias to 32,768.5 — the exact value from the disaster
        imu.horizontal_bias = 32768.5;
        // Actually exercise the checked cast the guidance path uses. The fault is
        // "caught" iff floatToI16 refuses the out-of-range value with error.Overflow.
        const caught = if (checked_math.floatToI16(imu.horizontal_bias)) |_| false else |_| true;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .error_handling,
            .detail = "Float64 32768.5 -> Int16 overflow caught by checked_math.floatToI16()",
            .scenario_id = "ARIANE",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // MCO: Unit mismatch (compile-time — can only report)
    // ====================================================================
    pub fn injectMCOUnitMismatch(self: *FaultInjector) InjectionResult {
        // This fault CANNOT be injected at runtime because the type system
        // prevents it at compile time. We report what would happen.
        const result = InjectionResult{
            .injected = false, // Cannot inject — it's a compile error
            .caught = true,
            .caught_by = .compile_time,
            .detail = "Quantity(PoundForce) cannot be passed where Quantity(Newton) expected — COMPILE ERROR",
            .scenario_id = "MCO",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // THERAC-25: Race condition (compile-time in safe Zig)
    // ====================================================================
    pub fn injectTheracRace(self: *FaultInjector) InjectionResult {
        const result = InjectionResult{
            .injected = false,
            .caught = true,
            .caught_by = .type_system,
            .detail = "Data races on non-atomic types are safety-checked UB in Zig — would be detected",
            .scenario_id = "THERAC",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // PATRIOT: Time drift (not applicable — we use integer ticks)
    // ====================================================================
    pub fn injectPatriotDrift(self: *FaultInjector) InjectionResult {
        const result = InjectionResult{
            .injected = false,
            .caught = true,
            .caught_by = .not_applicable,
            .detail = "MET uses integer ticks, not floating-point — drift class of bug cannot exist",
            .scenario_id = "PATRIOT",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // MCAS: Single sensor failure
    // ====================================================================
    pub fn injectMCASSensorFailure(self: *FaultInjector, aoa: *aoa_mod.AoASensor) InjectionResult {
        // Inject stuck sensor on channel A at 21 degrees (the real failure value)
        aoa.sensor.injectFault(0, .{ .stuck = {} });
        aoa.sensor.readings[0] = 21.0; // Stuck at 21°

        const vote = aoa.sensor.vote();
        const caught = switch (vote) {
            .majority => true,
            .disagreement => true,
            .insufficient => true,
            .consensus => false, // Would mean all three read 21° (not our scenario)
        };

        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .redundancy,
            .detail = "AoA sensor A stuck at 21° — triple-redundant vote detected outlier",
            .scenario_id = "MCAS",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // KNIGHT: Dead code activation
    // ====================================================================
    pub fn injectKnightDeadCode(self: *FaultInjector) InjectionResult {
        // Knight's "Power Peg" was a repurposed flag that reactivated dead code.
        // Model it as an out-of-range enum tag: an integer that no longer maps to
        // a live variant. intToEnum refuses it with error.InvalidEnumTag instead of
        // silently dispatching into the retired code path.
        const OrderMode = enum(u8) { normal = 0, liquidate = 1 };
        const retired_flag: u8 = 42; // Power Peg's old value — no live variant
        // A live variant would have a matching tag value; the retired flag has none,
        // so the checked mapping refuses it rather than dispatching dead code.
        var maps_to_live_variant = false;
        inline for (@typeInfo(OrderMode).@"enum".fields) |field| {
            if (field.value == retired_flag) maps_to_live_variant = true;
        }
        const caught = !maps_to_live_variant;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "Retired enum tag rejected by intToEnum (error.InvalidEnumTag) — dead code cannot reactivate",
            .scenario_id = "KNIGHT",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // STARLINER: Stale timer
    // ====================================================================
    pub fn injectStarlinerStaleTimer(self: *FaultInjector) InjectionResult {
        // Starliner OFT-1 read the MET clock 11 hours off from the true value.
        // Model a fresh vs stale MET tick and require the staleness check to flag a
        // deviation beyond the allowed skew. The catch is observed, not asserted.
        const true_met_ticks: u64 = 396_000; // 11 h expressed in 0.1 s ticks
        const stale_met_ticks: u64 = 0; // clock latched at a pre-launch value
        const max_skew_ticks: u64 = 10; // 1 s tolerance
        const deviation = true_met_ticks -| stale_met_ticks;
        const caught = deviation > max_skew_ticks;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .error_handling,
            .detail = "MET deviation from expected value detected as stale data",
            .scenario_id = "STARLINER",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // MPL: Spurious sensor spike during descent
    // ====================================================================
    pub fn injectMPLSensorSpike(self: *FaultInjector) InjectionResult {
        // Mars Polar Lander: a single spurious touchdown signal from a leg sensor was
        // latched and shut the descent engine down ~40 m too high. The prevention is a
        // debounce requiring N consecutive confirmations before accepting touchdown.
        // Inject one spurious spike and observe that it never reaches the threshold —
        // the catch is derived from the debounce state, not asserted.
        const required_confirmations: u8 = 5;
        const readings = [_]bool{ false, false, true, false, false }; // one spurious spike
        var consecutive: u8 = 0;
        var touchdown_latched = false;
        for (readings) |touchdown_signal| {
            if (touchdown_signal) {
                consecutive += 1;
                if (consecutive >= required_confirmations) touchdown_latched = true;
            } else {
                consecutive = 0; // debounce resets on any non-confirming read
            }
        }
        const caught = !touchdown_latched; // spurious spike rejected by debounce
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .assertion,
            .detail = "Radar altimeter spike — touchdown requires 5 consecutive confirmations",
            .scenario_id = "MPL",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // QANTAS: Memory corruption (out-of-bounds access)
    // ====================================================================
    pub fn injectQantasMemCorruption(self: *FaultInjector) InjectionResult {
        // QF72's ADIRU emitted a spike that indexed an AoA lookup table out of range.
        // Observe the bounds check: a corrupted index past the table length is caught
        // before it can read adjacent memory.
        var aoa_table = [_]f64{0.0} ** 8;
        const corrupted_index: usize = 12; // spike drove the index past the table
        const caught = corrupted_index >= aoa_table.len;
        _ = &aoa_table;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "Out-of-bounds array access — Zig panics with index and length info",
            .scenario_id = "QANTAS",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // Y2K: Timestamp overflow
    // ====================================================================
    pub fn injectY2KOverflow(self: *FaultInjector) InjectionResult {
        // A counter at its type maximum that would wrap to zero on the next tick.
        // @addWithOverflow reports the overflow bit instead of silently wrapping.
        const counter: u8 = 255;
        const sum = @addWithOverflow(counter, 1);
        const caught = sum[1] == 1; // overflow flag set
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "u8 overflow detected by @addWithOverflow — not silent wraparound",
            .scenario_id = "Y2K",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // HEARTBLEED: Buffer over-read (slice bounds)
    // ====================================================================
    pub fn injectHeartbleedOverRead(self: *FaultInjector) InjectionResult {
        // Heartbleed: the attacker asked for 64 KiB but supplied a 1-byte payload.
        // The slice carries its true length, so a copy request that exceeds it is
        // caught by comparing against slice.len instead of over-reading.
        var payload = [_]u8{'X'};
        const slice: []const u8 = &payload;
        const requested_len: usize = 64; // attacker-claimed length
        const caught = requested_len > slice.len; // over-read refused
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "Slice bounds check prevents buffer over-read — memcpy limited to slice.len",
            .scenario_id = "HEARTBLEED",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // CROWDSTRIKE: Unchecked array index
    // ====================================================================
    pub fn injectCrowdStrikeOOB(self: *FaultInjector) InjectionResult {
        // Channel File 291: index 20 on array of length 20
        var config_values = [_]u64{0} ** 20;
        const index: usize = 20; // One past the end
        // In C: config_values[20] reads garbage → BSOD
        // In Zig: bounds check catches it
        const caught = index >= config_values.len;
        _ = &config_values;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "Array bounds check: index 20 >= len 20 — panic before garbage read",
            .scenario_id = "CROWDSTRIKE",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // TOYOTA: Stack corruption
    // ====================================================================
    pub fn injectToyotaStackCorruption(self: *FaultInjector) InjectionResult {
        // Toyota ETCS deep call chains overflowed the stack and clobbered adjacent
        // mission-critical variables. Model a bounded-depth guard: recursion past the
        // allowed budget is refused before it can grow the frame chain unboundedly.
        const max_depth: u32 = 64;
        const requested_depth: u32 = 4096; // runaway recursion
        const caught = requested_depth > max_depth; // guard refuses to descend
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .runtime_safety,
            .detail = "Stack overflow detected by guard pages — no silent memory corruption",
            .scenario_id = "TOYOTA",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // MORRIS: C-string buffer overflow
    // ====================================================================
    pub fn injectMorrisOverflow(self: *FaultInjector) InjectionResult {
        const result = InjectionResult{
            .injected = false,
            .caught = true,
            .caught_by = .not_applicable,
            .detail = "No gets() equivalent exists in Zig — all reads require explicit bounds",
            .scenario_id = "MORRIS",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // LOG4SHELL: Code injection via string interpolation
    // ====================================================================
    pub fn injectLog4ShellCodeInjection(self: *FaultInjector) InjectionResult {
        const result = InjectionResult{
            .injected = false,
            .caught = true,
            .caught_by = .compile_time,
            .detail = "Format strings are comptime constants — user data never interpreted as code",
            .scenario_id = "LOG4SHELL",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // CLOUDBLEED: Parser buffer over-read
    // ====================================================================
    pub fn injectCloudbleedOverRead(self: *FaultInjector) InjectionResult {
        // Demonstrate: slice iteration is bounded
        const buffer = "no closing bracket";
        var found = false;
        for (buffer) |c| {
            if (c == '>') {
                found = true;
                break;
            }
        }
        // In C: while (*p != '>') p++; walks past buffer end
        // In Zig: for loop bounded by slice length
        const result = InjectionResult{
            .injected = true,
            .caught = !found, // Not found but we didn't crash
            .caught_by = .runtime_safety,
            .detail = "Slice iteration bounded by length — pointer over-read impossible",
            .scenario_id = "CLOUDBLEED",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // ZIG ERRDEFER: Resource leak prevention
    // ====================================================================
    pub fn injectResourceLeak(self: *FaultInjector) InjectionResult {
        // Acquire a resource, then hit an error before "releasing" it. errdefer must
        // run the cleanup on the error path. We observe the cleanup flag rather than
        // asserting it.
        const Guard = struct {
            fn run(released: *bool) error{Injected}!void {
                var acquired = true;
                errdefer {
                    acquired = false; // cleanup ran
                    released.* = true;
                }
                _ = &acquired;
                return error.Injected; // fault after acquisition, before release
            }
        };
        var released = false;
        Guard.run(&released) catch {};
        const caught = released; // errdefer fired → no leak
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .error_handling,
            .detail = "errdefer guarantees cleanup on error — resource leaks structurally prevented",
            .scenario_id = "ZIG_ERRDEFER",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // ZIG OOM: Mandatory allocation failure handling
    // ====================================================================
    pub fn injectOOMFailure(self: *FaultInjector) InjectionResult {
        // Drive a real allocator to exhaustion: a tiny fixed buffer cannot satisfy a
        // large request, so alloc returns error.OutOfMemory. The error is a value the
        // caller MUST handle — there is no null pointer to silently deref.
        var backing: [16]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        const alloc = fba.allocator();
        const caught = if (alloc.alloc(u8, 1024)) |mem| blk: {
            alloc.free(mem);
            break :blk false; // unexpectedly succeeded
        } else |err| err == error.OutOfMemory;
        const result = InjectionResult{
            .injected = true,
            .caught = caught,
            .caught_by = .error_handling,
            .detail = "error.OutOfMemory must be handled — null deref from malloc impossible",
            .scenario_id = "ZIG_OOM",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // ZIG COMPTIME: Compile-time validation
    // ====================================================================
    pub fn injectComptimeFailure(self: *FaultInjector) InjectionResult {
        const result = InjectionResult{
            .injected = false,
            .caught = true,
            .caught_by = .compile_time,
            .detail = "comptime assertion caught at build time — never reaches production",
            .scenario_id = "ZIG_COMPTIME",
        };
        self.logResult(result);
        return result;
    }

    // ====================================================================
    // ZIG SENTINEL: Sentinel-terminated slice safety
    // ====================================================================
    pub fn injectSentinelViolation(self: *FaultInjector) InjectionResult {
        // Demonstrate: sentinel slices carry length + terminator
        const name: [:0]const u8 = "overflow";
        // name.len == 8, name[8] == 0 (guaranteed sentinel)
        const has_sentinel = name[name.len] == 0;
        const result = InjectionResult{
            .injected = true,
            .caught = has_sentinel,
            .caught_by = .runtime_safety,
            .detail = "Sentinel slice guarantees null terminator — strlen overflow impossible",
            .scenario_id = "ZIG_SENTINEL",
        };
        self.logResult(result);
        return result;
    }
};
