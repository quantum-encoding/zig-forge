// Minimal HTTP/1.1 request parser + response builder.
//
// Scope: just enough to be a fast, correct HTTP/1.1 server for JSON APIs —
// request line + headers, Content-Length bodies, keep-alive. No chunked
// request bodies yet (responses use Content-Length). The parser is
// allocation-free: it returns slices into the caller's read buffer.

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    OTHER,
};

pub const Request = struct {
    method: Method,
    /// Raw method token (valid for OTHER, and cheap for known ones too).
    method_raw: []const u8,
    /// Request target including any query string (slice into the read buffer).
    target: []const u8,
    /// Path component of the target (target up to '?').
    path: []const u8,
    http_11: bool,
    keep_alive: bool,
    content_length: usize,
    /// Total request size on the wire (head + body). The caller advances its
    /// buffer by this many bytes once the body has fully arrived.
    total_len: usize,

    pub fn pathEquals(self: Request, p: []const u8) bool {
        return std.mem.eql(u8, self.path, p);
    }
};

pub const Parsed = union(enum) {
    /// A full request head is present (body may still be arriving — check
    /// total_len against the buffer length).
    ok: Request,
    /// Not enough bytes yet; read more and retry.
    incomplete,
    /// Malformed — the connection should be closed.
    invalid,
};

/// Parse the request head from `buf`. Returns `.incomplete` until the
/// CRLFCRLF header terminator is present. The body is NOT required to be
/// present for `.ok` — `total_len` tells the caller how many bytes the full
/// request occupies so it can wait for the body.
pub fn parse(buf: []const u8) Parsed {
    const term = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        // Defensive cap for direct callers of the public `parse` on a large
        // buffer. The server core enforces a tighter limit (its READ_CAP) and
        // answers an oversized head with `431` before `buf` ever reaches this
        // size, so in the shipped server this branch is the outer backstop.
        if (buf.len > 64 * 1024) return .invalid;
        return .incomplete;
    };
    const head = buf[0..term];
    const body_start = term + 4;

    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];

    // Request line: METHOD SP TARGET SP VERSION
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method_raw = it.next() orelse return .invalid;
    const target = it.next() orelse return .invalid;
    const version = it.next() orelse return .invalid;

    const http_11 = std.mem.eql(u8, version, "HTTP/1.1");
    if (!http_11 and !std.mem.eql(u8, version, "HTTP/1.0")) return .invalid;

    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    // Header scan: Connection + Content-Length (case-insensitive names).
    var keep_alive = http_11; // 1.1 keep-alive by default, 1.0 close by default
    var content_length: usize = 0;
    if (line_end < head.len) {
        var hit = std.mem.splitSequence(u8, head[line_end + 2 ..], "\r\n");
        while (hit.next()) |h| {
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const name = std.mem.trim(u8, h[0..colon], " \t");
            const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.eqlIgnoreCase(value, "close")) {
                    keep_alive = false;
                } else if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                    keep_alive = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch return .invalid;
            }
        }
    }

    return .{ .ok = .{
        .method = parseMethod(method_raw),
        .method_raw = method_raw,
        .target = target,
        .path = path,
        .http_11 = http_11,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .total_len = body_start + content_length,
    } };
}

fn parseMethod(m: []const u8) Method {
    return switch (m.len) {
        3 => if (std.mem.eql(u8, m, "GET")) .GET else if (std.mem.eql(u8, m, "PUT")) .PUT else .OTHER,
        4 => if (std.mem.eql(u8, m, "POST")) .POST else if (std.mem.eql(u8, m, "HEAD")) .HEAD else .OTHER,
        5 => if (std.mem.eql(u8, m, "PATCH")) .PATCH else .OTHER,
        6 => if (std.mem.eql(u8, m, "DELETE")) .DELETE else .OTHER,
        7 => if (std.mem.eql(u8, m, "OPTIONS")) .OPTIONS else .OTHER,
        else => .OTHER,
    };
}

// ── Response ─────────────────────────────────────────────────────────

