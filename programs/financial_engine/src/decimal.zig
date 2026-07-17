const std = @import("std");
const assert = std.debug.assert;

/// Fixed-point decimal for financial calculations
/// Uses 128-bit integer with configurable decimal places
pub const Decimal = struct {
    const Self = @This();
    const scale_factor = 1_000_000_000; // 9 decimal places
    const max_safe_value = std.math.maxInt(i128) / scale_factor;
    const min_safe_value = std.math.minInt(i128) / scale_factor;
    
    value: i128,
    
    /// Create from integer
    pub fn fromInt(n: i64) Self {
        return Self{ .value = @as(i128, n) * scale_factor };
    }
    
    /// Create from float (use with caution)
    pub fn fromFloat(f: f64) Self {
        return Self{ .value = @as(i128, @intFromFloat(f * @as(f64, @floatFromInt(scale_factor)))) };
    }

    /// Create from a fixed-point pair (`value × 10^-scale`). The canonical
    /// FFI boundary form — every Decimal-aware C client passes prices as
    /// `(i64 value, u8 scale)` so the wire can carry an exact decimal
    /// without going through an f64 round-trip. e.g. `(12345, 8)` ⇒
    /// `0.00012345`. Internal scale is 10^9; we rescale by integer multiply
    /// or @divTrunc so no rounding happens for representable inputs.
    /// Mantissa overflow is impossible for `scale ≤ 9` (one ratio multiply
    /// of an i64 widened to i128); `scale > 9` truncates excess precision
    /// the same way std.fmt.parseFloat would past f64's mantissa.
    pub fn fromFixedPoint(value: i64, scale: u8) Self {
        const widened: i128 = @as(i128, value);
        if (scale <= 9) {
            var multiplier: i128 = 1;
            var k: u8 = 0;
            while (k < (9 - scale)) : (k += 1) multiplier *= 10;
            return Self{ .value = widened * multiplier };
        }
        var divisor: i128 = 1;
        var k: u8 = 0;
        while (k < (scale - 9)) : (k += 1) divisor *= 10;
        return Self{ .value = @divTrunc(widened, divisor) };
    }
    
    /// Create from string representation
    pub fn fromString(str: []const u8) !Self {
        var parts = std.mem.splitScalar(u8, str, '.');
        const integer_part = parts.next() orelse return error.InvalidFormat;
        const decimal_part = parts.next();
        
        var value: i128 = 0;
        
        // Parse integer part
        const int_val = try std.fmt.parseInt(i64, integer_part, 10);
        value = @as(i128, int_val) * scale_factor;
        
        // Parse decimal part if exists
        if (decimal_part) |dec| {
            if (dec.len > 9) return error.TooManyDecimalPlaces;
            
            const dec_value = try std.fmt.parseInt(i64, dec, 10);
            var multiplier: i128 = scale_factor;
            for (0..dec.len) |_| {
                multiplier = @divTrunc(multiplier, 10);
            }
            
            if (int_val < 0) {
                value -= @as(i128, dec_value) * multiplier;
            } else {
                value += @as(i128, dec_value) * multiplier;
            }
        }
        
        return Self{ .value = value };
    }
    
    /// Convert to float (may lose precision)
    pub fn toFloat(self: Self) f64 {
        return @as(f64, @floatFromInt(self.value)) / @as(f64, @floatFromInt(scale_factor));
    }
    
    /// Format for display. Zig 0.16 calls `format(self, writer)` for the
    /// default `{}` specifier — the prior signature
    /// `format(self, fmt, options, writer)` was the Zig 0.14/0.15 shape and
    /// silently fell through to the anonymous-struct debug printer.
    pub fn format(self: Self, writer: *std.Io.Writer) !void {
        const is_negative = self.value < 0;
        const abs_value = if (is_negative) -self.value else self.value;

        const integer = @divTrunc(abs_value, scale_factor);
        const decimal = @mod(abs_value, scale_factor);

        if (is_negative) {
            try writer.writeByte('-');
        }

        try writer.print("{d}.{d:0>9}", .{ integer, decimal });
    }
    
    /// Addition
    pub fn add(self: Self, other: Self) !Self {
        if (self.value > 0 and other.value > max_safe_value - self.value) {
            return error.Overflow;
        }
        if (self.value < 0 and other.value < min_safe_value - self.value) {
            return error.Underflow;
        }
        return Self{ .value = self.value + other.value };
    }
    
    /// Subtraction
    pub fn sub(self: Self, other: Self) !Self {
        if (other.value < 0 and self.value > max_safe_value + other.value) {
            return error.Overflow;
        }
        if (other.value > 0 and self.value < min_safe_value + other.value) {
            return error.Underflow;
        }
        return Self{ .value = self.value - other.value };
    }
    
    /// Multiplication
    ///
    /// The raw product `self.value * other.value` is a 10^18-scaled i128
    /// that overflows i128 long before the final 10^9-scaled result would.
    /// The previous code executed the `*` *before* any bound test, so in a
    /// ReleaseFast build a crafted `qty × price` silently wrapped mod 2^128
    /// and the wrapped `position_value` sailed through every risk /
    /// Praetorian cap. `std.math.mul` performs the widened check and returns
    /// `error.Overflow` instead of wrapping. (findings.md C1)
    pub fn mul(self: Self, other: Self) !Self {
        const product = try std.math.mul(i128, self.value, other.value);
        return Self{ .value = @divTrunc(product, scale_factor) };
    }

    /// Division
    ///
    /// `self.value * scale_factor` is pre-scaled so the quotient keeps 9
    /// decimal places; that multiply can overflow i128 for large operands
    /// and must be checked *before* it executes (see `mul` above).
    pub fn div(self: Self, other: Self) !Self {
        if (other.value == 0) return error.DivisionByZero;
        const scaled = try std.math.mul(i128, self.value, scale_factor);
        return Self{ .value = @divTrunc(scaled, other.value) };
    }
    
    /// Percentage calculation
    pub fn percent(self: Self, pct: Self) !Self {
        const hundred = fromInt(100);
        return try self.mul(pct).div(hundred);
    }
    
    /// Round to n decimal places
    pub fn round(self: Self, places: u8) Self {
        if (places >= 9) return self;
        
        var divisor: i128 = 1;
        for (0..(9 - places)) |_| {
            divisor *= 10;
        }
        
        const remainder = @mod(self.value, divisor);
        const half = @divTrunc(divisor, 2);
        
        if (remainder >= half) {
            return Self{ .value = self.value - remainder + divisor };
        } else {
            return Self{ .value = self.value - remainder };
        }
    }
    
    /// Comparison
    pub fn equals(self: Self, other: Self) bool {
        return self.value == other.value;
    }
    
    pub fn lessThan(self: Self, other: Self) bool {
        return self.value < other.value;
    }
    
    pub fn greaterThan(self: Self, other: Self) bool {
        return self.value > other.value;
    }
    
    /// Zero value
    pub fn zero() Self {
        return Self{ .value = 0 };
    }
    
    /// Check if zero
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    
    /// Absolute value
    pub fn abs(self: Self) Self {
        return Self{ .value = if (self.value < 0) -self.value else self.value };
    }
    
    /// Negate
    pub fn negate(self: Self) Self {
        return Self{ .value = -self.value };
    }
};

