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
const gcp = @import("gcp-auth");
const http_sentinel = @import("http-sentinel");

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
    var failed_log_path: ?[]const u8 = null;
    // Auth refresh configuration
    var refresh_auth_command: ?[]const u8 = null;
    var refresh_auth_interval_sec: u64 = 1800; // 30 minutes default
    var auth_header_name: []const u8 = "Authorization";
    var auth_header_prefix: []const u8 = "Bearer ";
    var use_gcp_auth: bool = false;
    var gcp_auth_scope: []const u8 = gcp.SCOPE_CLOUD_PLATFORM;
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
        } else if (std.mem.eql(u8, arg, "--failed-log") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --failed-log requires a path\n", .{});
                return error.InvalidArgs;
            }
            failed_log_path = args[i];
        } else if (std.mem.eql(u8, arg, "--refresh-auth-header-command")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --refresh-auth-header-command requires a shell command\n", .{});
                return error.InvalidArgs;
            }
            refresh_auth_command = args[i];
        } else if (std.mem.eql(u8, arg, "--refresh-auth-interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --refresh-auth-interval requires seconds\n", .{});
                return error.InvalidArgs;
            }
            refresh_auth_interval_sec = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--auth-header-name")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --auth-header-name requires a header name\n", .{});
                return error.InvalidArgs;
            }
            auth_header_name = args[i];
        } else if (std.mem.eql(u8, arg, "--auth-header-prefix")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --auth-header-prefix requires a prefix string (may be empty)\n", .{});
                return error.InvalidArgs;
            }
            auth_header_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--gcp-auth")) {
            use_gcp_auth = true;
        } else if (std.mem.eql(u8, arg, "--gcp-auth-scope")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --gcp-auth-scope requires an OAuth2 scope URL\n", .{});
                return error.InvalidArgs;
            }
            gcp_auth_scope = args[i];
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    // Enforce mutual exclusion between the two auth refresh strategies.
    // Both configured would mean two refresh threads stomping on the same
    // header slot — reject at parse time rather than letting it misbehave.
    if (use_gcp_auth and refresh_auth_command != null) {
        std.debug.print(
            "Error: --gcp-auth and --refresh-auth-header-command are mutually exclusive\n",
            .{},
        );
        return error.InvalidArgs;
    }

    // Initialize the failure logger (if --failed-log provided).
    // Must be alive for the entire batch so worker threads can write to it.
    var fail_logger = try quantum_curl.fail_log.FailLogger.init(allocator, failed_log_path);
    defer fail_logger.deinit();

    // Set up the auth refresher (if requested). This must stay alive for
    // the entire batch — workers call into it on every outgoing request.
    // Constructed on the heap so its address remains stable across moves.
    var auth_refresher_ptr: ?*quantum_curl.AuthRefresher = null;
    defer if (auth_refresher_ptr) |r| {
        r.deinit();
        allocator.destroy(r);
    };

    if (use_gcp_auth or refresh_auth_command != null) {
        const source: quantum_curl.auth_refresher.Source = if (use_gcp_auth) blk: {
            // Build an environ map so autoDetect can find HOME /
            // GOOGLE_APPLICATION_CREDENTIALS. The minimal env slice from
            // std.process.Init gives us a raw c-string list; we parse it
            // into a lookup map here.
            var env_map = std.process.Environ.Map.init(allocator);
            defer env_map.deinit();
            const raw_env = std.mem.span(std.c.environ);
            for (raw_env) |maybe_cstr| {
                // Each slot is `?[*:0]u8` — gaps are legal per POSIX but rare.
                const entry_cstr = maybe_cstr orelse continue;
                const entry: []const u8 = std.mem.span(entry_cstr);
                if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                    env_map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
                }
            }

            // Spin up a temporary HttpClient for autoDetect (metadata probe,
            // credential file reads, etc.). The GcpSource constructs its own
            // long-lived client internally.
            var probe_client = try http_sentinel.HttpClient.init(allocator);
            defer probe_client.deinit();

            const provider = gcp.autoDetect(
                allocator,
                &probe_client,
                gcp_auth_scope,
                &env_map,
            ) catch |err| {
                std.debug.print(
                    "Error: --gcp-auth selected but no credentials found: {}\n" ++
                        "  Set GOOGLE_APPLICATION_CREDENTIALS, run `gcloud auth application-default login`,\n" ++
                        "  or deploy on a GCP instance with a service account attached.\n",
                    .{err},
                );
                return err;
            };

            const gcp_source = try quantum_curl.auth_refresher.GcpSource.init(allocator, provider);
            break :blk .{ .gcp = gcp_source };
        } else blk: {
            const cmd_source = try quantum_curl.auth_refresher.CommandSource.init(
                allocator,
                refresh_auth_command.?,
            );
            break :blk .{ .command = cmd_source };
        };

        const refresher = try allocator.create(quantum_curl.AuthRefresher);
        errdefer allocator.destroy(refresher);
        refresher.* = try quantum_curl.AuthRefresher.init(allocator, source);
        refresher.interval_ns = refresh_auth_interval_sec * std.time.ns_per_s;
        refresher.prefix = auth_header_prefix;

        // Initial synchronous fetch + background thread. Any failure here
        // aborts the batch — starting with no valid token is always wrong.
        refresher.start() catch |err| {
            std.debug.print("Error: auth refresher failed to start: {}\n", .{err});
            refresher.deinit();
            allocator.destroy(refresher);
            return err;
        };

        auth_refresher_ptr = refresher;
        std.debug.print(
            "[quantum-curl] auth refresh: {s}, interval {}s, header '{s}'\n",
            .{
                if (use_gcp_auth) "gcp-auth" else "command",
                refresh_auth_interval_sec,
                auth_header_name,
            },
        );
    }

    // Read input - the Battle Plan
    var requests: std.ArrayList(manifest.RequestManifest) = .empty;
    defer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit(allocator);
    }

    // 4 GB cap lets us handle batch-embedding plans where individual rows
    // can be hundreds of KB each (TEI multi-instance POST bodies). For the
    // chronos corpus we see ~222 MB plan files; the old 50 MB cap rejected
    // those with StreamTooLong. 4 GB is high enough to never trip on any
    // realistic plan while still being a sane upper bound.
    const max_plan_bytes: usize = 4 * 1024 * 1024 * 1024;

    if (input_file) |file_path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_plan_bytes));
        defer allocator.free(content);
        try ingest.parseInput(allocator, content, file_path, &requests, &fail_logger);
    } else {
        // Read stdin
        const stdin = std.Io.File.stdin();
        var buf: [8192]u8 = undefined;
        var stdin_reader = stdin.reader(io, &buf);
        const content = try stdin_reader.interface.allocRemaining(allocator, .limited(max_plan_bytes));
        defer allocator.free(content);
        try ingest.parseInput(allocator, content, null, &requests, &fail_logger);
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
            .auth_header_name = auth_header_name,
        },
        writer,
    );
    defer engine.deinit();

    // Attach the failure logger if enabled
    if (failed_log_path != null) {
        engine.setFailLogger(&fail_logger);
    }

    // Attach the auth refresher if enabled
    if (auth_refresher_ptr) |r| {
        engine.setAuthRefresher(r);
    }

    // Execute the Battle Plan
    try engine.processBatch(requests.items);

    // Flush any remaining buffered output
    try std.Io.Writer.flush(&writer.interface);

    // Print failure summary if fail logging was enabled
    if (failed_log_path) |log_path| {
        std.debug.print(
            "\n[quantum-curl] Failures: {} / {} requests\n" ++
                "[quantum-curl] Rerun failed requests:\n" ++
                "  quantum-curl --file {s}\n",
            .{ fail_logger.failed_count, requests.items.len, log_path },
        );
    }
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
        \\    -l, --failed-log [path] Write failed requests to {path} (replay-ready JSONL)
        \\                            Also creates {path}.errors.jsonl with diagnostics
        \\                            Rerun failures: quantum-curl --file failed.jsonl
        \\                            Failure criteria: status 0 (transport) or >= 400 (HTTP)
        \\
        \\AUTH REFRESH (for long-running batches whose tokens outlive their TTL):
        \\    --refresh-auth-header-command <cmd>
        \\                            Run <cmd> via `sh -c` to fetch a fresh bearer token.
        \\                            Stdout is trimmed and becomes the token value.
        \\                            Example: "gcloud auth print-access-token"
        \\    --refresh-auth-interval <seconds>
        \\                            Refresh interval in seconds (default: 1800 = 30 min)
        \\    --auth-header-name <name>
        \\                            Header to override (default: Authorization).
        \\                            Case-insensitive match against baked-in plan headers.
        \\    --auth-header-prefix <prefix>
        \\                            Prepended to the token value (default: "Bearer ").
        \\                            Use "" to inject raw non-Bearer auth (e.g. API keys).
        \\    --gcp-auth              Native gcp_auth integration (no shell-out).
        \\                            Auto-detects in order: GOOGLE_APPLICATION_CREDENTIALS,
        \\                            GCE/Cloud Run metadata server, ~/.config/gcloud ADC.
        \\                            Mutually exclusive with --refresh-auth-header-command.
        \\    --gcp-auth-scope <url>  OAuth2 scope for --gcp-auth
        \\                            (default: cloud-platform — covers most GCP APIs)
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
        \\    # Capture failures for retry
        \\    quantum-curl --file plan.jsonl --failed-log failed.jsonl
        \\    quantum-curl --file failed.jsonl  # Rerun only failures
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
