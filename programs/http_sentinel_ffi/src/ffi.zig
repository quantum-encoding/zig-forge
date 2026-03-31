const std = @import("std");
const http = std.http;
const c = std.c;

// =============================================================================
// HTTP Sentinel FFI - C-Compatible HTTP Client Interface
// =============================================================================
//
// This provides a simple, blocking HTTP client interface for FFI integration
// with Rust, C, and other languages. Each call is independent and thread-safe.
//
// Design principles:
// - Caller provides all buffers (no internal allocation visible to caller)
// - Response body is copied to caller-provided buffer
// - Simple error codes for cross-language compatibility
// - Thread-safe (each call creates its own client)
//
// =============================================================================

// =============================================================================
// Error Codes
// =============================================================================

pub const HttpSentinelError = enum(c_int) {
    success = 0,
    invalid_url = -1,
    connection_failed = -2,
    request_failed = -3,
    response_too_large = -4,
    invalid_input = -5,
    timeout = -6,
    tls_error = -7,
    internal_error = -8,
    buffer_too_small = -9,
};

// =============================================================================
// Thread-Local Error Storage
// =============================================================================

threadlocal var last_error_msg: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_msg.len - 1);
    @memcpy(last_error_msg[0..copy_len], msg[0..copy_len]);
    last_error_msg[copy_len] = 0;
    last_error_len = copy_len;
}

/// Get the last error message for this thread
export fn http_sentinel_get_error(buf: [*c]u8, buf_size: usize) usize {
    if (buf_size == 0) return last_error_len;
    const copy_len = @min(last_error_len, buf_size - 1);
    @memcpy(buf[0..copy_len], last_error_msg[0..copy_len]);
    buf[copy_len] = 0;
    return copy_len;
}

// =============================================================================
// Response Structure (passed by caller)
// =============================================================================

/// HTTP response structure - caller must provide buffer for body
pub const HttpResponse = extern struct {
    /// HTTP status code (200, 404, 500, etc.)
    status_code: u16,
    /// Actual length of response body copied to buffer
    body_len: usize,
    /// Set to true if body was truncated due to buffer size
    truncated: bool,
};

// =============================================================================
// Header Structure for requests
// =============================================================================

/// HTTP header key-value pair
pub const HttpHeader = extern struct {
    name: [*c]const u8,
    name_len: usize,
    value: [*c]const u8,
    value_len: usize,
};

// =============================================================================
// Core HTTP Functions
// =============================================================================

/// Perform a GET request
///
/// Parameters:
/// - url: Null-terminated URL string
/// - headers: Array of headers (can be null if header_count is 0)
/// - header_count: Number of headers
/// - response_body: Buffer to store response body
/// - response_body_size: Size of response_body buffer
/// - response: Output structure with status code and body length
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn http_sentinel_get(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    return performRequest(.GET, url, headers, header_count, null, 0, response_body, response_body_size, response);
}

/// Perform a POST request
///
/// Parameters:
/// - url: Null-terminated URL string
/// - headers: Array of headers (can be null if header_count is 0)
/// - header_count: Number of headers
/// - request_body: Body data to send
/// - request_body_len: Length of request body
/// - response_body: Buffer to store response body
/// - response_body_size: Size of response_body buffer
/// - response: Output structure with status code and body length
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn http_sentinel_post(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    request_body: [*c]const u8,
    request_body_len: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    return performRequest(.POST, url, headers, header_count, request_body, request_body_len, response_body, response_body_size, response);
}

/// Perform a PUT request
export fn http_sentinel_put(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    request_body: [*c]const u8,
    request_body_len: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    return performRequest(.PUT, url, headers, header_count, request_body, request_body_len, response_body, response_body_size, response);
}

/// Perform a PATCH request
export fn http_sentinel_patch(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    request_body: [*c]const u8,
    request_body_len: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    return performRequest(.PATCH, url, headers, header_count, request_body, request_body_len, response_body, response_body_size, response);
}