/// A handler fills this in; the server serializes it onto the wire.
pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: []const u8 = "",

    pub fn json(self: *Response, body: []const u8) void {
        self.status = 200;
        self.content_type = "application/json";
        self.body = body;
    }
    pub fn text(self: *Response, body: []const u8) void {
        self.status = 200;
        self.content_type = "text/plain; charset=utf-8";
        self.body = body;
    }
    pub fn status_(self: *Response, code: u16, body: []const u8) void {
        self.status = code;
        self.body = body;
    }
    pub fn notFound(self: *Response) void {
        self.status = 404;
        self.content_type = "application/json";
        self.body = "{\"error\":\"not_found\"}";
    }
};

/// Serialize `res` into `out` (a connection's write buffer). Returns the number
/// of bytes written, or null if it doesn't fit. Pure formatting, no alloc.
pub fn writeResponse(out: []u8, res: *const Response, keep_alive: bool) ?usize {
    // Response-header-injection guard. `content_type` is the only
    // caller-influenced value interpolated into the head; a handler that set it
    // from request-derived data could otherwise smuggle a CRLF and split the
    // response (inject headers / a second response). Refuse rather than emit a
    // corrupt head. `reason` comes from a fixed table and needs no check.
    if (std.mem.indexOfAny(u8, res.content_type, "\r\n") != null) return null;

    const reason = reasonPhrase(res.status);
    const conn = if (keep_alive) "keep-alive" else "close";
    const head = std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n", .{
        res.status, reason, res.content_type, res.body.len, conn,
    }) catch return null;
    if (head.len + res.body.len > out.len) return null;
    @memcpy(out[head.len .. head.len + res.body.len], res.body);
    return head.len + res.body.len;
}

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse simple GET keep-alive" {
    const raw = "GET /api/devices?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const p = parse(raw);
    try std.testing.expect(p == .ok);
    const r = p.ok;
    try std.testing.expectEqual(Method.GET, r.method);
    try std.testing.expectEqualStrings("/api/devices", r.path);
    try std.testing.expectEqualStrings("/api/devices?x=1", r.target);
    try std.testing.expect(r.keep_alive);
    try std.testing.expectEqual(@as(usize, 0), r.content_length);
    try std.testing.expectEqual(raw.len, r.total_len);
}

test "parse POST with body + connection close" {
    const raw = "POST /x HTTP/1.1\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    const p = parse(raw);
    try std.testing.expect(p == .ok);
    const r = p.ok;
    try std.testing.expectEqual(Method.POST, r.method);
    try std.testing.expect(!r.keep_alive);
    try std.testing.expectEqual(@as(usize, 5), r.content_length);
    try std.testing.expectEqual(raw.len, r.total_len);
}

test "parse incomplete head" {
    try std.testing.expect(parse("GET / HTTP/1.1\r\nHost: x") == .incomplete);
}

test "writeResponse" {
    var buf: [256]u8 = undefined;
    var res = Response{};
    res.json("{\"ok\":true}");
    const n = writeResponse(&buf, &res, true).?;
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 11\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n{\"ok\":true}"));
}

// ── External-anchored conformance ────────────────────────────────────
//
// Inputs and expected fields are taken from the HTTP/1.1 specs, not authored
// round-trips: the request-message example is RFC 7230 §2.1 verbatim, the
// version-defaulting rules are RFC 9112 §9.3 / RFC 7230 §6.3, and the exact
// serialized response bytes below match the RFC 9112 §2.1 message grammar.

test "RFC 7230 §2.1 example request parses field-for-field" {
    // The worked example from RFC 7230 "Message Format", verbatim.
    const raw =
        "GET /hello.txt HTTP/1.1\r\n" ++
        "User-Agent: curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3\r\n" ++
        "Host: www.example.com\r\n" ++
        "Accept-Language: en, mi\r\n\r\n";
    const p = parse(raw);
    try std.testing.expect(p == .ok);
    const r = p.ok;
    try std.testing.expectEqual(Method.GET, r.method);
    try std.testing.expectEqualStrings("/hello.txt", r.target);
    try std.testing.expectEqualStrings("/hello.txt", r.path);
    try std.testing.expect(r.http_11);
    try std.testing.expect(r.keep_alive); // 1.1 default persistent (RFC 9112 §9.3)
    try std.testing.expectEqual(@as(usize, 0), r.content_length);
    try std.testing.expectEqual(raw.len, r.total_len);
}

