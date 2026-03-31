//! Prometheus Counter Metric
//!
//! A counter is a cumulative metric that represents a single monotonically
//! increasing counter whose value can only increase or be reset to zero.
//!
//! Use counters for: request counts, completed tasks, errors, etc.
//!
//! Example:
//! ```zig
//! var counter = Counter.init("http_requests_total", "Total HTTP requests");
//! counter.inc();           // Increment by 1
//! counter.add(5);          // Add 5
//! ```

const std = @import("std");

/// Prometheus Counter (monotonically increasing)
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const Label = null,
    value: std.atomic.Value(u64),

    const Self = @This();

    pub const Label = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Initialize a new counter
    pub fn init(name: []const u8, help: []const u8) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = null,
            .value = std.atomic.Value(u64).init(0),
        };
    }

    /// Initialize with labels
    pub fn initWithLabels(name: []const u8, help: []const u8, labels: []const Label) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = labels,
            .value = std.atomic.Value(u64).init(0),
        };
    }

    /// Increment counter by 1
    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Add value to counter (must be positive)
    pub fn add(self: *Self, val: u64) void {
        _ = self.value.fetchAdd(val, .monotonic);
    }

    /// Get current value
    pub fn get(self: *const Self) u64 {
        return self.value.load(.monotonic);
    }

    /// Reset counter to zero (use sparingly - counters shouldn't normally reset)
    pub fn reset(self: *Self) void {
        self.value.store(0, .monotonic);
    }

    /// Format as Prometheus exposition format
    pub fn write(self: *const Self, writer: anytype) !void {
        // Write HELP line
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });

        // Write TYPE line
        try writer.print("# TYPE {s} counter\n", .{self.name});

        // Write metric line
        try writer.print("{s}", .{self.name});

        // Write labels if present
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

/// Counter with floating point value (for compatibility)
pub const CounterF64 = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const Counter.Label = null,
    // Use integer representation scaled by 1000 for atomic operations
    value_scaled: std.atomic.Value(i64),

    const Self = @This();
    const SCALE: f64 = 1000.0;

    pub fn init(name: []const u8, help: []const u8) Self {
        return Self{
            .name = name,
            .help = help,
            .labels = null,
            .value_scaled = std.atomic.Value(i64).init(0),
        };
    }

    pub fn inc(self: *Self) void {
        _ = self.value_scaled.fetchAdd(@intFromFloat(SCALE), .monotonic);
    }

    pub fn add(self: *Self, val: f64) void {
        const scaled: i64 = @intFromFloat(val * SCALE);
        _ = self.value_scaled.fetchAdd(scaled, .monotonic);
    }

    pub fn get(self: *const Self) f64 {
        const scaled = self.value_scaled.load(.monotonic);
        return @as(f64, @floatFromInt(scaled)) / SCALE;
    }

    pub fn reset(self: *Self) void {
        self.value_scaled.store(0, .monotonic);
    }

    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} counter\n", .{self.name});
        try writer.print("{s}", .{self.name});

        if (self.labels) |labels| {
            try writer.writeAll("{");
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
            }
            try writer.writeAll("}");
        }

        try writer.print(" {d}\n", .{self.get()});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "counter basic operations" {
    var counter = Counter.init("test_counter", "A test counter");

    try std.testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(5);
    try std.testing.expectEqual(@as(u64, 6), counter.get());

    counter.reset();
    try std.testing.expectEqual(@as(u64, 0), counter.get());
}

test "counter prometheus format" {
    var counter = Counter.init("http_requests_total", "Total HTTP requests");
    counter.add(42);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try counter.write(&writer.writer);

    const expected =
        \\# HELP http_requests_total Total HTTP requests
        \\# TYPE http_requests_total counter
        \\http_requests_total 42
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.written());
}

test "counter with labels" {
    const labels = [_]Counter.Label{
        .{ .name = "method", .value = "GET" },
        .{ .name = "path", .value = "/api" },
    };
    var counter = Counter.initWithLabels("http_requests_total", "Total HTTP requests", &labels);
    counter.add(100);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try counter.write(&writer.writer);

    const written = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "method=\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "path=\"/api\"") != null);
}
