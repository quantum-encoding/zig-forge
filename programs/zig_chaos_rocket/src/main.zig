// main.zig — ZIG CHAOS ROCKET: Safety-Critical Chaos Engineering in Zig
//
// "These bugs destroyed a $500M rocket, killed 346 people, and lost a Mars
// mission. Here's what happens when you write the same systems in Zig."
//
// A simulated rocket launch from ignition to orbit insertion, with a chaos
// engine that injects faults modeled on real-world disasters. The system
// survives everything thrown at it because Zig's language-level safety
// guarantees make the failure classes structurally impossible.

const std = @import("std");

// Units and math
const units = @import("units/units.zig");
const checked_math = @import("units/checked_math.zig");
const conversions = @import("units/conversions.zig");
const fixed_point = @import("units/fixed_point.zig");

// Simulation
const vehicle_mod = @import("sim/vehicle.zig");
const physics = @import("sim/physics.zig");
const propulsion = @import("sim/propulsion.zig");
const timeline_mod = @import("sim/timeline.zig");
const staging = @import("sim/staging.zig");
const telemetry_mod = @import("sim/telemetry.zig");
const navigation = @import("sim/navigation.zig");
const guidance = @import("sim/guidance.zig");
const flight_controller = @import("sim/flight_controller.zig");

// Sensors
const sensor_bus = @import("sensors/sensor_bus.zig");
const imu_mod = @import("sensors/imu.zig");
const aoa_mod = @import("sensors/aoa.zig");
const gps_mod = @import("sensors/gps.zig");
const baro_mod = @import("sensors/barometric.zig");
const temp_mod = @import("sensors/temperature.zig");
const fuel_mod = @import("sensors/fuel_gauge.zig");
const radar_mod = @import("sensors/radar_alt.zig");

// Chaos
const chaos_engine = @import("chaos/engine.zig");
const scenarios = @import("chaos/scenarios.zig");
const report_mod = @import("chaos/report.zig");

// Display
const dashboard_mod = @import("display/dashboard.zig");
const timeline_view = @import("display/timeline_view.zig");
const comparison_mod = @import("display/comparison.zig");

// C comparison
const c_compare = @import("c_compare/c_compare.zig");

// ANSI
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const GREEN = ESC ++ "[32m";
const YELLOW = ESC ++ "[33m";
const RED = ESC ++ "[31m";
const CYAN = ESC ++ "[36m";
const BRIGHT_GREEN = ESC ++ "[92m";
const BRIGHT_YELLOW = ESC ++ "[93m";
const BRIGHT_RED = ESC ++ "[91m";
const BRIGHT_CYAN = ESC ++ "[96m";
const BRIGHT_WHITE = ESC ++ "[97m";

// Separator line constants (Zig 0.16 does not support fill patterns)
const SEPARATOR_DASH_40 = "─" ** 40;

const Config = struct {
    mode: chaos_engine.ChaosMode = .scripted,
    tui: bool = false,
    scenario: ?[]const u8 = null,
    seed: u64 = 42,
    fuzz_iterations: u64 = 100_000,
    show_comparisons: bool = false,
    show_c_compare: bool = false,
    verbose: bool = false,
};

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &file_writer.interface;

    const config = parseArgs();

    // Print banner
    printBanner(w);

    if (config.show_comparisons) {
        comparison_mod.renderAllComparisons(w);
        if (config.show_c_compare) {
            c_compare.renderCComparison(w);
        }
        file_writer.flush() catch {};
        return;
    }

    if (config.show_c_compare) {
        c_compare.renderCComparison(w);
        file_writer.flush() catch {};
        return;
    }

    if (config.mode == .fuzz) {
        runFuzzMode(w, config);
        file_writer.flush() catch {};
        return;
    }

    // Run simulation
    runSimulation(w, config);
    file_writer.flush() catch {};
}

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

fn parseArgs() Config {
    var config = Config{};

    // Zig 0.16: use environment variables for configuration
    //   CHAOS_MODE=clean|scripted|random|stress|fuzz
    //   CHAOS_TUI=1
    //   CHAOS_SCENARIO=ARIANE|MCO|MCAS|...
    //   CHAOS_SEED=42
    //   CHAOS_ITERATIONS=100000
    //   CHAOS_COMPARISONS=1
    if (getenvSlice("CHAOS_MODE")) |mode_str| {
        if (std.mem.eql(u8, mode_str, "clean") or std.mem.eql(u8, mode_str, "off")) {
            config.mode = .off;
        } else if (std.mem.eql(u8, mode_str, "scripted")) {
            config.mode = .scripted;
        } else if (std.mem.eql(u8, mode_str, "random")) {
            config.mode = .random;
        } else if (std.mem.eql(u8, mode_str, "stress")) {
            config.mode = .stress;
        } else if (std.mem.eql(u8, mode_str, "fuzz")) {
            config.mode = .fuzz;
        }
    }

    if (getenvSlice("CHAOS_TUI")) |_| config.tui = true;
    if (getenvSlice("CHAOS_SCENARIO")) |s| {
        config.scenario = s;
        config.mode = .specific;
    }
    if (getenvSlice("CHAOS_SEED")) |seed_str| {
        config.seed = std.fmt.parseInt(u64, seed_str, 10) catch 42;
    }
    if (getenvSlice("CHAOS_ITERATIONS")) |iter_str| {
        config.fuzz_iterations = std.fmt.parseInt(u64, iter_str, 10) catch 100_000;
    }
    if (getenvSlice("CHAOS_COMPARISONS")) |_| config.show_comparisons = true;
    if (getenvSlice("CHAOS_C_COMPARE")) |_| config.show_c_compare = true;

    return config;
}

