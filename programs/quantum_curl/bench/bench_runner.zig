// Copyright (c) 2025 QUANTUM ENCODING LTD
// Quantum Curl Benchmark Runner
//
// Automated performance testing with statistical analysis for CI/CD integration.
// Measures throughput, latency percentiles, and detects performance regressions.

const std = @import("std");

/// Get monotonic time in nanoseconds using clock_gettime (Zig 0.16 compatible)
fn getMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

const BenchmarkConfig = struct {
    name: []const u8,
    request_count: u32,
    concurrency: u32,
    target_url: []const u8,
};

const BenchmarkResult = struct {
    name: []const u8,
    total_requests: u32,
    successful_requests: u32,
    failed_requests: u32,
    total_time_ms: u64,
    min_latency_ms: u64,
    max_latency_ms: u64,
    avg_latency_ms: f64,
    p50_latency_ms: u64,
    p95_latency_ms: u64,
    p99_latency_ms: u64,
    requests_per_second: f64,

    pub fn toJson(self: *const BenchmarkResult, writer: *std.Io.Writer) !void {
        try writer.print(
            \\{{
            \\  "name": "{s}",
            \\  "total_requests": {d},
            \\  "successful_requests": {d},
            \\  "failed_requests": {d},
            \\  "total_time_ms": {d},
            \\  "latency": {{
            \\    "min_ms": {d},
            \\    "max_ms": {d},
            \\    "avg_ms": {d:.2},
            \\    "p50_ms": {d},
            \\    "p95_ms": {d},
            \\    "p99_ms": {d}
            \\  }},
            \\  "throughput": {{
            \\    "requests_per_second": {d:.2}
            \\  }}
            \\}}
        , .{
            self.name,
            self.total_requests,
            self.successful_requests,
            self.failed_requests,
            self.total_time_ms,
            self.min_latency_ms,
            self.max_latency_ms,
            self.avg_latency_ms,
            self.p50_latency_ms,
            self.p95_latency_ms,
            self.p99_latency_ms,
            self.requests_per_second,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Create IO context for file operations
    var io_impl = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    defer io_impl.deinit();
    const io = io_impl.io();

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Parse arguments
    var target_url: []const u8 = "http://127.0.0.1:8888/";
    var output_json = false;
    var baseline_file: ?[]const u8 = null;
    var regression_threshold: f64 = 10.0; // 10% regression threshold

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--url") and i + 1 < args.len) {
            target_url = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            output_json = true;
        } else if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
            baseline_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold") and i + 1 < args.len) {
            regression_threshold = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    // Benchmark configurations - testing thread pool fixes
    const benchmarks = [_]BenchmarkConfig{
        .{ .name = "warmup", .request_count = 100, .concurrency = 10, .target_url = target_url },
        .{ .name = "light_load", .request_count = 500, .concurrency = 25, .target_url = target_url },
        .{ .name = "medium_load", .request_count = 1000, .concurrency = 50, .target_url = target_url },
        .{ .name = "heavy_load", .request_count = 2000, .concurrency = 100, .target_url = target_url },
    };

    var results: std.ArrayList(BenchmarkResult) = .empty;
    defer results.deinit(allocator);

    if (!output_json) {
        std.debug.print("\n", .{});
        std.debug.print("====================================================================\n", .{});
        std.debug.print("           QUANTUM CURL PERFORMANCE BENCHMARK SUITE                \n", .{});
        std.debug.print("====================================================================\n", .{});
        std.debug.print("  Target: {s}\n", .{target_url});
        std.debug.print("====================================================================\n", .{});
        std.debug.print("\n", .{});
    }

    // Run benchmarks
    for (benchmarks) |config| {
        const result = try runBenchmark(allocator, io, config);
        try results.append(allocator, result);

        if (!output_json) {
            printResult(&result);
        }
    }

    // Output JSON if requested
    if (output_json) {
        const stdout_file = std.Io.File.stdout();
        var stdout_buffer: [8192]u8 = undefined;
        var writer = stdout_file.writer(io, &stdout_buffer);
        try writer.interface.writeAll("{\n  \"benchmarks\": [\n");
        for (results.items, 0..) |result, idx| {
            try result.toJson(&writer.interface);
            if (idx < results.items.len - 1) {
                try writer.interface.writeAll(",\n");
            } else {
                try writer.interface.writeAll("\n");
            }
        }
        try writer.interface.writeAll("  ],\n");

        // Summary
        var total_rps: f64 = 0;
        var total_p99: u64 = 0;
        for (results.items[1..]) |result| { // Skip warmup
            total_rps += result.requests_per_second;
            total_p99 += result.p99_latency_ms;
        }
        const avg_rps = total_rps / @as(f64, @floatFromInt(results.items.len - 1));
        const avg_p99 = total_p99 / (results.items.len - 1);

        try writer.interface.print(
            \\  "summary": {{
            \\    "avg_requests_per_second": {d:.2},
            \\    "avg_p99_latency_ms": {d}
            \\  }}
            \\}}
            \\
        , .{ avg_rps, avg_p99 });
        try writer.interface.flush();
    } else {
        // Print summary
        std.debug.print("\n", .{});
        std.debug.print("====================================================================\n", .{});
        std.debug.print("                         SUMMARY                                   \n", .{});
        std.debug.print("====================================================================\n", .{});

        var total_rps: f64 = 0;
        var max_rps: f64 = 0;
        var min_p99: u64 = std.math.maxInt(u64);

        for (results.items[1..]) |result| { // Skip warmup
            total_rps += result.requests_per_second;
            if (result.requests_per_second > max_rps) max_rps = result.requests_per_second;
            if (result.p99_latency_ms < min_p99) min_p99 = result.p99_latency_ms;
        }

        std.debug.print("  Peak Throughput:    {d:.0} req/sec\n", .{max_rps});
        std.debug.print("  Best P99 Latency:   {d} ms\n", .{min_p99});
        std.debug.print("====================================================================\n", .{});
    }

    // Check for regression if baseline provided
    if (baseline_file) |baseline| {
        const regression = try checkRegression(allocator, baseline, &results, regression_threshold);
        if (regression) {
            std.debug.print("\nWARNING: REGRESSION DETECTED! Performance degraded by more than {d:.0}%\n", .{regression_threshold});
            std.process.exit(1);
        } else {
            std.debug.print("\nNo regression detected (threshold: {d:.0}%)\n", .{regression_threshold});
        }
    }
}

