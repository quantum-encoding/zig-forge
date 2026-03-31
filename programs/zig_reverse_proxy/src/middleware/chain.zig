//! Middleware Chain
//!
//! Composable request/response processing pipeline.
//!
//! Middleware can:
//! - Modify requests before forwarding
//! - Modify responses before returning
//! - Short-circuit the chain with an immediate response
//! - Add headers, logging, authentication, etc.

const std = @import("std");
const http = @import("../http/parser.zig");

// =============================================================================
// Middleware Context
// =============================================================================

/// Context passed through the middleware chain
pub const Context = struct {
    /// The incoming request
    request: *http.Request,
    /// Response buffer for building responses
    response_buf: []u8,
    /// Current position in response buffer
    response_len: usize = 0,
    /// Client IP address (for logging/rate limiting)
    client_ip: [4]u8 = .{ 0, 0, 0, 0 },
    /// Request start time (nanoseconds)
    start_time_ns: u64 = 0,
    /// Custom data storage for middleware
    user_data: ?*anyopaque = null,
    /// Whether response has been written
    response_written: bool = false,
    /// Whether to continue chain
    continue_chain: bool = true,

    /// Write an immediate response (short-circuits chain)
    pub fn respond(self: *Context, status: u16, body: []const u8, content_type: []const u8) void {
        var builder = http.Builder.init(self.response_buf);

        var response = http.Response{
            .status_code = status,
            .reason = statusReason(status),
            .header_count = 2,
            .body = body,
            .content_length = body.len,
        };
        response.headers[0] = .{ .name = "Content-Type", .value = content_type };
        response.headers[1] = .{ .name = "Content-Length", .value = "" }; // Will be computed

        builder.writeResponse(&response) catch return;
        self.response_len = builder.pos;
        self.response_written = true;
        self.continue_chain = false;
    }

    /// Add a response header
    pub fn addResponseHeader(self: *Context, name: []const u8, value: []const u8) void {
        _ = self;
        _ = name;
        _ = value;
        // Headers are added during response building
    }

    /// Get elapsed time in microseconds
    pub fn elapsedUs(self: *const Context) u64 {
        const now = getTimeNs();
        return (now - self.start_time_ns) / 1000;
    }
};

// =============================================================================
// Middleware Interface
// =============================================================================

/// Middleware function signature
/// Returns true to continue chain, false to stop
pub const MiddlewareFn = *const fn (*Context) bool;

/// Middleware with pre and post processing
pub const Middleware = struct {
    name: []const u8,
    /// Called before request is forwarded
    pre_request: ?MiddlewareFn = null,
    /// Called after response is received
    post_response: ?MiddlewareFn = null,
    /// Priority (higher = runs first)
    priority: u16 = 100,
};

// =============================================================================
// Middleware Chain
// =============================================================================

