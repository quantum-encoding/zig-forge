const std = @import("std");
const http = std.http;
const c = std.c;

// Default total request timeout (connect + send + receive) in milliseconds.
// Guards the calling thread against a black-holed endpoint blocking forever
// (an availability incident for the live Alpaca trading consumer). Overridable
// per-process via the `HTTP_SENTINEL_TIMEOUT_MS` environment variable; a value
// of 0 disables the timeout (restores the pure-blocking behavior).
const DEFAULT_TIMEOUT_MS: u64 = 30_000;

// Absolute cap on the number of *compressed* bytes read for a gzip/deflate
// body before decompression. Prevents an attacker-controlled Content-Encoding
// from forcing an unbounded read. Decompressed output is bounded separately by
// the caller's buffer size.
const MAX_COMPRESSED_BODY: usize = 64 * 1024 * 1024;

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
    if (buf_size == 0 or @intFromPtr(buf) == 0) return last_error_len;
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

// =============================================================================
// Request context (shared between the caller thread and the worker task)
// =============================================================================

const ReqCtx = struct {
    // Inputs (all read-only for the worker; the backing memory outlives the
    // worker because the caller thread awaits the worker before returning).
    io: std.Io,
    allocator: std.mem.Allocator,
    method: http.Method,
    uri: std.Uri,
    extra_headers: []const http.Header,
    body_ptr: ?[*c]const u8,
    body_len: usize,
    response_body: [*c]u8,
    response_body_size: usize,
    response: *HttpResponse,

    // Outputs written by the worker.
    code: c_int = @intFromEnum(HttpSentinelError.internal_error),
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    fn setErr(ctx: *ReqCtx, msg: []const u8) void {
        const n = @min(msg.len, ctx.err_buf.len);
        @memcpy(ctx.err_buf[0..n], msg[0..n]);
        ctx.err_len = n;
    }

    fn fail(ctx: *ReqCtx, code: HttpSentinelError, msg: []const u8) void {
        ctx.code = @intFromEnum(code);
        ctx.setErr(msg);
    }

    /// Map a stdlib HTTP/IO error onto a precise error code + message. `default`
    /// is used for errors that do not have a more specific mapping.
    fn failStage(ctx: *ReqCtx, err: anyerror, default: HttpSentinelError) void {
        switch (err) {
            error.Canceled => ctx.fail(.timeout, "request timed out"),
            error.TlsInitializationFailed,
            error.CertificateBundleLoadFailure,
            => ctx.fail(.tls_error, "TLS initialization failed"),
            error.UnsupportedUriScheme => ctx.fail(.invalid_url, "Unsupported URL scheme"),
            else => ctx.fail(default, errorToString(err)),
        }
    }
};

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

    // Clear any stale error message from a previous request on this thread so a
    // successful call cannot leave a misleading diagnostic behind.
    last_error_len = 0;
    last_error_msg[0] = 0;

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

    // Parse URL (no IO needed; report failure synchronously)
    const uri = std.Uri.parse(url) catch {
        setLastError("Invalid URL format");
        return @intFromEnum(HttpSentinelError.invalid_url);
    };

    // Build the headers array. Every slot placed into `extra_headers` MUST be
    // fully initialized: a null name/value pointer, or a count exceeding the
    // fixed buffer, is rejected up front rather than leaving `undefined` stack
    // memory to be read by the HTTP client as a header (which was undefined
    // behavior — garbage bytes on the wire / possible crash).
    var extra_headers: []const http.Header = &.{};
    var headers_buf: [64]http.Header = undefined;
    if (header_count > 0) {
        if (@intFromPtr(headers_ptr) == 0) {
            setLastError("Headers pointer is null but header_count > 0");
            return @intFromEnum(HttpSentinelError.invalid_input);
        }
        if (header_count > headers_buf.len) {
            setLastError("Too many headers (max 64)");
            return @intFromEnum(HttpSentinelError.invalid_input);
        }
        for (0..header_count) |i| {
            const h = headers_ptr[i];
            if (@intFromPtr(h.name) == 0 or @intFromPtr(h.value) == 0) {
                setLastError("Header name or value pointer is null");
                return @intFromEnum(HttpSentinelError.invalid_input);
            }
            headers_buf[i] = .{
                .name = h.name[0..h.name_len],
                .value = h.value[0..h.value_len],
            };
        }
        extra_headers = headers_buf[0..header_count];
    }

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

    var ctx: ReqCtx = .{
        .io = io,
        .allocator = allocator,
        .method = method,
        .uri = uri,
        .extra_headers = extra_headers,
        .body_ptr = body_ptr,
        .body_len = body_len,
        .response_body = response_body,
        .response_body_size = response_body_size,
        .response = response,
    };

    const timeout_ms = readTimeoutMs();
    if (timeout_ms == 0) {
        // Timeout disabled: run the request inline on this thread.
        runHttp(&ctx);
    } else {
        runWithTimeout(&ctx, io, timeout_ms);
    }

    // Publish the worker's error message to this thread's thread-local slot.
    setLastError(ctx.err_buf[0..ctx.err_len]);
    return ctx.code;
}

