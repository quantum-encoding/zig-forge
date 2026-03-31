// units.zig — Comptime-parameterized physical unit type system
//
// This is the Mars Climate Orbiter prevention. Wrong unit = compile error.
// Not a runtime check. Not a convention. A type error.
//
// MCO was lost because Lockheed Martin sent thrust data in pound-force (lbf)
// while NASA's navigation software expected newtons (N). The 4.45x error
// accumulated over months and drove the spacecraft into Mars' atmosphere.
// A type system like this makes that structurally impossible.

const std = @import("std");

/// Comptime-parameterized physical unit type.
/// Quantity(Newton) and Quantity(PoundForce) are DIFFERENT TYPES.
/// You cannot add, compare, or assign between them without explicit conversion.
pub fn Quantity(comptime UnitTag: type) type {
    return struct {
        value: f64,

        const Self = @This();
        pub const Unit = UnitTag;

        pub fn init(v: f64) Self {
            return .{ .value = v };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .value = a.value + b.value };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .value = a.value - b.value };
        }

        pub fn scale(self: Self, factor: f64) Self {
            return .{ .value = self.value * factor };
        }

        pub fn negate(self: Self) Self {
            return .{ .value = -self.value };
        }

        pub fn abs(self: Self) Self {
            return .{ .value = @abs(self.value) };
        }

        pub fn lessThan(a: Self, b: Self) bool {
            return a.value < b.value;
        }

        pub fn greaterThan(a: Self, b: Self) bool {
            return a.value > b.value;
        }

        pub fn clamp(self: Self, lo: Self, hi: Self) Self {
            if (self.value < lo.value) return lo;
            if (self.value > hi.value) return hi;
            return self;
        }

        /// Explicit conversion — the ONLY way to go between unit types.
        /// You must provide the conversion factor. This forces the programmer
        /// to think about what conversion they're performing.
        pub fn convertTo(self: Self, comptime Target: type, comptime factor: f64) Quantity(Target) {
            return .{ .value = self.value * factor };
        }

        pub fn isFinite(self: Self) bool {
            return std.math.isFinite(self.value);
        }

        pub fn isNan(self: Self) bool {
            return std.math.isNan(self.value);
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{d:.3}", .{self.value});
        }
    };
}

// ============================================================================
// Unit tag types (zero-size, exist only for type discrimination at comptime)
// ============================================================================

// Force
pub const Newton = struct {};
pub const PoundForce = struct {};

// Distance
pub const Meter = struct {};
pub const Foot = struct {};
pub const Kilometer = struct {};

// Mass
pub const Kilogram = struct {};
pub const Pound = struct {};

// Velocity
pub const MeterPerSec = struct {};
pub const FeetPerSec = struct {};
pub const KmPerSec = struct {};

// Acceleration
pub const MeterPerSecSq = struct {};

// Angle
pub const Radian = struct {};
pub const Degree = struct {};

// Angular rate
pub const RadPerSec = struct {};
pub const DegPerSec = struct {};

// Pressure
pub const Pascal = struct {};
pub const PSI = struct {};

// Temperature
pub const Kelvin = struct {};
pub const Celsius = struct {};

// Time
pub const Second = struct {};

// ============================================================================
// Conversion constants (sourced from NIST)
// ============================================================================
pub const LBF_TO_NEWTON: f64 = 4.44822;
pub const NEWTON_TO_LBF: f64 = 1.0 / LBF_TO_NEWTON;
pub const FOOT_TO_METER: f64 = 0.3048;
pub const METER_TO_FOOT: f64 = 1.0 / FOOT_TO_METER;
pub const PSI_TO_PASCAL: f64 = 6894.76;
pub const PASCAL_TO_PSI: f64 = 1.0 / PSI_TO_PASCAL;
pub const DEG_TO_RAD: f64 = std.math.pi / 180.0;
pub const RAD_TO_DEG: f64 = 180.0 / std.math.pi;
pub const CELSIUS_TO_KELVIN_OFFSET: f64 = 273.15;
pub const KM_TO_M: f64 = 1000.0;
pub const M_TO_KM: f64 = 0.001;

// ============================================================================
// Type aliases for readability
// ============================================================================
pub const Force = Quantity(Newton);
pub const Distance = Quantity(Meter);
pub const DistanceKm = Quantity(Kilometer);
pub const Mass = Quantity(Kilogram);
pub const Velocity = Quantity(MeterPerSec);
pub const VelocityKm = Quantity(KmPerSec);
pub const Acceleration = Quantity(MeterPerSecSq);
pub const Pressure = Quantity(Pascal);
pub const Temperature = Quantity(Kelvin);
pub const Angle = Quantity(Radian);
pub const AngleDeg = Quantity(Degree);
pub const AngularRate = Quantity(RadPerSec);
pub const Time = Quantity(Second);

