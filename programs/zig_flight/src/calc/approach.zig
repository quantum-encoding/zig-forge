//! Approach calculations — ILS glide path, VNAV deviation, MDA/DH checks.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");
const math = std.math;

pub const ApproachStatus = enum {
    on_path,
    above_path,
    below_path,
    below_minima,
};

pub const ApproachInfo = struct {
    deviation_ft: f32,
    deviation_dots: f32,
    status: ApproachStatus,
    target_alt_ft: f32,
    distance_to_threshold_nm: f32,
};

/// ILS glideslope deviation.
/// current_alt_ft: aircraft altitude (MSL)
/// tdz_elev_ft: touchdown zone elevation (MSL)
/// distance_nm: distance to threshold in NM
/// glide_angle_deg: glideslope angle (typically 3.0)
/// Returns: approach info with deviation and status.
pub fn ilsDeviation(
    current_alt_ft: f32,
    tdz_elev_ft: f32,
    distance_nm: f32,
    glide_angle_deg: f32,
) ApproachInfo {
    if (distance_nm <= 0 or glide_angle_deg <= 0) {
        return .{
            .deviation_ft = 0,
            .deviation_dots = 0,
            .status = .on_path,
            .target_alt_ft = tdz_elev_ft,
            .distance_to_threshold_nm = distance_nm,
        };
    }

    const angle_rad = glide_angle_deg * (math.pi / 180.0);
    const desired_alt = tdz_elev_ft + (distance_nm * 6076.12 * @tan(angle_rad));
    const deviation = current_alt_ft - desired_alt;

    // ILS dots: 1 dot = 0.35 degrees angular deviation
    const distance_ft = distance_nm * 6076.12;
    const angle_dev = radiansToDegrees(math.atan(@abs(deviation) / distance_ft));
    const dots_magnitude = angle_dev / 0.35;
    const dots = if (deviation >= 0) dots_magnitude else -dots_magnitude;

    const status: ApproachStatus = if (@abs(dots) < 0.5)
        .on_path
    else if (deviation > 0)
        .above_path
    else
        .below_path;

    return .{
        .deviation_ft = deviation,
        .deviation_dots = dots,
        .status = status,
        .target_alt_ft = desired_alt,
        .distance_to_threshold_nm = distance_nm,
    };
}

/// Check if current altitude is at or below decision height.
/// current_alt_ft: radio altitude (AGL)
/// decision_height_ft: DH for the approach
/// Returns: true if at or below DH.
pub fn atDecisionHeight(current_alt_ft: f32, decision_height_ft: f32) bool {
    return current_alt_ft <= decision_height_ft;
}

/// Check if current altitude is at or below minimum descent altitude.
/// current_alt_msl: barometric altitude (MSL)
/// mda_ft: MDA for the approach (MSL)
/// Returns: true if at or below MDA.
pub fn atMDA(current_alt_msl: f32, mda_ft: f32) bool {
    return current_alt_msl <= mda_ft;
}

/// VASI/PAPI indication.
/// Returns number of red lights (0 = all white/too high, 4 = all red/too low).
/// Standard PAPI: 3° centered, each light ≈ 0.5° band.
pub fn papiIndication(current_alt_ft: f32, tdz_elev_ft: f32, distance_nm: f32, glide_angle_deg: f32) u8 {
    if (distance_nm <= 0) return 2; // On ground, nominal

    const info = ilsDeviation(current_alt_ft, tdz_elev_ft, distance_nm, glide_angle_deg);
    const dots = info.deviation_dots;

    // Map dots to PAPI lights
    // > +1.5 dots: all white (too high)
    // +0.5 to +1.5: 1 red 3 white
    // -0.5 to +0.5: 2 red 2 white (on path)
    // -1.5 to -0.5: 3 red 1 white
    // < -1.5: all red (too low)
    if (dots > 1.5) return 0;
    if (dots > 0.5) return 1;
    if (dots > -0.5) return 2;
    if (dots > -1.5) return 3;
    return 4;
}

/// Compute required descent angle to make a waypoint at a given altitude.
/// current_alt_ft: current altitude
/// target_alt_ft: target altitude at waypoint
/// distance_nm: distance to waypoint
/// Returns: required descent angle in degrees.
pub fn requiredAngle(current_alt_ft: f32, target_alt_ft: f32, distance_nm: f32) f32 {
    if (distance_nm <= 0) return 0;

    const alt_diff = current_alt_ft - target_alt_ft;
    if (alt_diff <= 0) return 0;

    const distance_ft = distance_nm * 6076.12;
    return radiansToDegrees(math.atan(alt_diff / distance_ft));
}

