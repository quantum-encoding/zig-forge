//! Quantum Reverse Proxy Library
//!
//! High-performance reverse proxy with WASM edge function support.
//!
//! Features:
//! - Zero-allocation HTTP/1.1 parsing
//! - Connection pooling with health checks
//! - Flexible request routing (path, host, method)
//! - WASM edge function execution
//! - Circuit breaker pattern
//! - Round-robin load balancing
//!
//! Usage:
//! ```zig
//! const proxy = @import("proxy");
//!
//! var server = proxy.ProxyServer.init(allocator, .{
//!     .listen_port = 8080,
//! });
//! defer server.deinit();
//!
//! // Add backend pool
//! try server.addBackendPool("api", &.{
//!     .{ .host = "10.0.0.1", .port = 8001 },
//!     .{ .host = "10.0.0.2", .port = 8002 },
//! });
//!
//! // Route requests
//! try server.router.addPrefix("/api/", server.getPool("api"));
//!
//! // Add WASM edge function
//! try server.router.addWasm("/edge/", "functions/handler.wasm");
//!
//! try server.run();
//! ```

const std = @import("std");
const posix = std.posix;
const c = std.c;

// =============================================================================
// HTTP Module
// =============================================================================

pub const http = @import("http/parser.zig");
pub const Method = http.Method;
pub const Version = http.Version;
pub const Header = http.Header;
pub const Request = http.Request;
pub const Response = http.Response;
pub const Parser = http.Parser;
pub const Builder = http.Builder;
pub const ParseError = http.ParseError;

// =============================================================================
// Proxy Module
// =============================================================================

pub const backend = @import("proxy/backend.zig");
pub const BackendConfig = backend.BackendConfig;
pub const Backend = backend.Backend;
pub const BackendPool = backend.BackendPool;
pub const PooledConnection = backend.PooledConnection;
pub const HealthStatus = backend.HealthStatus;
pub const PoolStats = backend.PoolStats;

pub const router = @import("proxy/router.zig");
pub const Router = router.Router;
pub const Route = router.Route;
pub const RouteTarget = router.RouteTarget;
pub const RouteMatcher = router.RouteMatcher;
pub const PathMatcher = router.PathMatcher;
pub const MatchType = router.MatchType;
pub const WasmHandler = router.WasmHandler;
pub const StaticResponse = router.StaticResponse;
pub const RedirectConfig = router.RedirectConfig;

pub const loadbalancer = @import("proxy/loadbalancer.zig");
pub const LoadBalancer = loadbalancer.LoadBalancer;
pub const LoadBalanceStrategy = loadbalancer.Strategy;

// =============================================================================
// Middleware
// =============================================================================

pub const middleware = @import("middleware/chain.zig");
pub const MiddlewareChain = middleware.MiddlewareChain;
pub const Middleware = middleware.Middleware;
pub const MiddlewareContext = middleware.Context;
pub const LoggingMiddleware = middleware.LoggingMiddleware;
pub const CorsMiddleware = middleware.CorsMiddleware;
pub const RateLimitMiddleware = middleware.RateLimitMiddleware;
pub const SecurityHeadersMiddleware = middleware.SecurityHeadersMiddleware;

// =============================================================================
// WASM Edge Functions
// =============================================================================

pub const edge = @import("wasm/edge.zig");
pub const EdgeConfig = edge.EdgeConfig;
pub const EdgeRequest = edge.EdgeRequest;
pub const EdgeResponse = edge.EdgeResponse;
pub const EdgeHandler = edge.EdgeHandler;
pub const ModuleCache = edge.ModuleCache;

// =============================================================================
// Proxy Server Configuration
// =============================================================================

pub const ProxyConfig = struct {
    /// Listen address
    listen_addr: []const u8 = "0.0.0.0",
    /// Listen port
    listen_port: u16 = 8080,
    /// Enable TLS termination
    tls_enabled: bool = false,
    /// TLS certificate path
    tls_cert: ?[]const u8 = null,
    /// TLS private key path
    tls_key: ?[]const u8 = null,
    /// Maximum concurrent connections
    max_connections: u32 = 10000,
    /// Request timeout (ms)
    request_timeout_ms: u32 = 30000,
    /// Keep-alive timeout (ms)
    keepalive_timeout_ms: u32 = 60000,
    /// Enable access logging
    access_log: bool = true,
    /// Worker thread count (0 = auto)
    worker_threads: u32 = 0,
    /// Request buffer size
    request_buffer_size: u32 = 64 * 1024,
    /// Response buffer size
    response_buffer_size: u32 = 64 * 1024,
    /// Enable WASM edge functions
    wasm_enabled: bool = true,
    /// WASM execution timeout (ms)
    wasm_timeout_ms: u32 = 30000,
    /// WASM memory limit (bytes)
    wasm_memory_limit: u32 = 64 * 1024 * 1024,
};

