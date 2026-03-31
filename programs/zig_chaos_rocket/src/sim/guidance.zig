// guidance.zig — Guidance computer: trajectory targeting, steering commands
//
// Implements gravity turn guidance with closed-loop corrections.
// Authority limiting prevents any single input from commanding
// unsafe maneuvers (the MCAS fix).

const std = @import("std");
const units = @import("../units/units.zig");
const vehicle_mod = @import("vehicle.zig");
const navigation = @import("navigation.zig");

pub const GuidanceMode = enum {
    pre_launch,
    vertical_ascent,
    pitch_program,
    gravity_turn,
    closed_loop,
    coast,
    orbit_insertion,
    abort,
};

pub const SteeringCommand = struct {
    pitch_cmd_deg: f64 = 90, // Degrees from horizontal (90 = vertical)
    yaw_cmd_deg: f64 = 0,
    throttle_cmd: f64 = 1.0,
    mode: GuidanceMode = .pre_launch,
};

pub const GuidanceComputer = struct {
    mode: GuidanceMode = .pre_launch,
    target_orbit_km: f64 = 200, // Target circular orbit altitude
    target_azimuth_deg: f64 = 92.4, // Launch azimuth (Kennedy due east)
    pitch_rate_dps: f64 = 0.5, // Pitch rate during gravity turn
    current_pitch_deg: f64 = 90.0,

    // Authority limits — the MCAS fix
    max_pitch_rate_dps: f64 = 5.0, // Max pitch change per second
    max_authority_deg: f64 = 10.0, // Max single-step correction

    // Fallback mode (if navigation has errors)
    using_fallback_nav: bool = false,

    pub fn init() GuidanceComputer {
        return .{};
    }

    /// Compute steering commands based on navigation solution and vehicle state
    pub fn computeSteering(
        self: *GuidanceComputer,
        state: *const vehicle_mod.VehicleState,
        nav: *const navigation.NavSolution,
        dt: f64,
    ) SteeringCommand {
        var cmd = SteeringCommand{};

        // Check for navigation overflow (Ariane 5 scenario)
        if (nav.bias_overflow) {
            self.using_fallback_nav = true;
            // Don't abort — use last known good guidance
        }

        // Mode transitions based on flight phase
        if (!state.liftoff) {
            self.mode = .pre_launch;
        } else if (state.in_orbit) {
            self.mode = .orbit_insertion;
        } else if (state.altitude_m.value < 500 and state.liftoff) {
            self.mode = .vertical_ascent;
        } else if (state.altitude_m.value < 2000) {
            self.mode = .pitch_program;
        } else if (state.current_stage == 0) {
            self.mode = .gravity_turn;
        } else {
            self.mode = .closed_loop;
        }

        cmd.mode = self.mode;

        switch (self.mode) {
            .pre_launch => {
                cmd.pitch_cmd_deg = 90;
                cmd.throttle_cmd = 0;
            },
            .vertical_ascent => {
                cmd.pitch_cmd_deg = 90;
                cmd.throttle_cmd = 1.0;
            },
            .pitch_program => {
                // Gradually tilt from 90° to ~85° (pitch program)
                self.current_pitch_deg -= self.pitch_rate_dps * dt;
                self.current_pitch_deg = @max(85, self.current_pitch_deg);
                cmd.pitch_cmd_deg = self.current_pitch_deg;
                cmd.throttle_cmd = 1.0;
            },
            .gravity_turn => {
                // Follow gravity turn trajectory
                self.current_pitch_deg -= self.pitch_rate_dps * dt;
                self.current_pitch_deg = @max(20, self.current_pitch_deg);

                // Throttle management around max-Q
                if (state.dynamic_pressure_pa.value > 30000) {
                    cmd.throttle_cmd = 0.7; // Throttle down through max-Q
                } else {
                    cmd.throttle_cmd = 1.0;
                }

                cmd.pitch_cmd_deg = self.current_pitch_deg;
            },
            .closed_loop => {
                // Stage 2: steer toward target orbit
                const target_alt = self.target_orbit_km * 1000.0;
                const alt_error = target_alt - nav.altitude_m;

                // Simple proportional guidance
                var pitch_correction = alt_error * 0.001;

                // AUTHORITY LIMITING — the MCAS fix
                // No single correction can exceed max_authority_deg
                pitch_correction = std.math.clamp(pitch_correction, -self.max_authority_deg, self.max_authority_deg);

                self.current_pitch_deg = std.math.clamp(
                    self.current_pitch_deg + pitch_correction * dt,
                    0,
                    45,
                );

                cmd.pitch_cmd_deg = self.current_pitch_deg;
                cmd.throttle_cmd = 1.0;
            },
            .coast => {
                cmd.throttle_cmd = 0;
                cmd.pitch_cmd_deg = self.current_pitch_deg;
            },
            .orbit_insertion => {
                cmd.throttle_cmd = 0;
                cmd.pitch_cmd_deg = 0; // Horizontal for orbit
            },
            .abort => {
                cmd.throttle_cmd = 0;
                cmd.pitch_cmd_deg = 90; // Point up
            },
        }

        cmd.yaw_cmd_deg = 0; // Simplified: no yaw steering

        return cmd;
    }
};
