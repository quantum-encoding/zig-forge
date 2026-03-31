// fuel_gauge.zig — Fuel level and flow rate sensors

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");

pub const FuelGauge = struct {
    level: sensor_bus.TripleRedundantSensor(f64),
    flow_rate: sensor_bus.TripleRedundantSensor(f64),
    initial_mass: f64,

    pub fn init(initial_propellant_kg: f64) FuelGauge {
        return .{
            .level = sensor_bus.TripleRedundantSensor(f64).init(0.5), // 0.5% tolerance
            .flow_rate = sensor_bus.TripleRedundantSensor(f64).init(5.0), // 5 kg/s tolerance
            .initial_mass = initial_propellant_kg,
        };
    }

    pub fn update(self: *FuelGauge, state: *const vehicle_mod.VehicleState) void {
        const pct = if (self.initial_mass > 0)
            (state.propellant_mass_kg.value / self.initial_mass) * 100.0
        else
            0;
        self.level.setAllReadings(pct);
    }

    pub fn getFuelPercent(self: *const FuelGauge) ?f64 {
        return switch (self.level.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }
};