/// Read the configured total-request timeout in milliseconds. `0` disables the
/// timeout. Invalid values fall back to the default.
fn readTimeoutMs() u64 {
    if (c.getenv("HTTP_SENTINEL_TIMEOUT_MS")) |raw| {
        const v = std.mem.span(raw);
        return std.fmt.parseInt(u64, v, 10) catch DEFAULT_TIMEOUT_MS;
    }
    return DEFAULT_TIMEOUT_MS;
}

/// Run `runHttp` on a worker task and race it against a timer. If the timer
/// wins, the worker is canceled (its next cancelation point returns
/// `error.Canceled`, which unblocks a stalled connect/read via a signal in the
/// threaded IO implementation) and the call reports `timeout`.
fn runWithTimeout(ctx: *ReqCtx, io: std.Io, timeout_ms: u64) void {
    const Which = union(enum) { work: void, timer: void };
    var sel_buf: [2]Which = undefined;
    var sel = std.Io.Select(Which).init(io, &sel_buf);

    sel.concurrent(.work, runHttpTask, .{ctx}) catch {
        // Concurrency unavailable (e.g. single-threaded build): fall back to a
        // plain blocking request with no timeout rather than failing.
        runHttp(ctx);
        return;
    };

    const ns: u64 = timeout_ms *| std.time.ns_per_ms;
    sel.concurrent(.timer, timerTask, .{ io, ns }) catch {
        // Could not start the timer: await the in-flight worker with no timeout.
        _ = sel.await() catch {};
        sel.cancelDiscard();
        return;
    };

    const winner = sel.await() catch {
        // The caller task itself was canceled (not expected for a fresh FFI
        // call); tear everything down and report an internal error.
        sel.cancelDiscard();
        ctx.fail(.internal_error, "request canceled");
        return;
    };
    // Cancel and join whichever task did not win before returning, so no task
    // outlives this stack frame (which owns `ctx`, the client, and the IO).
    sel.cancelDiscard();

    switch (winner) {
        .work => {}, // `runHttp` already populated ctx.code / ctx.err_*.
        .timer => ctx.fail(.timeout, "request timed out"),
    }
}

fn runHttpTask(ctx: *ReqCtx) void {
    runHttp(ctx);
}

fn timerTask(io: std.Io, ns: u64) void {
    const to: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    } };
    to.sleep(io) catch {};
}