test "HTTP/1.0 defaults to close; keep-alive opts back in (RFC 7230 §6.3)" {
    {
        const p = parse("GET / HTTP/1.0\r\nHost: x\r\n\r\n");
        try std.testing.expect(p == .ok);
        try std.testing.expect(!p.ok.keep_alive); // 1.0 default: close
        try std.testing.expect(!p.ok.http_11);
    }
    {
        const p = parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
        try std.testing.expect(p == .ok);
        try std.testing.expect(p.ok.keep_alive); // explicit opt-in
    }
}

test "case-insensitive header names (RFC 9110 §5.1)" {
    const p = parse("POST /x HTTP/1.1\r\nCONTENT-LENGTH: 3\r\nCoNnEcTiOn: CLOSE\r\n\r\nabc");
    try std.testing.expect(p == .ok);
    try std.testing.expectEqual(@as(usize, 3), p.ok.content_length);
    try std.testing.expect(!p.ok.keep_alive);
}

test "malformed corpus is rejected or tolerated per spec" {
    // Request line missing the HTTP-version token → invalid.
    try std.testing.expect(parse("GET /\r\n\r\n") == .invalid);
    // Unsupported/other HTTP version → invalid.
    try std.testing.expect(parse("GET / HTTP/2.0\r\n\r\n") == .invalid);
    // Non-numeric Content-Length → invalid (can't frame the body).
    try std.testing.expect(parse("POST / HTTP/1.1\r\nContent-Length: xyz\r\n\r\n") == .invalid);
    // A header line without a colon is skipped, not fatal (RFC 9112 tolerant read).
    {
        const p = parse("GET / HTTP/1.1\r\nGarbageNoColon\r\nHost: x\r\n\r\n");
        try std.testing.expect(p == .ok);
    }
}

test "pipelined batch: total_len frames the first request only" {
    const first = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n";
    const second = "GET /b HTTP/1.1\r\nHost: x\r\n\r\n";
    const p = parse(first ++ second);
    try std.testing.expect(p == .ok);
    // The first request occupies exactly `first.len` bytes; the server shifts
    // the remainder and re-parses `second`.
    try std.testing.expectEqual(first.len, p.ok.total_len);
    try std.testing.expect(p.ok.total_len < (first ++ second).len);
}

test "writeResponse emits exact RFC 9112 message bytes (golden)" {
    var buf: [256]u8 = undefined;
    var res = Response{};
    res.json("{\"ok\":true}");
    const n = writeResponse(&buf, &res, true).?;
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 11\r\n" ++
            "Connection: keep-alive\r\n\r\n" ++
            "{\"ok\":true}",
        buf[0..n],
    );
}

test "writeResponse rejects CRLF-injected content_type (header injection)" {
    var buf: [256]u8 = undefined;
    var res = Response{};
    res.content_type = "text/plain\r\nX-Injected: 1";
    res.body = "hi";
    try std.testing.expect(writeResponse(&buf, &res, true) == null);
}

test "error status lines carry a reason phrase" {
    var buf: [256]u8 = undefined;
    inline for (.{
        .{ @as(u16, 413), "413 Content Too Large" },
        .{ @as(u16, 431), "431 Request Header Fields Too Large" },
        .{ @as(u16, 400), "400 Bad Request" },
    }) |case| {
        var res = Response{};
        res.status = case[0];
        res.content_type = "text/plain; charset=utf-8";
        const n = writeResponse(&buf, &res, false).?;
        try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 " ++ case[1] ++ "\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Connection: close\r\n") != null);
    }
}