test "Decimal arithmetic" {
    const a = Decimal.fromInt(100);
    const b = Decimal.fromInt(50);
    
    const sum = try a.add(b);
    try std.testing.expect(sum.equals(Decimal.fromInt(150)));
    
    const diff = try a.sub(b);
    try std.testing.expect(diff.equals(Decimal.fromInt(50)));
    
    const product = try a.mul(b);
    try std.testing.expect(product.equals(Decimal.fromInt(5000)));
    
    const quotient = try a.div(b);
    try std.testing.expect(quotient.equals(Decimal.fromInt(2)));
}

test "Decimal from string" {
    const d1 = try Decimal.fromString("123.456");
    const d2 = try Decimal.fromString("-99.99");
    const d3 = try Decimal.fromString("0.001");
    
    try std.testing.expect(d1.toFloat() == 123.456);
    try std.testing.expect(d2.toFloat() == -99.99);
    try std.testing.expect(d3.toFloat() == 0.001);
}

test "Decimal fromFixedPoint" {
    // scale = 8 (satoshi scale): 12_345 → 0.00012345
    const d1 = Decimal.fromFixedPoint(12_345, 8);
    try std.testing.expectEqual(@as(i128, 12_345 * 10), d1.value); // 9-8=1 multiplier

    // scale = 9 (matches internal): 123_000_000 → 0.123000000
    const d2 = Decimal.fromFixedPoint(123_000_000, 9);
    try std.testing.expectEqual(@as(i128, 123_000_000), d2.value);

    // scale = 2 (cents): 1_999 → 19.99
    const d3 = Decimal.fromFixedPoint(1_999, 2);
    try std.testing.expectEqual(@as(i128, 19_990_000_000), d3.value);

    // scale = 12 (deeper than internal): excess precision truncates
    // 1_000_000_000_000 at scale=12 ⇒ 1.0 ⇒ internal value 1_000_000_000
    const d4 = Decimal.fromFixedPoint(1_000_000_000_000, 12);
    try std.testing.expectEqual(@as(i128, 1_000_000_000), d4.value);
}

