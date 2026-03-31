// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Quantum Curl - High-Velocity Command-Driven Router
//!
//! A protocol-aware HTTP request processor built on http_sentinel's apex predator core.
//! This is not a curl clone - it is a strategic weapon for microservice orchestration
//! and stress-testing at the microsecond level.
//!
//! ## Usage
//!
//! ```bash
//! # Process requests from file
//! quantum-curl --file battle-plan.jsonl --concurrency 100
//!
//! # Process from stdin (pipeline mode)
//! cat requests.jsonl | quantum-curl --concurrency 50
//!
//! # Single request via echo
//! echo '{"id":"1","method":"GET","url":"https://httpbin.org/get"}' | quantum-curl
//! ```
//!
//! ## Performance
//!
//! - 5-7x lower latency than nginx for routing operations
//! - ~2ms p99 latency under concurrent load
//! - Zero-contention via client-per-worker pattern
//! - Real-time JSONL streaming output

const std = @import("std");
const quantum_curl = @import("quantum-curl");
const Engine = quantum_curl.Engine;
const manifest = quantum_curl.manifest;
const ingest = quantum_curl.ingest;

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

    var input_file: ?[]const u8 = null;
    var max_concurrency: u32 = 50;
    var timeout_ms: u64 = 300_000; // 5 minutes default
    var max_retries: u32 = 1;
    var output_dir: ?[]const u8 = null;
    var output_ext: []const u8 = "md";
    var base64_field: ?[]const u8 = null;
    var show_help = false;

    // Parse command line arguments (skip program name at index 0)
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
            break;
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file requires a path\n", .{});
                return error.InvalidArgs;
            }
            input_file = args[i];
        } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --concurrency requires a value\n", .{});
                return error.InvalidArgs;
            }
            max_concurrency = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --timeout requires milliseconds\n", .{});
                return error.InvalidArgs;
            }
            timeout_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--retries") or std.mem.eql(u8, arg, "-r")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --retries requires a value\n", .{});
                return error.InvalidArgs;
            }
            max_retries = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--output-dir") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output-dir requires a path\n", .{});
                return error.InvalidArgs;
            }
            output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--output-ext") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output-ext requires an extension\n", .{});
                return error.InvalidArgs;
            }
            output_ext = args[i];
        } else if (std.mem.eql(u8, arg, "--base64-field") or std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --base64-field requires a dot-path\n", .{});
                return error.InvalidArgs;
            }
            base64_field = args[i];
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    // Read input - the Battle Plan
    var requests: std.ArrayList(manifest.RequestManifest) = .empty;
    defer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit(allocator);
    }

    if (input_file) |file_path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(50 * 1024 * 1024));
        defer allocator.free(content);
        try ingest.parseInput(allocator, content, file_path, &requests);
    } else {
        // Read stdin
        const stdin = std.Io.File.stdin();
        var buf: [8192]u8 = undefined;
        var stdin_reader = stdin.reader(io, &buf);
        const content = try stdin_reader.interface.allocRemaining(allocator, .limited(50 * 1024 * 1024));
        defer allocator.free(content);
        try ingest.parseInput(allocator, content, null, &requests);
    }

    if (requests.items.len == 0) {
        std.debug.print("Error: No requests to process\n", .{});
        return error.NoRequests;
    }

    // Initialize the Execution Engine
    // Use larger buffer for high concurrency (64KB to handle burst writes)
    const stdout = std.Io.File.stdout();
    var stdout_buffer: [65536]u8 = undefined;
    var writer = stdout.writer(io, &stdout_buffer);

    const EngineType = Engine(@TypeOf(writer));
    var engine = try EngineType.init(
        allocator,
        .{
            .max_concurrency = max_concurrency,
            .default_timeout_ms = timeout_ms,
            .default_max_retries = max_retries,
            .output_dir = output_dir,
            .output_ext = output_ext,
            .base64_field = base64_field,
        },
        writer,
    );
    defer engine.deinit();

    // Execute the Battle Plan
    try engine.processBatch(requests.items);

    // Flush any remaining buffered output
    try std.Io.Writer.flush(&writer.interface);
}

