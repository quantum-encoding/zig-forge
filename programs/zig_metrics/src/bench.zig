//! zig_metrics Benchmarks

const std = @import("std");
const metrics = @import("metrics");

/// Timer implementation using clock_gettime for Zig 0.16+ compatibility
/// (std.time.Timer was removed in Zig 0.16)
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.gpa;

    try stdout.print("\n=== zig_metrics Benchmarks ===\n\n", .{});

    const iterations: usize = 10_000_000;

    // Counter benchmarks
    try stdout.print("--- Counter ---\n", .{});
    {
        var counter = metrics.Counter.init("bench_counter", "Benchmark counter");

        var timer = try Timer.start();
        for (0..iterations) |_| {
            counter.inc();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("inc():       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    {
        var counter = metrics.Counter.init("bench_counter", "Benchmark counter");

        var timer = try Timer.start();
        for (0..iterations) |i| {
            counter.add(i % 100);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("add():       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Gauge benchmarks
    try stdout.print("\n--- Gauge ---\n", .{});
    {
        var gauge_val = metrics.Gauge.init("bench_gauge", "Benchmark gauge");

        var timer = try Timer.start();
        for (0..iterations) |i| {
            gauge_val.set(@floatFromInt(i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("set():       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    {
        var gauge_val = metrics.Gauge.init("bench_gauge", "Benchmark gauge");

        var timer = try Timer.start();
        for (0..iterations) |_| {
            gauge_val.inc();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("inc():       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    {
        var gauge_int = metrics.GaugeInt.init("bench_gauge_int", "Benchmark gauge int");

        var timer = try Timer.start();
        for (0..iterations) |_| {
            gauge_int.inc();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("int inc():   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Histogram benchmarks
    try stdout.print("\n--- Histogram ---\n", .{});

    // With 11 buckets (default)
    {
        var hist = try metrics.Histogram.init(allocator, "bench_hist", "Benchmark histogram", metrics.Histogram.defaultBuckets());
        defer hist.deinit();

        const hist_iterations: usize = 1_000_000;
        var timer = try Timer.start();
        for (0..hist_iterations) |i| {
            hist.observe(@as(f64, @floatFromInt(i % 1000)) / 1000.0);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(hist_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("observe(11): {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // With 5 buckets
    {
        var hist = try metrics.Histogram.init(allocator, "bench_hist", "Benchmark histogram", &[_]f64{ 0.1, 0.25, 0.5, 0.75, 1.0 });
        defer hist.deinit();

        const hist_iterations: usize = 1_000_000;
        var timer = try Timer.start();
        for (0..hist_iterations) |i| {
            hist.observe(@as(f64, @floatFromInt(i % 1000)) / 1000.0);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(hist_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("observe(5):  {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Export benchmarks
    try stdout.print("\n--- Export (Prometheus format) ---\n", .{});
    {
        var counter = metrics.Counter.init("http_requests_total", "Total HTTP requests");
        counter.add(123456);

        const export_iterations: usize = 100_000;
        var timer = try Timer.start();
        for (0..export_iterations) |_| {
            var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
            defer writer.deinit();
            counter.write(&writer.writer) catch unreachable;
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(export_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("counter:     {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    {
        var hist = try metrics.Histogram.init(allocator, "request_duration", "Duration", metrics.Histogram.defaultBuckets());
        defer hist.deinit();

        for (0..1000) |i| {
            hist.observe(@as(f64, @floatFromInt(i)) / 1000.0);
        }

        const export_iterations: usize = 10_000;
        var timer = try Timer.start();
        for (0..export_iterations) |_| {
            var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
            defer writer.deinit();
            hist.write(&writer.writer) catch unreachable;
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(export_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("histogram:   {d:.1} ns/op  ({d:.2}K/sec)\n", .{ ns_per_op, ops_per_sec / 1_000 });
    }

    try stdout.print("\n", .{});
    try stdout.flush();
}