// External-anchored golden vectors for mul/div.
//
// Inputs AND expected outputs are produced by an independent implementation —
// CPython's `decimal.Decimal` at 60-digit precision — replicating this type's
// fixed-point storage (internal scale 10^9, @divTrunc toward zero). These are
// NOT roundtrip (`decode(encode(x)) == x`) tests: the expected `.value`
// integers below were computed by the reference implementation, not by calling
// this library. Regenerate with:
//
//   python3 - <<'PY'
//   from decimal import Decimal, getcontext; getcontext().prec = 60
//   SF = 10**9
//   iv = lambda s: int(Decimal(s) * SF)
//   for a,b in [("1.5","2.5"),("0.1","0.2"),("12345.678","2"),("-3.5","4")]:
//       p = iv(a)*iv(b); q = p//SF if p>=0 else -((-p)//SF); print(a,b,q)
//   for a,b in [("1","8"),("100","8"),("1","3"),("-1","4")]:
//       n = iv(a)*SF; q = abs(n)//abs(iv(b)); q = -q if (n<0)^(iv(b)<0) else q; print(a,b,q)
//   PY
test "Decimal mul golden vectors (CPython decimal reference)" {
    const cases = [_]struct { a: []const u8, b: []const u8, want: i128 }{
        .{ .a = "1.5", .b = "2.5", .want = 3_750_000_000 }, // 3.75
        .{ .a = "0.1", .b = "0.2", .want = 20_000_000 }, // 0.02
        .{ .a = "12345.678", .b = "2", .want = 24_691_356_000_000 }, // 24691.356
        .{ .a = "-3.5", .b = "4", .want = -14_000_000_000 }, // -14
    };
    for (cases) |c| {
        const a = try Decimal.fromString(c.a);
        const b = try Decimal.fromString(c.b);
        const got = try a.mul(b);
        try std.testing.expectEqual(c.want, got.value);
    }
}

test "Decimal div golden vectors (CPython decimal reference)" {
    const cases = [_]struct { a: []const u8, b: []const u8, want: i128 }{
        .{ .a = "1", .b = "8", .want = 125_000_000 }, // 0.125
        .{ .a = "100", .b = "8", .want = 12_500_000_000 }, // 12.5
        .{ .a = "1", .b = "3", .want = 333_333_333 }, // 0.333333333 (trunc)
        .{ .a = "-1", .b = "4", .want = -250_000_000 }, // -0.25
    };
    for (cases) |c| {
        const a = try Decimal.fromString(c.a);
        const b = try Decimal.fromString(c.b);
        const got = try a.div(b);
        try std.testing.expectEqual(c.want, got.value);
    }
    try std.testing.expectError(error.DivisionByZero, (try Decimal.fromString("5")).div(Decimal.zero()));
}

// Overflow-before-check regression (findings.md C1).
//
// The boundary is the published i128 maximum,
// std.math.maxInt(i128) = 170141183460469231731687303715884105727.
//
// mul: fromInt(10^15) has internal value 10^24 (well inside max_safe_value
// ≈ 1.70e29, so construction is valid). Its raw self-product 10^48 exceeds
// i128 max by ten orders of magnitude. The pre-fix code computed
// `self.value * other.value` first, wrapping mod 2^128 into a small in-range
// number, then divided — yielding a bogus finite `position_value` that
// defeated every downstream risk cap. The fix must return error.Overflow.
test "Decimal mul overflow returns error, not a wrapped value" {
    const big = Decimal.fromInt(1_000_000_000_000_000); // 10^15, value = 10^24
    // Sanity: the operand itself is representable (no construction overflow).
    try std.testing.expectEqual(@as(i128, 1_000_000_000_000_000_000_000_000), big.value);
    // 10^24 * 10^24 = 10^48 > maxInt(i128): must error rather than wrap.
    try std.testing.expectError(error.Overflow, big.mul(big));
}

test "Decimal div overflow (pre-scale multiply) returns error" {
    // value 2e29 is a valid i128 but 2e29 * scale_factor(1e9) = 2e38 exceeds
    // maxInt(i128) ≈ 1.70e38, so the pre-scaling multiply inside div must be
    // checked and surface error.Overflow.
    const big = Decimal{ .value = 200_000_000_000_000_000_000_000_000_000 }; // 2e29
    try std.testing.expectError(error.Overflow, big.div(Decimal.fromInt(1)));
}

test "Decimal rounding" {
    const d = try Decimal.fromString("123.456789");
    const r2 = d.round(2);
    const r5 = d.round(5);
    
    try std.testing.expect(r2.toFloat() == 123.46);
    try std.testing.expect(r5.toFloat() == 123.45679);
}