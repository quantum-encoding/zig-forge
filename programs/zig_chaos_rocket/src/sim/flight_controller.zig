// flight_controller.zig — Flight control system: PID loops, actuator commands
//
// Includes authority limiting — the architectural fix for the MCAS problem.
// No single input can command more than max_authority degrees of correction
// per control cycle.

const std = @import("std");
const units = @import("../units/units.zig");
const vehicle_mod = @import("vehicle.zig");
const guidance = @import("guidance.zig");
const propulsion = @import("propulsion.zig");

pub const PIDController = struct {
    kp: f64,
    ki: f64,
    kd: f64,
    integral: f64 = 0,
    prev_error: f64 = 0,
    output_min: f64,
    output_max: f64,

    pub fn init(kp: f64, ki: f64, kd: f64, out_min: f64, out_max: f64) PIDController {
        return .{
            .kp = kp,
            .ki = ki,
            .kd = kd,
            .output_min = out_min,
            .output_max = out_max,
        };
    }

    pub fn compute(self: *PIDController, error_val: f64, dt: f64) f64 {
        if (dt <= 0) return 0;

        self.integral += error_val * dt;
        // Anti-windup
        self.integral = std.math.clamp(self.integral, self.output_min * 10, self.output_max * 10);

        const derivative = (error_val - self.prev_error) / dt;
        self.prev_error = error_val;

        const output = self.kp * error_val + self.ki * self.integral + self.kd * derivative;
        return std.math.clamp(output, self.output_min, self.output_max);
    }

    pub fn reset(self: *PIDController) void {
        self.integral = 0;
        self.prev_error = 0;
    }
};

pub const FlightController = struct {
    pitch_pid: PIDController,
    yaw_pid: PIDController,

    pub fn init() FlightController {
        return .{
            .pitch_pid = PIDController.init(0.5, 0.01, 0.1, -5.0, 5.0),
            .yaw_pid = PIDController.init(0.3, 0.005, 0.05, -3.0, 3.0),
        };
    }

    /// Execute control loop: take steering command, produce actuator commands
    pub fn execute(
        self: *FlightController,
        cmd: *const guidance.SteeringCommand,
        state: *vehicle_mod.VehicleState,
        engines: *propulsion.EngineCluster,
        dt: f64,
    ) void {
        // Current pitch from attitude quaternion
        const current_pitch_deg = state.attitude.getPitch() * (180.0 / std.math.pi);
        const pitch_error = cmd.pitch_cmd_deg - current_pitch_deg;

        // PID control
        const pitch_correction = self.pitch_pid.compute(pitch_error, dt);

        // Apply attitude correction via quaternion rotation
        const correction_rad = pitch_correction * (std.math.pi / 180.0) * dt;
        const dq = units.Quaternion.fromAxisAngle(0, 1, 0, correction_rad);
        state.attitude = state.attitude.multiply(dq).normalizeQuat();

        // Apply throttle command
        engines.activeEngine().setThrottle(cmd.throttle_cmd);
    }
};