/// Perform the HTTP exchange and copy the (optionally decompressed) body into
/// the caller buffer. Writes the outcome into `ctx`. Runs either inline or on a
/// worker task.
fn runHttp(ctx: *ReqCtx) void {
    const allocator = ctx.allocator;

    var client = http.Client{
        .allocator = allocator,
        .io = ctx.io,
    };
    defer client.deinit();

    var req = client.request(ctx.method, ctx.uri, .{
        .extra_headers = ctx.extra_headers,
    }) catch |err| return ctx.failStage(err, .connection_failed);
    defer req.deinit();

    // Send body if present
    if (ctx.body_ptr != null and ctx.body_len > 0) {
        req.transfer_encoding = .{ .content_length = ctx.body_len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err|
            return ctx.failStage(err, .request_failed);
        body_writer.writer.writeAll(ctx.body_ptr.?[0..ctx.body_len]) catch |err|
            return ctx.failStage(err, .request_failed);
        body_writer.end() catch |err|
            return ctx.failStage(err, .request_failed);
        if (req.connection) |conn| {
            conn.flush() catch |err|
                return ctx.failStage(err, .request_failed);
        }
    } else {
        req.sendBodiless() catch |err|
            return ctx.failStage(err, .request_failed);
    }

    // Receive response head
    var http_response = req.receiveHead(&.{}) catch |err|
        return ctx.failStage(err, .request_failed);

    ctx.response.status_code = @intFromEnum(http_response.head.status);

    // Read response body (if not HEAD request and buffer provided)
    if (ctx.method != .HEAD and ctx.response_body_size > 0 and @intFromPtr(ctx.response_body) != 0) {
        var transfer_buffer: [8192]u8 = undefined;
        const body_reader = http_response.reader(&transfer_buffer);
        const ce = http_response.head.content_encoding;
        const size = ctx.response_body_size;

        switch (ce) {
            .identity => {
                // Read up to size+1 bytes to distinguish an exact fit from a
                // truncation, keeping the bytes read even on overflow.
                var list: std.ArrayList(u8) = .empty;
                defer list.deinit(allocator);
                var truncated = false;
                body_reader.appendRemaining(allocator, &list, std.Io.Limit.limited(size + 1)) catch |err| switch (err) {
                    error.StreamTooLong => truncated = true,
                    error.OutOfMemory => return ctx.fail(.internal_error, "out of memory"),
                    else => {
                        if (http_response.bodyErr()) |berr| {
                            return ctx.failStage(berr, .request_failed);
                        }
                        return ctx.failStage(err, .request_failed);
                    },
                };
                copyBody(ctx, list.items, truncated);
            },
            .gzip, .deflate => {
                // Read the full *compressed* body under an absolute cap, then
                // decompress bounded by the caller's buffer. A corrupt/truncated
                // compressed stream is a hard failure — it is NEVER surfaced as a
                // partial body with a success code (the previous behavior fed
                // wrong data into the trading path).
                const compressed = body_reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_COMPRESSED_BODY)) catch |err| switch (err) {
                    error.StreamTooLong => return ctx.fail(.response_too_large, "compressed body exceeds cap"),
                    error.OutOfMemory => return ctx.fail(.internal_error, "out of memory"),
                    else => {
                        if (http_response.bodyErr()) |berr| {
                            return ctx.failStage(berr, .request_failed);
                        }
                        return ctx.failStage(err, .request_failed);
                    },
                };
                defer allocator.free(compressed);

                const container: std.compress.flate.Container = if (ce == .gzip) .gzip else .zlib;
                const res = inflateBody(allocator, compressed, container, size + 1) catch |err| switch (err) {
                    error.OutOfMemory => return ctx.fail(.internal_error, "out of memory"),
                    error.DecompressFailed => return ctx.fail(.request_failed, "response body decompression failed"),
                };
                defer allocator.free(res.data);
                copyBody(ctx, res.data, res.truncated);
            },
            else => {
                // zstd/compress are not advertised by the client and cannot be
                // decoded here; surface an explicit error rather than returning
                // raw compressed bytes as if they were the body.
                return ctx.fail(.request_failed, "unsupported content-encoding");
            },
        }
    }

    ctx.code = @intFromEnum(HttpSentinelError.success);
    ctx.err_len = 0;
}

fn copyBody(ctx: *ReqCtx, data: []const u8, truncated: bool) void {
    const size = ctx.response_body_size;
    const copy_len = @min(data.len, size);
    @memcpy(ctx.response_body[0..copy_len], data[0..copy_len]);
    ctx.response.body_len = copy_len;
    ctx.response.truncated = truncated or data.len > size;
}

const DecompressResult = struct { data: []u8, truncated: bool };
const InflateError = error{ DecompressFailed, OutOfMemory };

