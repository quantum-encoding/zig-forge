// Router — path-based request dispatch with store-backed auth
// All /qai/v1/* routes go through the auth pipeline.

const std = @import("std");
const http = std.http;

const handlers = @import("handlers.zig");
const auth_pipeline = @import("auth_pipeline.zig");
const chat = @import("chat.zig");
const agent = @import("agent.zig");
const models = @import("models.zig");
const keys = @import("keys.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const bq_mod = @import("bq.zig");
const stream = @import("stream.zig");
const vertex = @import("vertex.zig");
const gcp_mod = @import("gcp.zig");
const apple_auth = @import("apple_auth.zig");
const google_auth = @import("google_auth.zig");

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: []const http.Header = &json_headers,
    /// Set to true when handler wrote directly to the stream (SSE).
    /// When true, main.zig skips request.respond().
    handled: bool = false,
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

/// Server store — set once at startup
var server_store: ?*store_mod.Store = null;

/// Ledger for billing + audit
var server_ledger: ?*ledger_mod.Ledger = null;

/// GCP context for Vertex AI
var server_gcp: ?*gcp_mod.GcpContext = null;

/// BigQuery audit logger
var server_bq: ?*bq_mod.BqAudit = null;

/// Legacy single-key mode (deprecated — use store-backed auth)
var legacy_api_key: ?[]const u8 = null;

pub fn setStore(store: *store_mod.Store) void {
    server_store = store;
}

pub fn setLedger(ledger: *ledger_mod.Ledger) void {
    server_ledger = ledger;
}

pub fn setGcpContext(ctx: *gcp_mod.GcpContext) void {
    server_gcp = ctx;
}

pub fn setBqAudit(bq: *bq_mod.BqAudit) void {
    server_bq = bq;
}

pub fn setApiKey(key: []const u8) void {
    legacy_api_key = key;
}

pub fn dispatch(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) Response {
    const target = request.head.target;
    const method = request.head.method;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    // OPTIONS preflight — no auth
    if (method == .OPTIONS) {
        return .{ .status = .no_content, .body = "", .headers = &cors_json_headers };
    }

    // Health — no auth
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        return handlers.health(request, allocator);
    }

    // Root — no auth
    if (std.mem.eql(u8, path, "/")) {
        return handlers.root(request, allocator);
    }

    // Auth endpoints — NO auth required (they ARE the auth entry point)
    if (std.mem.eql(u8, path, "/qai/v1/auth/apple")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return apple_auth.handle(request, allocator, io, server_store, server_gcp);
    }
    if (std.mem.eql(u8, path, "/qai/v1/auth/google")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return google_auth.handle(request, allocator, io, server_store, server_gcp);
    }

    // All other /qai/v1/* routes require auth
    if (std.mem.startsWith(u8, path, "/qai/v1/")) {
        // Authenticate via store or legacy mode
        if (server_store) |store| {
            const auth_result = auth_pipeline.authenticate(request, store);
            switch (auth_result) {
                .ok => |auth| return routeApiV1Authed(path[8..], method, request, allocator, io, environ_map, store, &auth),
                .err => |auth_err| return .{ .status = auth_err.status, .body = auth_err.body },
            }
        } else if (legacy_api_key) |key| {
            // Legacy: single env var auth
            const auth_mod = @import("auth.zig");
            if (auth_mod.validateRequest(request, key)) |auth_err| {
                return .{ .status = auth_err.statusCode(), .body = auth_err.body() };
            }
            return routeApiV1Legacy(path[8..], method, request, allocator, io, environ_map);
        } else {
            // No auth configured — open access (dev mode)
            return routeApiV1Legacy(path[8..], method, request, allocator, io, environ_map);
        }
    }

    return handlers.notFound(request, allocator);
}

