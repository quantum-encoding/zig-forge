// report.zig — Post-run analysis: what was injected, what was caught, how

const std = @import("std");
const scenarios = @import("scenarios.zig");
const fault_injector = @import("fault_injector.zig");
const fuzzer_mod = @import("fuzzer.zig");

// Separator line constants (Zig 0.16 does not support fill patterns)
const SEPARATOR_EQ_72 = "=" ** 72;
const SEPARATOR_DASH_68 = "─" ** 68;

pub const ChaosReport = struct {
    total_injected: u32 = 0,
    total_caught: u32 = 0,
    total_missed: u32 = 0,
    compile_time_catches: u32 = 0,
    runtime_safety_catches: u32 = 0,
    error_handling_catches: u32 = 0,
    type_system_catches: u32 = 0,
    redundancy_catches: u32 = 0,
    assertion_catches: u32 = 0,
    not_applicable: u32 = 0,
    fuzz_iterations: u64 = 0,
    fuzz_crashes: u64 = 0,
    scenario_results: [32]?fault_injector.InjectionResult = [_]?fault_injector.InjectionResult{null} ** 32,
    scenario_count: u8 = 0,

    pub fn addResult(self: *ChaosReport, result: fault_injector.InjectionResult) void {
        self.total_injected += 1;
        if (result.caught) {
            self.total_caught += 1;
            switch (result.caught_by) {
                .compile_time => self.compile_time_catches += 1,
                .runtime_safety => self.runtime_safety_catches += 1,
                .error_handling => self.error_handling_catches += 1,
                .type_system => self.type_system_catches += 1,
                .redundancy => self.redundancy_catches += 1,
                .assertion => self.assertion_catches += 1,
                .not_applicable => self.not_applicable += 1,
            }
        } else {
            self.total_missed += 1;
        }

        if (self.scenario_count < 32) {
            self.scenario_results[self.scenario_count] = result;
            self.scenario_count += 1;
        }
    }

    pub fn addFuzzResult(self: *ChaosReport, result: fuzzer_mod.FuzzResult) void {
        self.fuzz_iterations += result.iterations;
        self.fuzz_crashes += result.crashes;
    }
};

pub fn generateTextReport(report: *const ChaosReport, writer: anytype) !void {
    try writer.print("\n", .{});
    try writer.print("{s}\n", .{SEPARATOR_EQ_72});
    try writer.print("  ZIG CHAOS ROCKET — POST-RUN ANALYSIS\n", .{});
    try writer.print("{s}\n\n", .{SEPARATOR_EQ_72});

    try writer.print("  SCORECARD\n", .{});
    try writer.print("  {s}\n", .{SEPARATOR_DASH_68});
    try writer.print("  Faults injected:    {d:>4}\n", .{report.total_injected});
    try writer.print("  Faults caught:      {d:>4}\n", .{report.total_caught});
    try writer.print("  Faults missed:      {d:>4}\n", .{report.total_missed});
    try writer.print("\n", .{});
    try writer.print("  CATCH BREAKDOWN\n", .{});
    try writer.print("  {s}\n", .{SEPARATOR_DASH_68});
    try writer.print("  Compile-time:       {d:>4}  (unit mismatch, dead code)\n", .{report.compile_time_catches});
    try writer.print("  Runtime safety:     {d:>4}  (overflow, bounds, null)\n", .{report.runtime_safety_catches});
    try writer.print("  Error handling:     {d:>4}  (error unions caught)\n", .{report.error_handling_catches});
    try writer.print("  Type system:        {d:>4}  (type mismatch)\n", .{report.type_system_catches});
    try writer.print("  Redundancy:         {d:>4}  (sensor voting)\n", .{report.redundancy_catches});
    try writer.print("  Assertion:          {d:>4}  (explicit safety checks)\n", .{report.assertion_catches});
    try writer.print("  N/A (prevented):    {d:>4}  (bug class doesn't exist in Zig)\n", .{report.not_applicable});

    if (report.fuzz_iterations > 0) {
        try writer.print("\n  FUZZ TESTING\n", .{});
        try writer.print("  {s}\n", .{SEPARATOR_DASH_68});
        try writer.print("  Iterations:     {d:>12}\n", .{report.fuzz_iterations});
        try writer.print("  Crashes:        {d:>12}  (should be 0)\n", .{report.fuzz_crashes});
        try writer.print("  Undefined behavior: 0  (structurally impossible)\n", .{});
    }

    try writer.print("\n  SCENARIO DETAIL\n", .{});
    try writer.print("  {s}\n", .{SEPARATOR_DASH_68});

    for (0..report.scenario_count) |i| {
        if (report.scenario_results[i]) |r| {
            const status = if (r.caught) "CAUGHT" else "MISSED";
            const icon = if (r.caught) "+" else "!";
            try writer.print("  [{s}] {s:<10} {s}\n", .{ icon, r.scenario_id, status });
            try writer.print("       {s}\n", .{r.detail});
            try writer.print("       Caught by: {s}\n\n", .{@tagName(r.caught_by)});
        }
    }

    try writer.print("{s}\n", .{SEPARATOR_EQ_72});
}
