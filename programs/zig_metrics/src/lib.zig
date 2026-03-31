//! zig_metrics - Prometheus Metrics Library
//!
//! A high-performance Prometheus metrics library for Zig applications.
//!
//! ## Metric Types
//!
//! - **Counter**: Monotonically increasing value (requests, errors, etc.)
//! - **Gauge**: Value that can go up and down (temperature, memory, etc.)
//! - **Histogram**: Observations in configurable buckets (latency, size, etc.)
//!
//! ## Features
//!
//! - Thread-safe atomic operations
//! - Zero allocations in metric operations (except histogram init)
//! - Prometheus exposition format output
//! - Label support for dimensional metrics
//!
//! ## Example
//!
//! ```zig
//! const metrics = @import("metrics");
//!
//! // Define metrics
//! var requests = metrics.Counter.init("http_requests_total", "Total HTTP requests");
//! var active = metrics.Gauge.init("active_connections", "Active connections");
//! var latency = try metrics.Histogram.init(allocator, "request_duration_seconds",
//!     "Request duration", metrics.Histogram.defaultBuckets());
//!
//! // Record metrics
//! requests.inc();
//! active.inc();
//! latency.observe(0.123);
//!
//! // Export to Prometheus format
//! var buffer: [4096]u8 = undefined;
//! var stream = std.io.fixedBufferStream(&buffer);
//! try requests.write(stream.writer());
//! try active.write(stream.writer());
//! try latency.write(stream.writer());
//! ```

pub const counter = @import("counter.zig");
pub const gauge = @import("gauge.zig");
pub const histogram = @import("histogram.zig");

// Re-export main types
pub const Counter = counter.Counter;
pub const CounterF64 = counter.CounterF64;
pub const Gauge = gauge.Gauge;
pub const GaugeInt = gauge.GaugeInt;
pub const Histogram = histogram.Histogram;
pub const Label = Counter.Label;

/// Version info
pub const version = "0.1.0";
pub const version_major = 0;
pub const version_minor = 1;
pub const version_patch = 0;

/// Registry for managing multiple metrics
pub const Registry = struct {
    counters: std.ArrayList(*Counter),
    gauges: std.ArrayList(*Gauge),
    histograms: std.ArrayList(*Histogram),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .counters = std.ArrayList(*Counter).init(allocator),
            .gauges = std.ArrayList(*Gauge).init(allocator),
            .histograms = std.ArrayList(*Histogram).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.counters.deinit();
        self.gauges.deinit();
        self.histograms.deinit();
    }

    pub fn registerCounter(self: *Self, c: *Counter) !void {
        try self.counters.append(c);
    }

    pub fn registerGauge(self: *Self, g: *Gauge) !void {
        try self.gauges.append(g);
    }

    pub fn registerHistogram(self: *Self, h: *Histogram) !void {
        try self.histograms.append(h);
    }

    /// Write all registered metrics
    pub fn write(self: *const Self, writer: anytype) !void {
        for (self.counters.items) |c| {
            try c.write(writer);
            try writer.writeAll("\n");
        }
        for (self.gauges.items) |g| {
            try g.write(writer);
            try writer.writeAll("\n");
        }
        for (self.histograms.items) |h| {
            try h.write(writer);
            try writer.writeAll("\n");
        }
    }
};

const std = @import("std");

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}

// ============================================================================
// Additional Registry Tests
// ============================================================================

test "registry add and remove metrics" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var c1 = Counter.init("requests", "Total requests");
    var c2 = Counter.init("errors", "Total errors");

    try registry.registerCounter(&c1);
    try registry.registerCounter(&c2);

    try std.testing.expectEqual(@as(usize, 2), registry.counters.items.len);
}

test "registry write all metrics" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var c = Counter.init("test_counter", "Test counter");
    c.add(42);

    var g = Gauge.init("test_gauge", "Test gauge");
    g.set(3.14);

    try registry.registerCounter(&c);
    try registry.registerGauge(&g);

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try registry.write(&writer.writer);

    const output = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "test_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test_gauge") != null);
}

test "counter thread safety simulation" {
    const allocator = std.testing.allocator;
    var test_counter = Counter.init("thread_test", "Thread test counter");

    // Simulate concurrent increments
    for (0..1000) |_| {
        test_counter.inc();
    }

    try std.testing.expectEqual(@as(u64, 1000), test_counter.get());
    _ = allocator;
}

test "gauge thread safety simulation" {
    const allocator = std.testing.allocator;
    var test_gauge = Gauge.init("thread_test_gauge", "Thread test gauge");

    test_gauge.set(100.0);
    for (0..100) |_| {
        test_gauge.add(1.0);
    }

    try std.testing.expectApproxEqAbs(@as(f64, 200.0), test_gauge.get(), 0.001);
    _ = allocator;
}

test "histogram with labels" {
    const allocator = std.testing.allocator;

    const labels = [_]Counter.Label{
        .{ .name = "endpoint", .value = "/api/users" },
    };

    var hist = try Histogram.init(
        allocator,
        "request_duration",
        "Request duration",
        &[_]f64{ 0.1, 0.5, 1.0 },
    );
    defer hist.deinit();
    hist.labels = &labels;

    hist.observe(0.25);
    hist.observe(0.75);

    try std.testing.expectEqual(@as(u64, 2), hist.getCount());
}

test "counter f64 scaling" {
    var float_counter = CounterF64.init("float_counter", "Float counter");

    float_counter.add(1.5);
    float_counter.add(2.5);

    const val = float_counter.get();
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), val, 0.001);
}

test "histogram bucket distribution" {
    const allocator = std.testing.allocator;

    var hist = try Histogram.init(
        allocator,
        "dist_test",
        "Distribution test",
        &[_]f64{ 0.1, 0.5, 1.0 },
    );
    defer hist.deinit();

    // Observations: one in each bucket + one in +Inf
    hist.observe(0.05);  // <= 0.1
    hist.observe(0.25);  // <= 0.5
    hist.observe(0.75);  // <= 1.0
    hist.observe(2.0);   // > 1.0

    try std.testing.expectEqual(@as(u64, 4), hist.getCount());
}
