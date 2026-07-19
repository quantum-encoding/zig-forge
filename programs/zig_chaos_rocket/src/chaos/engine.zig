// engine.zig — Chaos orchestrator: schedules and triggers fault scenarios
//
// Modes:
//   off       — Clean run, no faults
//   scripted  — Run predefined scenarios in sequence at their trigger times
//   random    — Random fault injection at random times
//   stress    — Maximum chaos: all faults, all the time
//   specific  — Single named scenario

const std = @import("std");
const scenarios = @import("scenarios.zig");
const fault_injector = @import("fault_injector.zig");
const fuzzer_mod = @import("fuzzer.zig");
const report_mod = @import("report.zig");
const vehicle_mod = @import("../sim/vehicle.zig");
const imu_mod = @import("../sensors/imu.zig");
const aoa_mod = @import("../sensors/aoa.zig");

pub const ChaosMode = enum {
    off,
    scripted,
    random,
    stress,
    specific,
    fuzz,
};

pub const ChaosEngine = struct {
    mode: ChaosMode,
    injector: fault_injector.FaultInjector,
    fuzzer: fuzzer_mod.Fuzzer,
    report: report_mod.ChaosReport = .{},
    scenarios_triggered: [scenarios.ALL_SCENARIOS.len]bool = [_]bool{false} ** scenarios.ALL_SCENARIOS.len,
    specific_scenario: ?[]const u8 = null,
    seed: u64,

    pub fn init(mode: ChaosMode, seed: u64) ChaosEngine {
        return .{
            .mode = mode,
            .injector = fault_injector.FaultInjector.init(seed),
            .fuzzer = fuzzer_mod.Fuzzer.init(seed +% 1),
            .seed = seed,
        };
    }

    /// Called each simulation tick to check if any faults should be injected
    pub fn tick(
        self: *ChaosEngine,
        met_seconds: f64,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) ?fault_injector.InjectionResult {
        switch (self.mode) {
            .off => return null,
            .scripted => return self.tickScripted(met_seconds, imu, aoa),
            .specific => return self.tickSpecific(met_seconds, imu, aoa),
            .random => return self.tickRandom(met_seconds, imu, aoa),
            .stress => return self.tickStress(met_seconds, imu, aoa),
            .fuzz => return null,
        }
    }

    fn tickScripted(
        self: *ChaosEngine,
        met_seconds: f64,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) ?fault_injector.InjectionResult {
        // Check each scenario's trigger time
        for (scenarios.ALL_SCENARIOS, 0..) |scenario, i| {
            if (!self.scenarios_triggered[i] and met_seconds >= scenario.trigger_met_s) {
                self.scenarios_triggered[i] = true;
                const result = self.injectByType(scenario.fault_type, imu, aoa);
                self.report.addResult(result);
                return result;
            }
        }
        return null;
    }

    fn tickSpecific(
        self: *ChaosEngine,
        met_seconds: f64,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) ?fault_injector.InjectionResult {
        const target_id = self.specific_scenario orelse return null;

        for (scenarios.ALL_SCENARIOS, 0..) |scenario, i| {
            if (!self.scenarios_triggered[i] and
                std.mem.eql(u8, scenario.id, target_id) and
                met_seconds >= scenario.trigger_met_s)
            {
                self.scenarios_triggered[i] = true;
                const result = self.injectByType(scenario.fault_type, imu, aoa);
                self.report.addResult(result);
                return result;
            }
        }
        return null;
    }

    fn tickRandom(
        self: *ChaosEngine,
        _: f64,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) ?fault_injector.InjectionResult {
        // 0.5% chance per tick of injecting a random fault
        if (self.injector.rng.random().int(u16) % 200 == 0) {
            const fault_idx = self.injector.rng.random().uintLessThan(usize, scenarios.ALL_SCENARIOS.len);
            const fault_type = scenarios.ALL_SCENARIOS[fault_idx].fault_type;
            const result = self.injectByType(fault_type, imu, aoa);
            self.report.addResult(result);
            return result;
        }
        return null;
    }

    fn tickStress(
        self: *ChaosEngine,
        met_seconds: f64,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) ?fault_injector.InjectionResult {
        // Inject ALL faults at their trigger times
        return self.tickScripted(met_seconds, imu, aoa);
    }

    fn injectByType(
        self: *ChaosEngine,
        fault_type: scenarios.FaultType,
        imu: *imu_mod.IMU,
        aoa: *aoa_mod.AoASensor,
    ) fault_injector.InjectionResult {
        return switch (fault_type) {
            .integer_overflow => self.injector.injectArianeOverflow(imu),
            .unit_mismatch => self.injector.injectMCOUnitMismatch(),
            .race_condition => self.injector.injectTheracRace(),
            .time_drift => self.injector.injectPatriotDrift(),
            .sensor_failure => self.injector.injectMCASSensorFailure(aoa),
            .dead_code_activation => self.injector.injectKnightDeadCode(),
            .stale_data => self.injector.injectStarlinerStaleTimer(),
            .spurious_sensor => self.injector.injectMPLSensorSpike(),
            .memory_corruption => self.injector.injectQantasMemCorruption(),
            .timestamp_overflow => self.injector.injectY2KOverflow(),
            .buffer_overflow => self.injector.injectQantasMemCorruption(),
            .null_deref => self.injector.injectQantasMemCorruption(),
            .use_after_free => self.injector.injectQantasMemCorruption(),
            .divide_by_zero => self.injector.injectY2KOverflow(),
            .buffer_over_read => self.injector.injectHeartbleedOverRead(),
            .unchecked_index => self.injector.injectCrowdStrikeOOB(),
            .stack_corruption => self.injector.injectToyotaStackCorruption(),
            .c_string_overflow => self.injector.injectMorrisOverflow(),
            .code_injection => self.injector.injectLog4ShellCodeInjection(),
            .parser_overread => self.injector.injectCloudbleedOverRead(),
            .resource_leak => self.injector.injectResourceLeak(),
            .oom_handling => self.injector.injectOOMFailure(),
            .comptime_validation => self.injector.injectComptimeFailure(),
            .sentinel_overflow => self.injector.injectSentinelViolation(),
        };
    }

    /// Run both fuzz passes and fold their results into the report.
    pub fn runFuzz(self: *ChaosEngine, iterations: u64) void {
        self.fuzzSensorBus(iterations);
        self.fuzzCheckedMath(iterations);
    }

    /// Fuzz the sensor bus and record the result (separate pass for progress UI).
    pub fn fuzzSensorBus(self: *ChaosEngine, iterations: u64) void {
        self.report.addFuzzResult(self.fuzzer.fuzzSensorBus(iterations));
    }

    /// Fuzz the checked-math helpers and record the result.
    pub fn fuzzCheckedMath(self: *ChaosEngine, iterations: u64) void {
        self.report.addFuzzResult(self.fuzzer.fuzzCheckedMath(iterations));
    }

    pub fn getReport(self: *const ChaosEngine) *const report_mod.ChaosReport {
        return &self.report;
    }

    pub fn modeName(self: *const ChaosEngine) []const u8 {
        return switch (self.mode) {
            .off => "OFF",
            .scripted => "SCRIPTED",
            .random => "RANDOM",
            .stress => "STRESS",
            .specific => "SPECIFIC",
            .fuzz => "FUZZ",
        };
    }
};

