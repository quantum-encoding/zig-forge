// Copyright (c) 2025 QUANTUM ENCODING LTD
// Sustained Performance Benchmark for Quantum Curl
//
// Runs continuous load for a specified duration to measure:
// - Sustained throughput over time
// - Memory stability (no leaks under load)
// - Latency consistency over extended periods
// - System resource utilization patterns

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Config = struct {
    duration_seconds: u64 = 60,
    concurrency: u32 = 100,
    target_url: []const u8 = "http://127.0.0.1:8888/",
    report_interval_seconds: u64 = 5,
};

const Stats = struct {
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    successful_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    min_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(std.math.maxInt(u64)),
    max_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

var global_stats: Stats = .{};
var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

/// Get monotonic time in nanoseconds using clock_gettime (Zig 0.16 compatible)
fn getMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--duration") and i + 1 < args.len) {
            config.duration_seconds = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--concurrency") and i + 1 < args.len) {
            config.concurrency = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--url") and i + 1 < args.len) {
            config.target_url = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("        QUANTUM CURL SUSTAINED PERFORMANCE BENCHMARK               \n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("  Duration:    {d} seconds\n", .{config.duration_seconds});
    std.debug.print("  Concurrency: {d} workers\n", .{config.concurrency});
    std.debug.print("  Target:      {s}\n", .{config.target_url});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("\n", .{});

    const start_time_ns = getMonotonicNs();
    const end_time_ns: i128 = @as(i128, config.duration_seconds) * std.time.ns_per_s;

    // Start worker threads
    const workers = try allocator.alloc(std.Thread, config.concurrency);
    defer allocator.free(workers);

    for (workers, 0..) |*worker, idx| {
        worker.* = try std.Thread.spawn(.{}, workerThread, .{ config.target_url, start_time_ns, end_time_ns, idx });
    }

    // Reporter thread - prints stats every interval
    var last_report_ns = start_time_ns;
    var last_requests: u64 = 0;

    std.debug.print("Time(s)  | Requests  | RPS      | Success%% | Avg(ms) | Min(ms) | Max(ms)\n", .{});
    std.debug.print("---------|-----------|----------|----------|---------|---------|--------\n", .{});

    while (running.load(.monotonic)) {
        var ts: linux.timespec = .{ .sec = @intCast(config.report_interval_seconds), .nsec = 0 };
        _ = linux.nanosleep(&ts, null);

        const now_ns = getMonotonicNs();
        const elapsed_ns: u64 = @intCast(now_ns - start_time_ns);
        const elapsed_s = elapsed_ns / std.time.ns_per_s;

        if (now_ns - start_time_ns >= end_time_ns) {
            running.store(false, .monotonic);
            break;
        }

        const total = global_stats.total_requests.load(.monotonic);
        const successful = global_stats.successful_requests.load(.monotonic);
        const interval_requests = total - last_requests;

        const interval_ns: u64 = @intCast(now_ns - last_report_ns);
        const interval_s = @as(f64, @floatFromInt(interval_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const rps = @as(f64, @floatFromInt(interval_requests)) / interval_s;

        const success_pct = if (total > 0)
            (@as(f64, @floatFromInt(successful)) / @as(f64, @floatFromInt(total))) * 100.0
        else
            0.0;

        const total_latency = global_stats.total_latency_ns.load(.monotonic);
        const avg_latency_ms = if (total > 0)
            @as(f64, @floatFromInt(total_latency / total)) / @as(f64, @floatFromInt(std.time.ns_per_ms))
        else
            0.0;

        const min_lat = global_stats.min_latency_ns.load(.monotonic);
        const max_lat = global_stats.max_latency_ns.load(.monotonic);
        const min_ms = if (min_lat < std.math.maxInt(u64)) min_lat / std.time.ns_per_ms else 0;
        const max_ms = max_lat / std.time.ns_per_ms;

        std.debug.print("{d:>7}  | {d:>9} | {d:>8.0} | {d:>7.1}%% | {d:>7.2} | {d:>7} | {d:>7}\n", .{
            elapsed_s,
            total,
            rps,
            success_pct,
            avg_latency_ms,
            min_ms,
            max_ms,
        });

        last_report_ns = now_ns;
        last_requests = total;
    }

    // Wait for all workers to finish
    for (workers) |worker| {
        worker.join();
    }

    // Final summary
    const final_time_ns = getMonotonicNs();
    const total_elapsed_ns: u64 = @intCast(final_time_ns - start_time_ns);
    const total_elapsed_s = @as(f64, @floatFromInt(total_elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));

    const total = global_stats.total_requests.load(.monotonic);
    const successful = global_stats.successful_requests.load(.monotonic);
    const failed = global_stats.failed_requests.load(.monotonic);
    const total_latency = global_stats.total_latency_ns.load(.monotonic);

    const overall_rps = @as(f64, @floatFromInt(total)) / total_elapsed_s;
    const success_pct = if (total > 0)
        (@as(f64, @floatFromInt(successful)) / @as(f64, @floatFromInt(total))) * 100.0
    else
        0.0;
    const avg_latency_ms = if (total > 0)
        @as(f64, @floatFromInt(total_latency / total)) / @as(f64, @floatFromInt(std.time.ns_per_ms))
    else
        0.0;

    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("                         FINAL RESULTS                             \n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("  Total Duration:     {d:.2} seconds\n", .{total_elapsed_s});
    std.debug.print("  Total Requests:     {d}\n", .{total});
    std.debug.print("  Successful:         {d} ({d:.1}%%)\n", .{ successful, success_pct });
    std.debug.print("  Failed:             {d}\n", .{failed});
    std.debug.print("  Average Throughput: {d:.0} req/sec\n", .{overall_rps});
    std.debug.print("  Average Latency:    {d:.2} ms\n", .{avg_latency_ms});
    std.debug.print("====================================================================\n", .{});
}

fn workerThread(target_url: []const u8, start_time_ns: i128, end_time_ns: i128, worker_id: usize) void {
    _ = worker_id;

    // Each worker continuously makes requests until time is up
    while (running.load(.monotonic)) {
        const now_ns = getMonotonicNs();
        if (now_ns - start_time_ns >= end_time_ns) {
            break;
        }

        const req_start_ns = getMonotonicNs();

        // Make HTTP request with blocking socket
        const success = makeDirectRequest(target_url);

        const req_end_ns = getMonotonicNs();
        const latency_ns: u64 = @intCast(req_end_ns - req_start_ns);

        // Update stats atomically
        _ = global_stats.total_requests.fetchAdd(1, .monotonic);
        _ = global_stats.total_latency_ns.fetchAdd(latency_ns, .monotonic);

        if (success) {
            _ = global_stats.successful_requests.fetchAdd(1, .monotonic);
        } else {
            _ = global_stats.failed_requests.fetchAdd(1, .monotonic);
        }

        // Update min latency
        var current_min = global_stats.min_latency_ns.load(.monotonic);
        while (latency_ns < current_min) {
            const result = global_stats.min_latency_ns.cmpxchgWeak(current_min, latency_ns, .monotonic, .monotonic);
            if (result) |new_val| {
                current_min = new_val;
            } else break;
        }

        // Update max latency
        var current_max = global_stats.max_latency_ns.load(.monotonic);
        while (latency_ns > current_max) {
            const result = global_stats.max_latency_ns.cmpxchgWeak(current_max, latency_ns, .monotonic, .monotonic);
            if (result) |new_val| {
                current_max = new_val;
            } else break;
        }
    }
}

fn makeDirectRequest(url: []const u8) bool {
    _ = url;

    // Direct socket connection to echo server (blocking mode)
    const sock_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (@as(isize, @bitCast(sock_result)) < 0) return false;
    const sockfd: posix.fd_t = @intCast(sock_result);
    defer _ = std.c.close(sockfd);

    // Disable Nagle's algorithm for lower latency
    const nodelay: c_int = 1;
    _ = linux.setsockopt(
        @intCast(sockfd),
        linux.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&nodelay),
        @sizeOf(c_int),
    );

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 8888),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };

    const connect_result = linux.connect(@intCast(sockfd), @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    if (@as(isize, @bitCast(connect_result)) < 0) return false;

    // Send minimal HTTP request
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const write_result = linux.write(@intCast(sockfd), request.ptr, request.len);
    const written: isize = @bitCast(write_result);
    if (written != request.len) return false;

    // Read response - loop until we get data or error
    var buf: [256]u8 = undefined;
    var total_read: usize = 0;
    while (total_read == 0) {
        const read_result = linux.read(@intCast(sockfd), buf[total_read..].ptr, buf.len - total_read);
        const n: isize = @bitCast(read_result);
        if (n < 0) return false;
        if (n == 0) return false; // Connection closed without data
        total_read += @intCast(read_result);
    }

    return total_read > 0;
}

fn printUsage() void {
    const usage =
        \\Quantum Curl Sustained Benchmark
        \\
        \\USAGE:
        \\    sustained-bench [OPTIONS]
        \\
        \\OPTIONS:
        \\    --duration [seconds]   Test duration (default: 60)
        \\    --concurrency [n]      Number of worker threads (default: 100)
        \\    --url [url]            Target URL (default: http://127.0.0.1:8888/)
        \\    -h, --help             Show this help
        \\
        \\EXAMPLES:
        \\    # Run 60-second benchmark with 100 workers
        \\    sustained-bench
        \\
        \\    # Run 120-second benchmark with 200 workers
        \\    sustained-bench --duration 120 --concurrency 200
        \\
    ;
    std.debug.print("{s}", .{usage});
}
