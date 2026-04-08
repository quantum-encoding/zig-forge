// Copyright (c) 2025-2026 QUANTUM ENCODING LTD
// HTTP Sentinel — Benchmark & Stress Test Suite
//
// Pure Zig. Embedded test server + client benchmarks. No external dependencies.
//
// Usage:
//   zig build bench              # Run all benchmarks
//   zig build bench -- --quick   # Quick smoke test (fewer iterations)

const std = @import("std");
const http = std.http;
const net = std.Io.net;
const HttpClient = @import("http-sentinel").HttpClient;
const RetryEngine = @import("http-sentinel").retry.RetryEngine;

// ─────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────

const BenchConfig = struct {
    /// Number of sequential requests per benchmark
    sequential_requests: u32 = 500,
    /// Number of concurrent workers for throughput test
    concurrency_levels: []const u32 = &.{ 1, 4, 8, 16, 32, 64 },
    /// Requests per worker in throughput test
    requests_per_worker: u32 = 100,
    /// Large body size for payload tests (keep moderate for embedded server)
    large_body_size: usize = 64 * 1024, // 64KB
    /// Port for embedded test server
    port: u16 = 0, // 0 = ephemeral
};

const quick_config = BenchConfig{
    .sequential_requests = 50,
    .concurrency_levels = &.{ 1, 4, 8 },
    .requests_per_worker = 20,
    .large_body_size = 8 * 1024,
};

// ─────────────────────────────────────────────────
// Embedded Test Server (pure Zig)
// ─────────────────────────────────────────────────