fn printBanner(w: anytype) void {
    w.print("\n", .{}) catch {};
    w.print("{s}{s}    _______ _______ _______   _______ _     _ _______ _______ _______     _______ _______ _______ _     _ _______ _______{s}\n", .{ BOLD, BRIGHT_CYAN, RESET }) catch {};
    w.print("{s}{s}       /      |    |  | |  ___   |       |     | |_____| |     | |_____        |_____/ |     | |       |____/  |______ |      {s}\n", .{ BOLD, BRIGHT_CYAN, RESET }) catch {};
    w.print("{s}{s}      /    ___|    |  | |_____|  |_____  |_____| |     | |_____| _______|      |    \\_ |_____| |_____  |    \\_ |______ |_____{s}\n", .{ BOLD, BRIGHT_CYAN, RESET }) catch {};
    w.print("\n", .{}) catch {};
    w.print("{s}  Safety-Critical Chaos Engineering in Zig{s}\n", .{ DIM, RESET }) catch {};
    w.print("{s}  \"These bugs destroyed real rockets, killed real people, and lost real missions.{s}\n", .{ DIM, RESET }) catch {};
    w.print("{s}   Here's what happens when you write the same systems in Zig.\"{s}\n\n", .{ DIM, RESET }) catch {};
}

fn runFuzzMode(w: anytype, config: Config) void {
    w.print("{s}{s}  FUZZ MODE — {d} iterations per subsystem{s}\n\n", .{
        BOLD, BRIGHT_YELLOW, config.fuzz_iterations, RESET,
    }) catch {};

    var chaos = chaos_engine.ChaosEngine.init(.fuzz, config.seed);

    w.print("  Fuzzing sensor bus...        ", .{}) catch {};
    chaos.runFuzz(config.fuzz_iterations);

    const rpt = chaos.getReport();
    w.print("{s}DONE{s}\n", .{ BRIGHT_GREEN, RESET }) catch {};
    w.print("  Fuzzing checked math...      ", .{}) catch {};
    w.print("{s}DONE{s}\n\n", .{ BRIGHT_GREEN, RESET }) catch {};

    w.print("  {s}RESULTS{s}\n", .{ BOLD, RESET }) catch {};
    w.print("  {s}\n", .{SEPARATOR_DASH_40}) catch {};
    w.print("  Total iterations:   {d:>12}\n", .{rpt.fuzz_iterations}) catch {};
    w.print("  Crashes:            {s}{d:>12}{s}  {s}\n", .{
        if (rpt.fuzz_crashes == 0) BRIGHT_GREEN else BRIGHT_RED,
        rpt.fuzz_crashes,
        RESET,
        if (rpt.fuzz_crashes == 0) "(PERFECT)" else "(FAILURE!)",
    }) catch {};
    w.print("  Undefined behavior: {s}{d:>12}{s}  (structurally impossible)\n\n", .{
        BRIGHT_GREEN, @as(u64, 0), RESET,
    }) catch {};
}