/// Distance to a given altitude on the glide path.
/// current_alt_ft: current altitude
/// target_alt_ft: altitude to reach
/// glide_angle_deg: descent angle
/// Returns: distance in NM.
pub fn distanceToAltitude(current_alt_ft: f32, target_alt_ft: f32, glide_angle_deg: f32) f32 {
    if (glide_angle_deg <= 0) return 0;

    const alt_diff = current_alt_ft - target_alt_ft;
    if (alt_diff <= 0) return 0;

    const angle_rad = glide_angle_deg * (math.pi / 180.0);
    return alt_diff / (@tan(angle_rad) * 6076.12);
}

/// Missed approach point distance from threshold.
/// For a precision approach, MAP is at DH on the glideslope.
/// tdz_elev_ft: touchdown zone elevation
/// dh_ft: decision height above ground
/// glide_angle_deg: glideslope angle
/// Returns: distance from threshold in NM.
pub fn missedApproachPoint(tdz_elev_ft: f32, dh_ft: f32, glide_angle_deg: f32) f32 {
    if (glide_angle_deg <= 0) return 0;

    // DH is AGL, so MAP altitude MSL = tdz_elev + dh
    // Distance = (DH) / (tan(angle) * 6076.12)
    _ = tdz_elev_ft;
    const angle_rad = glide_angle_deg * (math.pi / 180.0);
    return dh_ft / (@tan(angle_rad) * 6076.12);
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

test "ilsDeviation on glideslope" {
    // At 3 degrees, 5 NM from threshold (TDZ at 100 ft)
    // Expected alt ≈ 100 + 5 * 6076.12 * tan(3°) ≈ 100 + 1591 ≈ 1691
    const info = ilsDeviation(1691, 100, 5.0, 3.0);
    try std.testing.expect(@abs(info.deviation_ft) < 5.0);
    try std.testing.expect(@abs(info.deviation_dots) < 0.5);
    try std.testing.expect(info.status == .on_path);
}

test "ilsDeviation above glideslope" {
    const info = ilsDeviation(2500, 100, 5.0, 3.0);
    try std.testing.expect(info.deviation_ft > 0);
    try std.testing.expect(info.deviation_dots > 0);
    try std.testing.expect(info.status == .above_path);
}

test "ilsDeviation below glideslope" {
    const info = ilsDeviation(800, 100, 5.0, 3.0);
    try std.testing.expect(info.deviation_ft < 0);
    try std.testing.expect(info.deviation_dots < 0);
    try std.testing.expect(info.status == .below_path);
}

test "atDecisionHeight" {
    try std.testing.expect(atDecisionHeight(200, 200) == true);
    try std.testing.expect(atDecisionHeight(150, 200) == true);
    try std.testing.expect(atDecisionHeight(250, 200) == false);
}

test "atMDA" {
    try std.testing.expect(atMDA(500, 500) == true);
    try std.testing.expect(atMDA(400, 500) == true);
    try std.testing.expect(atMDA(600, 500) == false);
}

test "papiIndication on path" {
    // On a 3° path at 5 NM, target alt ≈ 1691
    const lights = papiIndication(1691, 100, 5.0, 3.0);
    try std.testing.expectEqual(@as(u8, 2), lights);
}

test "papiIndication too high" {
    const lights = papiIndication(3000, 100, 5.0, 3.0);
    try std.testing.expect(lights <= 1);
}

test "papiIndication too low" {
    const lights = papiIndication(500, 100, 5.0, 3.0);
    try std.testing.expect(lights >= 3);
}

test "requiredAngle" {
    // 5000 ft above target at 10 NM → angle ≈ 4.7°
    const angle = requiredAngle(5000, 0, 10);
    try std.testing.expect(angle > 4.0 and angle < 6.0);
}

test "distanceToAltitude 3 degree path" {
    // From 3000 ft to sea level on 3° path
    const d = distanceToAltitude(3000, 0, 3.0);
    // Should be ~9.4 NM
    try std.testing.expect(d > 8 and d < 11);
}

test "missedApproachPoint" {
    // DH = 200 ft, 3° path → MAP ~0.6 NM from threshold
    const map = missedApproachPoint(100, 200, 3.0);
    try std.testing.expect(map > 0.5 and map < 0.7);
}
