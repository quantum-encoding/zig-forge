//! SurrealDB HTTP Client
//!
//! Handles HTTP communication with SurrealDB, including query execution
//! and response parsing. Same pattern as zig-code-query-native/src/surreal.zig.

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
};
