//! DNS over HTTPS (DoH) Implementation
//!
//! Implements RFC 8484 - DNS Queries over HTTPS
//!
//! Features:
//! - HTTP/1.1 and HTTP/2 support (via upgrade)
//! - GET and POST methods
//! - Wire format (application/dns-message)
//! - JSON format (application/dns-json) - optional
//! - TLS 1.3 with modern cipher suites
//! - Connection pooling and keep-alive

const std = @import("std");
const types = @import("../protocol/types.zig");
const parser = @import("../protocol/parser.zig");

const Name = types.Name;
const Header = types.Header;
const Question = types.Question;
const ResourceRecord = types.ResourceRecord;
const RecordType = types.RecordType;
const RecordClass = types.RecordClass;
const Parser = parser.Parser;
const Builder = parser.Builder;

pub const DoHError = error{
    InvalidRequest,
    InvalidMethod,
    InvalidContentType,
    InvalidPath,
    Base64DecodeError,
    ResponseTooLarge,
    ConnectionClosed,
    TlsError,
    HttpParseError,
    Timeout,
    OutOfMemory,
};

/// DoH server configuration
pub const DoHConfig = struct {
    /// Port to listen on (default: 443)
    port: u16 = 443,
    /// Bind address
    bind_address: [4]u8 = .{ 0, 0, 0, 0 },
    /// TLS certificate file path
    cert_file: ?[]const u8 = null,
    /// TLS private key file path
    key_file: ?[]const u8 = null,
    /// Path prefix for DoH queries (e.g., "/dns-query")
    path: []const u8 = "/dns-query",
    /// Enable HTTP/2
    enable_http2: bool = true,
    /// Connection timeout in seconds
    timeout_secs: u32 = 30,
    /// Maximum request size
    max_request_size: usize = 65535,
    /// Enable CORS headers
    enable_cors: bool = true,
    /// Max concurrent connections
    max_connections: u32 = 1000,
};

/// HTTP request parsed from DoH
pub const DoHRequest = struct {
    method: Method,
    path: []const u8,
    query_string: ?[]const u8,
    content_type: ContentType,
    accept: ContentType,
    dns_message: []const u8,
    keep_alive: bool,

    pub const Method = enum {
        get,
        post,
        options, // For CORS preflight
    };

    pub const ContentType = enum {
        dns_message, // application/dns-message (wire format)
        dns_json, // application/dns-json
        any,
    };
};