// =============================================================================
// Proxy Server
// =============================================================================

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    config: ProxyConfig,
    router_instance: Router,
    pools: std.StringHashMapUnmanaged(*BackendPool),
    wasm_cache: ModuleCache,
    running: std.atomic.Value(bool),
    listen_socket: ?std.posix.socket_t,

    // Statistics
    total_requests: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    bytes_received: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: ProxyConfig) ProxyServer {
        return .{
            .allocator = allocator,
            .config = config,
            .router_instance = Router.init(allocator),
            .pools = .{},
            .wasm_cache = ModuleCache.init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .listen_socket = null,
            .total_requests = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u32).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ProxyServer) void {
        // Close listen socket
        if (self.listen_socket) |sock| {
            _ = std.c.close(sock);
        }

        // Clean up pools
        var iter = self.pools.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pools.deinit(self.allocator);

        // Clean up router and WASM cache
        self.router_instance.deinit();
        self.wasm_cache.deinit();
    }

    /// Create a backend pool
    pub fn createPool(self: *ProxyServer, name: []const u8) !*BackendPool {
        const pool = try self.allocator.create(BackendPool);
        pool.* = BackendPool.init(self.allocator);
        try self.pools.put(self.allocator, name, pool);
        return pool;
    }

    /// Get a backend pool by name
    pub fn getPool(self: *ProxyServer, name: []const u8) ?*BackendPool {
        return self.pools.get(name);
    }

    /// Get the router
    pub fn getRouter(self: *ProxyServer) *Router {
        return &self.router_instance;
    }

    /// Start the proxy server
    pub fn run(self: *ProxyServer) !void {
        // Create listening socket
        const socket_ret = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (socket_ret < 0) return error.SocketCreateFailed;
        const socket: posix.socket_t = @intCast(socket_ret);
        errdefer _ = std.c.close(socket);

        // Set socket options
        const enable: c_int = 1;
        _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.REUSEADDR, std.mem.asBytes(&enable), @sizeOf(c_int));

        // Bind
        const addr = try parseListenAddr(self.config.listen_addr, self.config.listen_port);
        if (c.bind(socket, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
            return error.BindFailed;
        }

        // Listen
        if (c.listen(socket, 128) < 0) {
            return error.ListenFailed;
        }

        self.listen_socket = socket;
        self.running.store(true, .release);

        // Accept loop
        while (self.running.load(.acquire)) {
            var client_addr: c.sockaddr.in = undefined;
            var addr_len: c.socklen_t = @sizeOf(c.sockaddr.in);

            const client_ret = c.accept(socket, @ptrCast(&client_addr), &addr_len);
            if (client_ret < 0) continue;
            const client: posix.socket_t = @intCast(client_ret);

            // Handle connection (simplified - real impl would use thread pool)
            _ = self.active_connections.fetchAdd(1, .monotonic);
            defer _ = self.active_connections.fetchSub(1, .monotonic);

            self.handleConnection(client) catch |err| {
                std.log.debug("Connection error: {}", .{err});
            };
        }
    }

    /// Stop the proxy server
    pub fn stop(self: *ProxyServer) void {
        self.running.store(false, .release);
        if (self.listen_socket) |sock| {
            _ = std.c.close(sock);
            self.listen_socket = null;
        }
    }

    /// Handle a single client connection
    fn handleConnection(self: *ProxyServer, client_socket: posix.socket_t) !void {
        defer _ = std.c.close(client_socket);

        // Read the full request using a framing-aware read loop so that request
        // bodies larger than a single kernel read (and larger than 64 KiB) are
        // NOT truncated. The message is buffered into a growable heap buffer.
        var request_data = std.ArrayListUnmanaged(u8).empty;
        defer request_data.deinit(self.allocator);

        recvFullMessage(self.allocator, client_socket, &request_data, false) catch |err| {
            const status = if (err == error.MessageTooLarge)
                "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\n\r\n"
            else
                "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = c.send(client_socket, status.ptr, status.len, 0);
            return;
        };

        // Peer closed with nothing to say.
        if (request_data.items.len == 0) return;

        _ = self.bytes_received.fetchAdd(request_data.items.len, .monotonic);
        _ = self.total_requests.fetchAdd(1, .monotonic);

        // Parse request
        var parser_inst = Parser.init(request_data.items);
        const request = parser_inst.parseRequest() catch {
            // Send 400 Bad Request
            const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = c.send(client_socket, bad_request.ptr, bad_request.len, 0);
            return;
        };

        // Route request
        const target = self.router_instance.getTarget(&request) orelse {
            // Send 404 Not Found
            const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
            _ = c.send(client_socket, not_found.ptr, not_found.len, 0);
            return;
        };

        // Backend proxying can produce a response of arbitrary size, so it uses
        // its own framing-aware read loop into a growable buffer. Static /
        // redirect / wasm targets produce small, bounded responses that still
        // fit a fixed stack buffer.
        if (target == .backend) {
            var response_data = std.ArrayListUnmanaged(u8).empty;
            defer response_data.deinit(self.allocator);

            try self.proxyToBackend(target.backend, &request, &response_data);

            _ = c.send(client_socket, response_data.items.ptr, response_data.items.len, 0);
            _ = self.bytes_sent.fetchAdd(response_data.items.len, .monotonic);
            return;
        }

        var response_buf: [65536]u8 = undefined;
        const response_len = switch (target) {
            .backend => unreachable, // handled above
            .wasm => |wasm| try self.executeEdgeFunction(wasm, &request, &response_buf),
            .static => |static| try self.serveStatic(static, &response_buf),
            .redirect => |redir| try self.serveRedirect(redir, &response_buf),
        };

        // Send response
        _ = c.send(client_socket, response_buf[0..response_len].ptr, response_len, 0);
        _ = self.bytes_sent.fetchAdd(response_len, .monotonic);
    }

    /// Proxy request to backend. Appends the full HTTP response (or an error
    /// response) into `response_data`.
    fn proxyToBackend(self: *ProxyServer, pool: *BackendPool, request: *const Request, response_data: *std.ArrayListUnmanaged(u8)) !void {
        // Get backend
        const be = pool.nextBackend() orelse {
            return appendErrorResponse(self.allocator, response_data, 503, "Service Unavailable");
        };

        // Get connection from pool
        const conn = be.getConnection() catch {
            be.markFailure();
            return appendErrorResponse(self.allocator, response_data, 502, "Bad Gateway");
        };
        defer be.releaseConnection(conn, request.keep_alive);

        // Build forwarded request
        var forward_buf: [65536]u8 = undefined;
        var builder = Builder.init(&forward_buf);
        try builder.writeRequest(request);

        // Send to backend
        const start_time = getTimeNs();
        const msg = builder.message();
        if (c.send(conn.socket, msg.ptr, msg.len, 0) < 0) {
            be.markFailure();
            return appendErrorResponse(self.allocator, response_data, 502, "Bad Gateway");
        }

        // Read the full response with a framing-aware read loop (Content-Length,
        // chunked, or close-delimited) — never a single truncating recv.
        recvFullMessage(self.allocator, conn.socket, response_data, true) catch {
            be.markFailure();
            response_data.clearRetainingCapacity();
            return appendErrorResponse(self.allocator, response_data, 502, "Bad Gateway");
        };

        const latency: u64 = (getTimeNs() - start_time) / 1000; // Convert to microseconds
        be.markSuccess(latency);
    }

    /// Execute WASM edge function
    fn executeEdgeFunction(self: *ProxyServer, wasm: WasmHandler, request: *const Request, response_buf: []u8) !usize {
        // Get or load handler
        const handler = self.wasm_cache.getHandler(wasm.module_path, .{
            .max_memory = wasm.memory_limit,
            .timeout_ms = wasm.timeout_ms,
        }) catch {
            return buildErrorResponse(response_buf, 500, "Edge Function Error");
        };

        // Execute
        const edge_response = handler.execute(request) catch {
            return buildErrorResponse(response_buf, 500, "Edge Function Error");
        };

        // Convert to HTTP response
        const http_response = edge_response.toHttpResponse();

        // Build response
        var builder = Builder.init(response_buf);
        try builder.writeResponse(&http_response);

        return builder.pos;
    }

    /// Serve static response
    fn serveStatic(_: *ProxyServer, static: StaticResponse, response_buf: []u8) !usize {
        var builder = Builder.init(response_buf);

        var response = Response{
            .status_code = static.status,
            .reason = statusReason(static.status),
            .header_count = 1,
            .body = static.body,
            .content_length = static.body.len,
        };
        response.headers[0] = .{ .name = "Content-Type", .value = static.content_type };

        try builder.writeResponse(&response);
        return builder.pos;
    }

    /// Serve redirect
    fn serveRedirect(_: *ProxyServer, redir: RedirectConfig, response_buf: []u8) !usize {
        const status: u16 = if (redir.permanent) 301 else 302;
        const reason = if (redir.permanent) "Moved Permanently" else "Found";

        var builder = Builder.init(response_buf);

        var response = Response{
            .status_code = status,
            .reason = reason,
            .header_count = 1,
            .body = "",
        };
        response.headers[0] = .{ .name = "Location", .value = redir.url };

        try builder.writeResponse(&response);
        return builder.pos;
    }

    /// Get server statistics
    pub fn getStats(self: *const ProxyServer) ServerStats {
        return .{
            .total_requests = self.total_requests.load(.monotonic),
            .active_connections = self.active_connections.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .bytes_sent = self.bytes_sent.load(.monotonic),
        };
    }
};