/// Decompress a complete flate stream (`.gzip` for Content-Encoding: gzip,
/// `.zlib` for Content-Encoding: deflate) into a fresh, caller-owned slice,
/// bounded to `max_output` *decompressed* bytes.
///
/// - On a corrupt or truncated compressed stream: returns
///   `error.DecompressFailed`. It never returns a silently partial body.
/// - If the decompressed output would exceed `max_output`: returns the first
///   `max_output` bytes with `truncated = true` (the caller decides how to
///   surface truncation), rather than erroring.
fn inflateBody(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    container: std.compress.flate.Container,
    max_output: usize,
) InflateError!DecompressResult {
    // A full-size history window is required for correct back-reference
    // resolution across DEFLATE blocks.
    const window = allocator.alloc(u8, std.compress.flate.max_window_len) catch
        return error.OutOfMemory;
    defer allocator.free(window);

    var in: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&in, container, window);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var truncated = false;
    decompress.reader.appendRemaining(allocator, &list, std.Io.Limit.limited(max_output)) catch |err| switch (err) {
        error.StreamTooLong => truncated = true,
        error.OutOfMemory => return error.OutOfMemory,
        // ReadFailed (corrupt/truncated stream) and any other error: fail hard.
        else => return error.DecompressFailed,
    };

    const data = list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .data = data, .truncated = truncated };
}

fn errorToString(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Connection refused",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.NetworkUnreachable => "Network unreachable",
        error.HostUnreachable => "Host unreachable",
        error.UnexpectedEof => "Unexpected end of stream",
        error.OutOfMemory => "Out of memory",
        error.Canceled => "Request timed out",
        error.TlsInitializationFailed => "TLS initialization failed",
        error.CertificateBundleLoadFailure => "Failed to load certificate bundle",
        error.UnsupportedUriScheme => "Unsupported URL scheme",
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

// Live-network smoke tests. These depend on a reachable third-party service and
// are therefore non-deterministic (DNS, TLS, and the server's own availability —
// httpbin routinely returns 503 under load). They are opt-in: set
// `HTTP_SENTINEL_LIVE_TESTS=1` to run them. Deterministic coverage of the
// request pipeline lives in the offline tests below.
fn liveTestsEnabled() bool {
    const raw = c.getenv("HTTP_SENTINEL_LIVE_TESTS") orelse return false;
    return std.mem.span(raw).len > 0;
}

test "GET request to httpbin (live, opt-in)" {
    if (!liveTestsEnabled()) return error.SkipZigTest;
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

    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expect(response.status_code != 0);
}

test "POST request with body (live, opt-in)" {
    if (!liveTestsEnabled()) return error.SkipZigTest;
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

    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expect(response.status_code != 0);
}

test "version strings" {
    const version = http_sentinel_version();
    try std.testing.expect(version[0] != 0);
}

// -----------------------------------------------------------------------------
// External-anchor gzip vector
//
// These bytes are a real gzip (RFC 1952) stream produced by an INDEPENDENT
// implementation — CPython's `gzip`/`zlib` — not by this library:
//
//   python3 -c "import gzip; \
//     open('x','wb').write(gzip.compress(b'{\"symbol\":\"AAPL\",\"price\":150.25,\"qty\":10}', mtime=0))"
//
// The expected plaintext and the compressed bytes both come from outside this
// codebase, so decoding them to the exact plaintext proves interoperability
// with the real gzip format (not merely internal self-consistency). This is the
// path that feeds decompressed JSON into the Alpaca trading consumer.
// -----------------------------------------------------------------------------
const gz_vector = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xab, 0x56, 0x2a, 0xae, 0xcc, 0x4d,
    0xca, 0xcf, 0x51, 0xb2, 0x52, 0x72, 0x74, 0x0c, 0xf0, 0x51, 0xd2, 0x51, 0x2a, 0x28, 0xca, 0x4c,
    0x4e, 0x55, 0xb2, 0x32, 0x34, 0x35, 0xd0, 0x33, 0x32, 0xd5, 0x51, 0x2a, 0x2c, 0xa9, 0x04, 0x72,
    0x0c, 0x6a, 0x01, 0x8d, 0x82, 0x77, 0xa4, 0x29, 0x00, 0x00, 0x00,
};
const gz_plaintext = "{\"symbol\":\"AAPL\",\"price\":150.25,\"qty\":10}";

test "inflateBody decodes external gzip vector to exact plaintext" {
    const alloc = std.testing.allocator;
    const res = try inflateBody(alloc, &gz_vector, .gzip, 1 << 20);
    defer alloc.free(res.data);
    try std.testing.expect(!res.truncated);
    try std.testing.expectEqualStrings(gz_plaintext, res.data);
}