const TestServer = struct {
    port: u16,
    server: net.Server,
    io_threaded: std.Io.Threaded,
    running: std.atomic.Value(u32),
    request_count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    const BENCH_PORT: u16 = 18273; // Fixed port for benchmarks

    fn start(allocator: std.mem.Allocator) !*TestServer {
        const self = try allocator.create(TestServer);

        self.allocator = allocator;
        self.port = BENCH_PORT;
        self.running = std.atomic.Value(u32).init(1);
        self.request_count = std.atomic.Value(u64).init(0);
        self.io_threaded = std.Io.Threaded.init(allocator, .{});
        const io = self.io_threaded.io();

        var addr: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(BENCH_PORT) };
        addr.setPort(BENCH_PORT);

        self.server = net.IpAddress.listen(&addr, io, .{
            .reuse_address = true,
        }) catch |err| {
            std.debug.print("Failed to start test server on port {d}: {any}\n", .{ BENCH_PORT, err });
            allocator.destroy(self);
            return err;
        };

        // Start accept loop in background thread
        _ = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            self.server.deinit(io);
            allocator.destroy(self);
            return err;
        };

        return self;
    }

    fn stop(self: *TestServer, allocator: std.mem.Allocator) void {
        self.running.store(0, .release);
        self.server.deinit(self.io_threaded.io());
        self.io_threaded.deinit();
        allocator.destroy(self);
    }

    fn getRequestCount(self: *TestServer) u64 {
        return self.request_count.load(.acquire);
    }

    fn acceptLoop(self: *TestServer) void {
        while (self.running.load(.acquire) == 1) {
            const io = self.io_threaded.io();
            const stream = self.server.accept(io) catch continue;

            // Spawn handler thread
            const ctx = self.allocator.create(ConnCtx) catch {
                var s = stream;
                s.close(io);
                continue;
            };
            ctx.* = .{ .stream = stream, .server = self };

            const t = std.Thread.spawn(.{}, handleConn, .{ctx}) catch {
                self.allocator.destroy(ctx);
                var s = stream;
                s.close(io);
                continue;
            };
            t.detach();
        }
    }

    const ConnCtx = struct {
        stream: net.Stream,
        server: *TestServer,
    };

    fn handleConn(ctx: *ConnCtx) void {
        defer ctx.server.allocator.destroy(ctx);

        var io_threaded: std.Io.Threaded = .init(ctx.server.allocator, .{});
        const io = io_threaded.io();
        defer {
            var s = ctx.stream;
            s.close(io);
        }

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;

        var stream_reader = ctx.stream.reader(io, &read_buf);
        var stream_writer = ctx.stream.writer(io, &write_buf);

        var srv = http.Server.init(&stream_reader.interface, &stream_writer.interface);

        // Handle multiple requests on same connection (keep-alive)
        while (true) {
            var request = srv.receiveHead() catch break;
            _ = ctx.server.request_count.fetchAdd(1, .monotonic);

            const target = request.head.target;

            if (std.mem.startsWith(u8, target, "/echo")) {
                // Simple echo acknowledgment — respond immediately
                request.respond("{\"status\":\"ok\"}", .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch break;
            } else if (std.mem.startsWith(u8, target, "/status/")) {
                // Return specific status code
                const code_str = target[8..];
                const code = std.fmt.parseInt(u16, code_str, 10) catch {
                    request.respond("invalid status code", .{ .status = .bad_request }) catch break;
                    continue;
                };
                if (code < 100 or code > 599) {
                    request.respond("invalid status code", .{ .status = .bad_request }) catch break;
                } else {
                    const status: http.Status = @enumFromInt(code);
                    request.respond("", .{ .status = status }) catch break;
                }
            } else if (std.mem.startsWith(u8, target, "/bytes/")) {
                // Return N bytes of data
                const n_str = target[7..];
                const n = std.fmt.parseInt(usize, n_str, 10) catch 0;
                const capped = @min(n, 4 * 1024 * 1024);

                const data = ctx.server.allocator.alloc(u8, capped) catch {
                    request.respond("OOM", .{ .status = .internal_server_error }) catch break;
                    continue;
                };
                defer ctx.server.allocator.free(data);

                // Fill with deterministic pattern
                for (data, 0..) |*b, i| {
                    b.* = @truncate(i);
                }
                request.respond(data, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/octet-stream" },
                    },
                }) catch break;
            } else if (std.mem.startsWith(u8, target, "/delay/")) {
                // Delayed response
                const ms_str = target[7..];
                const ms = std.fmt.parseInt(i64, ms_str, 10) catch 0;
                const capped_ms = @min(ms, 5000);
                io.sleep(std.Io.Duration.fromMilliseconds(capped_ms), .awake) catch {};
                request.respond("delayed", .{ .status = .ok }) catch break;
            } else if (std.mem.eql(u8, target, "/json")) {
                const json = "{\"status\":\"ok\",\"message\":\"benchmark\",\"value\":42}";
                request.respond(json, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch break;
            } else if (std.mem.eql(u8, target, "/health")) {
                request.respond("ok", .{ .status = .ok }) catch break;
            } else if (std.mem.eql(u8, target, "/sse")) {
                // SSE endpoint — sends 5 events with small delays between them
                var stream_buf: [4096]u8 = undefined;
                var body_w = request.respondStreaming(&stream_buf, .{
                    .respond_options = .{
                        .status = .ok,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/event-stream" },
                            .{ .name = "cache-control", .value = "no-cache" },
                        },
                        .keep_alive = false,
                    },
                }) catch break;

                // Send 5 content events with 10ms delay between each
                var i: u32 = 0;
                while (i < 5) : (i += 1) {
                    const event = std.fmt.allocPrint(ctx.server.allocator,
                        "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":\"chunk{d}\"}}}}\n\n",
                        .{i},
                    ) catch break;
                    defer ctx.server.allocator.free(event);
                    body_w.writer.writeAll(event) catch break;
                    body_w.writer.flush() catch break;
                    io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                }

                // Send done
                body_w.writer.writeAll("data: [DONE]\n\n") catch {};
                body_w.writer.flush() catch {};
                body_w.end() catch {};
            } else {
                request.respond("not found", .{ .status = .not_found }) catch break;
            }
        }
    }
};

// ─────────────────────────────────────────────────
// Timing Utilities
// ─────────────────────────────────────────────────