fn runBenchmark(allocator: std.mem.Allocator, io: std.Io, config: BenchmarkConfig) !BenchmarkResult {
    // Generate JSONL requests
    var requests_jsonl: std.ArrayList(u8) = .empty;
    defer requests_jsonl.deinit(allocator);

    for (0..config.request_count) |req_id| {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"id\":\"req-{d}\",\"method\":\"GET\",\"url\":\"{s}\"}}\n", .{ req_id, config.target_url });
        try requests_jsonl.appendSlice(allocator, line);
    }

    // Use unique temp files per benchmark to avoid race conditions
    var temp_path_buf: [128]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_path_buf, "/tmp/qc_bench_{s}_req.jsonl", .{config.name});

    var output_path_buf: [128]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_path_buf, "/tmp/qc_bench_{s}_out.jsonl", .{config.name});

    // Write requests to temp file
    var temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    defer temp_file.close(io);
    var buf: [4096]u8 = undefined;
    var temp_writer = temp_file.writer(io, &buf);
    try temp_writer.interface.writeAll(requests_jsonl.items);
    try std.Io.Writer.flush(&temp_writer.interface);

    // Run quantum-curl and capture output
    const start_time_ns = getMonotonicNs();

    const concurrency_str = try std.fmt.allocPrint(allocator, "{d}", .{config.concurrency});
    defer allocator.free(concurrency_str);

    // Use shell to redirect stdout to file (avoids pipe buffer limits)
    const shell_cmd = try std.fmt.allocPrint(
        allocator,
        "./zig-out/bin/quantum-curl --file {s} --concurrency {s} > {s}",
        .{ temp_path, concurrency_str, output_path },
    );
    defer allocator.free(shell_cmd);

    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", shell_cmd },
        .stdout = .ignore,
        .stderr = .ignore,
    });

    // Wait for child to complete
    _ = try child.wait(io);

    const end_time_ns = getMonotonicNs();
    const elapsed_ns: u64 = @intCast(end_time_ns - start_time_ns);
    const total_time_ms = elapsed_ns / std.time.ns_per_ms;

    // Read output from file
    const output = std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(50 * 1024 * 1024)) catch {
        return BenchmarkResult{
            .name = config.name,
            .total_requests = config.request_count,
            .successful_requests = 0,
            .failed_requests = config.request_count,
            .total_time_ms = total_time_ms,
            .min_latency_ms = 0,
            .max_latency_ms = 0,
            .avg_latency_ms = 0,
            .p50_latency_ms = 0,
            .p95_latency_ms = 0,
            .p99_latency_ms = 0,
            .requests_per_second = 0,
        };
    };
    defer allocator.free(output);

    // Parse results and collect latencies
    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);

    var successful: u32 = 0;
    var failed: u32 = 0;

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{},
        ) catch continue;
        defer parsed.deinit();

        const obj = parsed.value.object;
        const status = if (obj.get("status")) |s| @as(u16, @intCast(s.integer)) else 0;
        const latency = if (obj.get("latency_ms")) |l| @as(u64, @intCast(l.integer)) else 0;

        if (status >= 200 and status < 300) {
            successful += 1;
        } else {
            failed += 1;
        }

        try latencies.append(allocator, latency);
    }

    // Calculate statistics
    if (latencies.items.len == 0) {
        return BenchmarkResult{
            .name = config.name,
            .total_requests = config.request_count,
            .successful_requests = 0,
            .failed_requests = config.request_count,
            .total_time_ms = total_time_ms,
            .min_latency_ms = 0,
            .max_latency_ms = 0,
            .avg_latency_ms = 0,
            .p50_latency_ms = 0,
            .p95_latency_ms = 0,
            .p99_latency_ms = 0,
            .requests_per_second = 0,
        };
    }

    // Sort for percentiles
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));

    const min_lat = latencies.items[0];
    const max_lat = latencies.items[latencies.items.len - 1];

    var sum: u64 = 0;
    for (latencies.items) |lat| {
        sum += lat;
    }
    const avg_lat = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(latencies.items.len));

    const p50_idx = latencies.items.len / 2;
    const p95_idx = (latencies.items.len * 95) / 100;
    const p99_idx = (latencies.items.len * 99) / 100;

    const rps = @as(f64, @floatFromInt(successful)) / (@as(f64, @floatFromInt(total_time_ms)) / 1000.0);

    return BenchmarkResult{
        .name = config.name,
        .total_requests = config.request_count,
        .successful_requests = successful,
        .failed_requests = failed,
        .total_time_ms = total_time_ms,
        .min_latency_ms = min_lat,
        .max_latency_ms = max_lat,
        .avg_latency_ms = avg_lat,
        .p50_latency_ms = latencies.items[p50_idx],
        .p95_latency_ms = latencies.items[p95_idx],
        .p99_latency_ms = latencies.items[p99_idx],
        .requests_per_second = rps,
    };
}

