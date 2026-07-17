//! Prometheus Histogram Metric
//!
//! A histogram samples observations (usually things like request durations
//! or response sizes) and counts them in configurable buckets. It also
//! provides a sum of all observed values and a count.
//!
//! Example:
//! ```zig
//! var histogram = try Histogram.init(allocator, "http_request_duration_seconds",
//!     "HTTP request duration", Histogram.defaultBuckets());
//! defer histogram.deinit();
//!
//! histogram.observe(0.25);  // Record 250ms request
//! histogram.observe(0.5);   // Record 500ms request
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Counter = @import("counter.zig").Counter;
const escape = @import("escape.zig");

/// Prometheus Histogram
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const Counter.Label = null,
    buckets: []const f64,
    bucket_counts: []std.atomic.Value(u64),
    sum_scaled: std.atomic.Value(i64),
    count: std.atomic.Value(u64),
    allocator: Allocator,

    const Self = @This();
    const SCALE: f64 = 1000000.0; // Higher precision for sums

    /// Default bucket boundaries for request duration (in seconds)
    pub fn defaultBuckets() []const f64 {
        return &[_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };
    }

    /// Linear buckets: start, width, count
    pub fn linearBuckets(allocator: Allocator, start: f64, width: f64, count_val: usize) ![]f64 {
        const buckets = try allocator.alloc(f64, count_val);
        for (buckets, 0..) |*b, i| {
            b.* = start + width * @as(f64, @floatFromInt(i));
        }
        return buckets;
    }

    /// Exponential buckets: start, factor, count
    pub fn exponentialBuckets(allocator: Allocator, start: f64, factor: f64, count_val: usize) ![]f64 {
        const buckets = try allocator.alloc(f64, count_val);
        var current = start;
        for (buckets) |*b| {
            b.* = current;
            current *= factor;
        }
        return buckets;
    }

    /// Initialize histogram with given buckets
    pub fn init(allocator: Allocator, name: []const u8, help: []const u8, buckets: []const f64) !Self {
        // Allocate bucket counts (+1 for +Inf)
        const bucket_counts = try allocator.alloc(std.atomic.Value(u64), buckets.len + 1);
        for (bucket_counts) |*bc| {
            bc.* = std.atomic.Value(u64).init(0);
        }

        return Self{
            .name = name,
            .help = help,
            .labels = null,
            .buckets = buckets,
            .bucket_counts = bucket_counts,
            .sum_scaled = std.atomic.Value(i64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bucket_counts);
    }

    /// Record an observation
    pub fn observe(self: *Self, val: f64) void {
        // Update sum
        const scaled: i64 = @intFromFloat(val * SCALE);
        _ = self.sum_scaled.fetchAdd(scaled, .monotonic);

        // Update count
        _ = self.count.fetchAdd(1, .monotonic);

        // Update buckets (cumulative)
        for (self.buckets, 0..) |bound, i| {
            if (val <= bound) {
                _ = self.bucket_counts[i].fetchAdd(1, .monotonic);
            }
        }
        // Always increment +Inf bucket
        _ = self.bucket_counts[self.buckets.len].fetchAdd(1, .monotonic);
    }

    /// Get total sum of observations
    pub fn getSum(self: *const Self) f64 {
        const scaled = self.sum_scaled.load(.monotonic);
        return @as(f64, @floatFromInt(scaled)) / SCALE;
    }

    /// Get total count of observations
    pub fn getCount(self: *const Self) u64 {
        return self.count.load(.monotonic);
    }

    /// Format as Prometheus exposition format
    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.print("# HELP {s} ", .{self.name});
        try escape.writeEscapedHelp(writer, self.help);
        try writer.writeAll("\n");
        try writer.print("# TYPE {s} histogram\n", .{self.name});

        // Write bucket lines. `observe` already stores cumulative per-bucket
        // counts (every bucket with bound >= val is incremented), so the
        // stored value IS the cumulative count — load it directly. Do NOT
        // re-accumulate here (that produced non-monotonic, doubly-counted
        // buckets and invalid exposition).
        for (self.buckets, 0..) |bound, i| {
            const count = self.bucket_counts[i].load(.monotonic);
            try writer.print("{s}_bucket{{le=\"{d}\"", .{ self.name, bound });

            if (self.labels) |labels| {
                for (labels) |label| {
                    try writer.print(",{s}=\"", .{label.name});
                    try escape.writeEscapedLabelValue(writer, label.value);
                    try writer.writeAll("\"");
                }
            }

            try writer.print("}} {}\n", .{count});
        }

        // +Inf bucket (stored cumulative count for all observations).
        const inf_count = self.bucket_counts[self.buckets.len].load(.monotonic);
        try writer.print("{s}_bucket{{le=\"+Inf\"", .{self.name});
        if (self.labels) |labels| {
            for (labels) |label| {
                try writer.print(",{s}=\"", .{label.name});
                try escape.writeEscapedLabelValue(writer, label.value);
                try writer.writeAll("\"");
            }
        }
        try writer.print("}} {}\n", .{inf_count});

        // Sum
        try writer.print("{s}_sum", .{self.name});
        if (self.labels) |labels| {
            try writer.writeAll("{");
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"", .{label.name});
                try escape.writeEscapedLabelValue(writer, label.value);
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }
        try writer.print(" {d}\n", .{self.getSum()});

        // Count
        try writer.print("{s}_count", .{self.name});
        if (self.labels) |labels| {
            try writer.writeAll("{");
            for (labels, 0..) |label, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{s}=\"", .{label.name});
                try escape.writeEscapedLabelValue(writer, label.value);
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }
        try writer.print(" {}\n", .{self.getCount()});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "histogram basic" {
    const allocator = std.testing.allocator;
    var hist = try Histogram.init(allocator, "test_histogram", "Test", &[_]f64{ 0.1, 0.5, 1.0 });
    defer hist.deinit();

    hist.observe(0.05);
    hist.observe(0.25);
    hist.observe(0.75);
    hist.observe(2.0);

    try std.testing.expectEqual(@as(u64, 4), hist.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 3.05), hist.getSum(), 0.001);
}

test "histogram prometheus format" {
    const allocator = std.testing.allocator;
    var hist = try Histogram.init(allocator, "request_duration", "Request duration", &[_]f64{ 0.1, 0.5, 1.0 });
    defer hist.deinit();

    hist.observe(0.25);
    hist.observe(0.75);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try hist.write(&writer.writer);

    const written = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "# TYPE request_duration histogram") != null);
    // Exact cumulative bucket values (observe 0.25, 0.75 into buckets {0.1,0.5,1.0}):
    // le=0.1 -> 0, le=0.5 -> 1, le=1.0 -> 2, le=+Inf -> 2. Must be monotonic.
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_bucket{le=\"0.1\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_bucket{le=\"0.5\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_bucket{le=\"1\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_bucket{le=\"+Inf\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "request_duration_count 2") != null);
}

test "histogram label value escaping" {
    const allocator = std.testing.allocator;
    var hist = try Histogram.init(allocator, "req", "Requests", &[_]f64{ 0.1, 0.5 });
    defer hist.deinit();

    const labels = [_]Counter.Label{
        .{ .name = "path", .value = "a\"b\\c" },
    };
    hist.labels = &labels;
    hist.observe(0.05);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try hist.write(&writer.writer);

    const written = writer.written();
    // The `"` and `\` in the label value must be escaped so the exposition
    // stays parseable.
    try std.testing.expect(std.mem.indexOf(u8, written, "path=\"a\\\"b\\\\c\"") != null);
}
