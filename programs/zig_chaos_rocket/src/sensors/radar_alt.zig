// radar_alt.zig — Radar altimeter (landing scenario)
//
// MARS POLAR LANDER — December 3, 1999 — $165M lost
//
// The radar altimeter sensed spurious noise spikes during landing leg
// deployment. The software interpreted a brief spike as "ground contact"
// and shut down the descent engines at 40 meters altitude. The lander
// crashed.
//
// Prevention: rate-of-change validation. A valid touchdown reading must
// persist for multiple consecutive samples, not just spike once.

const sensor_bus = @import("sensor_bus.zig");
const vehicle_mod = @import("../sim/vehicle.zig");

pub const RadarAltimeter = struct {
    altitude: sensor_bus.TripleRedundantSensor(f64),
    touchdown_confirmations: u8 = 0,
    required_confirmations: u8 = 5, // Need 5 consecutive low readings
    touchdown_threshold_m: f64 = 2.0,
    last_reading: f64 = 0,

    pub fn init() RadarAltimeter {
        return .{
            .altitude = sensor_bus.TripleRedundantSensor(f64).init(1.0),
        };
    }

    pub fn update(self: *RadarAltimeter, state: *const vehicle_mod.VehicleState) void {
        self.altitude.setAllReadings(state.altitude_m.value);

        // Touchdown validation: require consecutive low readings
        if (state.altitude_m.value <= self.touchdown_threshold_m) {
            if (self.touchdown_confirmations < 255) {
                self.touchdown_confirmations += 1;
            }
        } else {
            self.touchdown_confirmations = 0;
        }

        self.last_reading = state.altitude_m.value;
    }

    pub fn isTouchdownConfirmed(self: *const RadarAltimeter) bool {
        return self.touchdown_confirmations >= self.required_confirmations;
    }

    pub fn getAltitude(self: *const RadarAltimeter) ?f64 {
        return switch (self.altitude.vote()) {
            .consensus => |v| v,
            .majority => |m| m.value,
            .disagreement, .insufficient => null,
        };
    }
};
