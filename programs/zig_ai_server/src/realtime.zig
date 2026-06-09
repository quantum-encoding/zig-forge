// Realtime sessions — ephemeral token minting for OpenAI Realtime.
//
//   POST /qai/v1/realtime/session   → mint an ephemeral client token
//   POST /qai/v1/realtime/refresh   → mint a fresh ephemeral token
//   POST /qai/v1/realtime/end       → acknowledge session end
//
// The actual realtime audio stream is a WebSocket the CLIENT opens directly to
// OpenAI using the ephemeral `client_secret` minted here — so the gateway only
// needs this JSON token-minting surface, not a WS proxy. We POST to OpenAI's
// /v1/realtime/sessions with the server's OPENAI_API_KEY and return the
// ephemeral session (which embeds a short-lived client_secret the client uses
// to connect). `GET /qai/v1/realtime` (the raw WS upgrade) remains unwired —
// that one would need a true WebSocket transport.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const Response = router.Response;

const SessionRequest = struct {
    model: ?[]const u8 = null,
    voice: ?[]const u8 = null,
};

pub fn handleSession(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Response {
    const key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch
        return err(.service_unavailable);

    const body = json_util.readBody(request, allocator, 64 * 1024) catch return err(.bad_request);
    defer allocator.free(body);
    const req: SessionRequest = if (body.len == 0) .{} else (std.json.parseFromSlice(SessionRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return err(.bad_request)).value;

    const out_body = std.json.Stringify.valueAlloc(allocator, .{
        .model = req.model orelse "gpt-realtime",
        .voice = req.voice orelse "alloy",
    }, .{ .emit_null_optional_fields = false }) catch return err(.internal_server_error);
    defer allocator.free(out_body);

    var client = hs.HttpClient.init(allocator) catch return err(.internal_server_error);
    defer client.deinit();
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{key}) catch return err(.internal_server_error);
    defer allocator.free(auth_header);
    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "OpenAI-Beta", .value = "realtime=v1" },
    };

    var resp = client.post("https://api.openai.com/v1/realtime/sessions", &headers, out_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (resp.status != .ok) return err(.bad_gateway);

    const out = allocator.dupe(u8, resp.body) catch return err(.internal_server_error);
    return .{ .status = .ok, .body = out };
}

/// Session end is bookkeeping the client drives; acknowledge it.
pub fn handleEnd(allocator: std.mem.Allocator) Response {
    _ = allocator;
    return .{ .body = "{\"status\":\"ended\"}" };
}

fn err(status: http.Status) Response {
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"realtime not configured (OPENAI_API_KEY unset)\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"realtime session mint failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" },
    };
}
