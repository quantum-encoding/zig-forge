//! Vertical navigation calculations — TOD, descent rate, vertical deviation.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");
const math = std.math;

/// Top of descent distance from the target.
/// Returns distance in nautical miles from the target where descent should begin.
/// current_alt_ft: current altitude
/// target_alt_ft: target altitude
/// descent_angle_deg: descent angle (typically 3.0 for ILS)
pub fn topOfDescent(current_alt_ft: f32, target_alt_ft: f32, descent_angle_deg: f32) f32 {
    if (descent_angle_deg <= 0) return 0;

    const alt_diff = current_alt_ft - target_alt_ft;
    if (alt_diff <= 0) return 0;

    // distance = altitude_diff / tan(angle) converted to NM
    // 1 NM = 6076.12 ft
    const angle_rad = descent_angle_deg * (math.pi / 180.0);
    const tan_angle = @tan(angle_rad);
    if (tan_angle <= 0) return 0;

    return alt_diff / (tan_angle * 6076.12);
}

/// Required descent rate for a given glide path angle and groundspeed.
/// Returns vertical speed in feet per minute (negative = descending).
/// groundspeed_kts: groundspeed in knots
/// glide_angle_deg: descent angle in degrees (positive value)
pub fn requiredDescentRate(groundspeed_kts: f32, glide_angle_deg: f32) f32 {
    if (groundspeed_kts <= 0 or glide_angle_deg <= 0) return 0;

    // Rule of thumb: VS = GS * 5.3 * angle (for small angles near 3 deg)
    // Exact: VS = GS(nm/min) * tan(angle) * 6076.12
    const gs_nm_per_min = groundspeed_kts / 60.0;
    const angle_rad = glide_angle_deg * (math.pi / 180.0);

    return -(gs_nm_per_min * @tan(angle_rad) * 6076.12);
}

/// Quick descent rate estimate using the "multiply by 5" rule.
/// Returns approximate descent rate in fpm for a 3-degree path.
pub fn descentRateRule(groundspeed_kts: f32) f32 {
    return -(groundspeed_kts * 5.3);
}

/// Vertical deviation from desired glide path.
/// Returns deviation in feet (positive = above path, negative = below).
/// current_alt: current altitude in feet
/// target_alt: target altitude at the reference point in feet
/// distance_nm: distance to the reference point in NM
/// angle_deg: desired descent angle in degrees
pub fn verticalDeviation(current_alt: f32, target_alt: f32, distance_nm: f32, angle_deg: f32) f32 {
    if (distance_nm <= 0 or angle_deg <= 0) return 0;

    // Desired altitude at current position
    const angle_rad = angle_deg * (math.pi / 180.0);
    const desired_alt = target_alt + (distance_nm * 6076.12 * @tan(angle_rad));

    return current_alt - desired_alt;
}

/// Convert vertical deviation to ILS-style dots.
/// Standard: 1 dot = 0.35 degrees of angular deviation.
/// Returns deviation in dots (positive = above, negative = below).
pub fn deviationToDots(deviation_ft: f32, distance_nm: f32) f32 {
    if (distance_nm <= 0) return 0;

    // Angular deviation in degrees
    const distance_ft = distance_nm * 6076.12;
    const angle_dev_deg = std.math.atan(@abs(deviation_ft) / distance_ft) * (180.0 / math.pi);

    const dots = angle_dev_deg / 0.35;
    return if (deviation_ft >= 0) dots else -dots;
}

// ============================================================================
// Tests
// ============================================================================

test "topOfDescent 3 degree path from FL350 to sea level" {
    // ~56 NM is typical for FL350 on a 3-degree path
    const tod = topOfDescent(35000, 0, 3.0);
    try std.testing.expect(tod > 50 and tod < 120);
}

test "topOfDescent same altitude" {
    const tod = topOfDescent(5000, 5000, 3.0);
    try std.testing.expectEqual(@as(f32, 0), tod);
}

test "topOfDescent below target" {
    const tod = topOfDescent(3000, 5000, 3.0);
    try std.testing.expectEqual(@as(f32, 0), tod);
}

test "requiredDescentRate 3 degrees at 140 kts GS" {
    // ~740 fpm is typical for 140 kts on a 3-degree glideslope
    const vs = requiredDescentRate(140, 3.0);
    try std.testing.expect(vs < -700 and vs > -800);
}

test "requiredDescentRate 3 degrees at 250 kts" {
    const vs = requiredDescentRate(250, 3.0);
    // Higher speed = steeper descent rate
    try std.testing.expect(vs < -1200 and vs > -1500);
}

test "descentRateRule 140 kts" {
    const vs = descentRateRule(140);
    // 140 * 5.3 = 742
    try std.testing.expect(@abs(vs + 742) < 1);
}

test "verticalDeviation on path" {
    // If we're exactly on a 3-degree path, deviation should be ~0
    const alt_on_path = 0 + (10.0 * 6076.12 * @tan(3.0 * (math.pi / 180.0)));
    const dev = verticalDeviation(alt_on_path, 0, 10.0, 3.0);
    try std.testing.expect(@abs(dev) < 1.0);
}

test "verticalDeviation above path" {
    const dev = verticalDeviation(5000, 0, 10.0, 3.0);
    // 5000 ft at 10 NM on 3-degree path: should be above
    try std.testing.expect(dev > 0);
}

test "verticalDeviation below path" {
    const dev = verticalDeviation(1000, 0, 10.0, 3.0);
    // 1000 ft at 10 NM: should be well below a 3-degree path
    try std.testing.expect(dev < 0);
}
