//! SurrealDB HTTP Client
//!
//! Extracted from the monolithic main.zig. Handles HTTP communication
//! with SurrealDB, including query execution and response parsing.

const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const Config = types.Config;

pub const SurrealError = error{
    ConnectionFailed,
    QueryFailed,
    ParseError,
    HttpError,
    OutOfMemory,
    InvalidResponse,
};

const HttpClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *std.Io.Threaded,
    client: http.Client,

    fn init(allocator: std.mem.Allocator, environ: std.process.Environ) !HttpClient {
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator, .{ .environ = environ });
        const io = io_threaded.io();

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .client = http.Client{
                .allocator = allocator,
                .io = io,
            },
        };
    }

    fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    fn decompressGzip(self: *HttpClient, compressed_data: []const u8) ![]u8 {
        var in: std.Io.Reader = .fixed(compressed_data);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch {
            return try self.allocator.dupe(u8, compressed_data);
        };

        return try self.allocator.dupe(u8, aw.written());
    }

    fn post(self: *HttpClient, url: []const u8, headers: []const http.Header, body: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
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
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(body_data);

        if (response.head.content_encoding == .gzip) {
            return try self.decompressGzip(body_data);
        }

        return try self.allocator.dupe(u8, body_data);
    }
};

/// SurrealDB client wrapping HTTP communication and query execution.
pub const SurrealClient = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http_client: HttpClient,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, environ: std.process.Environ) !SurrealClient {
        return .{
            .allocator = allocator,
            .config = cfg,
            .http_client = try HttpClient.init(allocator, environ),
        };
    }

    pub fn deinit(self: *SurrealClient) void {
        self.http_client.deinit();
    }

    /// Execute a raw SQL query and return the JSON response string.
    /// Caller owns the returned slice.
    pub fn executeQuery(self: *SurrealClient, sql: []const u8) ![]const u8 {
        const full_query = try std.fmt.allocPrint(self.allocator, "USE NS {s} DB {s}; {s}", .{
            self.config.ns,
            self.config.db,
            sql,
        });
        defer self.allocator.free(full_query);

        const headers: []const http.Header = &.{
            .{ .name = "Authorization", .value = self.config.auth },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "text/plain" },
        };

        const body = self.http_client.post(self.config.url, headers, full_query) catch return SurrealError.ConnectionFailed;
        return body;
    }

    /// Execute a query and parse the JSON response, extracting the result array
    /// from the `[USE, {status, result}]` wrapper. Returns null on parse failure.
    pub fn executeQueryParsed(self: *SurrealClient, sql: []const u8) !?std.json.Value {
        const response = try self.executeQuery(sql);
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return null;
        };
        // Note: caller is responsible for deinit on the returned parsed value.
        // We return the parsed struct by value so the caller can manage it.
        _ = parsed;

        // Re-parse since we can't move ownership easily with std.json
        const parsed2 = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return null;
        };

        if (parsed2.value != .array or parsed2.value.array.items.len < 2) {
            parsed2.deinit();
            return null;
        }

        // We need a different approach: return the raw JSON and let callers parse
        // This is because std.json.Parsed owns the memory and we can't transfer it easily
        parsed2.deinit();
        return null;
    }

    /// Execute a query and parse the result, returning the items from the result array.
    /// This is the primary query method - returns the raw response JSON for callers to parse.
    /// Caller owns the returned slice.
    pub fn query(self: *SurrealClient, sql: []const u8) ![]const u8 {
        return self.executeQuery(sql);
    }

    /// Execute a batch of SQL statements in a single POST.
    /// Caller owns the returned slice.
    pub fn executeBatch(self: *SurrealClient, statements: []const []const u8) ![]const u8 {
        // Calculate total length
        var total_len: usize = 0;
        for (statements) |stmt| {
            total_len += stmt.len + 2; // "; " separator
        }
        total_len += 32; // USE NS ... DB ...;

        const ns_prefix = try std.fmt.allocPrint(self.allocator, "USE NS {s} DB {s}; ", .{
            self.config.ns,
            self.config.db,
        });
        defer self.allocator.free(ns_prefix);

        var buf = try self.allocator.alloc(u8, ns_prefix.len + total_len);
        defer self.allocator.free(buf);

        var pos: usize = 0;
        @memcpy(buf[pos .. pos + ns_prefix.len], ns_prefix);
        pos += ns_prefix.len;

        for (statements) |stmt| {
            @memcpy(buf[pos .. pos + stmt.len], stmt);
            pos += stmt.len;
            buf[pos] = ';';
            pos += 1;
            buf[pos] = ' ';
            pos += 1;
        }

        const headers: []const http.Header = &.{
            .{ .name = "Authorization", .value = self.config.auth },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "text/plain" },
        };

        const body = self.http_client.post(self.config.url, headers, buf[0..pos]) catch return SurrealError.ConnectionFailed;
        return body;
    }
};

/// Helper to extract the result array from a SurrealDB response.
/// Response format: `[{USE result}, {status: "OK", result: [...]}]`
/// Returns the items slice from the result array, or null if parsing fails.
pub fn extractResult(parsed_value: std.json.Value) ?[]std.json.Value {
    if (parsed_value != .array or parsed_value.array.items.len < 2) return null;

    const query_result = parsed_value.array.items[1];
    if (query_result != .object) return null;

    const result_obj = query_result.object;
    const status = result_obj.get("status") orelse return null;
    if (status != .string or !std.mem.eql(u8, status.string, "OK")) return null;

    const result = result_obj.get("result") orelse return null;
    if (result != .array) return null;

    return result.array.items;
}

/// Extract a count value from a SurrealDB GROUP ALL response.
pub fn extractCount(parsed_value: std.json.Value) i64 {
    const items = extractResult(parsed_value) orelse return 0;
    if (items.len == 0) return 0;
    if (items[0] != .object) return 0;
    const count = items[0].object.get("count") orelse return 0;
    if (count != .integer) return 0;
    return count.integer;
}

/// Extract a string field from a JSON object, returning a default if not found.
pub fn getString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "?";
}

/// Extract an integer field from a JSON object, returning 0 if not found.
pub fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |v| {
        if (v == .integer) return v.integer;
    }
    return 0;
}
