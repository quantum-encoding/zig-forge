// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const http = std.http;

/// Check if a URL targets a private/internal IP address (SSRF defense)
pub fn isPrivateRedirect(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return true;
    const host_component = uri.host orelse return true;

    // Extract raw host string from Uri.Component
    const host = switch (host_component) {
        .raw, .percent_encoded => |s| s,
    };

    // Block private IPv4 ranges
    const private_prefixes = [_][]const u8{
        "10.", "172.16.", "172.17.", "172.18.", "172.19.",
        "172.20.", "172.21.", "172.22.", "172.23.", "172.24.",
        "172.25.", "172.26.", "172.27.", "172.28.", "172.29.",
        "172.30.", "172.31.", "192.168.", "127.", "0.",
        "169.254.",
    };
    for (private_prefixes) |prefix| {
        if (std.mem.startsWith(u8, host, prefix)) return true;
    }

    // Block localhost variants
    const blocked_hosts = [_][]const u8{
        "localhost", "[::1]", "[::0]", "metadata.google.internal",
    };
    for (blocked_hosts) |blocked| {
        if (std.ascii.eqlIgnoreCase(host, blocked)) return true;
    }

    // Block non-HTTP schemes
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return true;
    }

    return false;
}

/// Validate outbound headers — reject CRLF injection attempts
fn validateHeaders(headers: []const http.Header) !void {
    for (headers) |header| {
        for (header.name) |c| {
            if (c == '\r' or c == '\n') return error.InvalidHeader;
        }
        for (header.value) |c| {
            if (c == '\r' or c == '\n') return error.InvalidHeader;
        }
    }
}