// ============================================================================
// Tests — chaos scheduling
// ============================================================================
const testing = std.testing;

test "off mode injects nothing" {
    var engine = ChaosEngine.init(.off, 1);
    var imu = imu_mod.IMU.init();
    var aoa = aoa_mod.AoASensor.init();
    var met: f64 = 0;
    while (met < 500.0) : (met += 0.1) {
        try testing.expect(engine.tick(met, &imu, &aoa) == null);
    }
    try testing.expectEqual(@as(u32, 0), engine.getReport().total_injected);
}

test "scripted mode triggers each scenario exactly once" {
    var engine = ChaosEngine.init(.scripted, 1);
    var imu = imu_mod.IMU.init();
    var aoa = aoa_mod.AoASensor.init();

    // No scenario triggers before the earliest trigger_met_s.
    var earliest: f64 = std.math.floatMax(f64);
    for (scenarios.ALL_SCENARIOS) |s| earliest = @min(earliest, s.trigger_met_s);
    try testing.expect(engine.tick(earliest - 0.1, &imu, &aoa) == null);

    // Drive the full mission window; count injections.
    var injected: usize = 0;
    var met: f64 = 0;
    while (met < 600.0) : (met += 0.1) {
        if (engine.tick(met, &imu, &aoa) != null) injected += 1;
    }
    try testing.expectEqual(scenarios.ALL_SCENARIOS.len, injected);
    try testing.expectEqual(@as(u32, scenarios.ALL_SCENARIOS.len), engine.getReport().total_injected);

    // Every scenario slot is marked triggered exactly once (idempotent after).
    for (engine.scenarios_triggered) |t| try testing.expect(t);
    try testing.expect(engine.tick(600.0, &imu, &aoa) == null);
}

test "specific mode triggers only the named scenario" {
    var engine = ChaosEngine.init(.specific, 1);
    engine.specific_scenario = "ARIANE";
    var imu = imu_mod.IMU.init();
    var aoa = aoa_mod.AoASensor.init();

    const ariane = scenarios.findScenario("ARIANE").?;
    var injected: usize = 0;
    var hit_id: []const u8 = "";
    var met: f64 = 0;
    while (met < 600.0) : (met += 0.1) {
        if (engine.tick(met, &imu, &aoa)) |r| {
            injected += 1;
            hit_id = r.scenario_id;
        }
    }
    try testing.expectEqual(@as(usize, 1), injected);
    try testing.expect(std.mem.eql(u8, hit_id, "ARIANE"));
    try testing.expect(ariane.trigger_met_s <= 600.0);
}

test "random mode never panics over a full run" {
    var engine = ChaosEngine.init(.random, 12345);
    var imu = imu_mod.IMU.init();
    var aoa = aoa_mod.AoASensor.init();
    var met: f64 = 0;
    while (met < 600.0) : (met += 0.1) {
        _ = engine.tick(met, &imu, &aoa);
    }
    // All recorded results stay within the report's capacity.
    try testing.expect(engine.getReport().total_injected == engine.getReport().total_caught +
        engine.getReport().total_missed);
}

test "fuzz passes fold observations into the report" {
    var engine = ChaosEngine.init(.fuzz, 7);
    engine.runFuzz(1000);
    const rpt = engine.getReport();
    try testing.expectEqual(@as(u64, 2000), rpt.fuzz_iterations); // two passes
    try testing.expectEqual(@as(u64, 0), rpt.fuzz_crashes);
}
