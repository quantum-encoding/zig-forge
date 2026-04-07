// Router — path-based request dispatch with auth
// Full /qai/v1/* endpoint map matching quantum-sdk contract

const std = @import("std");
const http = std.http;

const handlers = @import("handlers.zig");
const auth = @import("auth.zig");
const chat = @import("chat.zig");
const models = @import("models.zig");
const account = @import("account.zig");
const agent = @import("agent.zig");

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

/// Server API key — loaded once from env at startup
var server_api_key: ?[]const u8 = null;

pub fn setApiKey(key: []const u8) void {
    server_api_key = key;
}

pub fn dispatch(request: *http.Server.Request, allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) Response {
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
        if (server_api_key) |key| {
            if (auth.validateRequest(request, key)) |auth_err| {
                return .{
                    .status = auth_err.statusCode(),
                    .body = auth_err.body(),
                };
            }
        }
        return routeApiV1(path[8..], method, request, allocator, io, environ_map);
    }

    return handlers.notFound(request, allocator);
}

fn routeApiV1(path: []const u8, method: http.Method, request: *http.Server.Request, allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) Response {
    // ── Text Generation ─────────────────────────────────────
    if (std.mem.eql(u8, path, "chat")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return chat.handle(request, allocator, environ_map);
    }
    if (std.mem.eql(u8, path, "chat/session")) {
        return handlers.stub(request, allocator, "POST /qai/v1/chat/session");
    }

    // ── Models & Pricing ────────────────────────────────────
    if (std.mem.eql(u8, path, "models")) {
        return models.handleModels(request, allocator);
    }
    if (std.mem.eql(u8, path, "models/pricing")) {
        return models.handlePricing(request, allocator);
    }

    // ── Account ─────────────────────────────────────────────
    if (std.mem.eql(u8, path, "account/balance")) {
        return account.handleBalance(request, allocator);
    }

    // ── Search ──────────────────────────────────────────────
    if (std.mem.eql(u8, path, "search/web")) {
        return handlers.stub(request, allocator, "POST /qai/v1/search/web");
    }
    if (std.mem.eql(u8, path, "search/context")) {
        return handlers.stub(request, allocator, "POST /qai/v1/search/context");
    }
    if (std.mem.eql(u8, path, "search/answer")) {
        return handlers.stub(request, allocator, "POST /qai/v1/search/answer");
    }

    // ── Images ──────────────────────────────────────────────
    if (std.mem.eql(u8, path, "images/generate")) {
        return handlers.stub(request, allocator, "POST /qai/v1/images/generate");
    }
    if (std.mem.eql(u8, path, "images/edit")) {
        return handlers.stub(request, allocator, "POST /qai/v1/images/edit");
    }

    // ── Audio ───────────────────────────────────────────────
    if (std.mem.eql(u8, path, "audio/tts")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/tts");
    }
    if (std.mem.eql(u8, path, "audio/stt")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/stt");
    }
    if (std.mem.eql(u8, path, "audio/music")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/music");
    }
    if (std.mem.eql(u8, path, "audio/sound-effects")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/sound-effects");
    }
    if (std.mem.eql(u8, path, "audio/dialogue")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/dialogue");
    }
    if (std.mem.eql(u8, path, "audio/dub")) {
        return handlers.stub(request, allocator, "POST /qai/v1/audio/dub");
    }

    // ── Video ───────────────────────────────────────────────
    if (std.mem.eql(u8, path, "video/generate")) {
        return handlers.stub(request, allocator, "POST /qai/v1/video/generate");
    }
    if (std.mem.eql(u8, path, "video/studio")) {
        return handlers.stub(request, allocator, "POST /qai/v1/video/studio");
    }
    if (std.mem.eql(u8, path, "video/translate")) {
        return handlers.stub(request, allocator, "POST /qai/v1/video/translate");
    }
    if (std.mem.eql(u8, path, "video/avatars")) {
        return handlers.stub(request, allocator, "GET /qai/v1/video/avatars");
    }

    // ── Embeddings ──────────────────────────────────────────
    if (std.mem.eql(u8, path, "embeddings")) {
        return handlers.stub(request, allocator, "POST /qai/v1/embeddings");
    }

    // ── RAG ─────────────────────────────────────────────────
    if (std.mem.eql(u8, path, "rag/search")) {
        return handlers.stub(request, allocator, "POST /qai/v1/rag/search");
    }
    if (std.mem.eql(u8, path, "rag/surreal/search")) {
        return handlers.stub(request, allocator, "POST /qai/v1/rag/surreal/search");
    }

    // ── Agents & Missions ───────────────────────────────────
    if (std.mem.eql(u8, path, "agent")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return agent.handle(request, allocator, io, environ_map);
    }
    if (std.mem.eql(u8, path, "missions")) {
        return handlers.stub(request, allocator, "POST /qai/v1/missions");
    }

    // ── 3D / Mesh ───────────────────────────────────────────
    if (std.mem.startsWith(u8, path, "3d/")) {
        return handlers.stub(request, allocator, "POST /qai/v1/3d/*");
    }

    // ── Compute (Vertex MaaS) ───────────────────────────────
    if (std.mem.startsWith(u8, path, "compute/")) {
        return handlers.stub(request, allocator, "/qai/v1/compute/*");
    }

    // ── Voices ──────────────────────────────────────────────
    if (std.mem.eql(u8, path, "voices") or std.mem.eql(u8, path, "voices/library")) {
        return handlers.stub(request, allocator, "GET /qai/v1/voices");
    }

    // ── Jobs ────────────────────────────────────────────────
    if (std.mem.eql(u8, path, "jobs") or std.mem.startsWith(u8, path, "jobs/")) {
        return handlers.stub(request, allocator, "/qai/v1/jobs");
    }

    // ── Batch ───────────────────────────────────────────────
    if (std.mem.eql(u8, path, "batch")) {
        return handlers.stub(request, allocator, "POST /qai/v1/batch");
    }

    // ── Keys ────────────────────────────────────────────────
    if (std.mem.eql(u8, path, "keys")) {
        return handlers.stub(request, allocator, "/qai/v1/keys");
    }

    return handlers.notFound(request, allocator);
}