const Stopwatch = struct {
    start: std.Io.Timestamp,
    io: std.Io,

    fn begin(io: std.Io) Stopwatch {
        return .{ .start = std.Io.Timestamp.now(io, .awake), .io = io };
    }

    fn elapsedNs(self: *const Stopwatch) u64 {
        const d = self.start.untilNow(self.io, .awake);
        const ns = d.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }

    fn elapsedMs(self: *const Stopwatch) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / 1_000_000.0;
    }
};

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f = @as(f64, @floatFromInt(sorted.len - 1)) * p;
    const idx: usize = @intFromFloat(idx_f);
    return sorted[@min(idx, sorted.len - 1)];
}

// ─────────────────────────────────────────────────
// Benchmark Results
// ─────────────────────────────────────────────────

const BenchResult = struct {
    name: []const u8,
    total_requests: u64,
    successful: u64,
    failed: u64,
    total_time_ms: f64,
    p50_us: u64,
    p95_us: u64,
    p99_us: u64,
    min_us: u64,
    max_us: u64,
    rps: f64,
    total_bytes: u64,
    concurrency: u32,

    fn print(self: *const BenchResult) void {
        std.debug.print(
            \\
            \\  {s}
            \\  ──────────────────────────────────────
            \\  Requests:     {d} total, {d} ok, {d} failed
            \\  Concurrency:  {d}
            \\  Duration:     {d:.1}ms
            \\  Throughput:   {d:.1} req/s
            \\  Transferred:  {d} bytes
            \\  Latency:
            \\    min         {d}us
            \\    p50         {d}us
            \\    p95         {d}us
            \\    p99         {d}us
            \\    max         {d}us
            \\
        , .{
            self.name,
            self.total_requests,
            self.successful,
            self.failed,
            self.concurrency,
            self.total_time_ms,
            self.rps,
            self.total_bytes,
            self.min_us,
            self.p50_us,
            self.p95_us,
            self.p99_us,
            self.max_us,
        });
    }
};

// ─────────────────────────────────────────────────
// Benchmarks
// ─────────────────────────────────────────────────

fn benchSequentialGet(allocator: std.mem.Allocator, base_url: []const u8, n: u32) !BenchResult {
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    const io = client.io();

    const url = try std.fmt.allocPrint(allocator, "{s}/json", .{base_url});
    defer allocator.free(url);

    var latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    var successful: u64 = 0;
    var failed: u64 = 0;
    var total_bytes: u64 = 0;

    const sw = Stopwatch.begin(io);

    for (0..n) |i| {
        const req_sw = Stopwatch.begin(io);
        var response = client.get(url, &.{}) catch {
            failed += 1;
            latencies[i] = 0;
            continue;
        };
        latencies[i] = req_sw.elapsedNs() / 1000; // convert to us
        total_bytes += response.body.len;
        successful += 1;
        response.deinit();
    }

    const total_ms = sw.elapsedMs();

    // Sort for percentiles
    std.mem.sort(u64, latencies[0..@intCast(successful + failed)], {}, std.sort.asc(u64));

    return BenchResult{
        .name = "Sequential GET /json",
        .total_requests = n,
        .successful = successful,
        .failed = failed,
        .total_time_ms = total_ms,
        .p50_us = percentile(latencies, 0.50),
        .p95_us = percentile(latencies, 0.95),
        .p99_us = percentile(latencies, 0.99),
        .min_us = if (latencies.len > 0) latencies[0] else 0,
        .max_us = if (latencies.len > 0) latencies[latencies.len - 1] else 0,
        .rps = @as(f64, @floatFromInt(successful)) / (total_ms / 1000.0),
        .total_bytes = total_bytes,
        .concurrency = 1,
    };
}