test "inflateBody bounds decompressed output and flags truncation" {
    const alloc = std.testing.allocator;
    const res = try inflateBody(alloc, &gz_vector, .gzip, 5);
    defer alloc.free(res.data);
    try std.testing.expect(res.truncated);
    try std.testing.expectEqual(@as(usize, 5), res.data.len);
    try std.testing.expectEqualStrings(gz_plaintext[0..5], res.data);
}

test "inflateBody rejects a truncated gzip stream instead of returning partial data" {
    const alloc = std.testing.allocator;
    // Chop the trailing CRC32/ISIZE footer + last deflate bytes: a corrupt
    // stream must be a hard failure, never a silently partial body.
    try std.testing.expectError(
        error.DecompressFailed,
        inflateBody(alloc, gz_vector[0 .. gz_vector.len - 6], .gzip, 1 << 20),
    );
}

test "inflateBody rejects non-gzip garbage" {
    const alloc = std.testing.allocator;
    const garbage = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    try std.testing.expectError(
        error.DecompressFailed,
        inflateBody(alloc, &garbage, .gzip, 1 << 20),
    );
}

test "null header value pointer is rejected (no undefined-memory header)" {
    var response: HttpResponse = undefined;
    var body: [16]u8 = undefined;
    const headers = [_]HttpHeader{.{
        .name = "X-Test",
        .name_len = 6,
        .value = null,
        .value_len = 0,
    }};
    const r = http_sentinel_get(
        "http://127.0.0.1:1/",
        &headers,
        1,
        &body,
        body.len,
        &response,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HttpSentinelError.invalid_input)),
        r,
    );
}

test "header count above the fixed buffer is rejected, not silently truncated" {
    var response: HttpResponse = undefined;
    var body: [16]u8 = undefined;
    const one = [_]HttpHeader{.{
        .name = "X-Test",
        .name_len = 6,
        .value = "1",
        .value_len = 1,
    }};
    // Claim 65 headers (> 64-slot buffer) while only pointing at one; the
    // library must refuse rather than drop headers (e.g. an Authorization).
    const r = http_sentinel_get(
        "http://127.0.0.1:1/",
        &one,
        65,
        &body,
        body.len,
        &response,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HttpSentinelError.invalid_input)),
        r,
    );
}

// -----------------------------------------------------------------------------
// Deterministic loopback tests
//
// A tiny in-process TCP server (libc sockets on a background thread) serves
// canned responses over plain HTTP so the whole request pipeline — including
// the concurrent timeout wrapper and the gzip decode path — is exercised
// offline, with no dependency on any external host.
// -----------------------------------------------------------------------------