pub const MiddlewareChain = struct {
    middlewares: std.ArrayListUnmanaged(Middleware) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MiddlewareChain {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MiddlewareChain) void {
        self.middlewares.deinit(self.allocator);
    }

    /// Add middleware to the chain
    pub fn add(self: *MiddlewareChain, middleware: Middleware) !void {
        try self.middlewares.append(self.allocator, middleware);
        // Sort by priority (descending)
        std.mem.sort(Middleware, self.middlewares.items, {}, struct {
            fn lessThan(_: void, a: Middleware, b: Middleware) bool {
                return a.priority > b.priority;
            }
        }.lessThan);
    }

    /// Run pre-request middleware chain
    pub fn runPreRequest(self: *const MiddlewareChain, ctx: *Context) bool {
        for (self.middlewares.items) |mw| {
            if (mw.pre_request) |handler| {
                if (!handler(ctx)) {
                    return false;
                }
                if (!ctx.continue_chain) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Run post-response middleware chain (reverse order)
    pub fn runPostResponse(self: *const MiddlewareChain, ctx: *Context) void {
        var i: usize = self.middlewares.items.len;
        while (i > 0) {
            i -= 1;
            if (self.middlewares.items[i].post_response) |handler| {
                _ = handler(ctx);
            }
        }
    }
};

// =============================================================================
// Built-in Middleware
// =============================================================================

/// Logging middleware
pub const LoggingMiddleware = struct {
    pub fn preRequest(ctx: *Context) bool {
        ctx.start_time_ns = getTimeNs();
        return true;
    }

    pub fn postResponse(ctx: *Context) bool {
        const elapsed = ctx.elapsedUs();
        std.log.info("{s} {s} - {d}us", .{
            ctx.request.method.toString(),
            ctx.request.path,
            elapsed,
        });
        return true;
    }

    pub fn middleware() Middleware {
        return .{
            .name = "logging",
            .pre_request = preRequest,
            .post_response = postResponse,
            .priority = 200, // Run early
        };
    }
};

/// CORS middleware
pub const CorsMiddleware = struct {
    pub fn preRequest(ctx: *Context) bool {
        // Handle preflight
        if (ctx.request.method == .OPTIONS) {
            ctx.respond(204, "", "text/plain");
            return false;
        }
        return true;
    }

    pub fn middleware() Middleware {
        return .{
            .name = "cors",
            .pre_request = preRequest,
            .priority = 150,
        };
    }
};

/// Rate limiting middleware (placeholder - production would use proper state)
pub const RateLimitMiddleware = struct {
    const max_requests: u32 = 100;

    pub fn preRequest(_: *Context) bool {
        // In production, this would:
        // 1. Track request counts per client IP in a hash map
        // 2. Reset counts periodically based on window
        // 3. Return 429 when limit exceeded
        //
        // For now, always allow requests through
        // A real implementation needs an allocator for the hash map
        return true;
    }

    pub fn middleware() Middleware {
        return .{
            .name = "rate-limit",
            .pre_request = preRequest,
            .priority = 180,
        };
    }
};

/// Security headers middleware
pub const SecurityHeadersMiddleware = struct {
    pub fn postResponse(_: *Context) bool {
        // In a real implementation, would add these headers:
        // X-Content-Type-Options: nosniff
        // X-Frame-Options: DENY
        // X-XSS-Protection: 1; mode=block
        // Strict-Transport-Security: max-age=31536000
        return true;
    }

    pub fn middleware() Middleware {
        return .{
            .name = "security-headers",
            .post_response = postResponse,
            .priority = 50,
        };
    }
};

/// Request ID middleware
pub const RequestIdMiddleware = struct {
    var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    pub fn preRequest(ctx: *Context) bool {
        // Generate request ID
        const id = counter.fetchAdd(1, .monotonic);
        _ = ctx;
        _ = id;
        // Would add X-Request-ID header
        return true;
    }

    pub fn middleware() Middleware {
        return .{
            .name = "request-id",
            .pre_request = preRequest,
            .priority = 190,
        };
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn getTimeNs() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "middleware chain execution" {
    const allocator = std.testing.allocator;

    var chain = MiddlewareChain.init(allocator);
    defer chain.deinit();

    // Add logging middleware
    try chain.add(LoggingMiddleware.middleware());

    var request = http.Request{
        .method = .GET,
        .path = "/test",
    };

    var response_buf: [1024]u8 = undefined;
    var ctx = Context{
        .request = &request,
        .response_buf = &response_buf,
    };

    // Run pre-request
    const should_continue = chain.runPreRequest(&ctx);
    try std.testing.expect(should_continue);
    try std.testing.expect(ctx.start_time_ns > 0);
}

test "middleware short-circuit" {
    const allocator = std.testing.allocator;

    var chain = MiddlewareChain.init(allocator);
    defer chain.deinit();

    // Add CORS middleware that short-circuits OPTIONS
    try chain.add(CorsMiddleware.middleware());

    var request = http.Request{
        .method = .OPTIONS,
        .path = "/api",
    };

    var response_buf: [1024]u8 = undefined;
    var ctx = Context{
        .request = &request,
        .response_buf = &response_buf,
    };

    const should_continue = chain.runPreRequest(&ctx);
    try std.testing.expect(!should_continue);
    try std.testing.expect(ctx.response_written);
}
