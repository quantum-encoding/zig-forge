// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Quantum Curl - Universal HTTP Engine
//! A protocol-aware HTTP request processor built on zig-http-concurrent

const std = @import("std");
const Engine = @import("engine/core.zig").Engine;
const EngineConfig = @import("engine/core.zig").EngineConfig;
const manifest = @import("engine/manifest.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command line arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // Skip program name

    var input_file: ?[]const u8 = null;
    var max_concurrency: u32 = 50;
    var show_help = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
            break;
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            input_file = args_iter.next() orelse {
                std.debug.print("Error: --file requires a path\n", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-c")) {
            const concurrency_str = args_iter.next() orelse {
                std.debug.print("Error: --concurrency requires a value\n", .{});
                return error.InvalidArgs;
            };
            max_concurrency = try std.fmt.parseInt(u32, concurrency_str, 10);
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    // Read input
    var requests: std.ArrayListUnmanaged(manifest.RequestManifest) = .empty;
    defer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit(allocator);
    }

    if (input_file) |file_path| {
        try readRequestsFromFile(allocator, file_path, &requests);
    } else {
        try readRequestsFromStdin(allocator, &requests);
    }

    if (requests.items.len == 0) {
        std.debug.print("Error: No requests to process\n", .{});
        return error.NoRequests;
    }

    // Initialize engine - write directly to stdout using fd 1
    const StdoutWriter = struct {
        pub fn write(self: @This(), bytes: []const u8) !usize {
            _ = self;
            const n = std.c.write(1, bytes.ptr, bytes.len);
            if (n < 0) return error.WriteError;
            return @intCast(n);
        }
    };
    const writer = StdoutWriter{};

    const EngineType = Engine(@TypeOf(writer));
    var engine = try EngineType.init(
        allocator,
        .{ .max_concurrency = max_concurrency },
        writer,
    );
    defer engine.deinit();

    // Process requests
    try engine.processBatch(requests.items);
}

fn readRequestsFromFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    requests: *std.ArrayListUnmanaged(manifest.RequestManifest),
) !void {
    const path_z = try allocator.dupeZ(u8, file_path);
    defer allocator.free(path_z);

    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    // Read file contents
    var content_list: std.ArrayListUnmanaged(u8) = .empty;
    defer content_list.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try content_list.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    try parseJsonLines(allocator, content_list.items, requests);
}

fn readRequestsFromStdin(
    allocator: std.mem.Allocator,
    requests: *std.ArrayListUnmanaged(manifest.RequestManifest),
) !void {
    // Read from stdin (fd 0)
    var content_list: std.ArrayListUnmanaged(u8) = .empty;
    defer content_list.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n <= 0) break;
        try content_list.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    try parseJsonLines(allocator, content_list.items, requests);
}

fn parseJsonLines(
    allocator: std.mem.Allocator,
    content: []const u8,
    requests: *std.ArrayListUnmanaged(manifest.RequestManifest),
) !void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (line_iter.next()) |line| {
        line_num += 1;

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const request = manifest.parseRequestManifest(allocator, trimmed) catch |err| {
            std.debug.print("Error parsing line {}: {}\n", .{ line_num, err });
            continue;
        };

        try requests.append(allocator, request);
    }
}

fn printUsage() void {
    const usage =
        \\Quantum Curl - Universal HTTP Engine
        \\
        \\USAGE:
        \\    quantum-curl [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help              Show this help message
        \\    -f, --file [path]       Read requests from file (JSON Lines format)
        \\                            If not specified, reads from stdin
        \\    -c, --concurrency [n]   Maximum concurrent requests (default: 50)
        \\
        \\INPUT FORMAT (JSON Lines):
        \\    {"id": "1", "method": "GET", "url": "https://example.com"}
        \\    {"id": "2", "method": "POST", "url": "https://api.example.com", "body": "..."}
        \\
        \\OUTPUT FORMAT (JSON Lines):
        \\    {"id": "1", "status": 200, "latency_ms": 45, "body": "..."}
        \\    {"id": "2", "status": 500, "error": "Connection failed", "retry_count": 3}
        \\
        \\EXAMPLES:
        \\    # Process from stdin
        \\    echo '{"id":"1","method":"GET","url":"https://httpbin.org/get"}' | quantum-curl
        \\
        \\    # Process from file
        \\    quantum-curl --file requests.jsonl
        \\
        \\    # Process with custom concurrency
        \\    quantum-curl --file requests.jsonl --concurrency 100
        \\
    ;
    std.debug.print("{s}", .{usage});
}