/// Perform a DELETE request
export fn http_sentinel_delete(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    return performRequest(.DELETE, url, headers, header_count, null, 0, response_body, response_body_size, response);
}

/// Perform a HEAD request (no body returned)
export fn http_sentinel_head(
    url: [*c]const u8,
    headers: [*c]const HttpHeader,
    header_count: usize,
    response: *HttpResponse,
) c_int {
    // HEAD doesn't need a response body buffer
    var dummy: [1]u8 = undefined;
    return performRequest(.HEAD, url, headers, header_count, null, 0, &dummy, 0, response);
}

// =============================================================================
// Internal Implementation
// =============================================================================

fn performRequest(
    method: http.Method,
    url_ptr: [*c]const u8,
    headers_ptr: [*c]const HttpHeader,
    header_count: usize,
    body_ptr: ?[*c]const u8,
    body_len: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,
) c_int {
    // Validate inputs
    if (@intFromPtr(url_ptr) == 0) {
        setLastError("URL pointer is null");
        return @intFromEnum(HttpSentinelError.invalid_input);
    }
    if (@intFromPtr(response) == 0) {
        setLastError("Response pointer is null");
        return @intFromEnum(HttpSentinelError.invalid_input);
    }

    // Initialize response
    response.status_code = 0;
    response.body_len = 0;
    response.truncated = false;

    // Get URL as slice (find null terminator)
    var url_len: usize = 0;
    while (url_ptr[url_len] != 0) : (url_len += 1) {
        if (url_len > 8192) {
            setLastError("URL too long");
            return @intFromEnum(HttpSentinelError.invalid_url);
        }
    }
    const url = url_ptr[0..url_len];

    // Use general purpose allocator for HTTP client
    const allocator = std.heap.c_allocator;

    // Create IO subsystem
    const io_threaded = allocator.create(std.Io.Threaded) catch {
        setLastError("Failed to allocate IO system");
        return @intFromEnum(HttpSentinelError.internal_error);
    };
    defer allocator.destroy(io_threaded);

    io_threaded.* = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(c.environ)) } },
    });
    defer io_threaded.deinit();

    const io = io_threaded.io();

    // Create HTTP client
    var client = http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // Parse URL
    const uri = std.Uri.parse(url) catch {
        setLastError("Invalid URL format");
        return @intFromEnum(HttpSentinelError.invalid_url);
    };

    // Build headers array
    var extra_headers: []http.Header = &.{};
    var headers_buf: [64]http.Header = undefined;

    if (header_count > 0 and @intFromPtr(headers_ptr) != 0) {
        const count = @min(header_count, headers_buf.len);
        for (0..count) |i| {
            const h = headers_ptr[i];
            if (@intFromPtr(h.name) != 0 and @intFromPtr(h.value) != 0) {
                headers_buf[i] = .{
                    .name = h.name[0..h.name_len],
                    .value = h.value[0..h.value_len],
                };
            }
        }
        extra_headers = headers_buf[0..count];
    }

    // Make request
    var req = client.request(method, uri, .{
        .extra_headers = extra_headers,
    }) catch |err| {
        setLastError(errorToString(err));
        return @intFromEnum(HttpSentinelError.connection_failed);
    };
    defer req.deinit();

    // Send body if present
    if (body_ptr != null and body_len > 0) {
        req.transfer_encoding = .{ .content_length = body_len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            setLastError(errorToString(err));
            return @intFromEnum(HttpSentinelError.request_failed);
        };
        body_writer.writer.writeAll(body_ptr.?[0..body_len]) catch |err| {
            setLastError(errorToString(err));
            return @intFromEnum(HttpSentinelError.request_failed);
        };
        body_writer.end() catch |err| {
            setLastError(errorToString(err));
            return @intFromEnum(HttpSentinelError.request_failed);
        };
        if (req.connection) |conn| {
            conn.flush() catch |err| {
                setLastError(errorToString(err));
                return @intFromEnum(HttpSentinelError.request_failed);
            };
        }
    } else {
        req.sendBodiless() catch |err| {
            setLastError(errorToString(err));
            return @intFromEnum(HttpSentinelError.request_failed);
        };
    }

    // Receive response
    var http_response = req.receiveHead(&.{}) catch |err| {
        setLastError(errorToString(err));
        return @intFromEnum(HttpSentinelError.request_failed);
    };

    response.status_code = @intFromEnum(http_response.head.status);

    // Read response body (if not HEAD request and buffer provided)
    if (method != .HEAD and response_body_size > 0 and @intFromPtr(response_body) != 0) {
        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = http_response.reader(&transfer_buffer);

        // Read into caller's buffer
        const max_read = response_body_size;
        const body_data = response_reader.allocRemaining(
            allocator,
            std.Io.Limit.limited(max_read + 1), // Read one extra to detect truncation
        ) catch |err| {
            setLastError(errorToString(err));
            return @intFromEnum(HttpSentinelError.request_failed);
        };
        defer allocator.free(body_data);

        // Handle gzip decompression if needed
        var final_body: []const u8 = body_data;
        var decompressed: ?[]u8 = null;
        defer if (decompressed) |d| allocator.free(d);

        if (http_response.head.content_encoding == .gzip) {
            var in: std.Io.Reader = .fixed(body_data);
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();

            var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            _ = decompress.reader.streamRemaining(&aw.writer) catch {
                // If decompression fails, use raw body
                final_body = body_data;
            };

            if (aw.written().len > 0) {
                decompressed = allocator.dupe(u8, aw.written()) catch null;
                if (decompressed) |d| {
                    final_body = d;
                }
            }
        }

        // Copy to caller's buffer
        const copy_len = @min(final_body.len, response_body_size);
        @memcpy(response_body[0..copy_len], final_body[0..copy_len]);
        response.body_len = copy_len;
        response.truncated = final_body.len > response_body_size;
    }

    return @intFromEnum(HttpSentinelError.success);
}

