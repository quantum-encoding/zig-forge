// aoa.zig — Angle of Attack sensor (Boeing MCAS scenario)
//
// Triple-redundant AoA measurement. The 737 MAX had only TWO sensors
// and MCAS read from only ONE. We require 2-of-3 agreement.

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");

pub const AoASensor = struct {
    sensor: sensor_bus.TripleRedundantSensor(f64),

    pub fn init() AoASensor {
        return .{
            .sensor = sensor_bus.TripleRedundantSensor(f64).init(2.0), // 2° tolerance
        };
    }

    pub fn update(self: *AoASensor, state: *const vehicle_mod.VehicleState) void {
        // True AoA derived from velocity vector vs body axis
        const speed = state.speedMps();
        var aoa: f64 = 0;
        if (speed > 1.0) {
            const pitch = state.attitude.getPitch();
            const flight_path_angle = @import("std").math.atan2(state.velocity.z.value, state.velocity.x.value);
            aoa = pitch - flight_path_angle;
        }
        self.sensor.setAllReadings(aoa * (180.0 / @import("std").math.pi));
    }

    pub fn getAoA(self: *const AoASensor) ?f64 {
        return switch (self.sensor.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }
};
