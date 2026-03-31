//! Prometheus Gauge Metric
//!
//! A gauge represents a single numerical value that can go up and down.
//! Gauges are typically used for measured values like temperatures, current
//! memory usage, or the number of concurrent requests.
//!
//! Example:
//! ```zig
//! var gauge = Gauge.init("temperature_celsius", "Current temperature");
//! gauge.set(23.5);          // Set absolute value
//! gauge.inc();              // Increment by 1
//! gauge.dec();              // Decrement by 1
//! gauge.add(5);             // Add 5
//! gauge.sub(2);             // Subtract 2
//! ```

const std = @import("std");
const Counter = @import("counter.zig").Counter;

/// Prometheus Gauge (value that can go up and down)
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const Counter.Label = null,
    // Store as scaled integer for atomic operations
    value_scaled: std.atomic.Value(i64),

    const Self = @This();
    const SCALE: f64 = 1000.0;

    /// Initialize a new gauge
    pub fn init(name: []const u8, help: []const u8) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = null,
            .value_scaled = std.atomic.Value(i64).init(0),
        };
    }

    /// Initialize with labels
    pub fn initWithLabels(name: []const u8, help: []const u8, labels: []const Counter.Label) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = labels,
            .value_scaled = std.atomic.Value(i64).init(0),
        };
    }

    /// Set gauge to a specific value
    pub fn set(self: *Self, val: f64) void {
        const scaled: i64 = @intFromFloat(val * SCALE);
        self.value_scaled.store(scaled, .monotonic);
    }

    /// Increment gauge by 1
    pub fn inc(self: *Self) void {
        _ = self.value_scaled.fetchAdd(@intFromFloat(SCALE), .monotonic);
    }

    /// Decrement gauge by 1
    pub fn dec(self: *Self) void {
        _ = self.value_scaled.fetchSub(@intFromFloat(SCALE), .monotonic);
    }

    /// Add value to gauge
    pub fn add(self: *Self, val: f64) void {
        const scaled: i64 = @intFromFloat(val * SCALE);
        _ = self.value_scaled.fetchAdd(scaled, .monotonic);
    }

    /// Subtract value from gauge
    pub fn sub(self: *Self, val: f64) void {
        const scaled: i64 = @intFromFloat(val * SCALE);
        _ = self.value_scaled.fetchSub(scaled, .monotonic);
    }

    /// Get current value
    pub fn get(self: *const Self) f64 {
        const scaled = self.value_scaled.load(.monotonic);
        return @as(f64, @floatFromInt(scaled)) / SCALE;
    }

    /// Set to current time (useful for last-updated timestamps)
    pub fn setToCurrentTime(self: *Self) void {
        const now = std.time.timestamp() catch 0;
        self.set(@floatFromInt(now));
    }

    /// Format as Prometheus exposition format
    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} gauge\n", .{self.name});
        try writer.print("{s}", .{self.name});

        if (self.labels) |labels| {
            try writer.writeAll("{");
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
            }
            try writer.writeAll("}");
        }

        const val = self.get();
        // Format nicely: integer if whole number, otherwise decimal
        if (val == @floor(val) and @abs(val) < 1e15) {
            try writer.print(" {d:.0}\n", .{val});
        } else {
            try writer.print(" {d}\n", .{val});
        }
    }
};

/// Integer gauge (for when you only need whole numbers)
pub const GaugeInt = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const Counter.Label = null,
    value: std.atomic.Value(i64),

    const Self = @This();

    pub fn init(name: []const u8, help: []const u8) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = null,
            .value = std.atomic.Value(i64).init(0),
        };
    }

    pub fn set(self: *Self, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Self) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Self, val: i64) void {
        _ = self.value.fetchAdd(val, .monotonic);
    }

    pub fn sub(self: *Self, val: i64) void {
        _ = self.value.fetchSub(val, .monotonic);
    }

    pub fn get(self: *const Self) i64 {
        return self.value.load(.monotonic);
    }

    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} gauge\n", .{self.name});
        try writer.print("{s}", .{self.name});

        if (self.labels) |labels| {
            try writer.writeAll("{");
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
            }
            try writer.writeAll("}");
        }

        try writer.print(" {}\n", .{self.get()});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "gauge basic operations" {
    var gauge = Gauge.init("test_gauge", "A test gauge");

    try std.testing.expectApproxEqAbs(@as(f64, 0), gauge.get(), 0.001);

    gauge.set(10.5);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), gauge.get(), 0.001);

    gauge.inc();
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), gauge.get(), 0.001);

    gauge.dec();
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), gauge.get(), 0.001);

    gauge.add(2.5);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), gauge.get(), 0.001);

    gauge.sub(3.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), gauge.get(), 0.001);
}

test "gauge prometheus format" {
    var gauge = Gauge.init("temperature_celsius", "Current temperature");
    gauge.set(23.5);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try gauge.write(&writer.writer);

    const written = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "# TYPE temperature_celsius gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "temperature_celsius 23.5") != null);
}

test "gauge int" {
    var gauge = GaugeInt.init("active_connections", "Number of active connections");

    gauge.set(5);
    try std.testing.expectEqual(@as(i64, 5), gauge.get());

    gauge.inc();
    try std.testing.expectEqual(@as(i64, 6), gauge.get());

    gauge.dec();
    try std.testing.expectEqual(@as(i64, 5), gauge.get());
}
