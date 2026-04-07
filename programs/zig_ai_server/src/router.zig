// Router — path-based request dispatch with auth
// Maps incoming requests to handler functions

const std = @import("std");
const http = std.http;

const handlers = @import("handlers.zig");
const auth = @import("auth.zig");
const chat = @import("chat.zig");

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: []const http.Header = &json_headers,
};

const json_headers: [1]http.Header = .{
    .{ .name = "content-type", .value = "application/json" },
};

const cors_json_headers: [4]http.Header = .{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Authorization, Content-Type" },
};

/// Server API key — loaded once from env at startup, passed via ServerState
var server_api_key: ?[]const u8 = null;

pub fn setApiKey(key: []const u8) void {
    server_api_key = key;
}

pub fn dispatch(request: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const target = request.head.target;
    const method = request.head.method;

    // Strip query string for routing
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    // OPTIONS preflight — always allow (no auth)
    if (method == .OPTIONS) {
        return .{
            .status = .no_content,
            .body = "",
            .headers = &cors_json_headers,
        };
    }

    // Health check — no auth required
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        return handlers.health(request, allocator);
    }

    // Root — no auth required
    if (std.mem.eql(u8, path, "/")) {
        return handlers.root(request, allocator);
    }

    // All /qai/v1/* routes require auth
    if (std.mem.startsWith(u8, path, "/qai/v1/")) {
        // Validate auth if server has an API key configured
        if (server_api_key) |key| {
            if (auth.validateRequest(request, key)) |auth_err| {
                return .{
                    .status = auth_err.statusCode(),
                    .body = auth_err.body(),
                };
            }
        }
        return routeApiV1(path[8..], method, request, allocator);
    }

    return handlers.notFound(request, allocator);
}

fn routeApiV1(path: []const u8, method: http.Method, request: *http.Server.Request, allocator: std.mem.Allocator) Response {
    // Chat — POST only
    if (std.mem.eql(u8, path, "chat")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return chat.handle(request, allocator);
    }

    // Models
    if (std.mem.eql(u8, path, "models")) {
        return handlers.modelsPlaceholder(request, allocator);
    }

    // Account balance
    if (std.mem.eql(u8, path, "account/balance")) {
        return handlers.balancePlaceholder(request, allocator);
    }

    return handlers.notFound(request, allocator);
}
