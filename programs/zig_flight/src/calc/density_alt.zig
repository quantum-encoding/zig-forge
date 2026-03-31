//! Density altitude calculations.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");

/// Compute density altitude.
/// pressure_alt_ft: pressure altitude in feet
/// oat_c: outside air temperature in Celsius
/// Returns: density altitude in feet
pub fn densityAltitude(pressure_alt_ft: f32, oat_c: f32) f32 {
    // Koch formula: DA = PA + (120 * (OAT - ISA_temp))
    // ISA temp at altitude: 15 - (1.98 * PA/1000)
    const isa_temp = isaTemperature(pressure_alt_ft);
    const isa_dev = oat_c - isa_temp;
    return pressure_alt_ft + (120.0 * isa_dev);
}

/// ISA (International Standard Atmosphere) temperature at a given pressure altitude.
/// Returns temperature in Celsius.
pub fn isaTemperature(pressure_alt_ft: f32) f32 {
    // ISA: 15°C at sea level, lapse rate -1.98°C per 1000 ft (up to tropopause ~36,000 ft)
    if (pressure_alt_ft <= 36089) {
        return 15.0 - (1.98 * pressure_alt_ft / 1000.0);
    }
    // Above tropopause: constant -56.5°C
    return -56.5;
}

/// ISA temperature deviation.
/// Returns how many degrees above/below ISA standard the OAT is.
pub fn isaDeviation(pressure_alt_ft: f32, oat_c: f32) f32 {
    return oat_c - isaTemperature(pressure_alt_ft);
}

/// Pressure altitude from field elevation and altimeter setting.
/// field_elev_ft: field elevation in feet
/// altimeter_inhg: altimeter setting in inches of mercury
/// Returns: pressure altitude in feet
pub fn pressureAltitude(field_elev_ft: f32, altimeter_inhg: f32) f32 {
    // 1 inHg ≈ 1000 ft of altitude difference
    // Standard pressure: 29.92 inHg
    return field_elev_ft + (29.92 - altimeter_inhg) * 1000.0;
}

/// True airspeed from indicated airspeed and density altitude.
/// ias_kts: indicated airspeed in knots
/// density_alt_ft: density altitude in feet
/// Returns: true airspeed in knots
pub fn trueAirspeed(ias_kts: f32, density_alt_ft: f32) f32 {
    // TAS ≈ IAS * (1 + DA/60000) — simplified formula
    // More accurate: TAS = IAS * sqrt(rho_0 / rho)
    // Using the simplified altitude correction: ~2% per 1000 ft
    return ias_kts * (1.0 + density_alt_ft * 0.00002);
}

// ============================================================================
// Tests
// ============================================================================

test "isaTemperature sea level" {
    const t = isaTemperature(0);
    try std.testing.expectEqual(@as(f32, 15.0), t);
}

test "isaTemperature 10000 ft" {
    const t = isaTemperature(10000);
    // 15 - 1.98 * 10 = -4.8
    try std.testing.expect(@abs(t - (-4.8)) < 0.1);
}

test "isaTemperature above tropopause" {
    const t = isaTemperature(40000);
    try std.testing.expectEqual(@as(f32, -56.5), t);
}

test "densityAltitude ISA standard day" {
    // At sea level, 15°C (ISA standard), DA should equal PA
    const da = densityAltitude(0, 15);
    try std.testing.expect(@abs(da) < 1.0);
}

test "densityAltitude hot day" {
    // Sea level, 35°C (20° above ISA)
    // DA = 0 + 120 * 20 = 2400 ft
    const da = densityAltitude(0, 35);
    try std.testing.expect(@abs(da - 2400) < 1.0);
}

test "densityAltitude cold day" {
    // Sea level, 0°C (15° below ISA)
    // DA = 0 + 120 * (-15) = -1800 ft
    const da = densityAltitude(0, 0);
    try std.testing.expect(@abs(da - (-1800)) < 1.0);
}

test "densityAltitude at altitude" {
    // 5000 ft PA, 10°C
    // ISA at 5000 = 15 - 1.98*5 = 5.1°C
    // Dev = 10 - 5.1 = 4.9
    // DA = 5000 + 120 * 4.9 = 5588
    const da = densityAltitude(5000, 10);
    try std.testing.expect(@abs(da - 5588) < 2.0);
}

test "pressureAltitude standard pressure" {
    const pa = pressureAltitude(0, 29.92);
    try std.testing.expect(@abs(pa) < 1.0);
}

test "pressureAltitude low pressure" {
    // 29.72 inHg → 200 ft higher pressure altitude
    const pa = pressureAltitude(0, 29.72);
    try std.testing.expect(@abs(pa - 200) < 1.0);
}

test "pressureAltitude high pressure" {
    // 30.12 inHg → 200 ft lower pressure altitude
    const pa = pressureAltitude(0, 30.12);
    try std.testing.expect(@abs(pa - (-200)) < 1.0);
}

test "isaDeviation" {
    const dev = isaDeviation(0, 25);
    try std.testing.expect(@abs(dev - 10) < 0.1);
}

test "trueAirspeed sea level" {
    // At sea level DA=0, TAS ≈ IAS
    const tas = trueAirspeed(250, 0);
    try std.testing.expect(@abs(tas - 250) < 1.0);
}

test "trueAirspeed at altitude" {
    // At high DA, TAS > IAS
    const tas = trueAirspeed(250, 30000);
    try std.testing.expect(tas > 250);
}