fn benchSequentialPost(allocator: std.mem.Allocator, base_url: []const u8, n: u32, body_size: usize) !BenchResult {
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    const io = client.io();

    const url = try std.fmt.allocPrint(allocator, "{s}/echo", .{base_url});
    defer allocator.free(url);

    // Build payload
    const body = try allocator.alloc(u8, body_size);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i);

    var latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    var successful: u64 = 0;
    var failed: u64 = 0;
    var total_bytes: u64 = 0;

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/octet-stream" },
    };

    const sw = Stopwatch.begin(io);

    for (0..n) |i| {
        const req_sw = Stopwatch.begin(io);
        var response = client.post(url, &headers, body) catch {
            failed += 1;
            latencies[i] = 0;
            continue;
        };
        latencies[i] = req_sw.elapsedNs() / 1000;
        total_bytes += response.body.len + body_size;
        successful += 1;
        response.deinit();
    }

    const total_ms = sw.elapsedMs();
    std.mem.sort(u64, latencies[0..@intCast(successful + failed)], {}, std.sort.asc(u64));

    const name = if (body_size >= 1024 * 1024)
        "Sequential POST /echo (1MB body)"
    else if (body_size >= 1024)
        "Sequential POST /echo (1KB body)"
    else
        "Sequential POST /echo (tiny body)";

    return BenchResult{
        .name = name,
        .total_requests = n,
        .successful = successful,
        .failed = failed,
        .total_time_ms = total_ms,
        .p50_us = percentile(latencies, 0.50),
        .p95_us = percentile(latencies, 0.95),
        .p99_us = percentile(latencies, 0.99),
        .min_us = if (latencies.len > 0) latencies[0] else 0,
        .max_us = if (latencies.len > 0) latencies[latencies.len - 1] else 0,
        .rps = @as(f64, @floatFromInt(successful)) / (total_ms / 1000.0),
        .total_bytes = total_bytes,
        .concurrency = 1,
    };
}

fn benchConcurrentGet(allocator: std.mem.Allocator, base_url: []const u8, workers: u32, requests_per_worker: u32) !BenchResult {
    const total = @as(u64, workers) * @as(u64, requests_per_worker);
    var all_latencies = try allocator.alloc(u64, @intCast(total));
    defer allocator.free(all_latencies);

    var successful = std.atomic.Value(u64).init(0);
    var failed = std.atomic.Value(u64).init(0);
    var total_bytes = std.atomic.Value(u64).init(0);

    // Timing io
    var timing_io: std.Io.Threaded = .init(allocator, .{});
    defer timing_io.deinit();
    const io = timing_io.io();

    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        base_url: []const u8,
        requests: u32,
        latencies: []u64,
        successful: *std.atomic.Value(u64),
        failed: *std.atomic.Value(u64),
        total_bytes: *std.atomic.Value(u64),
    };

    var threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    var ctxs = try allocator.alloc(WorkerCtx, workers);
    defer allocator.free(ctxs);

    const sw = Stopwatch.begin(io);

    for (0..workers) |w| {
        const offset = w * requests_per_worker;
        ctxs[w] = .{
            .allocator = allocator,
            .base_url = base_url,
            .requests = requests_per_worker,
            .latencies = all_latencies[offset .. offset + requests_per_worker],
            .successful = &successful,
            .failed = &failed,
            .total_bytes = &total_bytes,
        };
        threads[w] = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *WorkerCtx) void {
                var client = HttpClient.init(ctx.allocator) catch return;
                defer client.deinit();
                const w_io = client.io();

                const url = std.fmt.allocPrint(ctx.allocator, "{s}/json", .{ctx.base_url}) catch return;
                defer ctx.allocator.free(url);

                for (0..ctx.requests) |i| {
                    const req_sw = Stopwatch.begin(w_io);
                    var response = client.get(url, &.{}) catch {
                        _ = ctx.failed.fetchAdd(1, .monotonic);
                        ctx.latencies[i] = 0;
                        continue;
                    };
                    ctx.latencies[i] = req_sw.elapsedNs() / 1000;
                    _ = ctx.total_bytes.fetchAdd(response.body.len, .monotonic);
                    _ = ctx.successful.fetchAdd(1, .monotonic);
                    response.deinit();
                }
            }
        }.run, .{&ctxs[w]});
    }

    for (threads) |t| t.join();

    const total_ms = sw.elapsedMs();
    const succ = successful.load(.acquire);
    const fail = failed.load(.acquire);

    std.mem.sort(u64, all_latencies, {}, std.sort.asc(u64));

    const name_buf = std.fmt.allocPrint(allocator, "Concurrent GET /json ({d} workers)", .{workers}) catch "Concurrent GET";
    // We'll leak this small string — it's fine for benchmark output

    return BenchResult{
        .name = name_buf,
        .total_requests = total,
        .successful = succ,
        .failed = fail,
        .total_time_ms = total_ms,
        .p50_us = percentile(all_latencies, 0.50),
        .p95_us = percentile(all_latencies, 0.95),
        .p99_us = percentile(all_latencies, 0.99),
        .min_us = all_latencies[0],
        .max_us = all_latencies[all_latencies.len - 1],
        .rps = @as(f64, @floatFromInt(succ)) / (total_ms / 1000.0),
        .total_bytes = total_bytes.load(.acquire),
        .concurrency = workers,
    };
}