// ============================================================================
// 3D Vector parameterized by unit type
// ============================================================================
pub fn Vector3(comptime UnitTag: type) type {
    return struct {
        x: Quantity(UnitTag),
        y: Quantity(UnitTag),
        z: Quantity(UnitTag),

        const Self = @This();

        pub fn zero() Self {
            return .{
                .x = .{ .value = 0 },
                .y = .{ .value = 0 },
                .z = .{ .value = 0 },
            };
        }

        pub fn init(x: f64, y: f64, z: f64) Self {
            return .{
                .x = .{ .value = x },
                .y = .{ .value = y },
                .z = .{ .value = z },
            };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{
                .x = a.x.add(b.x),
                .y = a.y.add(b.y),
                .z = a.z.add(b.z),
            };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{
                .x = a.x.sub(b.x),
                .y = a.y.sub(b.y),
                .z = a.z.sub(b.z),
            };
        }

        pub fn scale(self: Self, factor: f64) Self {
            return .{
                .x = self.x.scale(factor),
                .y = self.y.scale(factor),
                .z = self.z.scale(factor),
            };
        }

        pub fn magnitude(self: Self) f64 {
            return @sqrt(self.x.value * self.x.value +
                self.y.value * self.y.value +
                self.z.value * self.z.value);
        }

        pub fn normalize(self: Self) Self {
            const mag = self.magnitude();
            if (mag < 1e-12) return zero();
            return self.scale(1.0 / mag);
        }

        pub fn dot(a: Self, b: Self) f64 {
            return a.x.value * b.x.value + a.y.value * b.y.value + a.z.value * b.z.value;
        }
    };
}

// ============================================================================
// Quaternion for attitude representation
// ============================================================================
pub const Quaternion = struct {
    w: f64,
    x: f64,
    y: f64,
    z: f64,

    pub fn identity() Quaternion {
        return .{ .w = 1, .x = 0, .y = 0, .z = 0 };
    }

    pub fn fromAxisAngle(ax: f64, ay: f64, az: f64, angle_rad: f64) Quaternion {
        const half = angle_rad * 0.5;
        const s = @sin(half);
        const c = @cos(half);
        const mag = @sqrt(ax * ax + ay * ay + az * az);
        if (mag < 1e-12) return identity();
        return .{
            .w = c,
            .x = ax / mag * s,
            .y = ay / mag * s,
            .z = az / mag * s,
        };
    }

    pub fn multiply(a: Quaternion, b: Quaternion) Quaternion {
        return .{
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        };
    }

    pub fn normalizeQuat(self: Quaternion) Quaternion {
        const mag = @sqrt(self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z);
        if (mag < 1e-12) return identity();
        return .{
            .w = self.w / mag,
            .x = self.x / mag,
            .y = self.y / mag,
            .z = self.z / mag,
        };
    }

    /// Rotate a vector by this quaternion
    pub fn rotateVec(self: Quaternion, v: Vector3(Meter)) Vector3(Meter) {
        // q * v * q^-1
        const qv = Quaternion{ .w = 0, .x = v.x.value, .y = v.y.value, .z = v.z.value };
        const q_conj = Quaternion{ .w = self.w, .x = -self.x, .y = -self.y, .z = -self.z };
        const result = self.multiply(qv).multiply(q_conj);
        return Vector3(Meter).init(result.x, result.y, result.z);
    }

    /// Get pitch angle (rotation about Y axis) in radians
    pub fn getPitch(self: Quaternion) f64 {
        const sinp = 2.0 * (self.w * self.y - self.z * self.x);
        if (@abs(sinp) >= 1.0) {
            return if (sinp >= 0) std.math.pi / 2.0 else -std.math.pi / 2.0;
        }
        return std.math.asin(sinp);
    }
};

// ============================================================================
// Tests
// ============================================================================
test "unit type safety - different units are different types" {
    const force_n = Force.init(100.0);
    const force_n2 = Force.init(50.0);
    const result = force_n.add(force_n2);
    try std.testing.expectApproxEqAbs(150.0, result.value, 0.001);

    // This would NOT compile:
    // const force_lbf = Quantity(PoundForce).init(100.0);
    // _ = force_n.add(force_lbf); // compile error: type mismatch
}

test "explicit unit conversion" {
    const thrust_lbf = Quantity(PoundForce).init(100.0);
    const thrust_n = thrust_lbf.convertTo(Newton, LBF_TO_NEWTON);
    try std.testing.expectApproxEqAbs(444.822, thrust_n.value, 0.01);
}

test "vector operations" {
    const v1 = Vector3(MeterPerSec).init(1, 2, 3);
    const v2 = Vector3(MeterPerSec).init(4, 5, 6);
    const sum = v1.add(v2);
    try std.testing.expectApproxEqAbs(5.0, sum.x.value, 0.001);
    try std.testing.expectApproxEqAbs(7.0, sum.y.value, 0.001);
    try std.testing.expectApproxEqAbs(9.0, sum.z.value, 0.001);
}

test "quaternion rotation" {
    const q = Quaternion.identity();
    const v = Vector3(Meter).init(1, 0, 0);
    const rotated = q.rotateVec(v);
    try std.testing.expectApproxEqAbs(1.0, rotated.x.value, 0.001);
    try std.testing.expectApproxEqAbs(0.0, rotated.y.value, 0.001);
}
