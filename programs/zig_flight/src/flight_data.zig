//! Flight data structures.
//!
//! Fixed-size struct containing all flight parameters from X-Plane 12.
//! All defaults are safe values. Updates are dispatched via FieldMapping switch.
//! No heap allocation in the update path.

const std = @import("std");
const registry_mod = @import("dataref_registry.zig");
const FieldMapping = registry_mod.FieldMapping;
const DatarefRegistry = registry_mod.DatarefRegistry;
const protocol = @import("protocol.zig");
const density_calc = @import("calc/density_alt.zig");
const wind_calc = @import("calc/wind.zig");
const fuel_calc = @import("calc/fuel.zig");

pub const FlightData = struct {
    // Attitude
    pitch_deg: f32 = 0,
    roll_deg: f32 = 0,
    heading_mag_deg: f32 = 0,
    slip_deg: f32 = 0,

    // Air data
    airspeed_kts: f32 = 0,
    altitude_ft: f32 = 0,
    vsi_fpm: f32 = 0,
    radio_alt_ft: f32 = 0,
    barometer_inhg: f32 = 29.92,
    oat_c: f32 = 15.0,
    airspeed_trend: f32 = 0,

    // Navigation
    latitude: f64 = 0,
    longitude: f64 = 0,
    groundspeed_kts: f32 = 0,
    ground_track_deg: f32 = 0,
    wind_dir_deg: f32 = 0,
    wind_speed_kts: f32 = 0,
    nav1_dme_nm: f32 = 0,
    nav1_hdef_dots: f32 = 0,
    nav1_vdef_dots: f32 = 0,
    gps_dme_nm: f32 = 0,
    gps_bearing_deg: f32 = 0,

    // Engine (first engine for now — arrays in Phase 2)
    n1_percent: f32 = 0,
    n2_percent: f32 = 0,
    itt_deg_c: f32 = 0,
    oil_psi: f32 = 0,
    oil_temp_c: f32 = 0,
    fuel_flow_kgs: f32 = 0,

    // Fuel
    fuel_quantity: f32 = 0,
    fuel_used_kg: f32 = 0,
    fuel_total_kg: f32 = 0,

    // Autopilot
    ap_alt_ft: f32 = 0,
    ap_hdg_deg: f32 = 0,
    ap_speed_kts: f32 = 0,
    ap_vsi_fpm: f32 = 0,
    ap_state: u32 = 0,
    autothrottle_on: bool = false,

    // Derived (computed by calculators in Phase 2, not from datarefs)
    density_alt_ft: f32 = 0,
    wind_correction_deg: f32 = 0,
    crosswind_kts: f32 = 0,
    headwind_kts: f32 = 0,
    fuel_endurance_hrs: f32 = 0,
    fuel_range_nm: f32 = 0,

    // Metadata
    update_tick: u64 = 0,
    updates_received: u64 = 0,

    /// Apply a single dataref update to the appropriate field.
    pub fn applyField(self: *FlightData, field: FieldMapping, value: f64) void {
        const v: f32 = @floatCast(value);
        switch (field) {
            .airspeed_kts => self.airspeed_kts = v,
            .altitude_ft => self.altitude_ft = v,
            .vsi_fpm => self.vsi_fpm = v,
            .heading_mag_deg => self.heading_mag_deg = v,
            .pitch_deg => self.pitch_deg = v,
            .roll_deg => self.roll_deg = v,
            .slip_deg => self.slip_deg = v,
            .barometer_inhg => self.barometer_inhg = v,
            .radio_alt_ft => self.radio_alt_ft = v,
            .airspeed_trend => self.airspeed_trend = v,
            .n1_percent => self.n1_percent = v,
            .n2_percent => self.n2_percent = v,
            .itt_deg_c => self.itt_deg_c = v,
            .oil_psi => self.oil_psi = v,
            .oil_temp_c => self.oil_temp_c = v,
            .fuel_flow_kgs => self.fuel_flow_kgs = v,
            .nav1_dme_nm => self.nav1_dme_nm = v,
            .nav1_hdef_dots => self.nav1_hdef_dots = v,
            .nav1_vdef_dots => self.nav1_vdef_dots = v,
            .gps_dme_nm => self.gps_dme_nm = v,
            .gps_bearing_deg => self.gps_bearing_deg = v,
            .latitude => self.latitude = value, // Keep f64 precision
            .longitude => self.longitude = value,
            .groundspeed_kts => self.groundspeed_kts = v,
            .ground_track_deg => self.ground_track_deg = v,
            .wind_dir_deg => self.wind_dir_deg = v,
            .wind_speed_kts => self.wind_speed_kts = v,
            .fuel_quantity => self.fuel_quantity = v,
            .fuel_used_kg => self.fuel_used_kg = v,
            .fuel_total_kg => self.fuel_total_kg = v,
            .ap_alt_ft => self.ap_alt_ft = v,
            .ap_hdg_deg => self.ap_hdg_deg = v,
            .ap_speed_kts => self.ap_speed_kts = v,
            .ap_vsi_fpm => self.ap_vsi_fpm = v,
            .ap_state => self.ap_state = if (value >= 0) @intFromFloat(value) else 0,
            .autothrottle_on => self.autothrottle_on = value != 0.0,
            .unknown => {},
        }
    }

    /// Apply a batch of updates from a WebSocket message.
    /// After applying raw dataref values, recomputes all derived fields.
    pub fn applyBatch(
        self: *FlightData,
        batch: *const protocol.UpdateBatch,
        reg: *const DatarefRegistry,
    ) void {
        for (0..batch.count) |i| {
            const update = batch.updates[i];
            if (reg.lookupField(update.id)) |field| {
                self.applyField(field, update.value);
            }
        }
        self.updates_received += batch.count;
        self.update_tick += 1;

        // Recompute derived fields from latest raw values
        self.computeDerived();
    }

    /// Recompute all derived fields from current raw data.
    /// Pure calculations, zero allocation.
    pub fn computeDerived(self: *FlightData) void {
        // Density altitude from pressure altitude and OAT
        // Use barometric altitude as proxy for pressure altitude
        self.density_alt_ft = density_calc.densityAltitude(self.altitude_ft, self.oat_c);

        // Wind components relative to current heading
        const wind = wind_calc.windComponents(self.heading_mag_deg, self.wind_dir_deg, self.wind_speed_kts);
        self.headwind_kts = wind.headwind_kts;
        self.crosswind_kts = wind.crosswind_kts;

        // Wind correction angle for current ground track
        self.wind_correction_deg = wind_calc.windCorrectionAngle(
            self.ground_track_deg,
            self.airspeed_kts,
            self.wind_dir_deg,
            self.wind_speed_kts,
        );

        // Fuel endurance and range
        self.fuel_endurance_hrs = fuel_calc.endurance(self.fuel_total_kg, self.fuel_flow_kgs);
        self.fuel_range_nm = fuel_calc.range(self.fuel_total_kg, self.fuel_flow_kgs, self.groundspeed_kts);
    }

    /// Print a summary of current flight data.
    pub fn printSummary(self: *const FlightData, writer: anytype) !void {
        try writer.print(
            \\--- Flight Data (tick {d}, {d} updates) ---
            \\  IAS: {d:.1} kts   ALT: {d:.0} ft   HDG: {d:.1}M
            \\  VS:  {d:.0} fpm   RA:  {d:.0} ft   BARO: {d:.2} inHg
            \\  PITCH: {d:.1}     ROLL: {d:.1}      SLIP: {d:.1}
            \\  GS: {d:.1} kts    TRK: {d:.1}
            \\  LAT: {d:.6}  LON: {d:.6}
            \\  N1: {d:.1}%  N2: {d:.1}%  ITT: {d:.0}C  FF: {d:.3} kg/s
            \\  FUEL: {d:.0} kg   WIND: {d:.0}/{d:.0}
            \\  AP: ALT {d:.0}  HDG {d:.0}  SPD {d:.0}  VS {d:.0}
            \\  --- Derived ---
            \\  DA: {d:.0} ft   HW: {d:.1} kts   XW: {d:.1} kts   WCA: {d:.1}
            \\  ENDUR: {d:.1} hrs   RANGE: {d:.0} NM
            \\
        , .{
            self.update_tick,      self.updates_received,
            self.airspeed_kts,     self.altitude_ft,      self.heading_mag_deg,
            self.vsi_fpm,          self.radio_alt_ft,      self.barometer_inhg,
            self.pitch_deg,        self.roll_deg,          self.slip_deg,
            self.groundspeed_kts,  self.ground_track_deg,
            self.latitude,         self.longitude,
            self.n1_percent,       self.n2_percent,        self.itt_deg_c, self.fuel_flow_kgs,
            self.fuel_total_kg,    self.wind_dir_deg,      self.wind_speed_kts,
            self.ap_alt_ft,        self.ap_hdg_deg,        self.ap_speed_kts, self.ap_vsi_fpm,
            self.density_alt_ft,   self.headwind_kts,      self.crosswind_kts, self.wind_correction_deg,
            self.fuel_endurance_hrs, self.fuel_range_nm,
        });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FlightData default values" {
    const fd = FlightData{};
    try std.testing.expectEqual(@as(f32, 29.92), fd.barometer_inhg);
    try std.testing.expectEqual(@as(f32, 0), fd.airspeed_kts);
    try std.testing.expectEqual(@as(f64, 0), fd.latitude);
    try std.testing.expectEqual(@as(u64, 0), fd.update_tick);
    try std.testing.expect(!fd.autothrottle_on);
}

test "FlightData applyField scalar" {
    var fd = FlightData{};

    fd.applyField(.airspeed_kts, 250.5);
    try std.testing.expectEqual(@as(f32, 250.5), fd.airspeed_kts);

    fd.applyField(.altitude_ft, 35000);
    try std.testing.expectEqual(@as(f32, 35000), fd.altitude_ft);

    fd.applyField(.vsi_fpm, -500);
    try std.testing.expectEqual(@as(f32, -500), fd.vsi_fpm);

    fd.applyField(.heading_mag_deg, 275.3);
    try std.testing.expect(fd.heading_mag_deg > 275.2 and fd.heading_mag_deg < 275.4);
}

test "FlightData applyField lat/lon f64 precision" {
    var fd = FlightData{};

    fd.applyField(.latitude, 51.477928123456);
    try std.testing.expect(fd.latitude > 51.477928 and fd.latitude < 51.477929);

    fd.applyField(.longitude, -0.001545678901);
    try std.testing.expect(fd.longitude < -0.001545 and fd.longitude > -0.001546);
}

test "FlightData applyField special types" {
    var fd = FlightData{};

    fd.applyField(.ap_state, 42.0);
    try std.testing.expectEqual(@as(u32, 42), fd.ap_state);

    fd.applyField(.autothrottle_on, 1.0);
    try std.testing.expect(fd.autothrottle_on);

    fd.applyField(.autothrottle_on, 0.0);
    try std.testing.expect(!fd.autothrottle_on);
}

test "FlightData applyField unknown" {
    var fd = FlightData{};
    // Should not crash
    fd.applyField(.unknown, 999.0);
    try std.testing.expectEqual(@as(f32, 0), fd.airspeed_kts);
}

test "FlightData applyBatch" {
    var fd = FlightData{};
    var reg = DatarefRegistry.init();

    reg.addEntry(100, "airspeed", .airspeed_kts);
    reg.addEntry(200, "altitude", .altitude_ft);
    reg.addEntry(300, "heading", .heading_mag_deg);

    var batch = protocol.UpdateBatch{};
    batch.updates[0] = .{ .id = 100, .value = 280.0 };
    batch.updates[1] = .{ .id = 200, .value = 35000.0 };
    batch.updates[2] = .{ .id = 300, .value = 275.0 };
    batch.updates[3] = .{ .id = 999, .value = 0.0 }; // unknown ID, should be skipped
    batch.count = 4;

    fd.applyBatch(&batch, &reg);

    try std.testing.expectEqual(@as(f32, 280.0), fd.airspeed_kts);
    try std.testing.expectEqual(@as(f32, 35000.0), fd.altitude_ft);
    try std.testing.expectEqual(@as(f32, 275.0), fd.heading_mag_deg);
    try std.testing.expectEqual(@as(u64, 1), fd.update_tick);
    try std.testing.expectEqual(@as(u64, 4), fd.updates_received);
}
