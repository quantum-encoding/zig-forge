//! Axis Scaling
//!
//! Maps data domain to pixel range. Supports linear, logarithmic, and time scales.
//! Generates nice tick values for axis labels.

const std = @import("std");

/// Linear scale: maps [domain_min, domain_max] to [range_min, range_max]
pub const LinearScale = struct {
    domain_min: f64,
    domain_max: f64,
    range_min: f64,
    range_max: f64,
    clamp: bool = false,

    const Self = @This();

    /// Create a linear scale
    pub fn init(domain_min: f64, domain_max: f64, range_min: f64, range_max: f64) Self {
        return .{
            .domain_min = domain_min,
            .domain_max = domain_max,
            .range_min = range_min,
            .range_max = range_max,
        };
    }

    /// Map a domain value to range
    pub fn scale(self: Self, value: f64) f64 {
        const domain_span = self.domain_max - self.domain_min;
        if (domain_span == 0) return self.range_min;

        const t = (value - self.domain_min) / domain_span;
        const clamped_t = if (self.clamp) @min(1.0, @max(0.0, t)) else t;
        return self.range_min + clamped_t * (self.range_max - self.range_min);
    }

    /// Map a range value back to domain (inverse)
    pub fn invert(self: Self, value: f64) f64 {
        const range_span = self.range_max - self.range_min;
        if (range_span == 0) return self.domain_min;

        const t = (value - self.range_min) / range_span;
        return self.domain_min + t * (self.domain_max - self.domain_min);
    }

    /// Generate nice tick values for axis labels
    pub fn ticks(self: Self, allocator: std.mem.Allocator, approx_count: usize) ![]f64 {
        const span = self.domain_max - self.domain_min;
        if (span == 0) {
            const result = try allocator.alloc(f64, 1);
            result[0] = self.domain_min;
            return result;
        }

        // Calculate nice step size
        const raw_step = span / @as(f64, @floatFromInt(approx_count));
        const magnitude = @floor(@log10(@abs(raw_step)));
        const power = std.math.pow(f64, 10.0, magnitude);
        const normalized = raw_step / power;

        // Round to nice values: 1, 2, 5, 10
        const nice_step = blk: {
            if (normalized <= 1.5) break :blk 1.0 * power;
            if (normalized <= 3.0) break :blk 2.0 * power;
            if (normalized <= 7.0) break :blk 5.0 * power;
            break :blk 10.0 * power;
        };

        // Generate ticks
        const start = @ceil(self.domain_min / nice_step) * nice_step;
        const count: usize = @intFromFloat(@floor((self.domain_max - start) / nice_step) + 1);

        var result = try allocator.alloc(f64, count);
        for (0..count) |i| {
            result[i] = start + @as(f64, @floatFromInt(i)) * nice_step;
        }
        return result;
    }

    /// Extend domain to nice round numbers
    pub fn nice(self: *Self) void {
        const span = self.domain_max - self.domain_min;
        if (span == 0) return;

        const step = niceNumber(span / 10.0, false);
        self.domain_min = @floor(self.domain_min / step) * step;
        self.domain_max = @ceil(self.domain_max / step) * step;
    }
};

/// Logarithmic scale (base 10)
pub const LogScale = struct {
    domain_min: f64,
    domain_max: f64,
    range_min: f64,
    range_max: f64,
    clamp: bool = false,

    const Self = @This();

    pub fn init(domain_min: f64, domain_max: f64, range_min: f64, range_max: f64) Self {
        return .{
            .domain_min = @max(1e-10, domain_min), // Avoid log(0)
            .domain_max = @max(1e-10, domain_max),
            .range_min = range_min,
            .range_max = range_max,
        };
    }

    pub fn scale(self: Self, value: f64) f64 {
        const v = @max(1e-10, value);
        const log_min = @log10(self.domain_min);
        const log_max = @log10(self.domain_max);
        const log_val = @log10(v);

        const t = (log_val - log_min) / (log_max - log_min);
        const clamped_t = if (self.clamp) @min(1.0, @max(0.0, t)) else t;
        return self.range_min + clamped_t * (self.range_max - self.range_min);
    }

    pub fn invert(self: Self, value: f64) f64 {
        const range_span = self.range_max - self.range_min;
        if (range_span == 0) return self.domain_min;

        const t = (value - self.range_min) / range_span;
        const log_min = @log10(self.domain_min);
        const log_max = @log10(self.domain_max);
        return std.math.pow(f64, 10.0, log_min + t * (log_max - log_min));
    }

    /// Generate logarithmic ticks (powers of 10)
    pub fn ticks(self: Self, allocator: std.mem.Allocator) ![]f64 {
        const log_min = @floor(@log10(self.domain_min));
        const log_max = @ceil(@log10(self.domain_max));
        const count: usize = @intFromFloat(log_max - log_min + 1);

        var result = try allocator.alloc(f64, count);
        for (0..count) |i| {
            result[i] = std.math.pow(f64, 10.0, log_min + @as(f64, @floatFromInt(i)));
        }
        return result;
    }
};

