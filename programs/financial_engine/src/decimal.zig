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
    
    /// Create from string representation
    pub fn fromString(str: []const u8) !Self {
        var parts = std.mem.split(u8, str, ".");
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
            var multiplier = scale_factor;
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
    
    /// Format for display
    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        
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
    pub fn mul(self: Self, other: Self) !Self {
        const result = @divTrunc(self.value * other.value, scale_factor);
        return Self{ .value = result };
    }
    
    /// Division
    pub fn div(self: Self, other: Self) !Self {
        if (other.value == 0) return error.DivisionByZero;
        const scaled = self.value * scale_factor;
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

test "Decimal rounding" {
    const d = try Decimal.fromString("123.456789");
    const r2 = d.round(2);
    const r5 = d.round(5);
    
    try std.testing.expect(r2.toFloat() == 123.46);
    try std.testing.expect(r5.toFloat() == 123.45679);
}