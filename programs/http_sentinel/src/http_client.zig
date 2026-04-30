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

    const host = switch (host_component) {
        .raw, .percent_encoded => |s| s,
    };

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

    const blocked_hosts = [_][]const u8{
        "localhost", "[::1]", "[::0]", "metadata.google.internal",
    };
    for (blocked_hosts) |blocked| {
        if (std.ascii.eqlIgnoreCase(host, blocked)) return true;
    }

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
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *std.Io.Threaded,
    client: http.Client,
    /// Captured response body when an SSE streaming request returned a 4xx/5xx
    /// status. Owned by `allocator` and freed by `deinit` (or on the next
    /// failed call). Lets callers surface the upstream error message to the
    /// user instead of an opaque ApiRequestFailed.
    last_sse_error_body: ?[]u8 = null,

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

    /// Stash a copy of `body` into `last_sse_error_body` so streaming AI
    /// clients can surface the upstream error reason. Best-effort: on OOM
    /// the field stays null. Always frees the previous capture.
    pub fn captureError(self: *HttpClient, body: []const u8) void {
        if (self.last_sse_error_body) |b| {
            self.allocator.free(b);
            self.last_sse_error_body = null;
        }
        self.last_sse_error_body = self.allocator.dupe(u8, body) catch null;
    }

    /// Clean up client resources
    pub fn deinit(self: *HttpClient) void {
        if (self.last_sse_error_body) |b| {
            self.allocator.free(b);
            self.last_sse_error_body = null;
        }
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Process response body with gzip decompression if needed
    fn processBody(self: *HttpClient, body_data: []const u8, content_encoding: ?[]const u8, max_decompressed_size: usize) ![]u8 {
        if (content_encoding) |encoding| {
            if (std.mem.eql(u8, encoding, "gzip")) {
                const flate = std.compress.flate;
                var input_reader: std.Io.Reader = .fixed(body_data);
                var decomp_buffer: [flate.max_window_len]u8 = undefined;
                var decomp = flate.Decompress.init(&input_reader, .gzip, &decomp_buffer);

                const decompressed = decomp.reader.allocRemaining(
                    self.allocator,
                    std.Io.Limit.limited(max_decompressed_size),
                ) catch {
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

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    /// Streaming response — body was piped directly to a caller-supplied Writer.
    /// No buffered body slice. Used by the *StreamToWriter methods for memory-bound
    /// workloads like the Universal Batch API where 50 MB+ bodies × 100 concurrent
    /// workers would OOM a Cloud Run container.
    pub const StreamedResponse = struct {
        status: http.Status,
        bytes_written: u64,
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
        max_body_size: usize = 64 * 1024 * 1024,
        timeout_ns: u64 = 0,
    };

    /// A single Server-Sent Event parsed from an SSE stream
    pub const SseEvent = struct {
        data: []const u8,
        done: bool,
    };

    /// Callback for streaming SSE events. Return true to continue, false to stop.
    pub const SseCallback = *const fn (event: SseEvent, ctx: ?*anyopaque) bool;

    /// Streaming response — reads full body then parses SSE events from it.
    /// Used by postStreaming (Phase 1 blocking approach).
    pub const StreamingResponse = struct {
        status: http.Status,
        allocator: std.mem.Allocator,
        body: []u8,
        pos: usize,

        /// Read the next SSE event.
        /// Returns null at end-of-stream or after [DONE].
        pub fn next(self: *StreamingResponse) ?SseEvent {
            while (self.pos < self.body.len) {
                const remaining = self.body[self.pos..];
                const nl_pos = std.mem.indexOfScalar(u8, remaining, '\n');
                const line = if (nl_pos) |pos| blk: {
                    self.pos += pos + 1;
                    break :blk remaining[0..pos];
                } else blk: {
                    self.pos = self.body.len;
                    break :blk remaining;
                };

                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (trimmed.len == 0) continue;

                if (std.mem.startsWith(u8, trimmed, "data:")) {
                    var payload = trimmed["data:".len..];
                    if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];

                    if (std.mem.eql(u8, payload, "[DONE]")) {
                        return SseEvent{ .data = payload, .done = true };
                    }

                    return SseEvent{ .data = payload, .done = false };
                }
            }
            return null;
        }

        pub fn deinit(self: *StreamingResponse) void {
            self.allocator.free(self.body);
            self.allocator.destroy(self);
        }
    };

    /// Perform a POST and return a buffered StreamingResponse (Phase 1: blocking).
    /// Reads full body via post(), then parses SSE events from buffer.
    pub fn postStreaming(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !*StreamingResponse {
        var http_response = try self.postWithOptions(url, headers, body, .{
            .max_body_size = 64 * 1024 * 1024,
        });

        const stream = try self.allocator.create(StreamingResponse);
        stream.* = .{
            .status = http_response.status,
            .allocator = self.allocator,
            .body = http_response.body,
            .pos = 0,
        };
        http_response.body = try self.allocator.alloc(u8, 0);
        http_response.deinit();

        return stream;
    }

    /// TRUE incremental SSE streaming — reads line-by-line from TLS connection.
    /// Request stays on the stack (no copy = no broken TLS pointers).
    /// Calls `callback` for each SSE data event as it arrives from the server.
    /// Returns the HTTP status code.
    pub fn postSseStream(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        callback: SseCallback,
        ctx: ?*anyopaque,
    ) !http.Status {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        // Request lives on THIS stack frame — TLS pointers stay valid
        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        // Null-safe flush — connection could be null if earlier steps partially failed
        if (req.connection) |conn| {
            try conn.flush();
        } else {
            return error.ConnectionLost;
        }

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        const is_gzip = response.head.content_encoding == .gzip;

        // Buffers stay on this stack frame for both reader paths.
        var transfer_buffer: [16384]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;

        // readerDecompressing asserts single-call, so we have to commit to
        // one reader path up front based on status.
        if (@intFromEnum(status) >= 400) {
            // Capture the error body so callers can surface the upstream
            // reason (e.g. "model not found", "invalid API key").
            if (self.last_sse_error_body) |b| {
                self.allocator.free(b);
                self.last_sse_error_body = null;
            }
            const err_reader = if (is_gzip)
                response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer)
            else
                response.reader(&transfer_buffer);
            var err_buf: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer err_buf.deinit();
            _ = err_reader.streamRemaining(&err_buf.writer) catch {};
            const owned = err_buf.toOwnedSlice() catch null;
            self.last_sse_error_body = owned;
            return status;
        }

        // Success path — readerDecompressing transparently handles gzip/deflate;
        // identity falls through.
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        // Read SSE events line-by-line using takeDelimiter
        // This blocks on the TLS connection waiting for each chunk — true streaming
        while (true) {
            const line = reader.takeDelimiter('\n') catch break;
            if (line == null) break; // EOF
            const raw_line = line.?;

            const trimmed = std.mem.trimEnd(u8, raw_line, "\r\n \t");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "data:")) {
                var payload = trimmed["data:".len..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                payload = std.mem.trimEnd(u8, payload, " \t");

                const done = std.mem.eql(u8, payload, "[DONE]");
                const event = SseEvent{ .data = payload, .done = done };

                if (!callback(event, ctx)) break;
                if (done) break;
            }
        }

        // Drain remaining bytes so the connection can be cleanly closed or reused.
        // SSE streams often have trailing chunk boundaries after [DONE].
        _ = reader.discardRemaining() catch {};

        return status;
    }

    /// Stream a request's response body directly to a caller-supplied Writer.
    /// Private helper — use post/get/put/patch/deleteStreamToWriter wrappers.
    ///
    /// The Request stays on THIS stack frame (same pattern as postSseStream) so
    /// the TLS connection's @fieldParentPtr chains remain valid during the stream.
    /// Gzip content-encoding is handled transparently via inline flate.Decompress.
    ///
    /// Caller owns the Writer and must flush it after this function returns.
    /// Returns status + bytes_written (no allocated body slice — zero buffering).
    fn streamToWriter(
        self: *HttpClient,
        method: http.Method,
        url: []const u8,
        headers: []const http.Header,
        body: ?[]const u8,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        _ = options; // reserved for future timeout wiring
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(method, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(b);
            try body_writer.end();
            if (req.connection) |conn| {
                try conn.flush();
            } else {
                return error.ConnectionLost;
            }
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});
        const status = response.head.status;

        // Even on HTTP error status we still drain the body to the writer so the
        // caller can inspect error payloads. quantum_curl treats status>=400 as
        // a failure separately.
        var transfer_buffer: [16384]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const is_gzip = switch (response.head.content_encoding) {
            .gzip => true,
            else => false,
        };

        var bytes: u64 = 0;
        if (is_gzip) {
            const flate = std.compress.flate;
            var decomp_buffer: [flate.max_window_len]u8 = undefined;
            var decomp = flate.Decompress.init(response_reader, .gzip, &decomp_buffer);
            bytes = @intCast(try decomp.reader.streamRemaining(dest));
        } else {
            bytes = @intCast(try response_reader.streamRemaining(dest));
        }

        return StreamedResponse{
            .status = status,
            .bytes_written = bytes,
        };
    }

    /// POST with response body streamed directly to `dest` — no intermediate buffering.
    pub fn postStreamToWriter(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        return self.streamToWriter(.POST, url, headers, body, dest, options);
    }

    /// GET with response body streamed directly to `dest` — no intermediate buffering.
    pub fn getStreamToWriter(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        return self.streamToWriter(.GET, url, headers, null, dest, options);
    }

    /// PUT with response body streamed directly to `dest` — no intermediate buffering.
    pub fn putStreamToWriter(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        return self.streamToWriter(.PUT, url, headers, body, dest, options);
    }

    /// PATCH with response body streamed directly to `dest` — no intermediate buffering.
    pub fn patchStreamToWriter(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        return self.streamToWriter(.PATCH, url, headers, body, dest, options);
    }

    /// DELETE with response body streamed directly to `dest` — no intermediate buffering.
    pub fn deleteStreamToWriter(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        dest: *std.Io.Writer,
        options: RequestOptions,
    ) !StreamedResponse {
        return self.streamToWriter(.DELETE, url, headers, null, dest, options);
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
        // Null-safe flush — connection could be null if earlier steps partially failed
        if (req.connection) |conn| {
            try conn.flush();
        } else {
            return error.ConnectionLost;
        }

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(options.max_body_size),
        );
        defer self.allocator.free(body_data);

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
        // Null-safe flush — connection could be null if earlier steps partially failed
        if (req.connection) |conn| {
            try conn.flush();
        } else {
            return error.ConnectionLost;
        }

        var response = try req.receiveHead(&.{});

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
            std.Io.Limit.limited(64 * 1024 * 1024),
        );
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip",
            .identity => null,
            else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, 64 * 1024 * 1024);

        return ResponseWithHeader{
            .status = response.head.status,
            .body = final_body,
            .header_value = extracted,
            .allocator = self.allocator,
        };
    }

    /// Perform a GET request
    pub fn get(self: *HttpClient, url: []const u8, headers: []const http.Header) !Response {
        return self.getWithOptions(url, headers, .{});
    }

    /// Perform a GET request with custom options
    pub fn getWithOptions(self: *HttpClient, url: []const u8, headers: []const http.Header, options: RequestOptions) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{ .extra_headers = headers });
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

    /// Perform a GET without following redirects (SSRF-safe for metadata endpoints)
    pub fn getNoRedirect(self: *HttpClient, url: []const u8, headers: []const http.Header) !Response {
        try validateHeaders(headers);
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

        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(64 * 1024 * 1024));
        defer self.allocator.free(body_data);

        return Response{
            .status = response.head.status,
            .body = try self.allocator.dupe(u8, body_data),
            .allocator = self.allocator,
        };
    }

    /// Perform a PUT request
    pub fn put(self: *HttpClient, url: []const u8, headers: []const http.Header, body: []const u8) !Response {
        return self.putWithOptions(url, headers, body, .{});
    }

    pub fn putWithOptions(self: *HttpClient, url: []const u8, headers: []const http.Header, body: []const u8, options: RequestOptions) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PUT, uri, .{ .extra_headers = headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        // Null-safe flush — connection could be null if earlier steps partially failed
        if (req.connection) |conn| {
            try conn.flush();
        } else {
            return error.ConnectionLost;
        }

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(options.max_body_size));
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip", .identity => null, else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{ .status = response.head.status, .body = final_body, .allocator = self.allocator };
    }

    /// Perform a PATCH request
    pub fn patch(self: *HttpClient, url: []const u8, headers: []const http.Header, body: []const u8) !Response {
        return self.patchWithOptions(url, headers, body, .{});
    }

    pub fn patchWithOptions(self: *HttpClient, url: []const u8, headers: []const http.Header, body: []const u8, options: RequestOptions) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PATCH, uri, .{ .extra_headers = headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        // Null-safe flush — connection could be null if earlier steps partially failed
        if (req.connection) |conn| {
            try conn.flush();
        } else {
            return error.ConnectionLost;
        }

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(options.max_body_size));
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip", .identity => null, else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{ .status = response.head.status, .body = final_body, .allocator = self.allocator };
    }

    /// Perform a DELETE request
    pub fn delete(self: *HttpClient, url: []const u8, headers: []const http.Header) !Response {
        return self.deleteWithOptions(url, headers, .{});
    }

    pub fn deleteWithOptions(self: *HttpClient, url: []const u8, headers: []const http.Header, options: RequestOptions) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.DELETE, uri, .{ .extra_headers = headers });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(options.max_body_size));
        defer self.allocator.free(body_data);

        const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
            .gzip => "gzip", .identity => null, else => null,
        };
        const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

        return Response{ .status = response.head.status, .body = final_body, .allocator = self.allocator };
    }

    /// Perform a HEAD request (headers only, no body)
    pub fn head(self: *HttpClient, url: []const u8, headers: []const http.Header) !Response {
        try validateHeaders(headers);
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{ .extra_headers = headers });
        defer req.deinit();

        try req.sendBodiless();
        _ = try req.receiveHead(&.{});

        return Response{
            .status = .ok,
            .body = try self.allocator.alloc(u8, 0),
            .allocator = self.allocator,
        };
    }

    /// Download large file with manual redirect handling
    pub fn downloadLargeFile(self: *HttpClient, initial_url: []const u8, headers: []const http.Header, options: RequestOptions) !Response {
        try validateHeaders(headers);

        var current_url = try self.allocator.dupe(u8, initial_url);
        defer self.allocator.free(current_url);

        var redirect_count: u8 = 0;
        const max_redirects: u8 = 10;

        while (redirect_count < max_redirects) {
            const uri = std.Uri.parse(current_url) catch {
                return self.getWithOptions(current_url, headers, options);
            };

            var req = self.client.request(.GET, uri, .{
                .extra_headers = headers,
                .redirect_behavior = .not_allowed,
            }) catch {
                return self.getWithOptions(current_url, headers, options);
            };
            defer req.deinit();

            req.sendBodiless() catch {
                return self.getWithOptions(current_url, headers, options);
            };

            var response = req.receiveHead(&.{}) catch {
                return self.getWithOptions(current_url, headers, options);
            };

            const status_code = @intFromEnum(response.head.status);
            if (status_code >= 300 and status_code < 400) {
                if (response.head.location) |loc| {
                    self.allocator.free(current_url);
                    current_url = try self.allocator.dupe(u8, loc);

                    if (isPrivateRedirect(current_url)) {
                        return error.SsrfBlocked;
                    }

                    redirect_count += 1;
                    continue;
                }
            }

            var transfer_buffer: [8192]u8 = undefined;
            const response_reader = response.reader(&transfer_buffer);

            const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(options.max_body_size));
            defer self.allocator.free(body_data);

            const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
                .gzip => "gzip", .identity => null, else => null,
            };
            const final_body = try self.processBody(body_data, content_encoding_str, options.max_body_size);

            return Response{ .status = response.head.status, .body = final_body, .allocator = self.allocator };
        }

        return error.TooManyRedirects;
    }
};