fn benchLargeResponse(allocator: std.mem.Allocator, base_url: []const u8, n: u32, size: usize) !BenchResult {
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    const io = client.io();

    const url = try std.fmt.allocPrint(allocator, "{s}/bytes/{d}", .{ base_url, size });
    defer allocator.free(url);

    var latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    var successful: u64 = 0;
    var failed: u64 = 0;
    var total_bytes: u64 = 0;

    const sw = Stopwatch.begin(io);

    for (0..n) |i| {
        const req_sw = Stopwatch.begin(io);
        var response = client.getWithOptions(url, &.{}, .{
            .max_body_size = 8 * 1024 * 1024,
        }) catch {
            failed += 1;
            latencies[i] = 0;
            continue;
        };
        latencies[i] = req_sw.elapsedNs() / 1000;
        total_bytes += response.body.len;
        successful += 1;
        response.deinit();
    }

    const total_ms = sw.elapsedMs();
    std.mem.sort(u64, latencies[0..@intCast(successful + failed)], {}, std.sort.asc(u64));

    return BenchResult{
        .name = if (size >= 1024 * 1024) "Large response GET /bytes/1M" else "Medium response GET /bytes/64K",
        .total_requests = n,
        .successful = successful,
        .failed = failed,
        .total_time_ms = total_ms,
        .p50_us = percentile(latencies, 0.50),
        .p95_us = percentile(latencies, 0.95),
        .p99_us = percentile(latencies, 0.99),
        .min_us = if (latencies.len > 0) latencies[0] else 0,
        .max_us = if (latencies.len > 0) latencies[latencies.len - 1] else 0,
        .rps = @as(f64, @floatFromInt(successful)) / (total_ms / 1000.0),
        .total_bytes = total_bytes,
        .concurrency = 1,
    };
}

fn benchClientCreation(allocator: std.mem.Allocator, n: u32) !BenchResult {
    var timing_io: std.Io.Threaded = .init(allocator, .{});
    defer timing_io.deinit();
    const io = timing_io.io();

    var latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    var successful: u64 = 0;

    const sw = Stopwatch.begin(io);

    for (0..n) |i| {
        const req_sw = Stopwatch.begin(io);
        var client = HttpClient.init(allocator) catch {
            latencies[i] = 0;
            continue;
        };
        latencies[i] = req_sw.elapsedNs() / 1000;
        successful += 1;
        client.deinit();
    }

    const total_ms = sw.elapsedMs();
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    return BenchResult{
        .name = "Client init/deinit cycle",
        .total_requests = n,
        .successful = successful,
        .failed = n - @as(u32, @intCast(successful)),
        .total_time_ms = total_ms,
        .p50_us = percentile(latencies, 0.50),
        .p95_us = percentile(latencies, 0.95),
        .p99_us = percentile(latencies, 0.99),
        .min_us = latencies[0],
        .max_us = latencies[latencies.len - 1],
        .rps = @as(f64, @floatFromInt(successful)) / (total_ms / 1000.0),
        .total_bytes = 0,
        .concurrency = 1,
    };
}