pub const ServerStats = struct {
    total_requests: u64,
    active_connections: u32,
    bytes_received: u64,
    bytes_sent: u64,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Hard upper bound on a single buffered HTTP message (headers + body). Prevents
/// an unbounded read loop from being turned into a memory-exhaustion DoS.
const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

/// Per-syscall receive chunk size for the framing-aware read loop.
const RECV_CHUNK_SIZE: usize = 64 * 1024;

const Framing = struct {
    content_length: ?usize = null,
    chunked: bool = false,
};

/// Scan an HTTP header block (everything before the terminating CRLF CRLF, not
/// including it) for the framing headers needed by the read loop.
fn scanFraming(header_block: []const u8) Framing {
    var framing = Framing{};
    var it = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = it.next(); // skip request/status line
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            framing.content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) framing.chunked = true;
        }
    }
    return framing;
}

/// Read a complete HTTP message from `socket` into `out`, framing-aware.
///
/// The loop reads until the header terminator is seen, determines the body
/// framing (Content-Length, chunked, or connection-close), and keeps reading
/// until the full body has arrived. This replaces the old single unlooped recv
/// that truncated any message exceeding one kernel read / 64 KiB.
fn recvFullMessage(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    out: *std.ArrayListUnmanaged(u8),
    is_response: bool,
) !void {
    var chunk: [RECV_CHUNK_SIZE]u8 = undefined;
    var header_end: ?usize = null;
    var framing: Framing = .{};

    while (true) {
        const r = c.recv(socket, &chunk, chunk.len, 0);
        if (r < 0) return error.RecvFailed;
        if (r == 0) break; // peer closed the connection
        const n: usize = @intCast(r);

        if (out.items.len + n > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
        try out.appendSlice(allocator, chunk[0..n]);

        // Detect end of headers once.
        if (header_end == null) {
            if (std.mem.indexOf(u8, out.items, "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                framing = scanFraming(out.items[0..idx]);
            }
        }

        if (header_end) |he| {
            if (framing.content_length) |body_len| {
                // Bounded by an explicit length — stop once we have it all.
                if (out.items.len >= he + body_len) break;
            } else if (framing.chunked) {
                // Chunked: stop once the zero-length terminating chunk arrives.
                if (std.mem.indexOf(u8, out.items[he - 2 ..], "0\r\n\r\n") != null) break;
            } else if (!is_response) {
                // A request with neither Content-Length nor chunked has no body.
                break;
            }
            // A response with no framing headers is delimited by connection
            // close: keep reading until the peer closes (loop continues).
        }
    }
}

/// Append a synthetic error response into a growable buffer.
fn appendErrorResponse(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), status: u16, reason: []const u8) !void {
    var buf: [256]u8 = undefined;
    const len = buildErrorResponse(&buf, status, reason);
    try out.appendSlice(allocator, buf[0..len]);
}

/// Get current time in nanoseconds using clock_gettime
fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn parseListenAddr(addr_str: []const u8, port: u16) !c.sockaddr.in {
    var ip: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        ip[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (i != 4) return error.InvalidAddress;

    return c.sockaddr.in{
        .family = c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, @as(u32, ip[0]) << 24 | @as(u32, ip[1]) << 16 | @as(u32, ip[2]) << 8 | @as(u32, ip[3])),
    };
}

fn buildErrorResponse(buf: []u8, status: u16, reason: []const u8) usize {
    var builder = Builder.init(buf);

    var response = Response{
        .status_code = status,
        .reason = reason,
        .header_count = 1,
        .body = "",
    };
    response.headers[0] = .{ .name = "Content-Length", .value = "0" };

    builder.writeResponse(&response) catch return 0;
    return builder.pos;
}

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

// =============================================================================
// Tests
// =============================================================================

test {
    // Run all module tests
    _ = http;
    _ = backend;
    _ = router;
    _ = edge;
    _ = loadbalancer;
    _ = middleware;
}

test "proxy server initialization" {
    const allocator = std.testing.allocator;

    var server = ProxyServer.init(allocator, .{});
    defer server.deinit();

    // Create a pool
    const pool = try server.createPool("test");
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8080 });

    // Check pool retrieval
    try std.testing.expect(server.getPool("test") != null);
    try std.testing.expect(server.getPool("nonexistent") == null);
}
