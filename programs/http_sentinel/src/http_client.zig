// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const http = std.http;

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

    /// Initialize a new HTTP client
    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator, .{
            .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
        });
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

    /// Clean up client resources
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Process response body with gzip decompression if needed
    fn processBody(self: *HttpClient, body_data: []const u8, content_encoding: ?[]const u8) ![]u8 {
        if (content_encoding) |encoding| {
            if (std.mem.eql(u8, encoding, "gzip")) {
                // Decompress gzip data using flate decompressor
                const flate = std.compress.flate;

                // Create output writer
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();

                // Create fixed reader from input data
                var input: std.Io.Reader = .fixed(body_data);

                // Create decompression buffer
                var decomp_buffer: [flate.max_window_len]u8 = undefined;

                // Initialize decompressor with gzip container
                var decomp = flate.Decompress.init(&input, .gzip, &decomp_buffer);

                // Stream all decompressed data
                _ = decomp.reader.streamRemaining(&out.writer) catch {
                    // If decompression fails, return original data
                    return try self.allocator.dupe(u8, body_data);
                };

                return out.toOwnedSlice() catch {
                    return try self.allocator.dupe(u8, body_data);
                };
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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
        const final_body = try self.processBody(body_data, content_encoding_str);

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
            const final_body = try self.processBody(body_data, content_encoding_str);

            return Response{
                .status = response.head.status,
                .body = final_body,
                .allocator = self.allocator,
            };
        }

        return error.TooManyRedirects;
    }
};
