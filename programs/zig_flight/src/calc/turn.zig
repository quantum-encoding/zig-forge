//! Turn calculations — standard rate turns, bank angle, turn radius.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");
const math = std.math;

pub const TurnResult = struct {
    rate_deg_per_sec: f32,
    bank_deg: f32,
    radius_nm: f32,
    radius_ft: f32,
};

/// Compute turn parameters.
/// speed_kts: true airspeed (knots)
/// bank_deg: bank angle in degrees. If 0, computes standard rate (3 deg/sec) bank.
pub fn turnRate(speed_kts: f32, bank_deg: f32) TurnResult {
    if (speed_kts <= 0) return .{
        .rate_deg_per_sec = 0,
        .bank_deg = 0,
        .radius_nm = 0,
        .radius_ft = 0,
    };

    const g = 32.174; // ft/s²
    const speed_fps = speed_kts * 1.68781; // knots to ft/s

    if (bank_deg == 0) {
        // Standard rate turn: 3 degrees per second
        // bank = atan(V * rate / g), where rate is in rad/s
        const rate_rad = 3.0 * (math.pi / 180.0);
        const bank = radiansToDegrees(math.atan(speed_fps * rate_rad / g));
        const radius_ft = (speed_fps * speed_fps) / (g * @tan(degreesToRadians(bank)));

        return .{
            .rate_deg_per_sec = 3.0,
            .bank_deg = bank,
            .radius_nm = radius_ft / 6076.12,
            .radius_ft = radius_ft,
        };
    }

    // Given bank angle, compute rate and radius
    const bank_rad = degreesToRadians(bank_deg);
    const tan_bank = @tan(bank_rad);

    if (@abs(tan_bank) < 0.001) return .{
        .rate_deg_per_sec = 0,
        .bank_deg = bank_deg,
        .radius_nm = 0,
        .radius_ft = 0,
    };

    // rate = (g * tan(bank)) / V  (in rad/s)
    const rate_rad = (g * tan_bank) / speed_fps;
    const rate_deg = radiansToDegrees(rate_rad);

    // radius = V² / (g * tan(bank))
    const radius_ft = (speed_fps * speed_fps) / (g * tan_bank);

    return .{
        .rate_deg_per_sec = rate_deg,
        .bank_deg = bank_deg,
        .radius_nm = radius_ft / 6076.12,
        .radius_ft = radius_ft,
    };
}

/// Time to turn from current heading to target heading.
/// Always turns the shortest direction.
/// Returns time in seconds.
pub fn timeToTurn(current_hdg: f32, target_hdg: f32, rate_deg_per_sec: f32) f32 {
    if (rate_deg_per_sec <= 0) return 0;

    var diff = target_hdg - current_hdg;
    // Normalize to -180..+180 (shortest turn)
    while (diff > 180) diff -= 360;
    while (diff < -180) diff += 360;

    return @abs(diff) / rate_deg_per_sec;
}

/// Turn radius in nautical miles for a given speed and bank angle.
pub fn turnRadius(speed_kts: f32, bank_deg: f32) f32 {
    const result = turnRate(speed_kts, bank_deg);
    return result.radius_nm;
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

test "turnRate standard rate at 120 kts" {
    const r = turnRate(120, 0);
    try std.testing.expectEqual(@as(f32, 3.0), r.rate_deg_per_sec);
    // Standard rate bank at 120 kts should be ~17 degrees
    try std.testing.expect(r.bank_deg > 15 and r.bank_deg < 20);
    try std.testing.expect(r.radius_ft > 0);
}

test "turnRate standard rate at 250 kts" {
    const r = turnRate(250, 0);
    try std.testing.expectEqual(@as(f32, 3.0), r.rate_deg_per_sec);
    // Higher speed = more bank needed for standard rate
    try std.testing.expect(r.bank_deg > 25 and r.bank_deg < 35);
}

test "turnRate with specified bank" {
    const r = turnRate(200, 25);
    try std.testing.expect(r.rate_deg_per_sec > 0);
    try std.testing.expectEqual(@as(f32, 25), r.bank_deg);
    try std.testing.expect(r.radius_nm > 0);
}

test "turnRate zero speed" {
    const r = turnRate(0, 25);
    try std.testing.expectEqual(@as(f32, 0), r.rate_deg_per_sec);
}

test "timeToTurn 90 degrees at 3 deg/s" {
    const t = timeToTurn(270, 360, 3);
    try std.testing.expect(@abs(t - 30.0) < 0.1);
}

test "timeToTurn shortest path" {
    // 350 to 010 should be 20 degrees, not 340
    const t = timeToTurn(350, 10, 3);
    try std.testing.expect(@abs(t - 6.667) < 0.1);
}

test "timeToTurn full 180" {
    const t = timeToTurn(0, 180, 3);
    try std.testing.expect(@abs(t - 60.0) < 0.1);
}