fn benchRetryEngine(allocator: std.mem.Allocator) !BenchResult {
    var timing_io: std.Io.Threaded = .init(allocator, .{});
    defer timing_io.deinit();
    const io = timing_io.io();

    // Test retry engine overhead with success-only path (no sleep delays)
    const n: u32 = 5000;
    var latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    var successful: u64 = 0;

    var engine = RetryEngine.init(allocator, .{
        .max_attempts = 3,
        .base_delay_ms = 0,
        .max_delay_ms = 0,
        .enable_circuit_breaker = false,
    }, io);
    // Bypass rate limiter by giving it unlimited tokens
    engine.rate_limiter.max_tokens = 1_000_000;
    engine.rate_limiter.tokens = 1_000_000;

    var call_count = std.atomic.Value(u32).init(0);

    const sw = Stopwatch.begin(io);

    for (0..n) |i| {
        const req_sw = Stopwatch.begin(io);
        const Ctx = struct {
            counter: *std.atomic.Value(u32),
        };
        const ctx = Ctx{ .counter = &call_count };
        _ = engine.execute(u32, ctx, struct {
            fn run(c: Ctx) anyerror!u32 {
                // Always succeed — measure pure engine overhead
                return c.counter.fetchAdd(1, .monotonic);
            }
        }.run, null) catch {};
        latencies[i] = req_sw.elapsedNs() / 1000;
        successful += 1;
    }

    const total_ms = sw.elapsedMs();
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    return BenchResult{
        .name = "RetryEngine overhead (success path, no delays)",
        .total_requests = n,
        .successful = successful,
        .failed = 0,
        .total_time_ms = total_ms,
        .p50_us = percentile(latencies, 0.50),
        .p95_us = percentile(latencies, 0.95),
        .p99_us = percentile(latencies, 0.99),
        .min_us = latencies[0],
        .max_us = latencies[latencies.len - 1],
        .rps = @as(f64, @floatFromInt(successful)) / (total_ms / 1000.0),
        .total_bytes = 0,
        .concurrency = 1,
    };
}

