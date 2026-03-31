// physics.zig — Flight dynamics: thrust, drag, gravity, atmosphere model
//
// Simplified but physically correct rocket dynamics.
// Real gravity-turn ascent, real staging, real orbital insertion.

const std = @import("std");
const units = @import("../units/units.zig");
const vehicle_mod = @import("vehicle.zig");
const propulsion = @import("propulsion.zig");

// ============================================================================
// Physical constants
// ============================================================================
pub const EARTH_RADIUS_M: f64 = 6_371_000.0;
pub const EARTH_MU: f64 = 3.986004418e14; // Standard gravitational parameter (m³/s²)
pub const G0: f64 = 9.80665; // Standard gravity (m/s²)

// Sea-level atmospheric constants
pub const SEA_LEVEL_PRESSURE: f64 = 101_325.0; // Pa
pub const SEA_LEVEL_DENSITY: f64 = 1.225; // kg/m³
pub const SEA_LEVEL_TEMPERATURE: f64 = 288.15; // K
pub const SCALE_HEIGHT: f64 = 8_500.0; // m (atmospheric scale height)
pub const GAMMA_AIR: f64 = 1.4; // Heat capacity ratio
pub const R_AIR: f64 = 287.05; // Specific gas constant for air (J/(kg·K))

// Vehicle aerodynamic properties (Falcon 9-like)
pub const CROSS_SECTION_AREA: f64 = 10.52; // m² (3.66m diameter)
pub const CD_SUBSONIC: f64 = 0.3; // Drag coefficient (subsonic)
pub const CD_TRANSONIC: f64 = 0.5; // Drag coefficient (transonic, Mach 0.8-1.2)
pub const CD_SUPERSONIC: f64 = 0.2; // Drag coefficient (supersonic)

/// Gravity acceleration at altitude (inverse square law)
pub fn gravityAtAltitude(altitude_m: f64) f64 {
    const r = EARTH_RADIUS_M + altitude_m;
    return EARTH_MU / (r * r);
}

/// Atmospheric density using exponential model
pub fn atmosphericDensity(altitude_m: f64) f64 {
    if (altitude_m < 0) return SEA_LEVEL_DENSITY;
    if (altitude_m > 150_000) return 0; // Essentially vacuum above 150km
    return SEA_LEVEL_DENSITY * @exp(-altitude_m / SCALE_HEIGHT);
}

/// Atmospheric pressure
pub fn atmosphericPressure(altitude_m: f64) f64 {
    if (altitude_m < 0) return SEA_LEVEL_PRESSURE;
    if (altitude_m > 150_000) return 0;
    return SEA_LEVEL_PRESSURE * @exp(-altitude_m / SCALE_HEIGHT);
}

/// Temperature at altitude (simplified lapse rate model)
pub fn atmosphericTemperature(altitude_m: f64) f64 {
    if (altitude_m < 11_000) {
        // Troposphere: -6.5 K/km lapse rate
        return SEA_LEVEL_TEMPERATURE - 6.5e-3 * altitude_m;
    } else if (altitude_m < 25_000) {
        // Tropopause: constant temperature
        return 216.65;
    } else if (altitude_m < 47_000) {
        // Stratosphere: +1 K/km
        return 216.65 + 1.0e-3 * (altitude_m - 25_000);
    } else {
        return 270.65; // Simplification above stratosphere
    }
}

/// Speed of sound at altitude
pub fn speedOfSound(altitude_m: f64) f64 {
    const temp = atmosphericTemperature(altitude_m);
    return @sqrt(GAMMA_AIR * R_AIR * temp);
}

/// Drag coefficient as function of Mach number
pub fn dragCoefficient(mach: f64) f64 {
    if (mach < 0.8) return CD_SUBSONIC;
    if (mach < 1.2) {
        // Transonic drag rise
        const t = (mach - 0.8) / 0.4;
        return CD_SUBSONIC + (CD_TRANSONIC - CD_SUBSONIC) * t;
    }
    // Supersonic: decreasing Cd
    return CD_SUPERSONIC + (CD_TRANSONIC - CD_SUPERSONIC) / (1.0 + (mach - 1.2) * 2.0);
}

/// Compute all aerodynamic forces
pub fn computeDrag(speed_mps: f64, altitude_m: f64) f64 {
    const rho = atmosphericDensity(altitude_m);
    const sos = speedOfSound(altitude_m);
    const mach = if (sos > 1.0) speed_mps / sos else 0;
    const cd = dragCoefficient(mach);
    // Drag = 0.5 * rho * v² * Cd * A
    return 0.5 * rho * speed_mps * speed_mps * cd * CROSS_SECTION_AREA;
}

