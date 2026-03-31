// vehicle.zig — Rocket vehicle state
//
// All physical quantities use the comptime unit type system.
// Mission elapsed time is an integer tick counter (Patriot lesson).

const units = @import("../units/units.zig");

pub const MAX_STAGES = 4;

pub const VehicleState = struct {
    // Position (ENU: East-North-Up from launch site)
    position: units.Vector3(units.Meter) = units.Vector3(units.Meter).zero(),
    velocity: units.Vector3(units.MeterPerSec) = units.Vector3(units.MeterPerSec).zero(),
    acceleration: units.Vector3(units.MeterPerSecSq) = units.Vector3(units.MeterPerSecSq).zero(),

    // Attitude
    attitude: units.Quaternion = units.Quaternion.identity(),
    angular_rate: units.Vector3(units.RadPerSec) = units.Vector3(units.RadPerSec).zero(),

    // Mass
    dry_mass_kg: units.Mass,
    propellant_mass_kg: units.Mass,

    // Flight parameters (derived each tick)
    altitude_m: units.Distance = .{ .value = 0 },
    mach: f64 = 0,
    dynamic_pressure_pa: units.Pressure = .{ .value = 0 },
    downrange_m: units.Distance = .{ .value = 0 },

    // Mission clock — INTEGER TICKS, not floating point (Patriot lesson)
    met_ticks: u64 = 0,
    ticks_per_second: u64 = 1000, // 1ms resolution

    // Stage
    current_stage: u8 = 0,
    stage_ignited: [MAX_STAGES]bool = .{ false, false, false, false },
    stage_separated: [MAX_STAGES]bool = .{ false, false, false, false },

    // Status flags
    liftoff: bool = false,
    meco: bool = false, // Main Engine Cut-Off
    in_orbit: bool = false,
    aborted: bool = false,

    // Fault status
    active_faults: u32 = 0,
    faults_caught: u32 = 0,

    pub fn totalMass(self: *const VehicleState) units.Mass {
        return .{ .value = self.dry_mass_kg.value + self.propellant_mass_kg.value };
    }

    pub fn metSeconds(self: *const VehicleState) f64 {
        // DISPLAY ONLY — never use for control logic
        return @as(f64, @floatFromInt(self.met_ticks)) / @as(f64, @floatFromInt(self.ticks_per_second));
    }

    pub fn metFormatted(self: *const VehicleState) MetFormatted {
        return .{ .state = self };
    }

    pub fn speedMps(self: *const VehicleState) f64 {
        return self.velocity.magnitude();
    }
};

pub const MetFormatted = struct {
    state: *const VehicleState,

    pub fn format(self: MetFormatted, comptime _: []const u8, _: @import("std").fmt.FormatOptions, writer: anytype) !void {
        const total_ms = (self.state.met_ticks * 1000) / self.state.ticks_per_second;
        const secs = total_ms / 1000;
        const ms = total_ms % 1000;
        const mins = secs / 60;
        const s = secs % 60;
        if (self.state.met_ticks == 0) {
            try writer.print("T+00:00.000", .{});
        } else {
            try writer.print("T+{d:0>2}:{d:0>2}.{d:0>3}", .{ mins, s, ms });
        }
    }
};

/// Default vehicle configuration: modeled loosely on Falcon 9
pub fn defaultFalcon9() VehicleState {
    return .{
        // Stage 1 dry mass ~22,200 kg, Stage 2 dry mass ~4,000 kg
        // Fairing ~1,800 kg, Payload ~5,000 kg
        .dry_mass_kg = .{ .value = 33_000 },
        // ~411,000 kg propellant (RP-1/LOX)
        .propellant_mass_kg = .{ .value = 411_000 },
    };
}
