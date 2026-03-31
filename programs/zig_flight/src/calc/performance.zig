//! Performance calculations — V-speeds, takeoff/landing distances, weight & balance.
//! All functions are pure: no allocation, no side effects.

const std = @import("std");
const math = std.math;

pub const VSpeedSet = struct {
    v1_kts: f32, // Decision speed
    vr_kts: f32, // Rotation speed
    v2_kts: f32, // Takeoff safety speed
    vref_kts: f32, // Reference landing speed
    vs0_kts: f32, // Stall speed, landing config
    vs1_kts: f32, // Stall speed, clean config
};

/// Estimate V-speeds for a generic medium jet.
/// weight_kg: aircraft weight in kilograms
/// flap_setting: flap position (0 = clean, 1 = takeoff, 2+ = landing)
/// Returns: estimated V-speed set
pub fn estimateVSpeeds(weight_kg: f32, flap_setting: u8) VSpeedSet {
    if (weight_kg <= 0) return .{
        .v1_kts = 0,
        .vr_kts = 0,
        .v2_kts = 0,
        .vref_kts = 0,
        .vs0_kts = 0,
        .vs1_kts = 0,
    };

    // Base speeds for a ~70,000 kg medium jet at reference weight
    // Scale with sqrt(weight/reference) — lift equation relationship
    const ref_weight: f32 = 70000.0;
    const weight_ratio = @sqrt(weight_kg / ref_weight);

    // Clean stall speed base: ~140 kts at reference weight
    const vs1_base: f32 = 140.0;
    const vs1 = vs1_base * weight_ratio;

    // Flap extension reduces stall speed
    const flap_factor: f32 = switch (flap_setting) {
        0 => 1.0, // clean
        1 => 0.90, // takeoff flaps (~10% reduction)
        2 => 0.85, // approach flaps
        else => 0.80, // full flaps
    };

    const vs0 = vs1 * 0.80; // Full flaps stall

    return .{
        .v1_kts = vs1 * flap_factor * 1.15, // V1 ≈ 1.15 × Vs (flapped)
        .vr_kts = vs1 * flap_factor * 1.18, // Vr ≈ 1.18 × Vs (flapped)
        .v2_kts = vs1 * flap_factor * 1.25, // V2 ≈ 1.25 × Vs (flapped)
        .vref_kts = vs0 * 1.30, // Vref ≈ 1.30 × Vs0
        .vs0_kts = vs0,
        .vs1_kts = vs1,
    };
}

/// Takeoff ground roll estimate (simplified).
/// weight_kg: takeoff weight in kg
/// density_alt_ft: density altitude in feet
/// headwind_kts: headwind component (positive = headwind)
/// Returns: ground roll in feet
pub fn takeoffRoll(weight_kg: f32, density_alt_ft: f32, headwind_kts: f32) f32 {
    if (weight_kg <= 0) return 0;

    // Base roll for reference weight at sea level ISA: ~5000 ft
    const ref_weight: f32 = 70000.0;
    const base_roll: f32 = 5000.0;

    // Roll scales with (weight/ref)^2 (kinetic energy)
    const weight_factor = (weight_kg / ref_weight) * (weight_kg / ref_weight);

    // Density altitude correction: ~10% per 1000 ft
    const da_factor = 1.0 + density_alt_ft * 0.0001;

    // Headwind correction: ~1.5% reduction per knot
    const wind_factor = @max(0.3, 1.0 - headwind_kts * 0.015);

    return base_roll * weight_factor * da_factor * wind_factor;
}

/// Landing distance estimate (simplified).
/// weight_kg: landing weight in kg
/// density_alt_ft: density altitude in feet
/// headwind_kts: headwind component (positive = headwind)
/// Returns: landing roll in feet
pub fn landingRoll(weight_kg: f32, density_alt_ft: f32, headwind_kts: f32) f32 {
    if (weight_kg <= 0) return 0;

    // Base roll for reference weight at sea level: ~3500 ft
    const ref_weight: f32 = 60000.0; // Landing weight typically lighter
    const base_roll: f32 = 3500.0;

    const weight_factor = (weight_kg / ref_weight) * (weight_kg / ref_weight);
    const da_factor = 1.0 + density_alt_ft * 0.0001;
    const wind_factor = @max(0.3, 1.0 - headwind_kts * 0.015);

    return base_roll * weight_factor * da_factor * wind_factor;
}

/// Weight and balance — center of gravity calculation.
/// Returns CG as percentage of MAC (mean aerodynamic chord).
pub const MassItem = struct {
    weight_kg: f32,
    arm_m: f32, // Distance from datum in meters
};

