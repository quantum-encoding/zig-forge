//! zig_metrics CLI Demo
//!
//! Demonstrates Prometheus metrics collection and export.

const std = @import("std");
const metrics = @import("metrics");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.gpa;

    try stdout.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║          zig_metrics - Prometheus Metrics Demo               ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    try demoCounter(stdout);
    try demoGauge(stdout);
    try demoHistogram(allocator, stdout);
    try demoCompleteExport(allocator, stdout);

    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("All demos completed!\n\n", .{});
    try stdout.flush();
}

fn demoCounter(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 1: Counter                                             │\n", .{});
    try stdout.print("│ (Monotonically increasing value)                            │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var requests = metrics.Counter.init("http_requests_total", "Total HTTP requests received");

    // Simulate some requests
    try stdout.print("Simulating HTTP requests...\n", .{});
    for (0..100) |_| {
        requests.inc();
    }
    requests.add(50); // Add 50 more

    try stdout.print("Total requests: {}\n\n", .{requests.get()});

    try stdout.print("Prometheus format:\n", .{});
    try stdout.print("─────────────────\n", .{});
    try requests.write(stdout);
    try stdout.print("\n", .{});
}

fn demoGauge(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 2: Gauge                                               │\n", .{});
    try stdout.print("│ (Value that can go up and down)                             │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var temperature = metrics.Gauge.init("room_temperature_celsius", "Current room temperature");
    var connections = metrics.GaugeInt.init("active_connections", "Number of active connections");

    // Simulate temperature readings
    temperature.set(22.5);
    try stdout.print("Temperature set to: {d:.1}°C\n", .{temperature.get()});

    temperature.add(1.5);
    try stdout.print("After +1.5: {d:.1}°C\n", .{temperature.get()});

    temperature.sub(0.8);
    try stdout.print("After -0.8: {d:.1}°C\n\n", .{temperature.get()});

    // Simulate connections
    for (0..10) |_| {
        connections.inc();
    }
    connections.dec();
    connections.dec();
    try stdout.print("Active connections: {}\n\n", .{connections.get()});

    try stdout.print("Prometheus format:\n", .{});
    try stdout.print("─────────────────\n", .{});
    try temperature.write(stdout);
    try stdout.print("\n", .{});
    try connections.write(stdout);
    try stdout.print("\n", .{});
}

fn demoHistogram(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 3: Histogram                                           │\n", .{});
    try stdout.print("│ (Distribution of observations in buckets)                   │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var latency = try metrics.Histogram.init(
        allocator,
        "http_request_duration_seconds",
        "HTTP request latency in seconds",
        metrics.Histogram.defaultBuckets(),
    );
    defer latency.deinit();

    // Simulate request latencies
    try stdout.print("Simulating request latencies...\n", .{});

    // Generate some realistic latencies
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..1000) |_| {
        // Most requests are fast (10-100ms)
        // Some are slow (100ms-1s)
        // Few are very slow (1s+)
        const r = random.float(f64);
        const latency_val = if (r < 0.7)
            0.01 + random.float(f64) * 0.09 // 10-100ms
        else if (r < 0.95)
            0.1 + random.float(f64) * 0.9 // 100ms-1s
        else
            1.0 + random.float(f64) * 4.0; // 1-5s

        latency.observe(latency_val);
    }

    try stdout.print("Observations: {}\n", .{latency.getCount()});
    try stdout.print("Sum: {d:.3}s\n", .{latency.getSum()});
    try stdout.print("Average: {d:.3}s\n\n", .{latency.getSum() / @as(f64, @floatFromInt(latency.getCount()))});

    try stdout.print("Prometheus format:\n", .{});
    try stdout.print("─────────────────\n", .{});
    try latency.write(stdout);
    try stdout.print("\n", .{});
}

fn demoCompleteExport(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 4: Complete Prometheus Export                          │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    // Create labeled metrics
    const get_labels = [_]metrics.Label{
        .{ .name = "method", .value = "GET" },
        .{ .name = "path", .value = "/api/users" },
    };
    const post_labels = [_]metrics.Label{
        .{ .name = "method", .value = "POST" },
        .{ .name = "path", .value = "/api/users" },
    };

    var get_requests = metrics.Counter.initWithLabels(
        "http_requests_total",
        "Total HTTP requests",
        &get_labels,
    );
    var post_requests = metrics.Counter.initWithLabels(
        "http_requests_total",
        "Total HTTP requests",
        &post_labels,
    );

    get_requests.add(1500);
    post_requests.add(342);

    var memory = metrics.Gauge.init("process_memory_bytes", "Process memory usage in bytes");
    memory.set(128 * 1024 * 1024); // 128 MB

    var latency = try metrics.Histogram.init(
        allocator,
        "http_request_duration_seconds",
        "HTTP request latency",
        &[_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0 },
    );
    defer latency.deinit();

    // Add some observations
    for ([_]f64{ 0.008, 0.023, 0.045, 0.089, 0.156, 0.234, 0.567, 0.891 }) |l| {
        latency.observe(l);
    }

    try stdout.print("Complete Prometheus metrics export:\n", .{});
    try stdout.print("═══════════════════════════════════\n\n", .{});

    try get_requests.write(stdout);
    try stdout.print("\n", .{});
    try post_requests.write(stdout);
    try stdout.print("\n", .{});
    try memory.write(stdout);
    try stdout.print("\n", .{});
    try latency.write(stdout);
    try stdout.print("\n", .{});
}
