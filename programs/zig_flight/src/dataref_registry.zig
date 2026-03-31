//! Dataref name→ID resolution and subscription management.
//!
//! Pre-defined arrays of X-Plane 12 dataref names for each MFD page.
//! At startup, resolves names to session-specific numeric IDs via REST API.
//! Provides fast lookup from ID to FlightData field for the 10Hz update path.

const std = @import("std");
const XPlaneClient = @import("xplane_client.zig").XPlaneClient;

// ============================================================================
// Pre-defined dataref name arrays
// ============================================================================

pub const PFD_DATAREFS = [_][]const u8{
    "sim/cockpit2/gauges/indicators/airspeed_kts_pilot",
    "sim/cockpit2/gauges/indicators/altitude_ft_pilot",
    "sim/cockpit2/gauges/indicators/vvi_fpm_pilot",
    "sim/cockpit2/gauges/indicators/heading_AHARS_deg_mag_pilot",
    "sim/cockpit2/gauges/indicators/pitch_AHARS_deg_pilot",
    "sim/cockpit2/gauges/indicators/roll_AHARS_deg_pilot",
    "sim/cockpit2/gauges/indicators/slip_deg",
    "sim/cockpit/misc/barometer_setting",
    "sim/cockpit2/gauges/indicators/radio_altimeter_height_ft_pilot",
    "sim/cockpit2/gauges/indicators/airspeed_acceleration",
};

pub const ENGINE_DATAREFS = [_][]const u8{
    "sim/cockpit2/engine/indicators/N1_percent",
    "sim/cockpit2/engine/indicators/N2_percent",
    "sim/cockpit2/engine/indicators/ITT_deg_C",
    "sim/cockpit2/engine/indicators/oil_pressure_psi",
    "sim/cockpit2/engine/indicators/oil_temperature_deg_C",
    "sim/cockpit2/engine/indicators/fuel_flow_kg_sec",
};

pub const NAV_DATAREFS = [_][]const u8{
    "sim/cockpit2/radios/indicators/nav1_dme_distance_nm",
    "sim/cockpit2/radios/indicators/nav1_hdef_dots_pilot",
    "sim/cockpit2/radios/indicators/nav1_vdef_dots_pilot",
    "sim/cockpit2/radios/indicators/gps_dme_distance_nm",
    "sim/cockpit2/radios/indicators/gps_bearing_deg_mag",
    "sim/flightmodel/position/latitude",
    "sim/flightmodel/position/longitude",
    "sim/flightmodel/position/groundspeed",
    "sim/cockpit2/gauges/indicators/ground_track_mag_pilot",
    "sim/weather/wind_direction_degt",
    "sim/weather/wind_speed_kt",
};

pub const FUEL_DATAREFS = [_][]const u8{
    "sim/cockpit2/fuel/fuel_quantity",
    "sim/cockpit2/fuel/fuel_totalizer_sum_kg",
    "sim/flightmodel/weight/m_fuel_total",
};

pub const AUTOPILOT_DATAREFS = [_][]const u8{
    "sim/cockpit2/autopilot/altitude_dial_ft",
    "sim/cockpit2/autopilot/heading_dial_deg_mag_pilot",
    "sim/cockpit2/autopilot/airspeed_dial_kts_mach",
    "sim/cockpit2/autopilot/vvi_dial_fpm",
    "sim/cockpit2/autopilot/autopilot_state",
    "sim/cockpit2/autopilot/autothrottle_enabled",
};

// ============================================================================
// Field mapping — ordered to match the dataref arrays above
// ============================================================================

/// Which FlightData field to write for a given dataref.
/// Values are ordered to match the dataref name arrays:
///   PFD_DATAREFS[0] → airspeed_kts, [1] → altitude_ft, etc.
pub const FieldMapping = enum(u8) {
    // PFD datarefs (indices 0-9)
    airspeed_kts = 0,
    altitude_ft,
    vsi_fpm,
    heading_mag_deg,
    pitch_deg,
    roll_deg,
    slip_deg,
    barometer_inhg,
    radio_alt_ft,
    airspeed_trend,

    // Engine datarefs (indices 10-15)
    n1_percent = 10,
    n2_percent,
    itt_deg_c,
    oil_psi,
    oil_temp_c,
    fuel_flow_kgs,

    // Nav datarefs (indices 16-26)
    nav1_dme_nm = 16,
    nav1_hdef_dots,
    nav1_vdef_dots,
    gps_dme_nm,
    gps_bearing_deg,
    latitude,
    longitude,
    groundspeed_kts,
    ground_track_deg,
    wind_dir_deg,
    wind_speed_kts,

    // Fuel datarefs (indices 27-29)
    fuel_quantity = 27,
    fuel_used_kg,
    fuel_total_kg,

    // Autopilot datarefs (indices 30-35)
    ap_alt_ft = 30,
    ap_hdg_deg,
    ap_speed_kts,
    ap_vsi_fpm,
    ap_state,
    autothrottle_on,

    unknown = 255,
};

// ============================================================================
// DatarefRegistry
// ============================================================================

/// Maximum number of datarefs we track
pub const MAX_DATAREFS = 64;

/// A resolved dataref entry
pub const ResolvedDataref = struct {
    id: u64 = 0,
    name: []const u8 = "",
    field: FieldMapping = .unknown,
};

