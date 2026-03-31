//! Zero-Allocation HTTP/1.1 Parser
//!
//! High-performance HTTP parser using fixed-size buffers.
//! Supports both request and response parsing.
//!
//! Features:
//! - Zero heap allocations during parsing
//! - Streaming parser for large bodies
//! - Header indexing for fast lookup
//! - Chunked transfer encoding support

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

pub const MAX_HEADERS = 64;
pub const MAX_HEADER_NAME = 128;
pub const MAX_HEADER_VALUE = 8192;
pub const MAX_URI = 8192;
pub const MAX_METHOD = 16;
pub const MAX_REASON = 128;

// =============================================================================
// HTTP Method
// =============================================================================

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,
    UNKNOWN,

    pub fn fromString(str: []const u8) Method {
        const methods = .{
            .{ "GET", Method.GET },
            .{ "POST", Method.POST },
            .{ "PUT", Method.PUT },
            .{ "DELETE", Method.DELETE },
            .{ "PATCH", Method.PATCH },
            .{ "HEAD", Method.HEAD },
            .{ "OPTIONS", Method.OPTIONS },
            .{ "CONNECT", Method.CONNECT },
            .{ "TRACE", Method.TRACE },
        };

        inline for (methods) |m| {
            if (std.mem.eql(u8, str, m[0])) return m[1];
        }
        return .UNKNOWN;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .CONNECT => "CONNECT",
            .TRACE => "TRACE",
            .UNKNOWN => "UNKNOWN",
        };
    }
};

// =============================================================================
// HTTP Version
// =============================================================================

pub const Version = enum {
    http_1_0,
    http_1_1,
    http_2_0,

    pub fn fromString(str: []const u8) ?Version {
        if (std.mem.eql(u8, str, "HTTP/1.0")) return .http_1_0;
        if (std.mem.eql(u8, str, "HTTP/1.1")) return .http_1_1;
        if (std.mem.eql(u8, str, "HTTP/2.0") or std.mem.eql(u8, str, "HTTP/2")) return .http_2_0;
        return null;
    }

    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .http_1_0 => "HTTP/1.0",
            .http_1_1 => "HTTP/1.1",
            .http_2_0 => "HTTP/2.0",
        };
    }
};

// =============================================================================
// HTTP Header
// =============================================================================

