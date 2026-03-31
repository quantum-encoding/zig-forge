// conversions.zig — Explicit, auditable unit conversions
//
// Every conversion between unit types is an explicit function call.
// The MCO disaster happened because the unit conversion was IMPLICIT —
// the software just used the number without knowing its unit.
// Here, you can grep for every conversion in the codebase and audit them.

const units = @import("units.zig");

// ============================================================================
// Force conversions
// ============================================================================

pub fn lbfToNewton(f: units.Quantity(units.PoundForce)) units.Force {
    return f.convertTo(units.Newton, units.LBF_TO_NEWTON);
}

pub fn newtonToLbf(f: units.Force) units.Quantity(units.PoundForce) {
    return f.convertTo(units.PoundForce, units.NEWTON_TO_LBF);
}

// ============================================================================
// Distance conversions
// ============================================================================

pub fn footToMeter(d: units.Quantity(units.Foot)) units.Distance {
    return d.convertTo(units.Meter, units.FOOT_TO_METER);
}

pub fn meterToFoot(d: units.Distance) units.Quantity(units.Foot) {
    return d.convertTo(units.Foot, units.METER_TO_FOOT);
}

pub fn kmToMeter(d: units.DistanceKm) units.Distance {
    return d.convertTo(units.Meter, units.KM_TO_M);
}

pub fn meterToKm(d: units.Distance) units.DistanceKm {
    return d.convertTo(units.Kilometer, units.M_TO_KM);
}

// ============================================================================
// Angle conversions
// ============================================================================

pub fn degToRad(a: units.AngleDeg) units.Angle {
    return a.convertTo(units.Radian, units.DEG_TO_RAD);
}

pub fn radToDeg(a: units.Angle) units.AngleDeg {
    return a.convertTo(units.Degree, units.RAD_TO_DEG);
}

// ============================================================================
// Pressure conversions
// ============================================================================

pub fn psiToPascal(p: units.Quantity(units.PSI)) units.Pressure {
    return p.convertTo(units.Pascal, units.PSI_TO_PASCAL);
}

pub fn pascalToPsi(p: units.Pressure) units.Quantity(units.PSI) {
    return p.convertTo(units.PSI, units.PASCAL_TO_PSI);
}

// ============================================================================
// Temperature conversions
// ============================================================================

pub fn celsiusToKelvin(t: units.Quantity(units.Celsius)) units.Temperature {
    return .{ .value = t.value + units.CELSIUS_TO_KELVIN_OFFSET };
}

pub fn kelvinToCelsius(t: units.Temperature) units.Quantity(units.Celsius) {
    return .{ .value = t.value - units.CELSIUS_TO_KELVIN_OFFSET };
}