fn printResult(result: *const BenchmarkResult) void {
    std.debug.print("--------------------------------------------------------------------\n", .{});
    std.debug.print(" {s}\n", .{result.name});
    std.debug.print("--------------------------------------------------------------------\n", .{});
    std.debug.print(" Requests:    {d} total | {d} ok | {d} failed\n", .{
        result.total_requests,
        result.successful_requests,
        result.failed_requests,
    });
    std.debug.print(" Throughput:  {d:.0} req/sec\n", .{result.requests_per_second});
    std.debug.print(" Latency:     min={d}ms | avg={d:.1}ms | max={d}ms\n", .{
        result.min_latency_ms,
        result.avg_latency_ms,
        result.max_latency_ms,
    });
    std.debug.print(" Percentiles: p50={d}ms | p95={d}ms | p99={d}ms\n", .{
        result.p50_latency_ms,
        result.p95_latency_ms,
        result.p99_latency_ms,
    });
    std.debug.print(" Duration:    {d}ms\n", .{result.total_time_ms});
    std.debug.print("\n", .{});
}

fn checkRegression(
    _: std.mem.Allocator,
    baseline_path: []const u8,
    current_results: *const std.ArrayList(BenchmarkResult),
    threshold: f64,
) !bool {
    // Read baseline JSON file using C-level I/O (std.fs.cwd removed in Zig 0.16)
    // Need null-terminated path for C open()
    var path_buf: [4096]u8 = undefined;
    if (baseline_path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..baseline_path.len], baseline_path);
    path_buf[baseline_path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..baseline_path.len :0];

    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        std.debug.print("Cannot open baseline file: {s}\n", .{baseline_path});
        return false;
    }
    defer _ = std.c.close(fd);

    var buf: [65536]u8 = undefined;
    const n_read = std.c.read(fd, &buf, buf.len);
    if (n_read <= 0) return false;
    const n: usize = @intCast(n_read);
    const baseline_json = buf[0..n];

    // Compare each current result against baseline
    // Look for "total_time_ms" values in baseline JSON
    var regression_detected = false;

    for (current_results.items) |result| {
        // Search for this benchmark's timing in baseline
        // Simple approach: find "total_time_ms": <value> patterns
        var search_pos: usize = 0;
        var baseline_time_sum: f64 = 0.0;
        var baseline_count: u32 = 0;

        while (std.mem.indexOfPos(u8, baseline_json, search_pos, "\"total_time_ms\":")) |pos| {
            const val_start = pos + 16; // length of "total_time_ms":
            var val_end = val_start;
            // Skip whitespace
            while (val_end < baseline_json.len and (baseline_json[val_end] == ' ' or baseline_json[val_end] == '\t')) : (val_end += 1) {}
            const num_start = val_end;
            // Read number
            while (val_end < baseline_json.len and ((baseline_json[val_end] >= '0' and baseline_json[val_end] <= '9') or baseline_json[val_end] == '.')) : (val_end += 1) {}
            if (val_end > num_start) {
                const val = std.fmt.parseFloat(f64, baseline_json[num_start..val_end]) catch 0.0;
                if (val > 0.0) {
                    baseline_time_sum += val;
                    baseline_count += 1;
                }
            }
            search_pos = val_end;
        }

        if (baseline_count > 0) {
            const baseline_avg = baseline_time_sum / @as(f64, @floatFromInt(baseline_count));
            const current_time = @as(f64, @floatFromInt(result.total_time_ms));
            const diff_pct = ((current_time - baseline_avg) / baseline_avg) * 100.0;

            if (diff_pct > threshold) {
                std.debug.print("⚠️  Regression detected: current {d:.1}ms vs baseline {d:.1}ms ({d:.1}% slower, threshold: {d:.1}%)\n", .{
                    current_time, baseline_avg, diff_pct, threshold,
                });
                regression_detected = true;
            }
        }
    }

    return regression_detected;
}

fn printUsage() void {
    const usage =
        \\Quantum Curl Benchmark Runner
        \\
        \\USAGE:
        \\    bench-quantum-curl [OPTIONS]
        \\
        \\OPTIONS:
        \\    --url [url]         Target URL (default: http://127.0.0.1:8888/)
        \\    --json              Output results as JSON
        \\    --baseline [file]   Compare against baseline JSON file
        \\    --threshold [pct]   Regression threshold percentage (default: 10)
        \\    -h, --help          Show this help
        \\
        \\EXAMPLES:
        \\    # Run benchmark against local echo server
        \\    bench-quantum-curl
        \\
        \\    # Output JSON for CI/CD
        \\    bench-quantum-curl --json > benchmark_results.json
        \\
        \\    # Check for regression against baseline
        \\    bench-quantum-curl --json --baseline baseline.json --threshold 15
        \\
    ;
    std.debug.print("{s}", .{usage});
}