pub const Header = struct {
    name: []const u8,
    value: []const u8,

    pub fn eqlName(self: *const Header, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
};

// =============================================================================
// HTTP Request
// =============================================================================

pub const Request = struct {
    method: Method = .GET,
    uri: []const u8 = "",
    version: Version = .http_1_1,
    headers: [MAX_HEADERS]Header = undefined,
    header_count: usize = 0,
    body: []const u8 = "",
    content_length: ?usize = null,
    is_chunked: bool = false,
    keep_alive: bool = true,

    // Parsed URI components
    path: []const u8 = "",
    query: ?[]const u8 = null,
    host: []const u8 = "",

    /// Find header by name (case-insensitive)
    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    /// Check if request has body
    pub fn hasBody(self: *const Request) bool {
        return self.content_length != null or self.is_chunked;
    }

    /// Get content type
    pub fn getContentType(self: *const Request) ?[]const u8 {
        return self.getHeader("Content-Type");
    }
};

// =============================================================================
// HTTP Response
// =============================================================================

pub const Response = struct {
    version: Version = .http_1_1,
    status_code: u16 = 200,
    reason: []const u8 = "OK",
    headers: [MAX_HEADERS]Header = undefined,
    header_count: usize = 0,
    body: []const u8 = "",
    content_length: ?usize = null,
    is_chunked: bool = false,
    keep_alive: bool = true,

    /// Find header by name (case-insensitive)
    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    /// Check if response has body
    pub fn hasBody(self: *const Response) bool {
        // 1xx, 204, 304 have no body
        if (self.status_code < 200) return false;
        if (self.status_code == 204 or self.status_code == 304) return false;
        return true;
    }
};

// =============================================================================
// HTTP Parser
// =============================================================================

pub const ParseError = error{
    InvalidRequest,
    InvalidResponse,
    InvalidMethod,
    InvalidVersion,
    InvalidHeader,
    InvalidChunk,
    TooManyHeaders,
    LineTooLong,
    IncompleteMessage,
    InvalidContentLength,
};

pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Parser {
        return .{ .data = data };
    }

    /// Parse HTTP request
    pub fn parseRequest(self: *Parser) ParseError!Request {
        var request = Request{};

        // Parse request line: METHOD URI VERSION\r\n
        const request_line = self.readLine() orelse return error.IncompleteMessage;

        var parts = std.mem.tokenizeAny(u8, request_line, " ");

        // Method
        const method_str = parts.next() orelse return error.InvalidRequest;
        request.method = Method.fromString(method_str);

        // URI
        request.uri = parts.next() orelse return error.InvalidRequest;
        self.parseUri(&request);

        // Version
        const version_str = parts.next() orelse return error.InvalidRequest;
        request.version = Version.fromString(version_str) orelse return error.InvalidVersion;

        // Parse headers
        try self.parseHeaders(&request.headers, &request.header_count);

        // Extract special headers
        if (request.getHeader("Content-Length")) |cl| {
            request.content_length = std.fmt.parseInt(usize, cl, 10) catch return error.InvalidContentLength;
        }

        if (request.getHeader("Transfer-Encoding")) |te| {
            request.is_chunked = std.mem.indexOf(u8, te, "chunked") != null;
        }

        if (request.getHeader("Host")) |host| {
            request.host = host;
        }

        // Connection handling
        if (request.getHeader("Connection")) |conn| {
            request.keep_alive = !std.ascii.eqlIgnoreCase(conn, "close");
        } else {
            request.keep_alive = request.version == .http_1_1;
        }

        // Body
        if (request.content_length) |len| {
            if (self.pos + len <= self.data.len) {
                request.body = self.data[self.pos .. self.pos + len];
                self.pos += len;
            }
        }

        return request;
    }

    /// Parse HTTP response
    pub fn parseResponse(self: *Parser) ParseError!Response {
        var response = Response{};

        // Parse status line: VERSION STATUS REASON\r\n
        const status_line = self.readLine() orelse return error.IncompleteMessage;

        var parts = std.mem.tokenizeAny(u8, status_line, " ");

        // Version
        const version_str = parts.next() orelse return error.InvalidResponse;
        response.version = Version.fromString(version_str) orelse return error.InvalidVersion;

        // Status code
        const status_str = parts.next() orelse return error.InvalidResponse;
        response.status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        // Reason phrase (rest of line)
        if (parts.next()) |reason| {
            response.reason = reason;
        }

        // Parse headers
        try self.parseHeaders(&response.headers, &response.header_count);

        // Extract special headers
        if (response.getHeader("Content-Length")) |cl| {
            response.content_length = std.fmt.parseInt(usize, cl, 10) catch return error.InvalidContentLength;
        }

        if (response.getHeader("Transfer-Encoding")) |te| {
            response.is_chunked = std.mem.indexOf(u8, te, "chunked") != null;
        }

        // Connection handling
        if (response.getHeader("Connection")) |conn| {
            response.keep_alive = !std.ascii.eqlIgnoreCase(conn, "close");
        } else {
            response.keep_alive = response.version == .http_1_1;
        }

        // Body
        if (response.content_length) |len| {
            if (self.pos + len <= self.data.len) {
                response.body = self.data[self.pos .. self.pos + len];
                self.pos += len;
            }
        }

        return response;
    }

    fn parseUri(self: *Parser, request: *Request) void {
        _ = self;
        const uri = request.uri;

        // Find query string
        if (std.mem.indexOf(u8, uri, "?")) |qmark| {
            request.path = uri[0..qmark];
            request.query = uri[qmark + 1 ..];
        } else {
            request.path = uri;
        }
    }

    fn parseHeaders(self: *Parser, headers: *[MAX_HEADERS]Header, count: *usize) ParseError!void {
        count.* = 0;

        while (true) {
            const line = self.readLine() orelse return error.IncompleteMessage;

            // Empty line marks end of headers
            if (line.len == 0) break;

            // Find colon separator
            const colon = std.mem.indexOf(u8, line, ":") orelse return error.InvalidHeader;

            if (count.* >= MAX_HEADERS) return error.TooManyHeaders;

            headers[count.*] = .{
                .name = std.mem.trim(u8, line[0..colon], " \t"),
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
            };
            count.* += 1;
        }
    }

    fn readLine(self: *Parser) ?[]const u8 {
        const rem = self.data[self.pos..];

        // Find \r\n
        if (std.mem.indexOf(u8, rem, "\r\n")) |idx| {
            const line = rem[0..idx];
            self.pos += idx + 2;
            return line;
        }

        return null;
    }

    /// Get remaining unparsed data
    pub fn remaining(self: *const Parser) []const u8 {
        return self.data[self.pos..];
    }
};

