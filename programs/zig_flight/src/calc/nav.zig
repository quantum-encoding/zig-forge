//! Navigation calculations — great circle distance, bearing, ETA.
//! All functions are pure: no allocation, no side effects.
//! Uses f64 for lat/lon to preserve precision over long distances.

const std = @import("std");
const math = std.math;

const EARTH_RADIUS_NM: f64 = 3440.065; // Mean radius in nautical miles

/// Great circle distance between two points using the Haversine formula.
/// lat/lon in decimal degrees.
/// Returns: distance in nautical miles.
pub fn greatCircleDistance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const dlat = degreesToRadians(lat2 - lat1);
    const dlon = degreesToRadians(lon2 - lon1);

    const lat1_rad = degreesToRadians(lat1);
    const lat2_rad = degreesToRadians(lat2);

    const sin_dlat = @sin(dlat / 2.0);
    const sin_dlon = @sin(dlon / 2.0);

    const a = sin_dlat * sin_dlat + @cos(lat1_rad) * @cos(lat2_rad) * sin_dlon * sin_dlon;
    const c = 2.0 * math.atan2(@sqrt(a), @sqrt(1.0 - a));

    return EARTH_RADIUS_NM * c;
}

/// Initial bearing (forward azimuth) from point 1 to point 2.
/// Returns: bearing in degrees (0-360).
pub fn initialBearing(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const lat1_rad = degreesToRadians(lat1);
    const lat2_rad = degreesToRadians(lat2);
    const dlon = degreesToRadians(lon2 - lon1);

    const y = @sin(dlon) * @cos(lat2_rad);
    const x = @cos(lat1_rad) * @sin(lat2_rad) - @sin(lat1_rad) * @cos(lat2_rad) * @cos(dlon);

    var bearing = radiansToDegrees(math.atan2(y, x));
    // Normalize to 0-360
    bearing = @mod(bearing + 360.0, 360.0);
    return bearing;
}

/// Estimated time of arrival.
/// distance_nm: remaining distance in nautical miles
/// groundspeed_kts: groundspeed in knots
/// Returns: time in hours
pub fn eta(distance_nm: f32, groundspeed_kts: f32) f32 {
    if (groundspeed_kts <= 0) return 0;
    if (distance_nm <= 0) return 0;
    return distance_nm / groundspeed_kts;
}

/// ETA in minutes.
pub fn etaMinutes(distance_nm: f32, groundspeed_kts: f32) f32 {
    return eta(distance_nm, groundspeed_kts) * 60.0;
}

/// Cross-track distance from a great circle path.
/// lat/lon: current position
/// lat1/lon1: start of path
/// lat2/lon2: end of path
/// Returns: cross-track distance in NM (positive = right of path, negative = left).
pub fn crossTrackDistance(lat: f64, lon: f64, lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const d13 = greatCircleDistance(lat1, lon1, lat, lon) / EARTH_RADIUS_NM; // angular distance
    const bearing_13 = degreesToRadians(initialBearing(lat1, lon1, lat, lon));
    const bearing_12 = degreesToRadians(initialBearing(lat1, lon1, lat2, lon2));

    // Cross-track: asin(sin(d13) * sin(bearing_13 - bearing_12))
    const xtd = math.asin(@sin(d13) * @sin(bearing_13 - bearing_12));

    return xtd * EARTH_RADIUS_NM;
}

/// Along-track distance — how far along the path from start.
/// Returns: distance in NM from lat1/lon1 along the great circle toward lat2/lon2.
pub fn alongTrackDistance(lat: f64, lon: f64, lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const d13 = greatCircleDistance(lat1, lon1, lat, lon) / EARTH_RADIUS_NM;
    const xtd = crossTrackDistance(lat, lon, lat1, lon1, lat2, lon2) / EARTH_RADIUS_NM;

    const atd = math.acos(@cos(d13) / @cos(xtd));
    return atd * EARTH_RADIUS_NM;
}

fn degreesToRadians(deg: f64) f64 {
    return deg * (math.pi / 180.0);
}

fn radiansToDegrees(rad: f64) f64 {
    return rad * (180.0 / math.pi);
}

// ============================================================================
// Tests
// ============================================================================

test "greatCircleDistance JFK to LAX" {
    // JFK: 40.6413° N, 73.7781° W → LAX: 33.9425° N, 118.4081° W
    // Known distance: ~2145 NM
    const d = greatCircleDistance(40.6413, -73.7781, 33.9425, -118.4081);
    try std.testing.expect(d > 2100 and d < 2200);
}

test "greatCircleDistance same point" {
    const d = greatCircleDistance(51.5074, -0.1278, 51.5074, -0.1278);
    try std.testing.expect(d < 0.01);
}

test "greatCircleDistance London to Paris" {
    // ~188 NM
    const d = greatCircleDistance(51.5074, -0.1278, 48.8566, 2.3522);
    try std.testing.expect(d > 175 and d < 200);
}

test "initialBearing north" {
    // Due north: same longitude, higher latitude
    const b = initialBearing(0, 0, 10, 0);
    try std.testing.expect(@abs(b - 0.0) < 1.0 or @abs(b - 360.0) < 1.0);
}

test "initialBearing east" {
    // Due east at equator
    const b = initialBearing(0, 0, 0, 10);
    try std.testing.expect(@abs(b - 90.0) < 1.0);
}

test "initialBearing south" {
    const b = initialBearing(10, 0, 0, 0);
    try std.testing.expect(@abs(b - 180.0) < 1.0);
}

test "eta basic" {
    // 500 NM at 250 kts = 2 hours
    const t = eta(500, 250);
    try std.testing.expect(@abs(t - 2.0) < 0.01);
}

test "eta zero speed" {
    const t = eta(500, 0);
    try std.testing.expectEqual(@as(f32, 0), t);
}

test "etaMinutes" {
    const t = etaMinutes(250, 250);
    try std.testing.expect(@abs(t - 60.0) < 0.1);
}

test "crossTrackDistance on path" {
    // Point on the equator, path along the equator
    const xtd = crossTrackDistance(0, 5, 0, 0, 0, 10);
    try std.testing.expect(@abs(xtd) < 1.0);
}

test "crossTrackDistance off path" {
    // Point 1 degree north of equator, path along equator
    const xtd = crossTrackDistance(1, 5, 0, 0, 0, 10);
    // ~60 NM per degree of latitude
    try std.testing.expect(@abs(xtd) > 50 and @abs(xtd) < 70);
}