/// Routes with full store-backed auth context
fn routeApiV1Authed(
    path: []const u8,
    method: http.Method,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    store: *store_mod.Store,
    auth: *const types.AuthContext,
) Response {
    // ── Chat ────────────────────────────────────────────
    // Same endpoint handles both streaming and non-streaming (OpenAI convention).
    // If "stream":true in the JSON body, route to SSE handler.
    // /qai/v1/chat/stream is also supported as an explicit streaming path.
    if (std.mem.eql(u8, path, "chat") or std.mem.eql(u8, path, "chat/stream")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);

        const force_stream = std.mem.eql(u8, path, "chat/stream");

        if (force_stream) {
            // Explicit streaming path — handler reads its own body
            stream.handleStream(request, allocator, environ_map, io, store, auth, server_ledger);
            return .{ .handled = true };
        }

        // Read body once, check for "stream":true, route accordingly
        const json_util = @import("json.zig");
        const security = @import("security.zig");
        const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
            return .{ .status = .bad_request, .body =
                \\{"error":"invalid_request","message":"Failed to read request body"}
            };
        };

        const is_stream = std.mem.indexOf(u8, body, "\"stream\":true") != null or
            std.mem.indexOf(u8, body, "\"stream\": true") != null;

        if (is_stream) {
            // Check model route — Vertex models need vertex.handleStream
            const model_route = extractModelRoute(body, allocator);
            switch (model_route) {
                .vertex_maas, .vertex_native, .vertex_dedicated => {
                    vertex.handleStream(request, allocator, server_gcp, store, auth, io, server_ledger, environ_map);
                    allocator.free(body);
                    return .{ .handled = true };
                },
                else => {
                    stream.handleStreamWithBody(request, allocator, environ_map, io, store, auth, server_ledger, body);
                    allocator.free(body);
                    return .{ .handled = true };
                },
            }
        }

        const result = chat.handleWithBody(request, allocator, environ_map, io, store, auth, server_ledger, server_gcp, body);
        allocator.free(body);
        return result;
    }

    // ── Vertex AI (MaaS gateway — Gemini, DeepSeek, GLM-5, Qwen, Gemma 4, Codestral) ──
    if (std.mem.eql(u8, path, "vertex/chat")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return vertex.handle(request, allocator, server_gcp, store, auth, io, server_ledger, environ_map);
    }
    if (std.mem.eql(u8, path, "vertex/chat/stream")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        vertex.handleStream(request, allocator, server_gcp, store, auth, io, server_ledger, environ_map);
        return .{ .handled = true };
    }

    // ── Agent ───────────────────────────────────────────
    if (std.mem.eql(u8, path, "agent")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return agent.handle(request, allocator, io, environ_map);
    }

    // ── Models ──────────────────────────────────────────
    if (std.mem.eql(u8, path, "models")) {
        return models.handleModels(request, allocator);
    }
    if (std.mem.eql(u8, path, "models/pricing")) {
        return models.handlePricing(request, allocator);
    }

    // ── Account Balance ─────────────────────────────────
    if (std.mem.eql(u8, path, "account/balance")) {
        return handleAccountBalance(allocator, auth);
    }

    // ── Key Management (admin) ──────────────────────────
    if (std.mem.eql(u8, path, "keys")) {
        if (method == .POST) return keys.handleCreateKey(request, allocator, io, store, auth);
        if (method == .GET) return keys.handleListKeys(request, allocator, store, auth);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "keys/")) {
        if (method == .DELETE) {
            const prefix = path[5..];
            return keys.handleRevokeKey(request, allocator, io, store, auth, prefix);
        }
        return handlers.methodNotAllowed(request, allocator);
    }

    // ── Admin: Account Management ───────────────────────
    if (std.mem.eql(u8, path, "admin/accounts")) {
        if (method == .POST) return keys.handleCreateAccount(request, allocator, io, store, auth);
        if (method == .GET) return keys.handleListAccounts(request, allocator, store, auth);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "admin/accounts/")) {
        const after_prefix = path[15..]; // after "admin/accounts/"

        // Routes with sub-path: {id}/credit, {id}/freeze, {id}/tier
        if (std.mem.indexOf(u8, after_prefix, "/")) |slash_pos| {
            const account_id = after_prefix[0..slash_pos];
            const action = after_prefix[slash_pos + 1 ..];

            if (method != .POST) return handlers.methodNotAllowed(request, allocator);

            if (std.mem.eql(u8, action, "credit")) {
                return keys.handleCreditAccount(request, allocator, io, store, auth, account_id, server_ledger);
            }
            if (std.mem.eql(u8, action, "freeze")) {
                return keys.handleFreezeAccount(request, allocator, store, auth, account_id);
            }
            if (std.mem.eql(u8, action, "tier")) {
                return keys.handleSetTier(request, allocator, store, auth, account_id);
            }
            return handlers.notFound(request, allocator);
        }

        // Route: admin/accounts/{id} (GET single account)
        if (method == .GET) {
            return keys.handleGetAccount(request, allocator, store, auth, after_prefix);
        }
        return handlers.methodNotAllowed(request, allocator);
    }

    // ── Admin: Dedicated Endpoints ─────────────────────
    if (std.mem.eql(u8, path, "admin/endpoints")) {
        if (method == .POST) return vertex.handleRegisterEndpoint(request, allocator, auth);
        if (method == .GET) return vertex.handleListEndpoints(request, allocator, auth);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "admin/endpoints/")) {
        if (method == .DELETE) {
            const model_name = path[16..]; // after "admin/endpoints/"
            return vertex.handleRemoveEndpoint(request, allocator, auth, model_name);
        }
        return handlers.methodNotAllowed(request, allocator);
    }

    // ── Stubs for unimplemented endpoints ───────────────
    if (std.mem.eql(u8, path, "chat/session")) return handlers.stub(request, allocator, "POST /qai/v1/chat/session");
    if (std.mem.eql(u8, path, "search/web")) return handlers.stub(request, allocator, "POST /qai/v1/search/web");
    if (std.mem.eql(u8, path, "search/context")) return handlers.stub(request, allocator, "POST /qai/v1/search/context");
    if (std.mem.eql(u8, path, "search/answer")) return handlers.stub(request, allocator, "POST /qai/v1/search/answer");
    if (std.mem.eql(u8, path, "images/generate")) return handlers.stub(request, allocator, "POST /qai/v1/images/generate");
    if (std.mem.eql(u8, path, "images/edit")) return handlers.stub(request, allocator, "POST /qai/v1/images/edit");
    if (std.mem.startsWith(u8, path, "audio/")) return handlers.stub(request, allocator, "/qai/v1/audio/*");
    if (std.mem.startsWith(u8, path, "video/")) return handlers.stub(request, allocator, "/qai/v1/video/*");
    if (std.mem.eql(u8, path, "embeddings")) return handlers.stub(request, allocator, "POST /qai/v1/embeddings");
    if (std.mem.startsWith(u8, path, "rag/")) return handlers.stub(request, allocator, "/qai/v1/rag/*");
    if (std.mem.eql(u8, path, "missions")) return handlers.stub(request, allocator, "POST /qai/v1/missions");
    if (std.mem.startsWith(u8, path, "3d/")) return handlers.stub(request, allocator, "/qai/v1/3d/*");
    if (std.mem.startsWith(u8, path, "compute/")) return handlers.stub(request, allocator, "/qai/v1/compute/*");
    if (std.mem.eql(u8, path, "voices") or std.mem.eql(u8, path, "voices/library")) return handlers.stub(request, allocator, "GET /qai/v1/voices");
    if (std.mem.eql(u8, path, "jobs") or std.mem.startsWith(u8, path, "jobs/")) return handlers.stub(request, allocator, "/qai/v1/jobs");
    if (std.mem.eql(u8, path, "batch")) return handlers.stub(request, allocator, "POST /qai/v1/batch");

    return handlers.notFound(request, allocator);
}