fn errorToString(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Connection refused",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.NetworkUnreachable => "Network unreachable",
        error.HostUnreachable => "Host unreachable",
        error.UnexpectedEof => "Unexpected end of stream",
        error.OutOfMemory => "Out of memory",
        else => "HTTP request failed",
    };
}

// =============================================================================
// Version Information
// =============================================================================

/// Get library version string
export fn http_sentinel_version() [*:0]const u8 {
    return "http-sentinel-ffi-1.0.0";
}

/// Get Zig stdlib version
export fn http_sentinel_zig_version() [*:0]const u8 {
    return "zig-0.16.0-dev.1484";
}

// =============================================================================
// Tests
// =============================================================================

test "GET request to httpbin" {
    var response_body: [4096]u8 = undefined;
    var response: HttpResponse = undefined;

    const result = http_sentinel_get(
        "https://httpbin.org/get",
        null,
        0,
        &response_body,
        response_body.len,
        &response,
    );

    // Note: This test requires network access
    if (result == 0) {
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expect(response.body_len > 0);
    }
}

test "POST request with body" {
    var response_body: [4096]u8 = undefined;
    var response: HttpResponse = undefined;

    const body = "{\"test\": \"data\"}";
    const headers = [_]HttpHeader{
        .{
            .name = "Content-Type",
            .name_len = 12,
            .value = "application/json",
            .value_len = 16,
        },
    };

    const result = http_sentinel_post(
        "https://httpbin.org/post",
        &headers,
        1,
        body.ptr,
        body.len,
        &response_body,
        response_body.len,
        &response,
    );

    if (result == 0) {
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expect(response.body_len > 0);
    }
}

test "version strings" {
    const version = http_sentinel_version();
    try std.testing.expect(version[0] != 0);
}