/// A robust, thread-safe HTTP client for Zig 0.16.0-dev.2187+
///
/// Features:
/// - Simplified API for GET, POST, PUT, PATCH, DELETE operations
/// - Automatic memory management with proper cleanup
/// - Thread-safe design (each thread should use its own client instance)
/// - Configurable request timeouts and limits
/// - Support for custom headers
/// - Automatic gzip decompression
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *std.Io.Threaded,
    client: http.Client,

    /// Initialize a new HTTP client (pure Zig — no libc)
    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator, .{});
        const io_handle = io_threaded.io();

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .client = http.Client{
                .allocator = allocator,
                .io = io_handle,
            },
        };
    }

    /// Get the Io handle for timing, sleep, random, etc.
    pub fn io(self: *HttpClient) std.Io {
        return self.io_threaded.io();
    }

    /// Clean up client resources
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Process response body with gzip decompression if needed
    fn processBody(self: *HttpClient, body_data: []const u8, content_encoding: ?[]const u8, max_decompressed_size: usize) ![]u8 {
        if (content_encoding) |encoding| {
            if (std.mem.eql(u8, encoding, "gzip")) {
                const flate = std.compress.flate;
                var input: std.Io.Reader = .fixed(body_data);
                var decomp_buffer: [flate.max_window_len]u8 = undefined;
                var decomp = flate.Decompress.init(&input, .gzip, &decomp_buffer);

                // Bounded decompression — defense against ZIP bombs
                const decompressed = decomp.reader.allocRemaining(
                    self.allocator,
                    std.Io.Limit.limited(max_decompressed_size),
                ) catch {
                    // If decompression fails or exceeds limit, return original data
                    return try self.allocator.dupe(u8, body_data);
                };
                return decompressed;
            }
        }
        return try self.allocator.dupe(u8, body_data);
    }

    /// Response structure containing status code and body
    pub const Response = struct {
        status: http.Status,
        body: []u8,
        allocator: std.mem.Allocator,

        /// Free the response body memory
        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    /// Response with an extracted custom header value
    pub const ResponseWithHeader = struct {
        status: http.Status,
        body: []u8,
        header_value: ?[]u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ResponseWithHeader) void {
            self.allocator.free(self.body);
            if (self.header_value) |v| self.allocator.free(v);
        }
    };

    /// Configuration options for requests
    pub const RequestOptions = struct {
        /// Maximum response body size (default: 10MB)
        max_body_size: usize = 10 * 1024 * 1024,
        /// Request timeout in nanoseconds (0 = no timeout)
        timeout_ns: u64 = 0,
    };

    /// A single Server-Sent Event parsed from an SSE stream
    pub const SseEvent = struct {
        /// The event data (JSON payload without "data: " prefix)
        data: []const u8,
        /// True when the stream has ended (data is "[DONE]")
        done: bool,
    };

    /// Streaming response — wraps the HTTP connection for line-by-line SSE reading.
    /// Heap-allocated to ensure stable pointers for the reader's internal buffers.
    pub const StreamingResponse = struct {
        status: http.Status,
        reader: *std.Io.Reader,
        request: http.Client.Request,
        transfer_buffer: [8192]u8,
        allocator: std.mem.Allocator,
        done: bool = false,

        /// Maximum non-data lines to skip before giving up.
        /// Prevents CPU spin on malformed streams.
        const MAX_SKIP_LINES: u32 = 500;

        /// Read the next SSE event from the stream.
        /// Returns null at end-of-stream, after [DONE], or on read error/timeout.
        /// Returned SseEvent.data is a borrowed slice valid until the next call.
        pub fn next(self: *StreamingResponse) ?SseEvent {
            if (self.done) return null;

            var skip_count: u32 = 0;
            while (skip_count < MAX_SKIP_LINES) {
                const line = self.reader.takeDelimiterExclusive('\n') catch {
                    // Read error, EOF, or timeout — stream is over
                    self.done = true;
                    return null;
                };

                // Skip empty lines (SSE event separator) and carriage returns
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (trimmed.len == 0) {
                    skip_count += 1;
                    continue;
                }

                // SSE data line: "data: <payload>" or "data:<payload>"
                if (std.mem.startsWith(u8, trimmed, "data:")) {
                    var payload = trimmed["data:".len..];
                    if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];

                    if (std.mem.eql(u8, payload, "[DONE]")) {
                        self.done = true;
                        return SseEvent{ .data = payload, .done = true };
                    }

                    return SseEvent{ .data = payload, .done = false };
                }

                // Non-data SSE field (event:, id:, retry:, comment) — skip
                skip_count += 1;
            }

            // Too many non-data lines — malformed stream, bail out
            self.done = true;
            return null;
        }

        /// Clean up the streaming response
        pub fn deinit(self: *StreamingResponse) void {
            self.request.deinit();
            self.allocator.destroy(self);
        }
    };

    /// Perform a POST request and return a streaming SSE reader.
    /// Use `response.next()` to read events one at a time.
    /// Caller MUST call `response.deinit()` when done.
    ///
    /// Example:
    ///   var stream = try client.postStreaming(url, &headers, body);
    ///   defer stream.deinit();
    ///   while (stream.next()) |event| {
    ///       if (event.done) break;
    ///       // Parse event.data as JSON...
    ///   }
    pub fn postStreaming(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !*StreamingResponse {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        // Heap-allocate so the response struct (and its transfer_buffer) has a stable address
        const stream = try self.allocator.create(StreamingResponse);
        errdefer self.allocator.destroy(stream);

        stream.allocator = self.allocator;
        stream.transfer_buffer = undefined;

        stream.request = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
        });

        stream.request.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try stream.request.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try stream.request.connection.?.flush();

        var response = try stream.request.receiveHead(&.{});
        stream.status = response.head.status;

        // If server returned an error status, don't try to parse SSE
        const status_code = @intFromEnum(response.head.status);
        if (status_code >= 400) {
            stream.reader = response.reader(&stream.transfer_buffer);
            stream.done = true; // Mark as done so next() returns null immediately
            return stream;
        }

        stream.reader = response.reader(&stream.transfer_buffer);
        return stream;
    }

    /// Perform a POST request
    pub fn post(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.postWithOptions(url, headers, body, .{});
    }

    /// Perform a POST request with custom options
    pub fn postWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
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
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null, // We only support gzip for now
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// POST that extracts a specific response header by name (case-insensitive)
    pub fn postExtractHeader(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        extract_header: []const u8,
    ) !ResponseWithHeader {
        try validateHeaders(headers);
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

        // Extract the requested header from raw response headers
        var extracted: ?[]u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, extract_header)) {
                extracted = try self.allocator.dupe(u8, header.value);
                break;
            }
        }

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, 10 * 1024 * 1024);

        return ResponseWithHeader{
            .status = response.head.status,
            .body = final_body,
            .header_value = extracted,
            .allocator = self.allocator,
        };
    }

    /// Perform a GET request
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        return self.getWithOptions(url, headers, .{});
    }

    /// Perform a GET request with custom options
    pub fn getWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a GET request that strictly refuses to follow HTTP redirects.
    /// Use this for security-sensitive requests where headers (e.g., auth tokens,
    /// metadata-flavor markers) must NOT be forwarded to a redirect target.
    /// Returns the raw 3xx response if the server sends a redirect.
    pub fn getNoRedirect(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
            .redirect_behavior = .not_allowed,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(1024 * 1024),
        );
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, 1024 * 1024);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a PUT request
    pub fn put(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.putWithOptions(url, headers, body, .{});
    }

    /// Perform a PUT request with custom options
    pub fn putWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PUT, uri, .{
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
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a PATCH request
    pub fn patch(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        return self.patchWithOptions(url, headers, body, .{});
    }

    /// Perform a PATCH request with custom options
    pub fn patchWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PATCH, uri, .{
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
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a DELETE request
    pub fn delete(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        return self.deleteWithOptions(url, headers, .{});
    }

    /// Perform a DELETE request with custom options
    pub fn deleteWithOptions(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.DELETE, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

        // Decompress body if needed
        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{
            .status = response.head.status,
            .body = final_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a HEAD request (headers only, no body)
    pub fn head(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        const response = try req.receiveHead(&.{});

        return Response{
            .status = response.head.status,
            .body = try self.allocator.alloc(u8, 0),
            .allocator = self.allocator,
        };
    }

    /// Download large file with manual redirect handling
    /// This method handles very long redirect URLs that may overflow standard buffers
    pub fn downloadLargeFile(
        self: *HttpClient,
        initial_url: []const u8,
        headers: []const http.Header,
        options: RequestOptions,
    ) !Response {
        try validateHeaders(headers);
        var current_url = try self.allocator.dupe(u8, initial_url);
        defer self.allocator.free(current_url);

        var redirect_count: u8 = 0;
        const max_redirects: u8 = 10;

        while (redirect_count < max_redirects) {
            const uri = std.Uri.parse(current_url) catch {
                // If the URL is too complex for the parser, try simpler approach
                // Fall back to regular get which may fail on long redirects
                return self.getWithOptions(current_url, headers, options);
            };

            // Make request with redirect behavior disabled
            var req = self.client.request(.GET, uri, .{
                .extra_headers = headers,
                .redirect_behavior = .not_allowed,
            }) catch {
                // If request fails, try regular get
                return self.getWithOptions(current_url, headers, options);
            };
            defer req.deinit();

            req.sendBodiless() catch {
                return self.getWithOptions(current_url, headers, options);
            };

            var response = req.receiveHead(&.{}) catch {
                return self.getWithOptions(current_url, headers, options);
            };

            // Check if redirect
            const status_code = @intFromEnum(response.head.status);
            if (status_code >= 300 and status_code < 400) {
                // Get Location header from response head
                if (response.head.location) |loc| {
                    // Free old URL and follow redirect
                    self.allocator.free(current_url);
                    current_url = try self.allocator.dupe(u8, loc);

                    // SSRF defense: block redirects to private/internal addresses
                    if (isPrivateRedirect(current_url)) {
                        return error.SsrfBlocked;
                    }

                    redirect_count += 1;
                    continue;
                }
            }

            // Not a redirect or no Location header - read body
            var transfer_buffer: [8192]u8 = undefined;
            const response_reader = response.reader(&transfer_buffer);

            const body_data = try response_reader.allocRemaining(
                self.allocator,
                std.Io.Limit.limited(options.max_body_size),
            );
            defer self.allocator.free(body_data);

            // Decompress body if needed
            const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
                .gzip => "gzip",
                .identity => null,
                else => null,
            };
            const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

            return Response{
                .status = response.head.status,
                .body = final_body,
                .allocator = self.allocator,
            };
        }

        return error.TooManyRedirects;
    }
};
