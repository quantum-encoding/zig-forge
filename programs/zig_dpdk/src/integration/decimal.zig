/// Fixed-point decimal arithmetic for financial calculations.
/// Compatible with financial_engine's Decimal type.
///
/// Uses i64 with 9 decimal places (scale = 1_000_000_000).
/// i64 range: ±9,223,372,036 with 9 decimal places — sufficient for
/// all cryptocurrency and equity prices.
///
/// Why not f64: floating-point accumulation errors cause incorrect P&L,
/// wrong fill quantities, and failed exchange order validation.

const std = @import("std");

pub const SCALE: i64 = 1_000_000_000; // 10^9

pub const Decimal = struct {
    value: i64,

    pub const ZERO = Decimal{ .value = 0 };
    pub const ONE = Decimal{ .value = SCALE };

    pub fn fromInt(n: i64) Decimal {
        return .{ .value = n * SCALE };
    }

    pub fn fromFloat(f: f64) Decimal {
        return .{ .value = @intFromFloat(f * @as(f64, @floatFromInt(SCALE))) };
    }

    pub fn toFloat(self: Decimal) f64 {
        return @as(f64, @floatFromInt(self.value)) / @as(f64, @floatFromInt(SCALE));
    }

    pub fn add(self: Decimal, other: Decimal) Decimal {
        return .{ .value = self.value + other.value };
    }

    pub fn sub(self: Decimal, other: Decimal) Decimal {
        return .{ .value = self.value - other.value };
    }

    pub fn mul(self: Decimal, other: Decimal) Decimal {
        // Use i128 for intermediate product to avoid overflow
        const product: i128 = @as(i128, self.value) * @as(i128, other.value);
        return .{ .value = @intCast(@divTrunc(product, SCALE)) };
    }

    pub fn div(self: Decimal, other: Decimal) Decimal {
        if (other.value == 0) return ZERO;
        const scaled: i128 = @as(i128, self.value) * SCALE;
        return .{ .value = @intCast(@divTrunc(scaled, other.value)) };
    }

    pub fn lessThan(self: Decimal, other: Decimal) bool {
        return self.value < other.value;
    }

    pub fn greaterThan(self: Decimal, other: Decimal) bool {
        return self.value > other.value;
    }

    pub fn eql(self: Decimal, other: Decimal) bool {
        return self.value == other.value;
    }

    pub fn abs(self: Decimal) Decimal {
        return .{ .value = if (self.value < 0) -self.value else self.value };
    }

    /// Format for display: "1234.567890000"
    pub fn format(self: Decimal, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const v = if (self.value < 0) -self.value else self.value;
        if (self.value < 0) try writer.writeByte('-');
        const whole = @divTrunc(v, SCALE);
        const frac = @rem(v, SCALE);
        try writer.print("{d}.{d:0>9}", .{ whole, frac });
    }
};

/// Parse a decimal from a string slice (no allocation).
/// Handles: "123.456", "0.001", "99", "-12.5"
pub fn parseDecimal(s: []const u8) ?Decimal {
    if (s.len == 0) return null;

    var negative = false;
    var start: usize = 0;
    if (s[0] == '-') {
        negative = true;
        start = 1;
    }

    var whole: i64 = 0;
    var frac: i64 = 0;
    var frac_digits: u8 = 0;
    var in_frac = false;

    for (s[start..]) |c| {
        if (c == '.') {
            if (in_frac) return null; // double dot
            in_frac = true;
            continue;
        }
        if (c == '"') break; // JSON string terminator
        if (c < '0' or c > '9') return null;

        if (in_frac) {
            if (frac_digits < 9) { // max precision
                frac = frac * 10 + (c - '0');
                frac_digits += 1;
            }
        } else {
            whole = whole * 10 + (c - '0');
        }
    }

    // Scale fraction to 9 decimal places
    while (frac_digits < 9) : (frac_digits += 1) {
        frac *= 10;
    }

    var value = whole * SCALE + frac;
    if (negative) value = -value;
    return Decimal{ .value = value };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "decimal: from/to float" {
    const d = Decimal.fromFloat(123.456);
    const f = d.toFloat();
    try testing.expect(@abs(f - 123.456) < 0.0000001);
}

test "decimal: from int" {
    const d = Decimal.fromInt(42);
    try testing.expectEqual(@as(i64, 42 * SCALE), d.value);
    try testing.expect(@abs(d.toFloat() - 42.0) < 0.0000001);
}

test "decimal: arithmetic" {
    const a = Decimal.fromFloat(10.5);
    const b = Decimal.fromFloat(3.2);
    try testing.expect(@abs(a.add(b).toFloat() - 13.7) < 0.0000001);
    try testing.expect(@abs(a.sub(b).toFloat() - 7.3) < 0.0000001);
    try testing.expect(@abs(a.mul(b).toFloat() - 33.6) < 0.0000001);
    try testing.expect(@abs(a.div(b).toFloat() - 3.28125) < 0.0000001);
}

test "decimal: comparison" {
    const a = Decimal.fromFloat(1.5);
    const b = Decimal.fromFloat(2.5);
    try testing.expect(a.lessThan(b));
    try testing.expect(b.greaterThan(a));
    try testing.expect(!a.eql(b));
    try testing.expect(a.eql(a));
}

test "decimal: parse string" {
    const d1 = parseDecimal("123.456").?;
    try testing.expect(@abs(d1.toFloat() - 123.456) < 0.0000001);

    const d2 = parseDecimal("0.001").?;
    try testing.expect(@abs(d2.toFloat() - 0.001) < 0.0000001);

    const d3 = parseDecimal("99").?;
    try testing.expect(@abs(d3.toFloat() - 99.0) < 0.0000001);

    const d4 = parseDecimal("-12.5").?;
    try testing.expect(@abs(d4.toFloat() + 12.5) < 0.0000001);

    try testing.expect(parseDecimal("") == null);
    try testing.expect(parseDecimal("abc") == null);
}

test "decimal: parse with JSON quote terminator" {
    // JSON values often end with a quote
    const d = parseDecimal("45678.12345678\"").?;
    try testing.expect(@abs(d.toFloat() - 45678.12345678) < 0.0001);
}
