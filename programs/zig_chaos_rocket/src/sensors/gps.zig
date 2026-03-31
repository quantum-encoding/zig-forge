// gps.zig — GPS receiver simulation

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");

pub const GPSSensor = struct {
    altitude: sensor_bus.TripleRedundantSensor(f64),
    velocity: sensor_bus.TripleRedundantSensor(f64),
    available: bool = true,

    pub fn init() GPSSensor {
        return .{
            .altitude = sensor_bus.TripleRedundantSensor(f64).init(10.0), // 10m tolerance
            .velocity = sensor_bus.TripleRedundantSensor(f64).init(0.5), // 0.5 m/s tolerance
        };
    }

    pub fn update(self: *GPSSensor, state: *const vehicle_mod.VehicleState) void {
        if (!self.available) return;
        self.altitude.setAllReadings(state.altitude_m.value);
        self.velocity.setAllReadings(state.speedMps());
    }

    pub fn getAltitude(self: *const GPSSensor) ?f64 {
        return switch (self.altitude.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }

    pub fn getVelocity(self: *const GPSSensor) ?f64 {
        return switch (self.velocity.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }
};
