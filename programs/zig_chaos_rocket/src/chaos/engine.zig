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
    scenarios_triggered: [20]bool = [_]bool{false} ** 20,
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
            if (i < 20 and !self.scenarios_triggered[i] and met_seconds >= scenario.trigger_met_s) {
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
            if (i < 20 and !self.scenarios_triggered[i] and
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
            const fault_idx = self.injector.rng.random().int(u8) % 20;
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

    /// Run the fuzzer
    pub fn runFuzz(self: *ChaosEngine, iterations: u64) void {
        const sensor_result = self.fuzzer.fuzzSensorBus(iterations);
        self.report.addFuzzResult(sensor_result);

        const math_result = self.fuzzer.fuzzCheckedMath(iterations);
        self.report.addFuzzResult(math_result);
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