pub const DatarefRegistry = struct {
    entries: [MAX_DATAREFS]ResolvedDataref = [_]ResolvedDataref{.{}} ** MAX_DATAREFS,
    count: usize = 0,

    pub fn init() DatarefRegistry {
        return .{};
    }

    /// Resolve a set of datarefs via REST API.
    /// `base_field` is the FieldMapping for the first dataref in the set.
    pub fn resolveSet(
        self: *DatarefRegistry,
        client: *XPlaneClient,
        names: []const []const u8,
        base_field: FieldMapping,
    ) !void {
        const base = @intFromEnum(base_field);
        for (names, 0..) |name, i| {
            if (self.count >= MAX_DATAREFS) break;

            const id = client.findDatarefByName(name) catch |err| {
                std.debug.print("Warning: could not resolve '{s}': {any}\n", .{ name, err });
                continue;
            };

            self.entries[self.count] = .{
                .id = id,
                .name = name,
                .field = @enumFromInt(@as(u8, @truncate(base + i))),
            };
            self.count += 1;
        }
    }

    /// Resolve all standard dataref sets.
    pub fn resolveAll(self: *DatarefRegistry, client: *XPlaneClient) !void {
        try self.resolveSet(client, &PFD_DATAREFS, .airspeed_kts);
        try self.resolveSet(client, &ENGINE_DATAREFS, .n1_percent);
        try self.resolveSet(client, &NAV_DATAREFS, .nav1_dme_nm);
        try self.resolveSet(client, &FUEL_DATAREFS, .fuel_quantity);
        try self.resolveSet(client, &AUTOPILOT_DATAREFS, .ap_alt_ft);
    }

    /// Subscribe all resolved datarefs via WebSocket.
    pub fn subscribeAll(self: *DatarefRegistry, client: *XPlaneClient) !void {
        var ids: [MAX_DATAREFS]u64 = undefined;
        for (0..self.count) |i| {
            ids[i] = self.entries[i].id;
        }
        try client.subscribeDatarefs(ids[0..self.count]);
    }

    /// Look up the field mapping for a given X-Plane dataref ID.
    pub fn lookupField(self: *const DatarefRegistry, id: u64) ?FieldMapping {
        for (0..self.count) |i| {
            if (self.entries[i].id == id) return self.entries[i].field;
        }
        return null;
    }

    /// Look up the name for a given X-Plane dataref ID.
    pub fn lookupName(self: *const DatarefRegistry, id: u64) ?[]const u8 {
        for (0..self.count) |i| {
            if (self.entries[i].id == id) return self.entries[i].name;
        }
        return null;
    }

    /// Manually add a resolved entry (for testing or manual setup).
    pub fn addEntry(self: *DatarefRegistry, id: u64, name: []const u8, field: FieldMapping) void {
        if (self.count >= MAX_DATAREFS) return;
        self.entries[self.count] = .{ .id = id, .name = name, .field = field };
        self.count += 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DatarefRegistry init" {
    const reg = DatarefRegistry.init();
    try std.testing.expectEqual(@as(usize, 0), reg.count);
}

test "DatarefRegistry addEntry and lookup" {
    var reg = DatarefRegistry.init();

    reg.addEntry(100, "sim/cockpit2/gauges/indicators/airspeed_kts_pilot", .airspeed_kts);
    reg.addEntry(200, "sim/cockpit2/gauges/indicators/altitude_ft_pilot", .altitude_ft);
    reg.addEntry(300, "sim/cockpit2/gauges/indicators/vvi_fpm_pilot", .vsi_fpm);

    try std.testing.expectEqual(@as(usize, 3), reg.count);

    try std.testing.expectEqual(FieldMapping.airspeed_kts, reg.lookupField(100).?);
    try std.testing.expectEqual(FieldMapping.altitude_ft, reg.lookupField(200).?);
    try std.testing.expectEqual(FieldMapping.vsi_fpm, reg.lookupField(300).?);
    try std.testing.expect(reg.lookupField(999) == null);

    try std.testing.expectEqualStrings("sim/cockpit2/gauges/indicators/airspeed_kts_pilot", reg.lookupName(100).?);
    try std.testing.expect(reg.lookupName(999) == null);
}

test "FieldMapping enum ordering" {
    // Verify PFD datarefs start at 0
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(FieldMapping.airspeed_kts));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(FieldMapping.altitude_ft));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(FieldMapping.airspeed_trend));

    // Engine datarefs start at 10
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(FieldMapping.n1_percent));
    try std.testing.expectEqual(@as(u8, 15), @intFromEnum(FieldMapping.fuel_flow_kgs));

    // Nav datarefs start at 16
    try std.testing.expectEqual(@as(u8, 16), @intFromEnum(FieldMapping.nav1_dme_nm));

    // Autopilot datarefs start at 30
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(FieldMapping.ap_alt_ft));
}

test "PFD_DATAREFS count matches field range" {
    // PFD has 10 datarefs, fields 0-9
    try std.testing.expectEqual(@as(usize, 10), PFD_DATAREFS.len);
}

test "ENGINE_DATAREFS count matches field range" {
    try std.testing.expectEqual(@as(usize, 6), ENGINE_DATAREFS.len);
}

test "NAV_DATAREFS count matches field range" {
    try std.testing.expectEqual(@as(usize, 11), NAV_DATAREFS.len);
}