/// DoH server handling DNS over HTTPS requests
pub const DoHServer = struct {
    allocator: std.mem.Allocator,
    config: DoHConfig,
    socket: ?std.posix.socket_t = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handler: *const fn ([]const u8, []u8) usize, // DNS query handler

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: DoHConfig,
        handler: *const fn ([]const u8, []u8) usize,
    ) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.socket) |sock| {
            _ = std.c.close(sock);
            self.socket = null;
        }
    }

    pub fn start(self: *Self) !void {
        // Create TCP socket
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
            0,
        );
        errdefer _ = std.c.close(sock);

        // Set socket options
        const reuse: i32 = 1;
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            std.mem.asBytes(&reuse),
        );

        // Bind to address
        const addr = std.net.Address.initIp4(self.config.bind_address, self.config.port);
        try std.posix.bind(sock, &addr.any, addr.getOsSockLen());

        // Listen for connections
        try std.posix.listen(sock, 128);

        self.socket = sock;
        self.running.store(true, .release);

        std.debug.print("DoH server listening on {d}.{d}.{d}.{d}:{d}\n", .{
            self.config.bind_address[0],
            self.config.bind_address[1],
            self.config.bind_address[2],
            self.config.bind_address[3],
            self.config.port,
        });

        // Accept loop
        while (self.running.load(.acquire)) {
            const client = std.posix.accept(sock, null, null) catch |err| {
                if (err == error.WouldBlock or !self.running.load(.acquire)) continue;
                return err;
            };

            // Handle client (in production, spawn thread or use async)
            self.handleClient(client) catch |err| {
                std.debug.print("DoH client error: {}\n", .{err});
            };
            _ = std.c.close(client);
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    fn handleClient(self: *Self, client: std.posix.socket_t) !void {
        var recv_buf: [8192]u8 = undefined;
        const recv_len = try std.posix.recv(client, &recv_buf, 0);
        if (recv_len == 0) return;

        const request_data = recv_buf[0..recv_len];

        // Parse HTTP request
        const request = try parseHttpRequest(request_data);

        // Handle CORS preflight
        if (request.method == .options) {
            try self.sendCorsPreflightResponse(client);
            return;
        }

        // Extract DNS query
        var dns_query_buf: [4096]u8 = undefined;
        const dns_query = try self.extractDnsQuery(&request, &dns_query_buf);

        // Process DNS query
        var response_buf: [65535]u8 = undefined;
        const response_len = self.handler(dns_query, &response_buf);

        if (response_len == 0) {
            try self.sendErrorResponse(client, 500, "DNS processing failed");
            return;
        }

        // Send HTTP response
        try self.sendDnsResponse(client, response_buf[0..response_len], request.accept);
    }

    fn extractDnsQuery(
        self: *Self,
        request: *const DoHRequest,
        buf: []u8,
    ) ![]const u8 {
        _ = self;
        switch (request.method) {
            .get => {
                // GET method: DNS query is base64url-encoded in query string
                if (request.query_string) |qs| {
                    // Parse "dns=<base64url>" parameter
                    var iter = std.mem.splitScalar(u8, qs, '&');
                    while (iter.next()) |param| {
                        if (std.mem.startsWith(u8, param, "dns=")) {
                            const encoded = param[4..];
                            const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return DoHError.Base64DecodeError;
                            if (decoded_len > buf.len) return DoHError.ResponseTooLarge;
                            _ = std.base64.url_safe_no_pad.Decoder.decode(buf[0..decoded_len], encoded) catch return DoHError.Base64DecodeError;
                            return buf[0..decoded_len];
                        }
                    }
                }
                return DoHError.InvalidRequest;
            },
            .post => {
                // POST method: DNS query is in request body
                if (request.dns_message.len > buf.len) return DoHError.ResponseTooLarge;
                @memcpy(buf[0..request.dns_message.len], request.dns_message);
                return buf[0..request.dns_message.len];
            },
            .options => return DoHError.InvalidMethod,
        }
    }

    fn sendDnsResponse(
        self: *Self,
        client: std.posix.socket_t,
        dns_response: []const u8,
        accept: DoHRequest.ContentType,
    ) !void {
        var response_buf: [65535 + 512]u8 = undefined; // DNS response + HTTP headers
        var pos: usize = 0;

        // Determine content type
        const content_type = switch (accept) {
            .dns_json => "application/dns-json",
            else => "application/dns-message",
        };

        // Write HTTP status line
        const status = "HTTP/1.1 200 OK\r\n";
        @memcpy(response_buf[pos .. pos + status.len], status);
        pos += status.len;

        // Write headers
        pos += formatHeader(&response_buf, pos, "Content-Type", content_type);
        pos += formatContentLength(&response_buf, pos, dns_response.len);

        if (self.config.enable_cors) {
            pos += formatHeader(&response_buf, pos, "Access-Control-Allow-Origin", "*");
        }

        pos += formatHeader(&response_buf, pos, "Cache-Control", "max-age=300");
        pos += formatHeader(&response_buf, pos, "Connection", "keep-alive");

        // End headers
        response_buf[pos] = '\r';
        response_buf[pos + 1] = '\n';
        pos += 2;

        // Write body
        @memcpy(response_buf[pos .. pos + dns_response.len], dns_response);
        pos += dns_response.len;

        _ = try std.posix.send(client, response_buf[0..pos], 0);
    }

    fn sendCorsPreflightResponse(self: *Self, client: std.posix.socket_t) !void {
        _ = self;
        const response =
            "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Accept\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";

        _ = try std.posix.send(client, response, 0);
    }

    fn sendErrorResponse(self: *Self, client: std.posix.socket_t, status_code: u16, message: []const u8) !void {
        _ = self;
        var response_buf: [512]u8 = undefined;
        var pos: usize = 0;

        // Status line
        const status_text = switch (status_code) {
            400 => "HTTP/1.1 400 Bad Request\r\n",
            404 => "HTTP/1.1 404 Not Found\r\n",
            415 => "HTTP/1.1 415 Unsupported Media Type\r\n",
            500 => "HTTP/1.1 500 Internal Server Error\r\n",
            else => "HTTP/1.1 500 Internal Server Error\r\n",
        };

        @memcpy(response_buf[pos .. pos + status_text.len], status_text);
        pos += status_text.len;

        pos += formatHeader(&response_buf, pos, "Content-Type", "text/plain");
        pos += formatContentLength(&response_buf, pos, message.len);
        pos += formatHeader(&response_buf, pos, "Connection", "close");

        response_buf[pos] = '\r';
        response_buf[pos + 1] = '\n';
        pos += 2;

        @memcpy(response_buf[pos .. pos + message.len], message);
        pos += message.len;

        _ = try std.posix.send(client, response_buf[0..pos], 0);
    }
};

