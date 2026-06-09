// Generic authenticated reverse-proxy for external in-house services.
//
// Several gateway routes forward to separate in-house services (the Axiom
// document service, the scraper service, the SurrealDB RAG service). Each
// upstream's base URL + optional auth key come from env vars, so production
// (Cloud Run, where they're set) forwards the call, while an unconfigured
// environment returns 503 instead of guessing an endpoint. The request body
// is passed through verbatim and the upstream response is returned as-is.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const security = @import("security.zig");
const Response = router.Response;

const MAX_PROXY_BODY: usize = 16 * 1024 * 1024;

/// Forward a POST: read the client body, POST it to `<base_env>``upstream_path`
/// with an optional `Authorization: Bearer <key_env>`, return the response.
pub fn post(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    base_env: []const u8,
    key_env: []const u8,
    upstream_path: []const u8,
) Response {
    const base = hs.ai.getApiKeyFromEnv(environ_map, base_env) catch return unavailable();
    const body = json_util.readBody(request, allocator, MAX_PROXY_BODY) catch return errResp();
    defer allocator.free(body);
    return forward(allocator, environ_map, base, key_env, upstream_path, body);
}

/// Forward a GET (no request body).
pub fn get(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    base_env: []const u8,
    key_env: []const u8,
    upstream_path: []const u8,
) Response {
    const base = hs.ai.getApiKeyFromEnv(environ_map, base_env) catch return unavailable();

    var client = hs.HttpClient.init(allocator) catch return errResp();
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, upstream_path }) catch return errResp();
    defer allocator.free(url);

    var auth_buf: ?[]u8 = null;
    defer if (auth_buf) |b| allocator.free(b);
    const headers = buildHeaders(allocator, environ_map, key_env, &auth_buf);

    var resp = client.get(url, headers) catch return badGateway();
    defer resp.deinit();
    const out = allocator.dupe(u8, resp.body) catch return errResp();
    return .{ .status = resp.status, .body = out };
}

fn forward(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    base: []const u8,
    key_env: []const u8,
    upstream_path: []const u8,
    body: []const u8,
) Response {
    var client = hs.HttpClient.init(allocator) catch return errResp();
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, upstream_path }) catch return errResp();
    defer allocator.free(url);

    var auth_buf: ?[]u8 = null;
    defer if (auth_buf) |b| allocator.free(b);
    const headers = buildHeaders(allocator, environ_map, key_env, &auth_buf);

    var resp = client.post(url, headers, body) catch return badGateway();
    defer resp.deinit();
    const out = allocator.dupe(u8, resp.body) catch return errResp();
    return .{ .status = resp.status, .body = out };
}

/// Build request headers: always Content-Type/Accept JSON, plus a Bearer auth
/// header when the upstream's key env var is set. Returns a slice into a small
/// static-lifetime pattern: we stash the alloc'd auth header in `auth_buf` so
/// the caller frees it; the header array is returned by value via a thread-
/// local-free trick — here we just always include the auth slot when present.
fn buildHeaders(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    key_env: []const u8,
    auth_buf: *?[]u8,
) []const http.Header {
    if (hs.ai.getApiKeyFromEnv(environ_map, key_env) catch null) |key| {
        const h = std.fmt.allocPrint(allocator, "Bearer {s}", .{key}) catch return base_headers[0..];
        auth_buf.* = h;
        headers_with_auth = .{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Authorization", .value = h },
        };
        return headers_with_auth[0..];
    }
    return base_headers[0..];
}

// Header storage. NOTE: single-threaded-per-call use — these module globals
// are written then immediately read within one handler invocation on one
// worker thread. Each connection handler runs on its own thread and calls the
// proxy at most once per request before reading the result, so there is no
// cross-call aliasing in practice. (If that ever changes, move these into a
// caller-provided buffer.)
var base_headers = [_]http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Accept", .value = "application/json" },
};
threadlocal var headers_with_auth: [3]http.Header = undefined;

fn unavailable() Response {
    return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"upstream service not configured\"}" };
}
fn badGateway() Response {
    return .{ .status = .bad_gateway, .body = "{\"error\":\"upstream_error\",\"message\":\"upstream service request failed\"}" };
}
fn errResp() Response {
    return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"proxy request failed\"}" };
}
