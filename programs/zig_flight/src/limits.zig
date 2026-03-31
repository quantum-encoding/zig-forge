//! Aircraft envelope definitions.
//!
//! Comptime struct defining performance limits for threshold-based alerting.
//! Presets for common aircraft types. Zero allocation — all comptime constants
//! except `active` which is a mutable module-level var.

const std = @import("std");

pub const AircraftLimits = struct {
    // Speed (kts)
    vmo: f32, // Max operating speed
    vne: f32, // Never exceed speed
    va: f32, // Manoeuvring speed
    vfe: f32, // Max flap extended speed

    // Altitude (ft)
    service_ceiling_ft: f32,
    max_operating_alt_ft: f32,

    // Structural
    max_bank_deg: f32,
    max_descent_rate_fpm: f32,
    max_g_positive: f32,
    max_g_negative: f32,

    // Fuel
    fuel_capacity_kg: f32,
    min_endurance_warning_hrs: f32,
    min_endurance_caution_hrs: f32,
};

/// Medium twin jet — default envelope.
pub const GENERIC_JET = AircraftLimits{
    .vmo = 340,
    .vne = 365,
    .va = 250,
    .vfe = 200,
    .service_ceiling_ft = 41000,
    .max_operating_alt_ft = 39000,
    .max_bank_deg = 30,
    .max_descent_rate_fpm = 6000,
    .max_g_positive = 2.5,
    .max_g_negative = -1.0,
    .fuel_capacity_kg = 10000,
    .min_endurance_warning_hrs = 0.5,
    .min_endurance_caution_hrs = 1.0,
};

/// Cessna 172 — general aviation.
pub const CESSNA_172 = AircraftLimits{
    .vmo = 163,
    .vne = 182,
    .va = 99,
    .vfe = 85,
    .service_ceiling_ft = 14000,
    .max_operating_alt_ft = 13000,
    .max_bank_deg = 30,
    .max_descent_rate_fpm = 2000,
    .max_g_positive = 3.8,
    .max_g_negative = -1.52,
    .fuel_capacity_kg = 145,
    .min_endurance_warning_hrs = 0.5,
    .min_endurance_caution_hrs = 1.0,
};

/// Large transport category — airliner.
pub const TRANSPORT = AircraftLimits{
    .vmo = 350,
    .vne = 380,
    .va = 270,
    .vfe = 230,
    .service_ceiling_ft = 43000,
    .max_operating_alt_ft = 41000,
    .max_bank_deg = 25,
    .max_descent_rate_fpm = 6000,
    .max_g_positive = 2.5,
    .max_g_negative = -1.0,
    .fuel_capacity_kg = 80000,
    .min_endurance_warning_hrs = 0.5,
    .min_endurance_caution_hrs = 1.0,
};

/// Active limits — mutable, defaults to GENERIC_JET.
pub var active: AircraftLimits = GENERIC_JET;

// ============================================================================
// Tests
// ============================================================================

test "preset values" {
    try std.testing.expectEqual(@as(f32, 340), GENERIC_JET.vmo);
    try std.testing.expectEqual(@as(f32, 163), CESSNA_172.vmo);
    try std.testing.expectEqual(@as(f32, 350), TRANSPORT.vmo);
    try std.testing.expectEqual(@as(f32, 25), TRANSPORT.max_bank_deg);
}

test "active defaults to generic jet" {
    try std.testing.expectEqual(@as(f32, 340), active.vmo);
    try std.testing.expectEqual(@as(f32, 30), active.max_bank_deg);
}