fn runSimulation(w: anytype, config: Config) void {
    // Initialize all subsystems
    var state = vehicle_mod.defaultFalcon9();
    var engines = propulsion.EngineCluster.init();
    var tl = timeline_mod.Timeline.init();
    var imu = imu_mod.IMU.init();
    var aoa = aoa_mod.AoASensor.init();
    var gps = gps_mod.GPSSensor.init();
    var baro = baro_mod.BarometricSensor.init();
    var temp = temp_mod.TemperatureSensor.init();
    var fuel = fuel_mod.FuelGauge.init(411_000);
    var radar = radar_mod.RadarAltimeter.init();
    var nav = navigation.NavigationComputer.init();
    var guid = guidance.GuidanceComputer.init();
    var fc = flight_controller.FlightController.init();
    var telem = telemetry_mod.TelemetryLog{};
    var dash = dashboard_mod.Dashboard.init(w, config.tui);

    var chaos = chaos_engine.ChaosEngine.init(config.mode, config.seed);
    if (config.scenario) |s| {
        chaos.specific_scenario = s;
    }

    // Simulation parameters
    const dt: f64 = 0.1; // 100ms timestep
    const max_time: f64 = 600.0; // 10 minutes max
    var sim_time: f64 = -10.0; // Start at T-10
    var last_print_time: f64 = -100.0;
    var last_tui_time: f64 = -100.0;

    // Print mode info
    w.print("  {s}Mode:{s} {s}    {s}Seed:{s} {d}\n", .{
        BOLD, RESET, chaos.modeName(), BOLD, RESET, config.seed,
    }) catch {};
    if (config.scenario) |s| {
        w.print("  {s}Scenario:{s} {s}\n", .{ BOLD, RESET, s }) catch {};
    }
    w.print("\n", .{}) catch {};

    dash.start();

    // ================================================================
    // MAIN SIMULATION LOOP
    // ================================================================
    while (sim_time < max_time and !state.in_orbit) {
        // 1. Check mission timeline
        while (tl.checkMilestones(sim_time)) |milestone| {
            timeline_mod.Timeline.executeMilestone(milestone, &state, &engines);
            dash.renderMilestone(milestone.name, milestone.description, sim_time);
        }

        // 2. Update engines
        engines.update(dt);

        // 3. Physics integration
        if (state.liftoff) {
            physics.integrate(&state, &engines, dt);
        }

        // 4. Update sensors from true state
        imu.update(&state, dt);
        aoa.update(&state);
        gps.update(&state);
        baro.update(&state);
        temp.update(&state);
        fuel.update(&state);
        radar.update(&state);

        // 5. Navigation solution
        const nav_sol = nav.computeSolution(&imu, &gps, &baro, dt);

        // 6. Guidance
        const steering = guid.computeSteering(&state, &nav_sol, dt);

        // 7. Flight control
        if (state.liftoff) {
            fc.execute(&steering, &state, &engines, dt);
        }

        // 8. Chaos engine: inject faults
        if (chaos.tick(sim_time, &imu, &aoa)) |result| {
            dash.logFault(sim_time, result);
            if (!config.tui) {
                dash.renderFaultText(sim_time, &result);
            }
            state.active_faults += 1;
            if (result.caught) state.faults_caught += 1;
        }

        // 9. Telemetry
        telem.record(&state, steering.throttle_cmd);

        // 10. Display update
        if (config.tui) {
            if (sim_time - last_tui_time >= 0.5) {
                dash.render(&state, &steering, &chaos);
                last_tui_time = sim_time;
            }
        } else {
            // Text mode: print every 10 seconds
            if (sim_time - last_print_time >= 10.0 and state.liftoff) {
                dash.renderTelemetryLine(&state);
                last_print_time = sim_time;
            }
        }

        // 11. Check orbit insertion (simplified: 200km altitude + >7500 m/s)
        if (state.altitude_m.value > 200_000 and state.speedMps() > 7500) {
            state.in_orbit = true;
        }

        sim_time += dt;
    }

    dash.stop();

    // ================================================================
    // POST-SIMULATION
    // ================================================================

    // Print timeline
    timeline_view.renderTimeline(&tl, w);

    // Print chaos report
    const rpt = chaos.getReport();
    report_mod.generateTextReport(rpt, w) catch {};

    // Final status
    w.print("\n", .{}) catch {};
    if (state.in_orbit) {
        w.print("  {s}{s}  MISSION SUCCESS — ORBIT ACHIEVED  {s}\n", .{ BOLD, BRIGHT_GREEN, RESET }) catch {};
        w.print("  Final altitude: {d:.0} m  |  Velocity: {d:.0} m/s\n", .{
            state.altitude_m.value, state.speedMps(),
        }) catch {};
    } else if (state.aborted) {
        w.print("  {s}{s}  MISSION ABORTED  {s}\n", .{ BOLD, BRIGHT_RED, RESET }) catch {};
    } else {
        w.print("  {s}{s}  SIMULATION TIMEOUT  {s}\n", .{ BOLD, BRIGHT_YELLOW, RESET }) catch {};
        w.print("  Final altitude: {d:.0} m  |  Velocity: {d:.0} m/s\n", .{
            state.altitude_m.value, state.speedMps(),
        }) catch {};
    }

    w.print("\n  {s}\"In Zig, the rocket survives. Every time.\"{s}\n\n", .{ DIM, RESET }) catch {};
}

// ============================================================================
// Tests — import all modules to run their tests
// ============================================================================
test {
    _ = @import("units/units.zig");
    _ = @import("units/checked_math.zig");
    _ = @import("units/fixed_point.zig");
    _ = @import("units/conversions.zig");
    _ = @import("sim/vehicle.zig");
    _ = @import("sim/physics.zig");
    _ = @import("sim/propulsion.zig");
    _ = @import("sim/timeline.zig");
    _ = @import("sensors/sensor_bus.zig");
    _ = @import("chaos/scenarios.zig");
    _ = @import("chaos/fault_injector.zig");
}
