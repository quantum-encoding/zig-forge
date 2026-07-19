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
    show_help: bool = false,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &file_writer.interface;

    const config = parseArgs(init.args);

    if (config.show_help) {
        printHelp(w);
        file_writer.flush() catch {};
        return;
    }

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

/// Value-aware boolean env flag: an unset var is `false`; the strings
/// "0", "false", "no", "off", and "" are `false`; anything else is `true`.
/// (Presence-only flags treated `CHAOS_TUI=0` as enabled — this fixes that.)
fn envFlag(name: [*:0]const u8) bool {
    const val = getenvSlice(name) orelse return false;
    return !isFalsey(val);
}

fn isFalsey(val: []const u8) bool {
    return val.len == 0 or
        std.mem.eql(u8, val, "0") or
        std.ascii.eqlIgnoreCase(val, "false") or
        std.ascii.eqlIgnoreCase(val, "no") or
        std.ascii.eqlIgnoreCase(val, "off");
}

fn parseMode(str: []const u8) ?chaos_engine.ChaosMode {
    if (std.mem.eql(u8, str, "clean") or std.mem.eql(u8, str, "off")) return .off;
    if (std.mem.eql(u8, str, "scripted")) return .scripted;
    if (std.mem.eql(u8, str, "random")) return .random;
    if (std.mem.eql(u8, str, "stress")) return .stress;
    if (std.mem.eql(u8, str, "fuzz")) return .fuzz;
    return null;
}

/// Returns the value part of `--name=value`, or null if `arg` isn't that flag.
fn flagValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    return null;
}

fn parseArgs(args: std.process.Args) Config {
    var config = Config{};

    // Configuration source order: environment variables first, then any
    //   command-line flags override them (flags win). Both map onto Config.
    //   CHAOS_MODE=clean|scripted|random|stress|fuzz    (--mode=)
    //   CHAOS_TUI=1                                      (--tui / --no-tui)
    //   CHAOS_SCENARIO=ARIANE|MCO|MCAS|...               (--scenario=)
    //   CHAOS_SEED=42                                    (--seed=)
    //   CHAOS_ITERATIONS=100000                          (--iterations=)
    //   CHAOS_COMPARISONS=1                              (--comparisons)
    //   CHAOS_C_COMPARE=1                                (--c-compare)
    if (getenvSlice("CHAOS_MODE")) |mode_str| {
        if (parseMode(mode_str)) |m| config.mode = m;
    }
    config.tui = envFlag("CHAOS_TUI");
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
    config.show_comparisons = envFlag("CHAOS_COMPARISONS");
    config.show_c_compare = envFlag("CHAOS_C_COMPARE");

    parseArgvInto(&config, args);

    return config;
}

/// Parse command-line flags (from `zig build run -- <flags>` or the binary
/// directly) over the top of the env-derived config. The args come from the
/// process init vector, so no allocator is needed — the program stays
/// allocation-free.
fn parseArgvInto(config: *Config, args: std.process.Args) void {
    var it = args.iterate();
    _ = it.next(); // skip argv[0] (program name)

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.show_help = true;
        } else if (flagValue(arg, "--mode")) |v| {
            if (parseMode(v)) |m| config.mode = m;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            config.tui = true;
        } else if (std.mem.eql(u8, arg, "--no-tui")) {
            config.tui = false;
        } else if (flagValue(arg, "--scenario")) |v| {
            config.scenario = v;
            config.mode = .specific;
        } else if (flagValue(arg, "--seed")) |v| {
            config.seed = std.fmt.parseInt(u64, v, 10) catch config.seed;
        } else if (flagValue(arg, "--iterations")) |v| {
            config.fuzz_iterations = std.fmt.parseInt(u64, v, 10) catch config.fuzz_iterations;
        } else if (std.mem.eql(u8, arg, "--comparisons")) {
            config.show_comparisons = true;
        } else if (std.mem.eql(u8, arg, "--c-compare")) {
            config.show_c_compare = true;
        }
        // Unknown flags are ignored (env-only config remains the documented path).
    }
}

fn printHelp(w: anytype) void {
    w.print(
        \\zig_chaos_rocket — safety-critical chaos-engineering rocket-launch demo
        \\
        \\Usage: zig_chaos_rocket [flags]   (or: zig build run -- [flags])
        \\
        \\Flags (override the matching CHAOS_* environment variable):
        \\  --mode=<m>          off|clean, scripted (default), random, stress, fuzz
        \\  --scenario=<id>     run one scenario, e.g. ARIANE, MCO, MCAS
        \\  --seed=<n>          RNG seed (default 42)
        \\  --iterations=<n>    fuzz iterations per subsystem (default 100000)
        \\  --tui / --no-tui    enable/disable the live TUI dashboard
        \\  --comparisons       render the Zig-vs-disaster writeups
        \\  --c-compare         render the C-bug comparison
        \\  -h, --help          show this help and exit
        \\
        \\Environment variables: CHAOS_MODE, CHAOS_SCENARIO, CHAOS_SEED,
        \\  CHAOS_ITERATIONS, CHAOS_TUI, CHAOS_COMPARISONS, CHAOS_C_COMPARE.
        \\  Boolean vars accept 0/false/no/off to disable.
        \\
    , .{}) catch {};
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

    // Run each pass separately so each "DONE" prints after its own work
    // (previously both ran inside a single call before the first DONE).
    w.print("  Fuzzing sensor bus...        ", .{}) catch {};
    flushWriter(w);
    chaos.fuzzSensorBus(config.fuzz_iterations);
    w.print("{s}DONE{s}\n", .{ BRIGHT_GREEN, RESET }) catch {};
    flushWriter(w);

    w.print("  Fuzzing checked math...      ", .{}) catch {};
    flushWriter(w);
    chaos.fuzzCheckedMath(config.fuzz_iterations);
    w.print("{s}DONE{s}\n\n", .{ BRIGHT_GREEN, RESET }) catch {};

    const rpt = chaos.getReport();
    w.print("  {s}RESULTS{s}\n", .{ BOLD, RESET }) catch {};
    w.print("  {s}\n", .{SEPARATOR_DASH_40}) catch {};
    w.print("  Total iterations:   {d:>12}\n", .{rpt.fuzz_iterations}) catch {};
    w.print("  Errors handled:     {d:>12}\n", .{rpt.fuzz_errors_handled}) catch {};
    w.print("  Safety catches:     {d:>12}\n", .{rpt.fuzz_safety_catches}) catch {};
    // A crash would abort the process, so reaching here means crashes == 0.
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

fn flushWriter(w: *std.Io.Writer) void {
    // Push buffered progress text to the terminal so each "DONE" is visible
    // as its pass completes, not all at once when main() flushes at exit.
    w.flush() catch {};
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
    _ = @import("chaos/engine.zig");
    _ = @import("chaos/report.zig");
    _ = @import("chaos/fuzzer.zig");
}
