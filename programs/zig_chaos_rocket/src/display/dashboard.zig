// dashboard.zig — Real-time TUI dashboard: vehicle state, alerts, faults
//
// Color-coded: green = nominal, yellow = fault injected, red = would-be-catastrophic

const std = @import("std");
const vehicle_mod = @import("../sim/vehicle.zig");
const propulsion = @import("../sim/propulsion.zig");
const guidance = @import("../sim/guidance.zig");
const chaos_engine = @import("../chaos/engine.zig");
const fault_injector = @import("../chaos/fault_injector.zig");
const report_mod = @import("../chaos/report.zig");
const scenarios = @import("../chaos/scenarios.zig");
const timeline_view = @import("timeline_view.zig");
const comparison_mod = @import("comparison.zig");

// ANSI escape codes
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const GREEN = ESC ++ "[32m";
const YELLOW = ESC ++ "[33m";
const RED = ESC ++ "[31m";
const CYAN = ESC ++ "[36m";
const WHITE = ESC ++ "[37m";
const BRIGHT_GREEN = ESC ++ "[92m";
const BRIGHT_YELLOW = ESC ++ "[93m";
const BRIGHT_RED = ESC ++ "[91m";
const BRIGHT_CYAN = ESC ++ "[96m";
const BRIGHT_WHITE = ESC ++ "[97m";
const BG_BLACK = ESC ++ "[40m";
const CLEAR_SCREEN = ESC ++ "[2J" ++ ESC ++ "[H";
const HIDE_CURSOR = ESC ++ "[?25l";
const SHOW_CURSOR = ESC ++ "[?25h";

// Separator line constants (Zig 0.16 does not support fill patterns)
const SEPARATOR_DASH_72 = "─" ** 72;