const sock = struct {
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
    extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    extern "c" fn nanosleep(req: *const TimeSpec, rem: ?*TimeSpec) c_int;

    const TimeSpec = extern struct { sec: isize, nsec: isize };

    // macOS/BSD sockaddr_in (leading length byte + 1-byte family).
    const SockaddrIn = extern struct {
        len: u8 = @sizeOf(SockaddrIn),
        family: u8 = 2, // AF_INET
        port: u16, // network byte order
        addr: u32, // network byte order
        zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    const ServerMode = enum { gzip_ok, plain_ok, hang };

    const Server = struct {
        listen_fd: c_int,
        port: u16,
        mode: ServerMode,
        thread: std.Thread,
        plain_body_len: usize,
    };

    fn handle(srv: *Server) void {
        const conn = accept(srv.listen_fd, null, null);
        if (conn < 0) return;
        defer _ = close(conn);
        // Drain the request (a small GET/POST fits in one read).
        var reqbuf: [2048]u8 = undefined;
        _ = read(conn, &reqbuf, reqbuf.len);

        switch (srv.mode) {
            .hang => {
                // Accept the connection but never answer, so the client must
                // rely on its own timeout to unblock.
                const ts = TimeSpec{ .sec = 3, .nsec = 0 };
                _ = nanosleep(&ts, null);
            },
            .gzip_ok => {
                var hdr: [256]u8 = undefined;
                const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{gz_vector.len}) catch return;
                _ = write(conn, h.ptr, h.len);
                _ = write(conn, &gz_vector, gz_vector.len);
            },
            .plain_ok => {
                var body: [100]u8 = undefined;
                for (&body, 0..) |*b, i| b.* = 'A' + @as(u8, @intCast(i % 26));
                srv.plain_body_len = body.len;
                var hdr: [256]u8 = undefined;
                const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
                _ = write(conn, h.ptr, h.len);
                _ = write(conn, &body, body.len);
            },
        }
    }

    /// Create+bind+listen a loopback server, spawn its accept thread, and return
    /// once the bound port is known. Returns null if sockets are unavailable.
    fn start(srv: *Server, mode: ServerMode) !void {
        const fd = socket(2, 1, 0); // AF_INET, SOCK_STREAM
        if (fd < 0) return error.SkipZigTest;
        errdefer _ = close(fd);

        const one: c_int = 1;
        _ = setsockopt(fd, 0xffff, 0x0004, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_REUSEADDR

        var addr = SockaddrIn{
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        };
        if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.SkipZigTest;

        var slen: u32 = @sizeOf(SockaddrIn);
        if (getsockname(fd, &addr, &slen) != 0) return error.SkipZigTest;
        if (listen(fd, 1) != 0) return error.SkipZigTest;

        srv.* = .{
            .listen_fd = fd,
            .port = std.mem.bigToNative(u16, addr.port),
            .mode = mode,
            .thread = undefined,
            .plain_body_len = 0,
        };
        srv.thread = try std.Thread.spawn(.{}, handle, .{srv});
    }

    fn stop(srv: *Server) void {
        srv.thread.join();
        _ = close(srv.listen_fd);
    }
};

test "loopback: gzip response is decoded to exact plaintext through the FFI" {
    var srv: sock.Server = undefined;
    sock.start(&srv, .gzip_ok) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer sock.stop(&srv);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{srv.port});

    var response_body: [256]u8 = undefined;
    var response: HttpResponse = undefined;
    const result = http_sentinel_get(url.ptr, null, 0, &response_body, response_body.len, &response);

    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(!response.truncated);
    try std.testing.expectEqualStrings(gz_plaintext, response_body[0..response.body_len]);
}

test "loopback: an oversized body is truncated and flagged, not errored" {
    var srv: sock.Server = undefined;
    sock.start(&srv, .plain_ok) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer sock.stop(&srv);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{srv.port});

    var response_body: [10]u8 = undefined; // server sends 100 bytes
    var response: HttpResponse = undefined;
    const result = http_sentinel_get(url.ptr, null, 0, &response_body, response_body.len, &response);

    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expectEqual(@as(usize, 10), response.body_len);
    try std.testing.expect(response.truncated);
    try std.testing.expectEqualStrings("ABCDEFGHIJ", response_body[0..response.body_len]);
}

test "loopback: a non-responsive server trips the request timeout" {
    var srv: sock.Server = undefined;
    sock.start(&srv, .hang) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer sock.stop(&srv);

    // Force a short total timeout for this test only.
    _ = sock.setenv("HTTP_SENTINEL_TIMEOUT_MS", "400", 1);
    defer _ = sock.unsetenv("HTTP_SENTINEL_TIMEOUT_MS");

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{srv.port});

    var response_body: [256]u8 = undefined;
    var response: HttpResponse = undefined;
    const result = http_sentinel_get(url.ptr, null, 0, &response_body, response_body.len, &response);

    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HttpSentinelError.timeout)),
        result,
    );
}

/// FFI panic seal: convert any panic into an immediate abort() so it can never
/// unwind across the C ABI into the Rust host (which would be undefined behaviour).
fn ffiPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = ret_addr;
    std.debug.print("FATAL ZIG FFI PANIC: {s}\n", .{msg});
    std.process.abort();
}

/// Zig 0.16 panic interface: the root module must expose `pub const panic` as a
/// namespace. `std.debug.FullPanic` wraps `ffiPanic` and routes every safety
/// check (outOfBounds, unwrapNull, integerOverflow, …) into it. The previous
/// 3-arg `pub fn panic` form only worked via a deprecated 0.16 compat shim.
pub const panic = std.debug.FullPanic(ffiPanic);

