// navigation.zig — Inertial Navigation System (INS): sensor fusion, state estimation
//
// This module includes the Ariane 5 horizontal bias computation with proper
// overflow checks. The original Ada code converted a 64-bit float to a 16-bit
// integer without range checking. We use checked_math.floatToI16() which
// returns error.Overflow instead of crashing.

const std = @import("std");
const units = @import("../units/units.zig");
const checked_math = @import("../units/checked_math.zig");
const vehicle_mod = @import("vehicle.zig");
const imu_mod = @import("../sensors/imu.zig");
const gps_mod = @import("../sensors/gps.zig");
const baro_mod = @import("../sensors/barometric.zig");

pub const NavSolution = struct {
    altitude_m: f64 = 0,
    velocity_mps: f64 = 0,
    acceleration_mps2: f64 = 0,
    horizontal_bias_i16: ?i16 = null, // Ariane 5 variable
    bias_overflow: bool = false,
    valid: bool = false,
};

pub const NavigationComputer = struct {
    last_solution: NavSolution = .{},
    imu_integrated_alt: f64 = 0,
    imu_integrated_vel: f64 = 0,

    pub fn init() NavigationComputer {
        return .{};
    }

    /// Compute navigation solution by fusing IMU, GPS, and barometric data.
    /// Includes the Ariane 5 horizontal bias conversion with overflow checks.
    pub fn computeSolution(
        self: *NavigationComputer,
        imu: *const imu_mod.IMU,
        gps: *const gps_mod.GPSSensor,
        baro: *const baro_mod.BarometricSensor,
        dt: f64,
    ) NavSolution {
        var sol = NavSolution{};

        // Get IMU data (voted)
        const accel = imu.getAcceleration();
        if (accel.valid) {
            self.imu_integrated_vel += accel.z * dt;
            self.imu_integrated_alt += self.imu_integrated_vel * dt;
        }

        // Fuse with GPS (if available)
        const gps_alt = gps.getAltitude();
        const gps_vel = gps.getVelocity();

        // Fuse with barometric (if available)
        const baro_alt = baro.getAltitude();

        // Weighted fusion: GPS > Baro > IMU for altitude
        if (gps_alt) |ga| {
            if (baro_alt) |ba| {
                sol.altitude_m = ga * 0.7 + ba * 0.3;
            } else {
                sol.altitude_m = ga;
            }
        } else if (baro_alt) |ba| {
            sol.altitude_m = ba * 0.6 + self.imu_integrated_alt * 0.4;
        } else {
            sol.altitude_m = self.imu_integrated_alt;
        }

        sol.velocity_mps = gps_vel orelse self.imu_integrated_vel;
        sol.acceleration_mps2 = if (accel.valid) accel.z else 0;

        // ARIANE 5 SCENARIO: Convert horizontal bias to 16-bit integer
        // This is the exact computation that destroyed Flight 501.
        // The original code did an unchecked 64→16 bit conversion.
        // Zig forces us to handle the error.
        const hbias = imu.getHorizontalBias();
        sol.horizontal_bias_i16 = checked_math.floatToI16(hbias) catch |err| blk: {
            switch (err) {
                error.Overflow => {
                    sol.bias_overflow = true;
                    // CRITICAL DIFFERENCE from Ariane 5:
                    // Instead of shutting down the navigation computer,
                    // we flag the overflow and continue with fallback data.
                    // The guidance computer will see bias_overflow=true and
                    // switch to GPS-only navigation.
                    break :blk null;
                },
            }
        };

        sol.valid = true;
        self.last_solution = sol;
        return sol;
    }
};