/// Compute dynamic pressure (Q)
pub fn dynamicPressure(speed_mps: f64, altitude_m: f64) f64 {
    const rho = atmosphericDensity(altitude_m);
    return 0.5 * rho * speed_mps * speed_mps;
}

/// Integrate vehicle state forward by dt seconds using semi-implicit Euler
pub fn integrate(state: *vehicle_mod.VehicleState, engine: *const propulsion.EngineCluster, dt: f64) void {
    const alt = state.altitude_m.value;
    const speed = state.velocity.magnitude();

    // Gravity (downward = negative Z in ENU)
    const g = gravityAtAltitude(alt);

    // Get thrust from engine cluster
    const thrust_info = engine.currentThrust(alt);
    const thrust_n = thrust_info.thrust_n;
    const mdot = thrust_info.mass_flow_kgs;

    // Pitch angle from attitude quaternion
    const pitch = state.attitude.getPitch();

    // Thrust direction (along vehicle axis, which is pitched from vertical)
    var thrust_x: f64 = 0;
    var thrust_z: f64 = 0;
    if (state.liftoff and thrust_n > 0) {
        // After liftoff, thrust along vehicle axis
        thrust_x = thrust_n * @cos(pitch); // Horizontal (downrange)
        thrust_z = thrust_n * @sin(pitch); // Vertical
        if (alt < 100 and !state.stage_separated[0]) {
            // Before pitch program, thrust is purely vertical
            thrust_x = 0;
            thrust_z = thrust_n;
        }
    }

    // Drag (opposing velocity)
    const drag = computeDrag(speed, alt);
    var drag_x: f64 = 0;
    var drag_z: f64 = 0;
    if (speed > 0.1) {
        const vx = state.velocity.x.value;
        const vz = state.velocity.z.value;
        drag_x = -drag * vx / speed;
        drag_z = -drag * vz / speed;
    }

    // Total mass
    const mass = state.totalMass().value;
    if (mass < 1.0) return; // Safety: avoid division by zero

    // Accelerations (F = ma)
    const ax = (thrust_x + drag_x) / mass;
    const az = (thrust_z + drag_z) / mass - g;

    state.acceleration = units.Vector3(units.MeterPerSecSq).init(ax, 0, az);

    // Semi-implicit Euler: update velocity first, then position
    state.velocity = units.Vector3(units.MeterPerSec).init(
        state.velocity.x.value + ax * dt,
        0,
        state.velocity.z.value + az * dt,
    );

    state.position = units.Vector3(units.Meter).init(
        state.position.x.value + state.velocity.x.value * dt,
        0,
        state.position.z.value + state.velocity.z.value * dt,
    );

    // Consume propellant
    if (thrust_n > 0 and state.propellant_mass_kg.value > 0) {
        state.propellant_mass_kg.value -= mdot * dt;
        if (state.propellant_mass_kg.value < 0) {
            state.propellant_mass_kg.value = 0;
        }
    }

    // Derive flight parameters
    state.altitude_m.value = @max(0, state.position.z.value);
    state.downrange_m.value = @abs(state.position.x.value);

    const sos = speedOfSound(alt);
    state.mach = if (sos > 1.0) speed / sos else 0;
    state.dynamic_pressure_pa.value = dynamicPressure(speed, alt);

    // Update MET
    const dt_ticks: u64 = @intFromFloat(dt * @as(f64, @floatFromInt(state.ticks_per_second)));
    state.met_ticks += dt_ticks;
}

test "gravity varies with altitude" {
    const g_surface = gravityAtAltitude(0);
    const g_200km = gravityAtAltitude(200_000);
    try std.testing.expectApproxEqAbs(9.82, g_surface, 0.01);
    try std.testing.expect(g_200km < g_surface);
    try std.testing.expect(g_200km > 9.0);
}

test "atmosphere model" {
    const rho_0 = atmosphericDensity(0);
    const rho_100km = atmosphericDensity(100_000);
    try std.testing.expectApproxEqAbs(1.225, rho_0, 0.001);
    try std.testing.expect(rho_100km < 0.001);
}

test "dynamic pressure at max-Q" {
    // At ~12 km altitude, ~350 m/s with exponential atmosphere model
    const q = dynamicPressure(350, 12000);
    try std.testing.expect(q > 5000);
    try std.testing.expect(q < 50000);
}