// Input parsing is handled by the ingest module (CSV, TSV, JSON, JSONL).

fn printUsage() void {
    const usage =
        \\Quantum Curl - High-Velocity Command-Driven Router
        \\
        \\A protocol-aware HTTP request processor for microservice orchestration
        \\and stress-testing. Built on http_sentinel's apex predator core.
        \\
        \\USAGE:
        \\    quantum-curl [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help              Show this help message
        \\    -f, --file [path]       Read requests from file (JSON Lines format)
        \\                            If not specified, reads from stdin
        \\    -c, --concurrency [n]   Maximum concurrent requests (default: 50)
        \\    -t, --timeout [ms]      Request timeout in milliseconds (default: 300000 = 5min)
        \\                            Use 0 for no timeout. Per-request override via timeout_ms field
        \\    -r, --retries [n]       Max retry attempts on failure (default: 1)
        \\    -o, --output-dir [dir]  Save each response body to {dir}/{id}.{ext}
        \\                            Creates directory if it doesn't exist
        \\    -e, --output-ext [ext]  File extension for saved files (default: md)
        \\    -b, --base64-field [p]  Dot-path to base64 data in JSON response body
        \\                            Decodes base64 → binary file (for images, audio, etc.)
        \\                            Example: predictions.0.bytesBase64Encoded
        \\
        \\INPUT FORMATS (auto-detected from extension or content):
        \\
        \\    JSONL (.jsonl, .ndjson — one JSON object per line):
        \\    {"id": "1", "method": "GET", "url": "https://example.com"}
        \\    {"id": "2", "method": "POST", "url": "https://api.example.com", "body": "..."}
        \\
        \\    JSON Array (.json):
        \\    [{"url": "https://example.com"}, {"url": "https://example.com/other"}]
        \\
        \\    CSV (.csv — header row maps fields, only 'url' required):
        \\    url,method,body
        \\    https://api.example.com/health,GET,
        \\    https://api.example.com/data,POST,{"key":"value"}
        \\
        \\    TSV (.tsv — tab-separated, same field mapping as CSV)
        \\
        \\    Fields: url (required), id, method, body, headers, timeout_ms, max_retries
        \\    Missing 'id' → auto-generated (row-1, row-2, ...); missing 'method' → GET
        \\
        \\OUTPUT FORMAT (JSON Lines - Telemetry Stream):
        \\    {"id": "1", "status": 200, "latency_ms": 45, "retry_count": 0, "body": "..."}
        \\    {"id": "2", "status": 500, "error": "Connection failed", "retry_count": 3}
        \\
        \\EXAMPLES:
        \\    # Process from stdin
        \\    echo '{"id":"1","method":"GET","url":"https://httpbin.org/get"}' | quantum-curl
        \\
        \\    # Process from file
        \\    quantum-curl --file requests.jsonl
        \\
        \\    # Process with high concurrency (stress testing)
        \\    quantum-curl --file battle-plan.jsonl --concurrency 100
        \\
        \\    # Pipeline mode - generate requests on the fly
        \\    ./generate-requests.sh | quantum-curl --concurrency 200
        \\
        \\STRATEGIC APPLICATIONS:
        \\    - Service Mesh Router: High-velocity inter-service communication
        \\    - Resilience Testing: Impose discipline on flaky services via retry
        \\    - Stress Testing: Find breaking points under realistic concurrent load
        \\    - API Testing: Batch execution of test suites with full telemetry
        \\
        \\PERFORMANCE:
        \\    - 5-7x lower latency than nginx routing
        \\    - ~2ms p99 latency under concurrent load
        \\    - Zero-contention via client-per-worker pattern
        \\
    ;
    std.debug.print("{s}", .{usage});
}
