// imu.zig — Inertial Measurement Unit: accelerometer + gyroscope
//
// Generates simulated IMU readings from true vehicle state,
// with configurable noise, bias, and fault injection points.
// The Ariane 5 horizontal bias computation lives here.

const std = @import("std");
const units = @import("../units/units.zig");
const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");

pub const IMU = struct {
    // Triple-redundant accelerometers (m/s²)
    accel_x: sensor_bus.TripleRedundantSensor(f64),
    accel_y: sensor_bus.TripleRedundantSensor(f64),
    accel_z: sensor_bus.TripleRedundantSensor(f64),

    // Triple-redundant gyroscopes (rad/s)
    gyro_x: sensor_bus.TripleRedundantSensor(f64),
    gyro_y: sensor_bus.TripleRedundantSensor(f64),
    gyro_z: sensor_bus.TripleRedundantSensor(f64),

    // Ariane 5 scenario: horizontal bias accumulator
    horizontal_bias: f64 = 0,
    horizontal_bias_rate: f64 = 0,

    pub fn init() IMU {
        return .{
            .accel_x = sensor_bus.TripleRedundantSensor(f64).init(0.5),
            .accel_y = sensor_bus.TripleRedundantSensor(f64).init(0.5),
            .accel_z = sensor_bus.TripleRedundantSensor(f64).init(0.5),
            .gyro_x = sensor_bus.TripleRedundantSensor(f64).init(0.01),
            .gyro_y = sensor_bus.TripleRedundantSensor(f64).init(0.01),
            .gyro_z = sensor_bus.TripleRedundantSensor(f64).init(0.01),
        };
    }

    /// Update IMU readings from true vehicle state
    pub fn update(self: *IMU, state: *const vehicle_mod.VehicleState, dt: f64) void {
        // Set true readings on all three sensors
        self.accel_x.setAllReadings(state.acceleration.x.value);
        self.accel_y.setAllReadings(state.acceleration.y.value);
        self.accel_z.setAllReadings(state.acceleration.z.value);

        self.gyro_x.setAllReadings(state.angular_rate.x.value);
        self.gyro_y.setAllReadings(state.angular_rate.y.value);
        self.gyro_z.setAllReadings(state.angular_rate.z.value);

        // Update horizontal bias (Ariane 5 scenario variable)
        // This accumulates based on horizontal velocity — the variable
        // that overflowed in the real Ariane 5 SRI
        self.horizontal_bias += state.velocity.x.value * dt;
        self.horizontal_bias_rate = state.velocity.x.value;
    }

    /// Get voted accelerometer reading
    pub fn getAcceleration(self: *const IMU) struct { x: f64, y: f64, z: f64, valid: bool } {
        const vx = self.accel_x.vote();
        const vz = self.accel_z.vote();

        const x = switch (vx) {
            .consensus => |v| v,
            .majority => |m| m.value,
            else => return .{ .x = 0, .y = 0, .z = 0, .valid = false },
        };
        const z = switch (vz) {
            .consensus => |v| v,
            .majority => |m| m.value,
            else => return .{ .x = 0, .y = 0, .z = 0, .valid = false },
        };

        return .{ .x = x, .y = 0, .z = z, .valid = true };
    }

    /// Get the horizontal bias value (Ariane 5 scenario)
    pub fn getHorizontalBias(self: *const IMU) f64 {
        return self.horizontal_bias;
    }
};
