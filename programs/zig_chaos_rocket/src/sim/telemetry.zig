// telemetry.zig — Telemetry stream: downlink formatting, data encoding

const std = @import("std");
const units = @import("../units/units.zig");
const vehicle_mod = @import("vehicle.zig");

pub const TelemetryFrame = struct {
    met_ticks: u64,
    altitude_m: f64,
    velocity_mps: f64,
    acceleration_mps2: f64,
    downrange_m: f64,
    mass_kg: f64,
    mach: f64,
    dynamic_pressure_pa: f64,
    stage: u8,
    throttle_pct: f64,
    status_flags: u16,

    pub const STATUS_LIFTOFF: u16 = 0x0001;
    pub const STATUS_MECO: u16 = 0x0002;
    pub const STATUS_IN_ORBIT: u16 = 0x0004;
    pub const STATUS_ABORT: u16 = 0x0008;
    pub const STATUS_FAULT: u16 = 0x0010;
};

pub const TelemetryLog = struct {
    frames: [2048]?TelemetryFrame = [_]?TelemetryFrame{null} ** 2048,
    count: usize = 0,

    pub fn record(self: *TelemetryLog, state: *const vehicle_mod.VehicleState, throttle: f64) void {
        if (self.count >= 2048) return;

        var flags: u16 = 0;
        if (state.liftoff) flags |= TelemetryFrame.STATUS_LIFTOFF;
        if (state.meco) flags |= TelemetryFrame.STATUS_MECO;
        if (state.in_orbit) flags |= TelemetryFrame.STATUS_IN_ORBIT;
        if (state.aborted) flags |= TelemetryFrame.STATUS_ABORT;
        if (state.active_faults > 0) flags |= TelemetryFrame.STATUS_FAULT;

        self.frames[self.count] = .{
            .met_ticks = state.met_ticks,
            .altitude_m = state.altitude_m.value,
            .velocity_mps = state.speedMps(),
            .acceleration_mps2 = state.acceleration.magnitude(),
            .downrange_m = state.downrange_m.value,
            .mass_kg = state.totalMass().value,
            .mach = state.mach,
            .dynamic_pressure_pa = state.dynamic_pressure_pa.value,
            .stage = state.current_stage,
            .throttle_pct = throttle * 100.0,
            .status_flags = flags,
        };
        self.count += 1;
    }
};
