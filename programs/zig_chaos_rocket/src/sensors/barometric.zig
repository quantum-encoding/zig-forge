// barometric.zig — Barometric altimeter

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");
const physics = @import("../sim/physics.zig");

pub const BarometricSensor = struct {
    pressure: sensor_bus.TripleRedundantSensor(f64),

    pub fn init() BarometricSensor {
        return .{
            .pressure = sensor_bus.TripleRedundantSensor(f64).init(100.0), // 100 Pa tolerance
        };
    }

    pub fn update(self: *BarometricSensor, state: *const vehicle_mod.VehicleState) void {
        const p = physics.atmosphericPressure(state.altitude_m.value);
        self.pressure.setAllReadings(p);
    }

    pub fn getPressure(self: *const BarometricSensor) ?f64 {
        return switch (self.pressure.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }

    /// Derive altitude from pressure reading
    pub fn getAltitude(self: *const BarometricSensor) ?f64 {
        const p = self.getPressure() orelse return null;
        if (p <= 0) return null;
        // Inverse of exponential atmosphere model
        return -physics.SCALE_HEIGHT * @log(p / physics.SEA_LEVEL_PRESSURE);
    }
};
