// propulsion.zig — Engine model: thrust curves, fuel consumption, throttle
//
// Modeled on Merlin 1D (Falcon 9 first stage) and Merlin Vacuum (second stage).
// Thrust varies with atmospheric pressure (sea level vs vacuum Isp).

const std = @import("std");
const units = @import("../units/units.zig");
const physics = @import("physics.zig");

pub const EngineState = enum {
    off,
    igniting,
    running,
    throttling_down,
    shutdown,
    failed,
};

pub const Engine = struct {
    name: []const u8,
    thrust_sea_level_n: f64, // Thrust at sea level (N)
    thrust_vacuum_n: f64, // Thrust in vacuum (N)
    isp_sea_level_s: f64, // Specific impulse at sea level (s)
    isp_vacuum_s: f64, // Specific impulse in vacuum (s)
    throttle: f64 = 1.0, // 0.0 to 1.0
    state: EngineState = .off,
    ignition_time_s: f64 = 0.5, // Time to reach full thrust
    ignition_progress: f64 = 0,

    /// Effective thrust at a given altitude
    pub fn thrustAtAltitude(self: *const Engine, altitude_m: f64) f64 {
        if (self.state != .running and self.state != .igniting) return 0;

        const pressure_ratio = physics.atmosphericPressure(altitude_m) / physics.SEA_LEVEL_PRESSURE;
        const thrust = self.thrust_sea_level_n +
            (self.thrust_vacuum_n - self.thrust_sea_level_n) * (1.0 - pressure_ratio);

        var effective = thrust * self.throttle;
        if (self.state == .igniting) {
            effective *= self.ignition_progress;
        }
        return effective;
    }

    /// Effective Isp at a given altitude
    pub fn ispAtAltitude(self: *const Engine, altitude_m: f64) f64 {
        const pressure_ratio = physics.atmosphericPressure(altitude_m) / physics.SEA_LEVEL_PRESSURE;
        return self.isp_sea_level_s + (self.isp_vacuum_s - self.isp_sea_level_s) * (1.0 - pressure_ratio);
    }

    /// Mass flow rate (kg/s) at given altitude
    pub fn massFlowRate(self: *const Engine, altitude_m: f64) f64 {
        const thrust = self.thrustAtAltitude(altitude_m);
        const isp = self.ispAtAltitude(altitude_m);
        if (isp < 1.0) return 0;
        return thrust / (isp * physics.G0);
    }

    pub fn ignite(self: *Engine) void {
        if (self.state == .off) {
            self.state = .igniting;
            self.ignition_progress = 0;
        }
    }

    pub fn shutdown(self: *Engine) void {
        self.state = .shutdown;
    }

    pub fn update(self: *Engine, dt: f64) void {
        if (self.state == .igniting) {
            self.ignition_progress += dt / self.ignition_time_s;
            if (self.ignition_progress >= 1.0) {
                self.ignition_progress = 1.0;
                self.state = .running;
            }
        }
    }

    pub fn setThrottle(self: *Engine, t: f64) void {
        self.throttle = std.math.clamp(t, 0.0, 1.0);
    }
};

pub const EngineCluster = struct {
    stage1: Engine,
    stage2: Engine,
    active_stage: u8 = 0,

    pub fn init() EngineCluster {
        return .{
            // Merlin 1D cluster (9 engines, combined)
            .stage1 = .{
                .name = "Merlin 1D x9",
                .thrust_sea_level_n = 7_607_000, // ~7.6 MN at sea level
                .thrust_vacuum_n = 8_227_000, // ~8.2 MN in vacuum
                .isp_sea_level_s = 282,
                .isp_vacuum_s = 311,
            },
            // Merlin Vacuum (1 engine)
            .stage2 = .{
                .name = "MVac",
                .thrust_sea_level_n = 0, // Can't operate at sea level (nozzle too big)
                .thrust_vacuum_n = 981_000, // ~981 kN vacuum
                .isp_sea_level_s = 0,
                .isp_vacuum_s = 348,
            },
        };
    }

    pub fn activeEngine(self: *EngineCluster) *Engine {
        return if (self.active_stage == 0) &self.stage1 else &self.stage2;
    }

    pub fn currentThrust(self: *const EngineCluster, altitude_m: f64) struct { thrust_n: f64, mass_flow_kgs: f64 } {
        const eng = if (self.active_stage == 0) &self.stage1 else &self.stage2;
        return .{
            .thrust_n = eng.thrustAtAltitude(altitude_m),
            .mass_flow_kgs = eng.massFlowRate(altitude_m),
        };
    }

    pub fn update(self: *EngineCluster, dt: f64) void {
        self.stage1.update(dt);
        self.stage2.update(dt);
    }

    pub fn igniteStage(self: *EngineCluster, stage: u8) void {
        switch (stage) {
            0 => self.stage1.ignite(),
            1 => {
                self.stage2.ignite();
                self.active_stage = 1;
            },
            else => {},
        }
    }

    pub fn shutdownStage(self: *EngineCluster, stage: u8) void {
        switch (stage) {
            0 => self.stage1.shutdown(),
            1 => self.stage2.shutdown(),
            else => {},
        }
    }
};

test "Merlin 1D thrust at sea level" {
    const cluster = EngineCluster.init();
    const info = cluster.currentThrust(0);
    // Engines are off, no thrust
    try std.testing.expectApproxEqAbs(0.0, info.thrust_n, 0.1);
}

test "engine ignition sequence" {
    var cluster = EngineCluster.init();
    cluster.stage1.ignite();
    try std.testing.expect(cluster.stage1.state == .igniting);

    // After ignition time, should be running
    var t: f64 = 0;
    while (t < 1.0) : (t += 0.01) {
        cluster.update(0.01);
    }
    try std.testing.expect(cluster.stage1.state == .running);
}
