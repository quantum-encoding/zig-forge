//! Fuel calculations — endurance, range, specific range.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");

/// Fuel endurance — how long until fuel exhaustion.
/// fuel_remaining_kg: remaining fuel in kilograms
/// fuel_flow_total_kgs: total fuel flow in kg/second
/// Returns: endurance in hours
pub fn endurance(fuel_remaining_kg: f32, fuel_flow_total_kgs: f32) f32 {
    if (fuel_flow_total_kgs <= 0) return 0;
    if (fuel_remaining_kg <= 0) return 0;

    // Convert kg/s to kg/h, then divide
    const flow_per_hour = fuel_flow_total_kgs * 3600.0;
    return fuel_remaining_kg / flow_per_hour;
}

/// Fuel range — how far we can fly at current consumption and speed.
/// fuel_remaining_kg: remaining fuel in kilograms
/// fuel_flow_total_kgs: total fuel flow in kg/second
/// groundspeed_kts: groundspeed in knots
/// Returns: range in nautical miles
pub fn range(fuel_remaining_kg: f32, fuel_flow_total_kgs: f32, groundspeed_kts: f32) f32 {
    if (groundspeed_kts <= 0) return 0;

    const hours = endurance(fuel_remaining_kg, fuel_flow_total_kgs);
    return hours * groundspeed_kts;
}

/// Specific range — distance per unit of fuel.
/// groundspeed_kts: groundspeed in knots
/// fuel_flow_total_kgs: total fuel flow in kg/second
/// Returns: nautical miles per kilogram
pub fn specificRange(groundspeed_kts: f32, fuel_flow_total_kgs: f32) f32 {
    if (fuel_flow_total_kgs <= 0) return 0;
    if (groundspeed_kts <= 0) return 0;

    // NM/h ÷ kg/h = NM/kg
    const flow_per_hour = fuel_flow_total_kgs * 3600.0;
    return groundspeed_kts / flow_per_hour;
}

/// Fuel flow in more readable units.
/// fuel_flow_kgs: fuel flow in kg/second
/// Returns: fuel flow in kg/hour
pub fn flowKgPerHour(fuel_flow_kgs: f32) f32 {
    return fuel_flow_kgs * 3600.0;
}

/// Fuel flow in pounds per hour.
/// fuel_flow_kgs: fuel flow in kg/second
/// Returns: fuel flow in lbs/hour
pub fn flowLbsPerHour(fuel_flow_kgs: f32) f32 {
    return fuel_flow_kgs * 3600.0 * 2.20462;
}

/// Convert fuel weight between kg and lbs.
pub fn kgToLbs(kg: f32) f32 {
    return kg * 2.20462;
}

pub fn lbsToKg(lbs: f32) f32 {
    return lbs * 0.453592;
}

// ============================================================================
// Tests
// ============================================================================

test "endurance basic" {
    // 1000 kg fuel, 0.5 kg/s flow = 2000 seconds = 0.556 hours
    const e = endurance(1000, 0.5);
    try std.testing.expect(@abs(e - 0.5556) < 0.01);
}

test "endurance zero flow" {
    const e = endurance(1000, 0);
    try std.testing.expectEqual(@as(f32, 0), e);
}

test "endurance zero fuel" {
    const e = endurance(0, 0.5);
    try std.testing.expectEqual(@as(f32, 0), e);
}

test "range basic" {
    // 1000 kg, 0.1 kg/s, 250 kts GS
    // Endurance = 1000 / (0.1 * 3600) = 2.778 hours
    // Range = 2.778 * 250 = 694.4 NM
    const r = range(1000, 0.1, 250);
    try std.testing.expect(@abs(r - 694.4) < 1.0);
}

test "range zero speed" {
    const r = range(1000, 0.1, 0);
    try std.testing.expectEqual(@as(f32, 0), r);
}

test "specificRange basic" {
    // 250 kts, 0.1 kg/s → 250 / 360 = 0.694 NM/kg
    const sr = specificRange(250, 0.1);
    try std.testing.expect(@abs(sr - 0.6944) < 0.01);
}

test "flowKgPerHour" {
    const f = flowKgPerHour(0.5);
    try std.testing.expect(@abs(f - 1800) < 1.0);
}

test "flowLbsPerHour" {
    const f = flowLbsPerHour(0.5);
    // 0.5 * 3600 * 2.20462 = 3968.3
    try std.testing.expect(@abs(f - 3968.3) < 1.0);
}

test "kgToLbs" {
    const lbs = kgToLbs(100);
    try std.testing.expect(@abs(lbs - 220.462) < 0.1);
}

test "lbsToKg" {
    const kg = lbsToKg(220.462);
    try std.testing.expect(@abs(kg - 100) < 0.1);
}