fn benchMixedWorkload(allocator: std.mem.Allocator, base_url: []const u8, workers: u32) !BenchResult {
    const requests_per_worker: u32 = 50;
    const total = @as(u64, workers) * @as(u64, requests_per_worker);
    var all_latencies = try allocator.alloc(u64, @intCast(total));
    defer allocator.free(all_latencies);

    var successful = std.atomic.Value(u64).init(0);
    var failed = std.atomic.Value(u64).init(0);
    var total_bytes = std.atomic.Value(u64).init(0);

    var timing_io: std.Io.Threaded = .init(allocator, .{});
    defer timing_io.deinit();
    const io = timing_io.io();

    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        base_url: []const u8,
        worker_id: u32,
        latencies: []u64,
        successful: *std.atomic.Value(u64),
        failed: *std.atomic.Value(u64),
        total_bytes: *std.atomic.Value(u64),
    };

    var threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    var ctxs = try allocator.alloc(WorkerCtx, workers);
    defer allocator.free(ctxs);

    const sw = Stopwatch.begin(io);

    for (0..workers) |w| {
        const offset = w * requests_per_worker;
        ctxs[w] = .{
            .allocator = allocator,
            .base_url = base_url,
            .worker_id = @intCast(w),
            .latencies = all_latencies[offset .. offset + requests_per_worker],
            .successful = &successful,
            .failed = &failed,
            .total_bytes = &total_bytes,
        };
        threads[w] = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *WorkerCtx) void {
                var client = HttpClient.init(ctx.allocator) catch return;
                defer client.deinit();
                const w_io = client.io();

                const urls = [_][]const u8{
                    "/json",
                    "/health",
                    "/bytes/1024",
                    "/echo",
                    "/status/200",
                    "/status/404",
                };

                for (0..50) |i| {
                    const endpoint = urls[i % urls.len];
                    const url = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ctx.base_url, endpoint }) catch continue;
                    defer ctx.allocator.free(url);

                    const req_sw = Stopwatch.begin(w_io);

                    if (std.mem.eql(u8, endpoint, "/echo")) {
                        var resp = client.post(url, &.{
                            .{ .name = "content-type", .value = "text/plain" },
                        }, "benchmark payload") catch {
                            _ = ctx.failed.fetchAdd(1, .monotonic);
                            ctx.latencies[i] = 0;
                            continue;
                        };
                        ctx.latencies[i] = req_sw.elapsedNs() / 1000;
                        _ = ctx.total_bytes.fetchAdd(resp.body.len, .monotonic);
                        _ = ctx.successful.fetchAdd(1, .monotonic);
                        resp.deinit();
                    } else {
                        var resp = client.get(url, &.{}) catch {
                            _ = ctx.failed.fetchAdd(1, .monotonic);
                            ctx.latencies[i] = 0;
                            continue;
                        };
                        ctx.latencies[i] = req_sw.elapsedNs() / 1000;
                        _ = ctx.total_bytes.fetchAdd(resp.body.len, .monotonic);
                        _ = ctx.successful.fetchAdd(1, .monotonic);
                        resp.deinit();
                    }
                }
            }
        }.run, .{&ctxs[w]});
    }

    for (threads) |t| t.join();

    const total_ms = sw.elapsedMs();
    std.mem.sort(u64, all_latencies, {}, std.sort.asc(u64));

    return BenchResult{
        .name = "Mixed workload (GET+POST+status, multi-endpoint)",
        .total_requests = total,
        .successful = successful.load(.acquire),
        .failed = failed.load(.acquire),
        .total_time_ms = total_ms,
        .p50_us = percentile(all_latencies, 0.50),
        .p95_us = percentile(all_latencies, 0.95),
        .p99_us = percentile(all_latencies, 0.99),
        .min_us = all_latencies[0],
        .max_us = all_latencies[all_latencies.len - 1],
        .rps = @as(f64, @floatFromInt(successful.load(.acquire))) / (total_ms / 1000.0),
        .total_bytes = total_bytes.load(.acquire),
        .concurrency = workers,
    };
}