/// Time scale for timestamps (Unix epoch seconds or milliseconds)
pub const TimeScale = struct {
    domain_min: i64, // Unix timestamp
    domain_max: i64,
    range_min: f64,
    range_max: f64,
    is_milliseconds: bool = false,

    const Self = @This();

    pub fn init(domain_min: i64, domain_max: i64, range_min: f64, range_max: f64) Self {
        return .{
            .domain_min = domain_min,
            .domain_max = domain_max,
            .range_min = range_min,
            .range_max = range_max,
        };
    }

    pub fn scale(self: Self, timestamp: i64) f64 {
        const domain_span: f64 = @floatFromInt(self.domain_max - self.domain_min);
        if (domain_span == 0) return self.range_min;

        const t: f64 = @as(f64, @floatFromInt(timestamp - self.domain_min)) / domain_span;
        return self.range_min + t * (self.range_max - self.range_min);
    }

    pub fn invert(self: Self, value: f64) i64 {
        const range_span = self.range_max - self.range_min;
        if (range_span == 0) return self.domain_min;

        const t = (value - self.range_min) / range_span;
        const domain_span: f64 = @floatFromInt(self.domain_max - self.domain_min);
        return self.domain_min + @as(i64, @intFromFloat(t * domain_span));
    }

    /// Time intervals for tick generation
    pub const Interval = enum {
        second,
        minute,
        hour,
        day,
        week,
        month,
        year,

        pub fn seconds(self: Interval) i64 {
            return switch (self) {
                .second => 1,
                .minute => 60,
                .hour => 3600,
                .day => 86400,
                .week => 604800,
                .month => 2592000, // 30 days approx
                .year => 31536000, // 365 days
            };
        }
    };

    /// Generate time-based ticks
    pub fn ticks(self: Self, allocator: std.mem.Allocator, approx_count: usize) ![]i64 {
        const span = self.domain_max - self.domain_min;
        const target_interval = @divFloor(span, @as(i64, @intCast(approx_count)));

        // Find appropriate interval
        const interval: i64 = blk: {
            if (target_interval < 60) break :blk niceTimeInterval(target_interval, 1); // seconds
            if (target_interval < 3600) break :blk niceTimeInterval(target_interval, 60); // minutes
            if (target_interval < 86400) break :blk niceTimeInterval(target_interval, 3600); // hours
            if (target_interval < 604800) break :blk niceTimeInterval(target_interval, 86400); // days
            break :blk niceTimeInterval(target_interval, 604800); // weeks
        };

        const start = @divFloor(self.domain_min, interval) * interval;
        const count: usize = @intCast(@divFloor(self.domain_max - start, interval) + 1);

        var result = try allocator.alloc(i64, count);
        for (0..count) |i| {
            result[i] = start + @as(i64, @intCast(i)) * interval;
        }
        return result;
    }
};