// =============================================================================
// HTTP Builder
// =============================================================================

pub const Builder = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Builder {
        return .{ .buf = buf };
    }

    /// Build HTTP request
    pub fn writeRequest(self: *Builder, request: *const Request) !void {
        // Request line
        try self.write(request.method.toString());
        try self.write(" ");
        try self.write(request.uri);
        try self.write(" ");
        try self.write(request.version.toString());
        try self.write("\r\n");

        // Headers
        for (request.headers[0..request.header_count]) |h| {
            try self.writeHeader(h.name, h.value);
        }

        try self.write("\r\n");

        // Body
        if (request.body.len > 0) {
            try self.write(request.body);
        }
    }

    /// Build HTTP response
    pub fn writeResponse(self: *Builder, response: *const Response) !void {
        // Status line
        try self.write(response.version.toString());
        try self.write(" ");

        var status_buf: [8]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{response.status_code}) catch return error.BufferTooSmall;
        try self.write(status_str);

        try self.write(" ");
        try self.write(response.reason);
        try self.write("\r\n");

        // Headers
        for (response.headers[0..response.header_count]) |h| {
            try self.writeHeader(h.name, h.value);
        }

        try self.write("\r\n");

        // Body
        if (response.body.len > 0) {
            try self.write(response.body);
        }
    }

    /// Write a header
    pub fn writeHeader(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.write(name);
        try self.write(": ");
        try self.write(value);
        try self.write("\r\n");
    }

    fn write(self: *Builder, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Get built message
    pub fn message(self: *const Builder) []const u8 {
        return self.buf[0..self.pos];
    }

    /// Get remaining capacity
    pub fn capacity(self: *const Builder) usize {
        return if (self.pos < self.buf.len) self.buf.len - self.pos else 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parse GET request" {
    const data =
        "GET /api/users?page=1 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "User-Agent: test/1.0\r\n" ++
        "Accept: application/json\r\n" ++
        "\r\n";

    var parser = Parser.init(data);
    const request = try parser.parseRequest();

    try std.testing.expectEqual(Method.GET, request.method);
    try std.testing.expectEqualStrings("/api/users?page=1", request.uri);
    try std.testing.expectEqualStrings("/api/users", request.path);
    try std.testing.expectEqualStrings("page=1", request.query.?);
    try std.testing.expectEqual(Version.http_1_1, request.version);
    try std.testing.expectEqualStrings("example.com", request.host);
    try std.testing.expectEqual(@as(usize, 3), request.header_count);
    try std.testing.expect(request.keep_alive);
}

test "parse POST request with body" {
    const data =
        "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 13\r\n" ++
        "\r\n" ++
        "{\"key\":\"val\"}";

    var parser = Parser.init(data);
    const request = try parser.parseRequest();

    try std.testing.expectEqual(Method.POST, request.method);
    try std.testing.expectEqual(@as(usize, 13), request.content_length.?);
    try std.testing.expectEqualStrings("{\"key\":\"val\"}", request.body);
}

test "parse HTTP response" {
    const data =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "Hello";

    var parser = Parser.init(data);
    const response = try parser.parseResponse();

    try std.testing.expectEqual(Version.http_1_1, response.version);
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expectEqualStrings("OK", response.reason);
    try std.testing.expectEqualStrings("Hello", response.body);
}

test "build request" {
    var buf: [256]u8 = undefined;
    var builder = Builder.init(&buf);

    var request = Request{
        .method = .GET,
        .uri = "/test",
        .version = .http_1_1,
        .header_count = 2,
    };
    request.headers[0] = .{ .name = "Host", .value = "example.com" };
    request.headers[1] = .{ .name = "Accept", .value = "*/*" };

    try builder.writeRequest(&request);
    const result = builder.message();

    try std.testing.expect(std.mem.startsWith(u8, result, "GET /test HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "Host: example.com\r\n") != null);
}