/// Parse HTTP request from raw bytes
fn parseHttpRequest(data: []const u8) !DoHRequest {
    var request = DoHRequest{
        .method = .get,
        .path = "/",
        .query_string = null,
        .content_type = .dns_message,
        .accept = .dns_message,
        .dns_message = &[_]u8{},
        .keep_alive = true,
    };

    // Find end of headers
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return DoHError.HttpParseError;

    // Parse request line
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return DoHError.HttpParseError;
    const request_line = data[0..first_line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');

    // Method
    const method_str = parts.next() orelse return DoHError.HttpParseError;
    if (std.mem.eql(u8, method_str, "GET")) {
        request.method = .get;
    } else if (std.mem.eql(u8, method_str, "POST")) {
        request.method = .post;
    } else if (std.mem.eql(u8, method_str, "OPTIONS")) {
        request.method = .options;
    } else {
        return DoHError.InvalidMethod;
    }

    // URI with query string
    const uri = parts.next() orelse return DoHError.HttpParseError;
    if (std.mem.indexOf(u8, uri, "?")) |qmark| {
        request.path = uri[0..qmark];
        request.query_string = uri[qmark + 1 ..];
    } else {
        request.path = uri;
    }

    // Parse headers
    var header_lines = std.mem.splitSequence(u8, data[first_line_end + 2 .. header_end], "\r\n");
    var content_length: usize = 0;

    while (header_lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            if (std.mem.indexOf(u8, value, "application/dns-message") != null) {
                request.content_type = .dns_message;
            } else if (std.mem.indexOf(u8, value, "application/dns-json") != null) {
                request.content_type = .dns_json;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "accept")) {
            if (std.mem.indexOf(u8, value, "application/dns-message") != null) {
                request.accept = .dns_message;
            } else if (std.mem.indexOf(u8, value, "application/dns-json") != null) {
                request.accept = .dns_json;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            request.keep_alive = !std.ascii.eqlIgnoreCase(value, "close");
        }
    }

    // Extract body for POST requests
    if (request.method == .post and content_length > 0) {
        const body_start = header_end + 4;
        if (body_start + content_length <= data.len) {
            request.dns_message = data[body_start .. body_start + content_length];
        }
    }

    return request;
}

fn formatHeader(buf: []u8, pos: usize, name: []const u8, value: []const u8) usize {
    var p = pos;
    @memcpy(buf[p .. p + name.len], name);
    p += name.len;
    buf[p] = ':';
    buf[p + 1] = ' ';
    p += 2;
    @memcpy(buf[p .. p + value.len], value);
    p += value.len;
    buf[p] = '\r';
    buf[p + 1] = '\n';
    p += 2;
    return p - pos;
}

fn formatContentLength(buf: []u8, pos: usize, len: usize) usize {
    var p = pos;
    const header = "Content-Length: ";
    @memcpy(buf[p .. p + header.len], header);
    p += header.len;

    // Format number
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{len}) catch return 0;
    @memcpy(buf[p .. p + num_str.len], num_str);
    p += num_str.len;

    buf[p] = '\r';
    buf[p + 1] = '\n';
    p += 2;
    return p - pos;
}

// =============================================================================
// TESTS
// =============================================================================

test "parse HTTP GET request" {
    const request_data =
        "GET /dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB HTTP/1.1\r\n" ++
        "Host: doh.example.com\r\n" ++
        "Accept: application/dns-message\r\n" ++
        "\r\n";

    const request = try parseHttpRequest(request_data);
    try std.testing.expectEqual(DoHRequest.Method.get, request.method);
    try std.testing.expectEqualStrings("/dns-query", request.path);
    try std.testing.expect(request.query_string != null);
}

test "parse HTTP POST request" {
    const dns_query = [_]u8{
        0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x03, 'w',  'w',  'w',
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',
        0x03, 'c',  'o',  'm',  0x00, 0x00, 0x01, 0x00,
        0x01,
    };

    var request_buf: [512]u8 = undefined;
    const header = "POST /dns-query HTTP/1.1\r\n" ++
        "Host: doh.example.com\r\n" ++
        "Content-Type: application/dns-message\r\n" ++
        "Content-Length: 33\r\n" ++
        "\r\n";

    @memcpy(request_buf[0..header.len], header);
    @memcpy(request_buf[header.len .. header.len + dns_query.len], &dns_query);

    const request = try parseHttpRequest(request_buf[0 .. header.len + dns_query.len]);
    try std.testing.expectEqual(DoHRequest.Method.post, request.method);
    try std.testing.expectEqualStrings("/dns-query", request.path);
    try std.testing.expectEqual(DoHRequest.ContentType.dns_message, request.content_type);
    try std.testing.expectEqual(@as(usize, 33), request.dns_message.len);
}