/// Legacy routes (no store, no per-user auth)
fn routeApiV1Legacy(
    path: []const u8,
    method: http.Method,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) Response {
    if (std.mem.eql(u8, path, "chat")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return chat.handle(request, allocator, environ_map, null, null, null, null, server_gcp);
    }
    if (std.mem.eql(u8, path, "agent")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return agent.handle(request, allocator, io, environ_map);
    }
    if (std.mem.eql(u8, path, "models")) return models.handleModels(request, allocator);
    if (std.mem.eql(u8, path, "models/pricing")) return models.handlePricing(request, allocator);
    return handlers.stub(request, allocator, path);
}

/// Per-account balance using store data
fn handleAccountBalance(allocator: std.mem.Allocator, auth: *const types.AuthContext) Response {
    const ticks_per_usd: i64 = 10_000_000_000;
    const balance = auth.account.balance_ticks;
    const spent = auth.key.spent_ticks;

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"balance_ticks":{d},"spent_ticks":{d},"ticks_per_usd":{d},"account_id":"{s}","tier":"{s}"}}
    , .{ balance, spent, ticks_per_usd, auth.account.id.slice(), auth.account.tier.toString() }) catch
        \\{"error":"internal"}
    };
}

/// Extract model name from JSON body and resolve its route.
/// Quick string scan — avoids full JSON parse just for routing.
fn extractModelRoute(body: []const u8, allocator: std.mem.Allocator) models.Route {
    // Find "model":"<value>" in the JSON body
    const needle = "\"model\":\"";
    const start = (std.mem.indexOf(u8, body, needle) orelse return .unknown) + needle.len;
    const remaining = body[start..];
    const end = std.mem.indexOfScalar(u8, remaining, '"') orelse return .unknown;
    const model_name = remaining[0..end];
    _ = allocator;
    return models.getRoute(model_name);
}
