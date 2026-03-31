// temperature.zig — Thermal sensors (engine, skin, propellant)

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");
const physics = @import("../sim/physics.zig");

pub const TemperatureSensor = struct {
    engine_temp: sensor_bus.TripleRedundantSensor(f64),
    skin_temp: sensor_bus.TripleRedundantSensor(f64),

    pub fn init() TemperatureSensor {
        return .{
            .engine_temp = sensor_bus.TripleRedundantSensor(f64).init(50.0), // 50K tolerance
            .skin_temp = sensor_bus.TripleRedundantSensor(f64).init(20.0), // 20K tolerance
        };
    }

    pub fn update(self: *TemperatureSensor, state: *const vehicle_mod.VehicleState) void {
        // Engine temperature: combustion chamber ~3500K when running
        const engine_t: f64 = if (state.stage_ignited[state.current_stage]) 3500.0 else 300.0;
        self.engine_temp.setAllReadings(engine_t);

        // Skin temperature from aerodynamic heating
        const ambient = physics.atmosphericTemperature(state.altitude_m.value);
        const speed = state.speedMps();
        // Stagnation temperature rise: T_s = T_ambient * (1 + 0.2 * M²)
        const mach = state.mach;
        const skin_t = ambient * (1.0 + 0.2 * mach * mach);
        _ = speed;
        self.skin_temp.setAllReadings(skin_t);
    }

    pub fn getEngineTemp(self: *const TemperatureSensor) ?f64 {
        return switch (self.engine_temp.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }

    pub fn getSkinTemp(self: *const TemperatureSensor) ?f64 {
        return switch (self.skin_temp.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }
};