/// Band scale for categorical data (bar charts)
pub const BandScale = struct {
    domain: []const []const u8, // Category names
    range_min: f64,
    range_max: f64,
    padding_inner: f64 = 0.1, // Padding between bands (0-1)
    padding_outer: f64 = 0.05, // Padding at edges (0-1)

    const Self = @This();

    pub fn init(domain: []const []const u8, range_min: f64, range_max: f64) Self {
        return .{
            .domain = domain,
            .range_min = range_min,
            .range_max = range_max,
        };
    }

    /// Get band width
    pub fn bandwidth(self: Self) f64 {
        const n = self.domain.len;
        if (n == 0) return 0;

        const range_span = self.range_max - self.range_min;
        const outer_padding = self.padding_outer * 2;
        const inner_padding = self.padding_inner * @as(f64, @floatFromInt(n - 1));
        const total_padding = outer_padding + inner_padding;

        return (range_span * (1.0 - total_padding / @as(f64, @floatFromInt(n)))) / @as(f64, @floatFromInt(n));
    }

    /// Get position for category index
    pub fn scale(self: Self, index: usize) f64 {
        if (index >= self.domain.len) return self.range_min;

        const step_size = self.step();
        return self.range_min + self.padding_outer * step_size + @as(f64, @floatFromInt(index)) * step_size;
    }

    /// Step size between band starts
    pub fn step(self: Self) f64 {
        const n = self.domain.len;
        if (n == 0) return 0;
        return (self.range_max - self.range_min) / @as(f64, @floatFromInt(n));
    }

    /// Find index for category name
    pub fn indexOf(self: Self, name: []const u8) ?usize {
        for (self.domain, 0..) |d, i| {
            if (std.mem.eql(u8, d, name)) return i;
        }
        return null;
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate a "nice" number close to the input
fn niceNumber(value: f64, round: bool) f64 {
    const exp = @floor(@log10(@abs(value)));
    const fraction = value / std.math.pow(f64, 10.0, exp);

    const nice_fraction = if (round) blk: {
        if (fraction < 1.5) break :blk 1.0;
        if (fraction < 3.0) break :blk 2.0;
        if (fraction < 7.0) break :blk 5.0;
        break :blk 10.0;
    } else blk: {
        if (fraction <= 1.0) break :blk 1.0;
        if (fraction <= 2.0) break :blk 2.0;
        if (fraction <= 5.0) break :blk 5.0;
        break :blk 10.0;
    };

    return nice_fraction * std.math.pow(f64, 10.0, exp);
}

/// Find nice time interval
fn niceTimeInterval(target: i64, base: i64) i64 {
    const multiples = [_]i64{ 1, 2, 5, 10, 15, 30, 60 };
    for (multiples) |m| {
        if (m * base >= target) return m * base;
    }
    return target;
}

// =============================================================================
// Tests
// =============================================================================

test "linear scale basic" {
    const scale = LinearScale.init(0, 100, 0, 500);
    try std.testing.expectEqual(@as(f64, 0), scale.scale(0));
    try std.testing.expectEqual(@as(f64, 250), scale.scale(50));
    try std.testing.expectEqual(@as(f64, 500), scale.scale(100));
}

test "linear scale invert" {
    const scale = LinearScale.init(0, 100, 0, 500);
    try std.testing.expectEqual(@as(f64, 50), scale.invert(250));
}

test "linear scale ticks" {
    var scale = LinearScale.init(0, 100, 0, 500);
    const allocator = std.testing.allocator;
    const tick_values = try scale.ticks(allocator, 5);
    defer allocator.free(tick_values);

    try std.testing.expect(tick_values.len > 0);
    try std.testing.expect(tick_values[0] >= 0);
}

test "log scale" {
    const scale = LogScale.init(1, 1000, 0, 300);
    try std.testing.expectEqual(@as(f64, 0), scale.scale(1));
    try std.testing.expectApproxEqRel(@as(f64, 150), scale.scale(31.62), 0.1); // sqrt(1000)
    try std.testing.expectEqual(@as(f64, 300), scale.scale(1000));
}

test "band scale" {
    const categories = [_][]const u8{ "A", "B", "C" };
    const scale = BandScale.init(&categories, 0, 300);

    try std.testing.expect(scale.bandwidth() > 0);
    try std.testing.expect(scale.scale(0) >= 0);
    try std.testing.expect(scale.scale(1) > scale.scale(0));
}
