// race_injector.zig — Simulated race conditions and timing faults
//
// In a truly multi-threaded Zig program, data races on non-atomic types are
// safety-checked undefined behavior (caught in Debug/ReleaseSafe).
// This module demonstrates the CONCEPT of race conditions for the TUI display
// without actually creating unsafe concurrent access.

const std = @import("std");
const scenarios = @import("scenarios.zig");

pub const RaceScenario = struct {
    thread_a_action: []const u8,
    thread_b_action: []const u8,
    window_ns: u64,
    description: []const u8,
    zig_prevention: []const u8,
};

pub const THERAC_RACE = RaceScenario{
    .thread_a_action = "Operator changes beam mode from X-ray to electron",
    .thread_b_action = "Beam fires with previous (X-ray) collimator setting",
    .window_ns = 8_000, // 8 microsecond race window
    .description = "The Therac-25 had a race between the operator input task and the beam " ++
        "configuration task. If the operator changed the mode within ~8 ms of the " ++
        "beam firing, the high-energy X-ray beam could fire with the wrong collimator.",
    .zig_prevention = "In safe Zig, shared mutable state accessed from multiple threads must use " ++
        "atomic operations (@atomicStore, @atomicLoad) or mutexes. Data races on " ++
        "non-atomic types are safety-checked UB — caught in Debug/ReleaseSafe builds.",
};

pub const RaceInjector = struct {
    scenarios_demonstrated: u8 = 0,

    pub fn demonstrateTheracRace(self: *RaceInjector) scenarios.CaughtBy {
        self.scenarios_demonstrated += 1;
        // In Zig, this class of bug is prevented by the type system:
        // - Shared mutable state requires atomic operations or synchronization
        // - Data races on non-atomic types are UB and caught in safe build modes
        return .type_system;
    }
};