/// Compute CG position from an array of mass items.
/// Returns: CG arm in meters from datum.
pub fn computeCG(items: []const MassItem) f32 {
    var total_weight: f32 = 0;
    var total_moment: f32 = 0;

    for (items) |item| {
        total_weight += item.weight_kg;
        total_moment += item.weight_kg * item.arm_m;
    }

    if (total_weight <= 0) return 0;
    return total_moment / total_weight;
}

/// Convert CG arm to %MAC.
/// cg_arm_m: CG position in meters from datum
/// lemac_m: leading edge of MAC from datum
/// mac_m: MAC length in meters
pub fn cgPercentMAC(cg_arm_m: f32, lemac_m: f32, mac_m: f32) f32 {
    if (mac_m <= 0) return 0;
    return ((cg_arm_m - lemac_m) / mac_m) * 100.0;
}

/// Rate of climb estimate from excess thrust.
/// excess_thrust_n: excess thrust in Newtons (thrust - drag)
/// weight_kg: aircraft weight in kg
/// tas_kts: true airspeed in knots
/// Returns: rate of climb in feet per minute
pub fn rateOfClimb(excess_thrust_n: f32, weight_kg: f32, tas_kts: f32) f32 {
    if (weight_kg <= 0 or tas_kts <= 0) return 0;

    // ROC = (excess_power) / weight
    // excess_power = excess_thrust × TAS
    const tas_ms = tas_kts * 0.514444; // knots to m/s
    const weight_n = weight_kg * 9.80665;

    // ROC in m/s
    const roc_ms = (excess_thrust_n * tas_ms) / weight_n;

    // Convert to ft/min
    return roc_ms * 196.85; // m/s to ft/min
}

// ============================================================================
// Tests
// ============================================================================

test "estimateVSpeeds reference weight" {
    const v = estimateVSpeeds(70000, 1);
    // At reference weight, ratio = 1.0
    try std.testing.expect(v.vs1_kts > 135 and v.vs1_kts < 145);
    try std.testing.expect(v.v2_kts > v.vr_kts);
    try std.testing.expect(v.vr_kts > v.v1_kts);
}

test "estimateVSpeeds heavier = faster" {
    const v_light = estimateVSpeeds(50000, 1);
    const v_heavy = estimateVSpeeds(80000, 1);
    try std.testing.expect(v_heavy.v1_kts > v_light.v1_kts);
    try std.testing.expect(v_heavy.vs1_kts > v_light.vs1_kts);
}

test "estimateVSpeeds zero weight" {
    const v = estimateVSpeeds(0, 0);
    try std.testing.expectEqual(@as(f32, 0), v.v1_kts);
}

test "takeoffRoll reference conditions" {
    const roll = takeoffRoll(70000, 0, 0);
    try std.testing.expect(roll > 4000 and roll < 6000);
}

test "takeoffRoll heavier = longer" {
    const light = takeoffRoll(50000, 0, 0);
    const heavy = takeoffRoll(90000, 0, 0);
    try std.testing.expect(heavy > light);
}

test "takeoffRoll high DA = longer" {
    const sea_level = takeoffRoll(70000, 0, 0);
    const high_alt = takeoffRoll(70000, 5000, 0);
    try std.testing.expect(high_alt > sea_level);
}

test "takeoffRoll headwind = shorter" {
    const no_wind = takeoffRoll(70000, 0, 0);
    const headwind = takeoffRoll(70000, 0, 20);
    try std.testing.expect(headwind < no_wind);
}

test "landingRoll basic" {
    const roll = landingRoll(60000, 0, 0);
    try std.testing.expect(roll > 3000 and roll < 4000);
}

test "computeCG basic" {
    const items = [_]MassItem{
        .{ .weight_kg = 5000, .arm_m = 10 },
        .{ .weight_kg = 3000, .arm_m = 15 },
    };
    const cg = computeCG(&items);
    // (5000*10 + 3000*15) / 8000 = (50000+45000)/8000 = 11.875
    try std.testing.expect(@abs(cg - 11.875) < 0.01);
}

test "computeCG empty" {
    const items = [_]MassItem{};
    const cg = computeCG(&items);
    try std.testing.expectEqual(@as(f32, 0), cg);
}

test "cgPercentMAC" {
    // CG at 12m, LEMAC at 10m, MAC = 5m → (12-10)/5 * 100 = 40%
    const pct = cgPercentMAC(12, 10, 5);
    try std.testing.expect(@abs(pct - 40.0) < 0.1);
}

test "rateOfClimb basic" {
    // 50kN excess thrust, 70000 kg, 250 kts
    const roc = rateOfClimb(50000, 70000, 250);
    try std.testing.expect(roc > 0);
    // Should be reasonable: ~1800 fpm
    try std.testing.expect(roc > 1000 and roc < 3000);
}
