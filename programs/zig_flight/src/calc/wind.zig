//! Wind calculations — headwind/crosswind components and wind correction angle.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");
const math = std.math;

pub const WindResult = struct {
    headwind_kts: f32,
    crosswind_kts: f32,
    correction_deg: f32,
};

/// Compute headwind and crosswind components.
/// runway_heading: magnetic heading of the runway (degrees)
/// wind_dir: wind direction "from" (degrees)
/// wind_speed: wind speed (knots)
pub fn windComponents(runway_heading: f32, wind_dir: f32, wind_speed: f32) WindResult {
    const angle = degreesToRadians(wind_dir - runway_heading);
    return .{
        .headwind_kts = wind_speed * @cos(angle),
        .crosswind_kts = wind_speed * @sin(angle),
        .correction_deg = 0, // Set by windCorrectionAngle if needed
    };
}

/// Compute wind correction angle (WCA) for a desired ground track.
/// track: desired ground track (degrees)
/// tas: true airspeed (knots)
/// wind_dir: wind direction "from" (degrees)
/// wind_speed: wind speed (knots)
/// Returns: correction angle in degrees (positive = right correction)
pub fn windCorrectionAngle(track: f32, tas: f32, wind_dir: f32, wind_speed: f32) f32 {
    if (tas <= 0) return 0;

    // sin(WCA) = (Vw / TAS) * sin(wind_from_dir - track)
    // Positive WCA = crab right (into wind from the right)
    const relative_wind = degreesToRadians(wind_dir - track);
    const sin_wca = (wind_speed / tas) * @sin(relative_wind);

    // Clamp to valid asin range
    const clamped = @max(-1.0, @min(1.0, sin_wca));
    return radiansToDegrees(math.asin(clamped));
}

/// Compute groundspeed given TAS, wind, and track.
pub fn groundspeed(track: f32, tas: f32, wind_dir: f32, wind_speed: f32) f32 {
    if (tas <= 0) return 0;

    const wca = windCorrectionAngle(track, tas, wind_dir, wind_speed);
    const heading = track + wca;
    const wind_angle = degreesToRadians(heading - wind_dir);

    // GS = TAS * cos(WCA) + wind_speed * cos(wind_angle)
    return tas * @cos(degreesToRadians(wca)) + wind_speed * @cos(wind_angle);
}

fn degreesToRadians(deg: f32) f32 {
    return deg * (math.pi / 180.0);
}

fn radiansToDegrees(rad: f32) f32 {
    return rad * (180.0 / math.pi);
}

// ============================================================================
// Tests
// ============================================================================

test "windComponents direct headwind" {
    // Wind straight down the runway
    const r = windComponents(360, 360, 20);
    try std.testing.expect(r.headwind_kts > 19.9 and r.headwind_kts < 20.1);
    try std.testing.expect(@abs(r.crosswind_kts) < 0.1);
}

test "windComponents direct tailwind" {
    const r = windComponents(360, 180, 20);
    try std.testing.expect(r.headwind_kts < -19.9 and r.headwind_kts > -20.1);
    try std.testing.expect(@abs(r.crosswind_kts) < 0.1);
}

test "windComponents 90 degree crosswind" {
    const r = windComponents(360, 90, 20);
    try std.testing.expect(@abs(r.headwind_kts) < 0.1);
    try std.testing.expect(@abs(r.crosswind_kts) > 19.9);
}

test "windComponents 45 degree" {
    const r = windComponents(0, 45, 20);
    // cos(45) ≈ 0.707, sin(45) ≈ 0.707
    const expected = 20.0 * 0.7071;
    try std.testing.expect(@abs(r.headwind_kts - expected) < 0.1);
    try std.testing.expect(@abs(r.crosswind_kts - expected) < 0.1);
}

test "windCorrectionAngle no wind" {
    const wca = windCorrectionAngle(360, 250, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), wca);
}

test "windCorrectionAngle zero TAS" {
    const wca = windCorrectionAngle(360, 0, 270, 20);
    try std.testing.expectEqual(@as(f32, 0), wca);
}

test "windCorrectionAngle crosswind" {
    // 90-degree crosswind from the right
    const wca = windCorrectionAngle(360, 250, 90, 25);
    // Should require a right correction (positive)
    try std.testing.expect(wca > 0);
    try std.testing.expect(wca < 15); // Reasonable range
}
