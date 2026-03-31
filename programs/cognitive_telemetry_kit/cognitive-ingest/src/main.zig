//! Cognitive State Ingest - SurrealDB v3 Integration
//!
//! Reads cognitive states captured by libcognitive-capture.dylib
//! and inserts them into SurrealDB for analysis and querying.
//!
//! Usage:
//!   cognitive-ingest [options]
//!
//! Options:
//!   --daemon          Run continuously, watching for new states
//!   --once            Process once and exit (default)
//!   --url <url>       SurrealDB URL (default: http://127.0.0.1:8000/sql)
//!   --ns <name>       Namespace (default: cognitive)
//!   --db <name>       Database (default: telemetry)

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

// =============================================================================
// Configuration
// =============================================================================

const Config = struct {
    url: []const u8 = "http://127.0.0.1:8000/sql",
    auth: []const u8 = "Basic cm9vdDpyb290", // root:root
    ns: []const u8 = "cognitive",
    db: []const u8 = "telemetry",
    daemon: bool = false,
    capture_file: []const u8 = "/tmp/cognitive-state-capture",
    poll_interval_ms: u64 = 1000,
};

var config: Config = .{};

// =============================================================================
// Cognitive State
// =============================================================================

const CognitiveState = struct {
    timestamp: i64,
    pid: i32,
    state: []const u8,
};

fn parseState(allocator: Allocator, line: []const u8) !?CognitiveState {
    // Format: timestamp:pid:state
    var parts = std.mem.splitScalar(u8, line, ':');

    const ts_str = parts.next() orelse return null;
    const pid_str = parts.next() orelse return null;
    const state = parts.rest();

    if (state.len == 0) return null;

    const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return null;
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch return null;

    return CognitiveState{
        .timestamp = timestamp,
        .pid = pid,
        .state = try allocator.dupe(u8, std.mem.trim(u8, state, " \t\r\n")),
    };
}

// =============================================================================
// HTTP Client for Zig 0.16
// =============================================================================

var global_io: ?std.Io = null;

fn httpPost(allocator: Allocator, url: []const u8, headers: []const http.Header, body: []const u8) ![]u8 {
    const io = global_io orelse return error.NoIoContext;
    const uri = try std.Uri.parse(url);

    var client = http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    var transfer_buffer: [8192]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    const body_data = try response_reader.allocRemaining(
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    );

    return body_data;
}

// =============================================================================
// SurrealDB Client
// =============================================================================

fn executeQuery(allocator: Allocator, sql: []const u8) ![]const u8 {
    const full_query = try std.fmt.allocPrint(allocator, "USE NS {s} DB {s}; {s}", .{
        config.ns,
        config.db,
        sql,
    });
    defer allocator.free(full_query);

    const headers: []const http.Header = &.{
        .{ .name = "Authorization", .value = config.auth },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };

    return httpPost(allocator, config.url, headers, full_query);
}

fn initSchema(allocator: Allocator) !void {
    const schema =
        \\DEFINE TABLE IF NOT EXISTS cognitive_state SCHEMAFULL;
        \\DEFINE FIELD state ON cognitive_state TYPE string;
        \\DEFINE FIELD pid ON cognitive_state TYPE int;
        \\DEFINE FIELD timestamp ON cognitive_state TYPE int;
        \\DEFINE FIELD captured_at ON cognitive_state TYPE datetime DEFAULT time::now();
        \\DEFINE FIELD session_id ON cognitive_state TYPE option<string>;
        \\DEFINE INDEX idx_timestamp ON cognitive_state FIELDS timestamp;
        \\DEFINE INDEX idx_state ON cognitive_state FIELDS state;
        \\DEFINE INDEX idx_pid ON cognitive_state FIELDS pid;
    ;

    const response = executeQuery(allocator, schema) catch |err| {
        std.debug.print("Warning: Failed to initialize schema: {s}\n", .{@errorName(err)});
        return;
    };
    allocator.free(response);
    std.debug.print("Schema initialized.\n", .{});
}