// ─────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    // Parse args
    var quick = false;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick") or std.mem.eql(u8, arg, "-q")) {
            quick = true;
        }
    }

    const cfg: BenchConfig = if (quick) quick_config else .{};

    std.debug.print(
        \\
        \\  HTTP Sentinel Benchmark Suite
        \\  ══════════════════════════════════════
        \\  Mode:    {s}
        \\  Zig:     pure (link_libc = false)
        \\
    , .{if (quick) "quick" else "full"});

    // Start embedded test server
    std.debug.print("  Starting embedded test server...\n", .{});
    const server = try TestServer.start(allocator);
    defer server.stop(allocator);

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{server.port});
    defer allocator.free(base_url);

    std.debug.print("  Server listening on port {d}\n", .{server.port});

    // Wait briefly for server to be ready
    {
        var warmup_io: std.Io.Threaded = .init(allocator, .{});
        defer warmup_io.deinit();
        warmup_io.io().sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    // Warm up — a few requests to prime connections
    {
        var client = try HttpClient.init(allocator);
        defer client.deinit();
        const warmup_url = try std.fmt.allocPrint(allocator, "{s}/health", .{base_url});
        defer allocator.free(warmup_url);
        for (0..5) |_| {
            var resp = client.get(warmup_url, &.{}) catch continue;
            resp.deinit();
        }
    }

    std.debug.print(
        \\
        \\  Running benchmarks...
        \\
    , .{});

    var results: std.ArrayListUnmanaged(BenchResult) = .empty;
    defer results.deinit(allocator);

    // ── 1. Client lifecycle ──
    {
        const r = try benchClientCreation(allocator, cfg.sequential_requests);
        r.print();
        try results.append(allocator, r);
    }

    // ── 2. Sequential GET ──
    {
        const r = try benchSequentialGet(allocator, base_url, cfg.sequential_requests);
        r.print();
        try results.append(allocator, r);
    }

    // ── 3. Sequential POST (small body) ──
    {
        const r = try benchSequentialPost(allocator, base_url, cfg.sequential_requests, 64);
        r.print();
        try results.append(allocator, r);
    }

    // ── 4. Sequential POST (large body) ──
    {
        const r = try benchSequentialPost(allocator, base_url, @min(cfg.sequential_requests, 50), cfg.large_body_size);
        r.print();
        try results.append(allocator, r);
    }

    // ── 5. Large response download ──
    {
        const r = try benchLargeResponse(allocator, base_url, @min(cfg.sequential_requests, 50), cfg.large_body_size);
        r.print();
        try results.append(allocator, r);
    }

    // ── 6. Concurrent GET at various levels ──
    for (cfg.concurrency_levels) |level| {
        const r = try benchConcurrentGet(allocator, base_url, level, cfg.requests_per_worker);
        r.print();
        try results.append(allocator, r);
    }

    // ── 7. RetryEngine ──
    {
        const r = try benchRetryEngine(allocator);
        r.print();
        try results.append(allocator, r);
    }

    // ── 8. Mixed workload stress ──
    {
        const r = try benchMixedWorkload(allocator, base_url, 16);
        r.print();
        try results.append(allocator, r);
    }

    // ── 9. SSE incremental streaming test ──
    {
        std.debug.print(
            \\
            \\  SSE incremental streaming (postSseStream)
            \\  ──────────────────────────────────────
        , .{});

        var client = try HttpClient.init(allocator);
        defer client.deinit();

        const sse_url = try std.fmt.allocPrint(allocator, "{s}/sse", .{base_url});
        defer allocator.free(sse_url);

        const SseTestCtx = struct {
            events_received: u32 = 0,
            first_event_ns: u64 = 0,
            last_event_ns: u64 = 0,
            io: std.Io,

            fn handler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
                const ctx: *@This() = @alignCast(@ptrCast(raw_ctx orelse return false));
                if (event.done) return false;
                ctx.events_received += 1;
                const now = Stopwatch.begin(ctx.io).elapsedNs();
                if (ctx.events_received == 1) ctx.first_event_ns = now;
                ctx.last_event_ns = now;
                return true;
            }
        };

        var sse_ctx = SseTestCtx{ .io = client.io() };
        const sse_sw = Stopwatch.begin(client.io());

        const status = client.postSseStream(
            sse_url,
            &.{ .{ .name = "content-type", .value = "application/json" } },
            "{}",
            SseTestCtx.handler,
            &sse_ctx,
        ) catch |err| blk: {
            std.debug.print("  ERROR: {s}\n", .{@errorName(err)});
            break :blk @as(std.http.Status, .internal_server_error);
        };

        const total_ms = sse_sw.elapsedMs();

        std.debug.print(
            \\
            \\  Status:       {d}
            \\  Events:       {d}
            \\  Duration:     {d:.1}ms
            \\  Result:       {s}
            \\
        , .{
            @intFromEnum(status),
            sse_ctx.events_received,
            total_ms,
            if (sse_ctx.events_received >= 4) "PASS — incremental SSE working" else "NEEDS WORK",
        });
    }

    // ── Summary ──
    const server_reqs = server.getRequestCount();
    std.debug.print(
        \\
        \\  ══════════════════════════════════════
        \\  Summary
        \\  ──────────────────────────────────────
        \\  Benchmarks run:        {d}
        \\  Server requests:       {d}
        \\
    , .{ results.items.len, server_reqs });

    // Find peak throughput
    var peak_rps: f64 = 0;
    var peak_name: []const u8 = "";
    for (results.items) |r| {
        if (r.rps > peak_rps) {
            peak_rps = r.rps;
            peak_name = r.name;
        }
    }
    std.debug.print(
        \\  Peak throughput:       {d:.0} req/s ({s})
        \\  ══════════════════════════════════════
        \\
    , .{ peak_rps, peak_name });
}