pub const Dashboard = struct {
    writer: *std.Io.Writer,
    tui_mode: bool,
    fault_log: [64]FaultLogEntry = undefined,
    fault_count: u8 = 0,
    last_comparison: ?comparison_mod.ComparisonEntry = null,

    pub const FaultLogEntry = struct {
        met_seconds: f64,
        result: fault_injector.InjectionResult,
    };

    pub fn init(writer: *std.Io.Writer, tui: bool) Dashboard {
        return .{
            .writer = writer,
            .tui_mode = tui,
        };
    }

    pub fn start(self: *Dashboard) void {
        if (self.tui_mode) {
            self.writer.print("{s}{s}", .{ HIDE_CURSOR, CLEAR_SCREEN }) catch {};
        }
    }

    pub fn stop(self: *Dashboard) void {
        if (self.tui_mode) {
            self.writer.print("{s}\n", .{SHOW_CURSOR}) catch {};
        }
    }

    pub fn logFault(self: *Dashboard, met_seconds: f64, result: fault_injector.InjectionResult) void {
        if (self.fault_count < 64) {
            self.fault_log[self.fault_count] = .{
                .met_seconds = met_seconds,
                .result = result,
            };
            self.fault_count += 1;
        }

        // Look up comparison data
        if (scenarios.findScenario(result.scenario_id)) |scenario| {
            self.last_comparison = comparison_mod.ComparisonEntry{
                .scenario = scenario,
            };
        }
    }

    pub fn render(
        self: *Dashboard,
        state: *const vehicle_mod.VehicleState,
        steering: *const guidance.SteeringCommand,
        chaos: *const chaos_engine.ChaosEngine,
    ) void {
        if (self.tui_mode) {
            self.renderTUI(state, steering, chaos);
        } else {
            self.renderText(state, steering, chaos);
        }
    }

    fn renderTUI(
        self: *Dashboard,
        state: *const vehicle_mod.VehicleState,
        steering: *const guidance.SteeringCommand,
        chaos: *const chaos_engine.ChaosEngine,
    ) void {
        const w = self.writer;
        const met_s = state.metSeconds();
        const rpt = chaos.getReport();

        // Move cursor to top
        w.print("{s}", .{ESC ++ "[H"}) catch {};

        // Header
        const mode_str = chaos.modeName();
        const stage_str: []const u8 = switch (state.current_stage) {
            0 => "STAGE 1",
            1 => "STAGE 2",
            else => "COAST",
        };
        w.print("{s}{s}+--- ZIG CHAOS ROCKET -- T+{d:0>2}:{d:0>2}.{d:0>3} -- {s} -- CHAOS: {s} ---+{s}\n", .{
            BOLD, BRIGHT_CYAN,
            @as(u64, @intFromFloat(met_s)) / 60,
            @as(u64, @intFromFloat(met_s)) % 60,
            @as(u64, @intFromFloat(@mod(met_s * 1000, 1000))),
            stage_str,
            mode_str,
            RESET,
        }) catch {};

        w.print("{s}|{s}\n", .{ DIM, RESET }) catch {};

        // Vehicle state
        const status_color = if (state.aborted) BRIGHT_RED else if (state.active_faults > 0) BRIGHT_YELLOW else BRIGHT_GREEN;
        w.print("{s}  VEHICLE STATE{s}                    ", .{ BOLD, RESET }) catch {};
        w.print("{s}  GUIDANCE{s}\n", .{ BOLD, RESET }) catch {};

        w.print("  Alt: {s}{d:>10.0}{s} m  {s}               ", .{
            status_color, state.altitude_m.value, RESET,
            if (state.velocity.z.value > 0) "^" else "v",
        }) catch {};
        w.print("  Pitch: {d:>6.1} deg\n", .{steering.pitch_cmd_deg}) catch {};

        w.print("  Vel: {s}{d:>10.1}{s} m/s {s}              ", .{
            status_color, state.speedMps(), RESET,
            if (state.velocity.z.value > 0) "^" else "v",
        }) catch {};
        w.print("  Mode:  {s}\n", .{@tagName(steering.mode)}) catch {};

        w.print("  Acc: {d:>10.1} m/s2                ", .{state.acceleration.magnitude()}) catch {};
        w.print("  Thrtl: {d:>5.0}%\n", .{steering.throttle_cmd * 100}) catch {};

        w.print("  Mass:{d:>10.0} kg\n", .{state.totalMass().value}) catch {};

        const fuel_pct = if (state.dry_mass_kg.value + state.propellant_mass_kg.value > 0)
            state.propellant_mass_kg.value / (state.dry_mass_kg.value + state.propellant_mass_kg.value) * 100
        else
            0;
        w.print("  Fuel:  {d:>5.1}%%\n", .{fuel_pct}) catch {};
        w.print("  Q:   {d:>10.0} Pa\n", .{state.dynamic_pressure_pa.value}) catch {};
        w.print("  Mach:  {d:>5.2}\n", .{state.mach}) catch {};

        // Separator
        w.print("{s}{s}+{s}+{s}\n", .{ BOLD, DIM, SEPARATOR_DASH_72, RESET }) catch {};

        // Fault injection log
        w.print("{s}  FAULT INJECTION LOG{s}\n", .{ BOLD, RESET }) catch {};

        const log_start: u8 = if (self.fault_count > 6) self.fault_count - 6 else 0;
        var i: u8 = log_start;
        while (i < self.fault_count) : (i += 1) {
            const entry = self.fault_log[i];
            const r = entry.result;
            const icon = if (r.caught) "+" else "!";
            const color = if (r.caught) BRIGHT_GREEN else BRIGHT_RED;

            w.print("  T+{d:0>2}:{d:0>2}.{d:0>3}  {s}[{s}]{s} {s}: {s}\n", .{
                @as(u64, @intFromFloat(entry.met_seconds)) / 60,
                @as(u64, @intFromFloat(entry.met_seconds)) % 60,
                @as(u64, @intFromFloat(@mod(entry.met_seconds * 1000, 1000))),
                color, icon, RESET,
                r.scenario_id,
                r.detail,
            }) catch {};
            w.print("           Caught by: {s}{s}{s}\n", .{ CYAN, @tagName(r.caught_by), RESET }) catch {};
        }

        // Pad remaining lines
        var remaining: u8 = 6 -| (self.fault_count -| log_start);
        while (remaining > 0) : (remaining -= 1) {
            w.print("\n", .{}) catch {};
        }

        // Separator
        w.print("{s}{s}+{s}+{s}\n", .{ BOLD, DIM, SEPARATOR_DASH_72, RESET }) catch {};

        // Scorecard
        const vehicle_status: []const u8 = if (state.in_orbit) "IN ORBIT" else if (state.aborted) "ABORTED" else "NOMINAL";
        const sc = if (state.in_orbit) BRIGHT_GREEN else if (state.aborted) BRIGHT_RED else GREEN;
        w.print("  {s}SCORECARD{s}\n", .{ BOLD, RESET }) catch {};
        w.print("  Faults injected: {s}{d}{s}    Caught: {s}{d}{s}    Missed: {s}{d}{s}    Vehicle: {s}{s}{s}\n", .{
            BRIGHT_WHITE,           rpt.total_injected,                                               RESET,
            BRIGHT_GREEN,           rpt.total_caught,                                                 RESET,
            if (rpt.total_missed > 0) BRIGHT_RED else BRIGHT_GREEN, rpt.total_missed,                RESET,
            sc,                     vehicle_status,                                                   RESET,
        }) catch {};
        w.print("  Compile: {d}  Runtime: {d}  ErrorH: {d}  Redundancy: {d}  Type: {d}  N/A: {d}\n", .{
            rpt.compile_time_catches,
            rpt.runtime_safety_catches,
            rpt.error_handling_catches,
            rpt.redundancy_catches,
            rpt.type_system_catches,
            rpt.not_applicable,
        }) catch {};

        // Show comparison if available
        if (self.last_comparison) |comp| {
            w.print("\n", .{}) catch {};
            comparison_mod.renderComparison(&comp, w);
            self.last_comparison = null;
        }
    }

    fn renderText(
        _: *Dashboard,
        state: *const vehicle_mod.VehicleState,
        _: *const guidance.SteeringCommand,
        _: *const chaos_engine.ChaosEngine,
    ) void {
        _ = state;
    }

    /// Render a milestone event
    pub fn renderMilestone(self: *Dashboard, name: []const u8, description: []const u8, met_seconds: f64) void {
        const w = self.writer;
        if (self.tui_mode) return; // Milestones shown in log in TUI mode

        w.print("{s}{s}  T+{d:0>2}:{d:0>2}.{d:0>3}  >>> {s} — {s}{s}\n", .{
            BOLD, BRIGHT_CYAN,
            @as(u64, @intFromFloat(@max(0, met_seconds))) / 60,
            @as(u64, @intFromFloat(@max(0, met_seconds))) % 60,
            @as(u64, @intFromFloat(@mod(@max(0, met_seconds) * 1000, 1000))),
            name,
            description,
            RESET,
        }) catch {};
    }

    /// Render fault in text mode
    pub fn renderFaultText(self: *Dashboard, met_seconds: f64, result: *const fault_injector.InjectionResult) void {
        const w = self.writer;
        const color = if (result.caught) BRIGHT_GREEN else BRIGHT_RED;
        const icon = if (result.caught) "+" else "!";

        w.print("{s}  T+{d:0>2}:{d:0>2}.{d:0>3}  [{s}] {s}: {s}{s}\n", .{
            color,
            @as(u64, @intFromFloat(met_seconds)) / 60,
            @as(u64, @intFromFloat(met_seconds)) % 60,
            @as(u64, @intFromFloat(@mod(met_seconds * 1000, 1000))),
            icon,
            result.scenario_id,
            result.detail,
            RESET,
        }) catch {};

        // Show the scenario context
        if (scenarios.findScenario(result.scenario_id)) |scenario| {
            w.print("               {s}Real incident: {s} ({d}) — {s}{s}\n", .{
                DIM, scenario.name, scenario.year, scenario.cost, RESET,
            }) catch {};
            w.print("               {s}C/C++: {s}{s}\n", .{ YELLOW, scenario.c_behavior, RESET }) catch {};
            w.print("               {s}Zig:   {s}{s}\n", .{ GREEN, scenario.zig_behavior, RESET }) catch {};
            w.print("               Caught by: {s}{s}{s}\n", .{ CYAN, @tagName(result.caught_by), RESET }) catch {};
        }
        w.print("\n", .{}) catch {};
    }

    /// Print the text-mode telemetry line
    pub fn renderTelemetryLine(self: *Dashboard, state: *const vehicle_mod.VehicleState) void {
        if (self.tui_mode) return;
        const w = self.writer;
        const met_s = state.metSeconds();
        w.print("  T+{d:0>2}:{d:0>2}  Alt:{d:>9.0}m  Vel:{d:>7.0}m/s  Acc:{d:>5.1}m/s2  M:{d:>4.1}  Q:{d:>7.0}Pa  Fuel:{d:>5.1}%%\n", .{
            @as(u64, @intFromFloat(met_s)) / 60,
            @as(u64, @intFromFloat(met_s)) % 60,
            state.altitude_m.value,
            state.speedMps(),
            state.acceleration.magnitude(),
            state.mach,
            state.dynamic_pressure_pa.value,
            if (state.propellant_mass_kg.value > 0) state.propellant_mass_kg.value / (state.dry_mass_kg.value + state.propellant_mass_kg.value) * 100 else @as(f64, 0),
        }) catch {};
    }
};