fn insertState(allocator: Allocator, state: CognitiveState) !void {
    // Escape the state string for SQL
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);

    for (state.state) |c| {
        switch (c) {
            '\'' => try escaped.appendSlice(allocator, "\\'"),
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            else => try escaped.append(allocator, c),
        }
    }

    const sql = try std.fmt.allocPrint(allocator,
        \\CREATE cognitive_state SET
        \\  state = '{s}',
        \\  pid = {d},
        \\  timestamp = {d}
    , .{ escaped.items, state.pid, state.timestamp });
    defer allocator.free(sql);

    const response = try executeQuery(allocator, sql);
    allocator.free(response);
}

// =============================================================================
// State Processing
// =============================================================================

var last_processed_offset: usize = 0;

fn processCaptures(allocator: Allocator) !usize {
    // Read capture file using std.c
    const c = std.c;
    const path_z: [*:0]const u8 = @ptrCast(config.capture_file.ptr);
    const fd = c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return 0; // File not found
    defer _ = c.close(fd);

    // Get file size
    var stat: c.Stat = undefined;
    if (c.fstat(fd, &stat) < 0) return 0;
    const file_size: usize = @intCast(stat.size);

    if (file_size == 0) return 0;

    // Read file content
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    var total_read: usize = 0;
    while (total_read < file_size) {
        const ret = c.read(fd, content.ptr + total_read, file_size - total_read);
        if (ret <= 0) break;
        total_read += @intCast(ret);
    }

    if (content.len <= last_processed_offset) return 0;

    // Process new lines only
    const new_content = content[last_processed_offset..];
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, new_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (parseState(allocator, line) catch null) |state| {
            defer allocator.free(state.state);

            insertState(allocator, state) catch |err| {
                std.debug.print("Insert error: {s}\n", .{@errorName(err)});
                continue;
            };
            count += 1;
        }
    }

    last_processed_offset = content.len;
    return count;
}

// =============================================================================
// Main
// =============================================================================

fn printUsage() void {
    std.debug.print(
        \\cognitive-ingest - Cognitive State SurrealDB Ingestion
        \\
        \\USAGE:
        \\  cognitive-ingest [options]
        \\
        \\OPTIONS:
        \\  --daemon          Run continuously, watching for new states
        \\  --once            Process once and exit (default)
        \\  --url <url>       SurrealDB URL (default: http://127.0.0.1:8000/sql)
        \\  --ns <name>       Namespace (default: cognitive)
        \\  --db <name>       Database (default: telemetry)
        \\  --help, -h        Show this help
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    global_io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--daemon")) {
            config.daemon = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            config.daemon = false;
        } else if (std.mem.eql(u8, arg, "--url") and i + 1 < args.len) {
            i += 1;
            config.url = args[i];
        } else if (std.mem.eql(u8, arg, "--ns") and i + 1 < args.len) {
            i += 1;
            config.ns = args[i];
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            i += 1;
            config.db = args[i];
        }
    }

    // io context from init

    std.debug.print("\n=== Cognitive State Ingest ===\n", .{});
    std.debug.print("Target: {s} -> {s}.{s}\n", .{ config.url, config.ns, config.db });
    std.debug.print("Mode: {s}\n\n", .{if (config.daemon) "daemon" else "once"});

    // Initialize schema
    try initSchema(allocator);

    if (config.daemon) {
        std.debug.print("Watching {s} for new states...\n", .{config.capture_file});

        while (true) {
            const count = processCaptures(allocator) catch |err| blk: {
                std.debug.print("Error: {s}\n", .{@errorName(err)});
                break :blk 0;
            };

            if (count > 0) {
                std.debug.print("Ingested {d} states\n", .{count});
            }

            if (global_io) |io| {
                io.sleep(.fromMilliseconds(@intCast(config.poll_interval_ms)), .awake) catch {};
            }
        }
    } else {
        const count = try processCaptures(allocator);
        std.debug.print("Ingested {d} cognitive states.\n", .{count});
    }
}
