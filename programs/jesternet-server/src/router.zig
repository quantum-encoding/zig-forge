// jesternet-server router — path-based dispatch over jesternet's contract.
//
// Lifted shape from programs/zig_ai_server/src/router.zig:
//   - Response{status, body, headers, handled} struct
//   - The `handled` flag for SSE handoff (handler wrote directly to
//     the stream; main.zig must not call request.respond())
//   - Module-level setter pattern (setStore/setEvents/etc) instead of
//     threading dependencies through every dispatch call
//
// Routes (CONTRACT.md surface, headers per audit caveat #3):
//
//   Layer A — source-adapter shim (Bearer PAT, CORS, JSON):
//     POST /api/source/{method}
//
//   Layer B — smart-HTTP (Bearer/Basic, NO CORS, git-pack content-types):
//     GET  /git/{owner}/{repo}/info/refs
//     POST /git/{owner}/{repo}/git-upload-pack
//     POST /git/{owner}/{repo}/git-receive-pack
//
//   Layer C — REST (Bearer or session, CORS, JSON or SSE):
//     POST /api/prs/{owner}/{name}/open
//     GET  /api/prs/{owner}/{name}/{n}
//     POST /api/prs/{owner}/{name}/{n}/close
//     POST /api/prs/{owner}/{name}/{n}/reopen
//     POST /api/prs/{owner}/{name}/{n}/comment
//     POST /api/prs/{owner}/{name}/{n}/merge
//     GET  /api/notifications/recent
//     POST /api/notifications/seen
//     GET  /api/notifications/stream                (SSE)
//     GET  /api/tokens / POST /api/tokens
//     DELETE /api/tokens/{id}
//     PATCH /api/repos/{owner}/{name}/settings
//
//   Layer C external — lazy commit-diff (Bearer PAT, CORS, JSON):
//     GET  /qai/v1/repos/{owner}/{name}/commit/{sha}/diff
//
//   Misc:
//     GET  /healthz, /health  (no auth)
//     OPTIONS *               (CORS preflight)
//
// All handlers currently return 501-stubs; #61/#62/#64 wire real bodies.

const std = @import("std");
const http = std.http;
const store_mod = @import("store/store.zig");
const pipeline = @import("auth/pipeline.zig");
const notifications = @import("handlers/notifications.zig");
const tokens_handler = @import("handlers/tokens.zig");
const settings = @import("handlers/settings.zig");

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: []const http.Header = &json_no_cors_headers,
    /// True when the handler wrote directly to the stream (SSE).
    /// When true, main.zig skips request.respond().
    handled: bool = false,
};

// ── Header sets ──
// Per audit caveat #3: each route picks its content-type + CORS policy
// explicitly. The AI server's blanket `access-control-allow-origin: *`
// is GONE; main.zig no longer injects anything beyond x-request-id.

const json_no_cors_headers: [2]http.Header = .{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// JSON + CORS for browser-callable Layer A/C endpoints. Used by the
/// source shim, the notifications JSON endpoints, the PR endpoints,
/// the settings endpoint, the token endpoints.
const json_cors_headers: [5]http.Header = .{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, PATCH, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Authorization, Content-Type, Last-Event-ID" },
};

/// SSE headers. `text/event-stream` is the wire content-type git-spec
/// browsers expect; cache-control disables intermediary caching. The
/// router sets these on the SSE response; the handler itself writes
/// directly to the stream (handled=true) so main.zig won't add a body.
const sse_headers: [4]http.Header = .{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache, no-transform" },
    .{ .name = "x-accel-buffering", .value = "no" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};

/// info/refs advertisement for upload-pack (clone). The smart-HTTP
/// spec mandates `application/x-git-{service}-advertisement` exactly —
/// drift here breaks every git client.
const git_upload_pack_advert_headers: [2]http.Header = .{
    .{ .name = "content-type", .value = "application/x-git-upload-pack-advertisement" },
    .{ .name = "cache-control", .value = "no-cache" },
};

/// info/refs advertisement for receive-pack (push).
const git_receive_pack_advert_headers: [2]http.Header = .{
    .{ .name = "content-type", .value = "application/x-git-receive-pack-advertisement" },
    .{ .name = "cache-control", .value = "no-cache" },
};

/// upload-pack result (clone response body).
const git_upload_pack_result_headers: [2]http.Header = .{
    .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
    .{ .name = "cache-control", .value = "no-cache" },
};

/// receive-pack result (push response body).
const git_receive_pack_result_headers: [2]http.Header = .{
    .{ .name = "content-type", .value = "application/x-git-receive-pack-result" },
    .{ .name = "cache-control", .value = "no-cache" },
};

const plain_text_headers: [1]http.Header = .{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

// ── Module-level dependencies (set once at startup) ──
// Setter pattern lifted from zig_ai_server's router. Each setter is
// called from main.zig after the corresponding subsystem is initialized;
// dispatch reads the pointers without further synchronization. The
// pointers are write-once-at-boot, read-after by every request.

/// Server-wide store, set once at boot. Read-only after `setStore`
/// returns — handlers read the pointer, store internals synchronise
/// via the store's parking mutex.
var server_store: ?*store_mod.Store = null;

pub fn setStore(store: *store_mod.Store) void {
    server_store = store;
}

/// Shared handler context. Carries everything Layer C handlers need:
/// per-conn io for store/WAL ops, per-request allocator (arena) for
/// response bodies, the configured store, and the current epoch-ms
/// for auth's expires_at check. Built once per dispatch.
pub const HandlerCtx = struct {
    store: *store_mod.Store,
    io: std.Io,
    allocator: std.mem.Allocator,
    now_ms: i64,
};

// ── Dispatch ──

pub fn dispatch(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) Response {
    _ = environ_map;

    const target = request.head.target;
    const method = request.head.method;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    // Build the handler context once. If the store isn't wired (boot
    // path bug or test harness), every authenticated route fails-
    // closed via the pipeline's 503; unauthed routes (/healthz, /, etc.)
    // still work without a store.
    const ctx: ?HandlerCtx = if (server_store) |store| .{
        .store = store,
        .io = io,
        .allocator = allocator,
        .now_ms = pipeline.nowMs(io),
    } else null;

    // OPTIONS preflight — CORS-aware, no auth.
    if (method == .OPTIONS) {
        return .{ .status = .no_content, .body = "", .headers = &json_cors_headers };
    }

    // Health — no auth, plain text.
    if (std.mem.eql(u8, path, "/healthz") or std.mem.eql(u8, path, "/health")) {
        return .{ .status = .ok, .body = "ok\n", .headers = &plain_text_headers };
    }

    // Root — plain landing for now. Astro frontend would render the
    // marketing landing in a co-deployed setup; the Zig backend's "/"
    // is just a liveness reply.
    if (std.mem.eql(u8, path, "/")) {
        return .{
            .status = .ok,
            .body = "jesternet-server\n",
            .headers = &plain_text_headers,
        };
    }

    // ── Layer A — source-adapter shim ──
    // POST /api/source/{method}
    if (std.mem.startsWith(u8, path, "/api/source/")) {
        if (method != .POST) return methodNotAllowed();
        return notImplemented("Layer A source-adapter shim — task #64");
    }

    // ── Layer B — smart-HTTP ──
    // GET  /git/{owner}/{repo}/info/refs?service=git-{upload,receive}-pack
    // POST /git/{owner}/{repo}/git-upload-pack
    // POST /git/{owner}/{repo}/git-receive-pack
    if (std.mem.startsWith(u8, path, "/git/")) {
        if (std.mem.endsWith(u8, path, "/info/refs")) {
            if (method != .GET) return methodNotAllowed();
            // Choose advertisement headers by service query param.
            const service = parseServiceParam(target);
            const headers: []const http.Header = switch (service) {
                .upload_pack => &git_upload_pack_advert_headers,
                .receive_pack => &git_receive_pack_advert_headers,
                .unknown => &plain_text_headers,
            };
            return .{
                .status = .not_implemented,
                .body = "Layer B info/refs — task #64\n",
                .headers = headers,
            };
        }
        if (std.mem.endsWith(u8, path, "/git-upload-pack")) {
            if (method != .POST) return methodNotAllowed();
            return .{
                .status = .not_implemented,
                .body = "Layer B upload-pack — task #64\n",
                .headers = &git_upload_pack_result_headers,
            };
        }
        if (std.mem.endsWith(u8, path, "/git-receive-pack")) {
            if (method != .POST) return methodNotAllowed();
            return .{
                .status = .not_implemented,
                .body = "Layer B receive-pack — task #64\n",
                .headers = &git_receive_pack_result_headers,
            };
        }
        return notFound();
    }

    // ── Layer C — notifications ──
    if (std.mem.eql(u8, path, "/api/notifications/recent")) {
        if (method != .GET) return methodNotAllowed();
        const c = ctx orelse return serviceUnavailable();
        return notifications.handleRecent(request, c);
    }
    if (std.mem.eql(u8, path, "/api/notifications/seen")) {
        if (method != .POST) return methodNotAllowed();
        const c = ctx orelse return serviceUnavailable();
        return notifications.handleSeen(request, c);
    }
    if (std.mem.eql(u8, path, "/api/notifications/stream")) {
        if (method != .GET) return methodNotAllowed();
        // SSE handler lands in a focused follow-up; the streaming
        // path needs careful poll-loop construction over the WAL
        // primitive. Until then return 501 with SSE-flavored headers
        // so probing clients see the right content-type.
        return .{
            .status = .not_implemented,
            .body = "data: not-implemented\n\n",
            .headers = &sse_headers,
        };
    }

    // ── Layer C — PRs ──
    // /api/prs/{owner}/{name}/...
    if (std.mem.startsWith(u8, path, "/api/prs/")) {
        return notImplemented("PRs — task #64");
    }

    // ── Layer C — tokens ──
    if (std.mem.eql(u8, path, "/api/tokens")) {
        const c = ctx orelse return serviceUnavailable();
        if (method == .GET) return tokens_handler.handleList(request, c);
        if (method == .POST) return tokens_handler.handleMint(request, c);
        return methodNotAllowed();
    }
    if (std.mem.startsWith(u8, path, "/api/tokens/")) {
        if (method != .DELETE) return methodNotAllowed();
        const c = ctx orelse return serviceUnavailable();
        return tokens_handler.handleRevoke(request, c);
    }

    // ── Layer C — repo settings ──
    if (std.mem.startsWith(u8, path, "/api/repos/") and std.mem.endsWith(u8, path, "/settings")) {
        if (method != .PATCH) return methodNotAllowed();
        const c = ctx orelse return serviceUnavailable();
        return settings.handlePatch(request, c);
    }

    // ── Layer C external — lazy commit-diff ──
    if (std.mem.startsWith(u8, path, "/qai/v1/repos/") and std.mem.endsWith(u8, path, "/diff")) {
        if (method != .GET) return methodNotAllowed();
        return notImplemented("lazy commit-diff — task #64");
    }

    return notFound();
}

// ── Stub helpers ──
// All return JSON ErrorResponse shape per CONTRACT §6.6: `{error, message}`.
// This is the audit caveat #3 lesson — the lifted shell's error shape gets
// re-examined at graft time, not inherited. The AI server's `err()` helper
// emitted `{error, kind}`; jesternet-server emits `{error, message}` from
// the start so the two implementations can never drift on this.

const not_implemented_body =
    \\{"error":"not-implemented","message":"This route is a stub — see tasks #61/#62/#64"}
    \\
;

const not_found_body =
    \\{"error":"not-found","message":"No route matches this path"}
    \\
;

const method_not_allowed_body =
    \\{"error":"method-not-allowed","message":"Method not allowed for this path"}
    \\
;

const service_unavailable_body =
    \\{"error":"service-unavailable","message":"Server store not initialised"}
    \\
;

fn notImplemented(comptime _: []const u8) Response {
    return .{
        .status = .not_implemented,
        .body = not_implemented_body,
        .headers = &json_cors_headers,
    };
}

fn notFound() Response {
    return .{
        .status = .not_found,
        .body = not_found_body,
        .headers = &json_cors_headers,
    };
}

fn methodNotAllowed() Response {
    return .{
        .status = .method_not_allowed,
        .body = method_not_allowed_body,
        .headers = &json_cors_headers,
    };
}

fn serviceUnavailable() Response {
    return .{
        .status = .service_unavailable,
        .body = service_unavailable_body,
        .headers = &json_cors_headers,
    };
}

/// Shared JSON+CORS header set, re-exported for handlers in the
/// `handlers/` directory to reuse on their successful-response paths.
/// Avoids each handler redeclaring the same five-header literal.
pub const headers_json_cors = json_cors_headers;

// ── service query param ──
// Smart-HTTP info/refs uses `?service=git-upload-pack` (clone) or
// `?service=git-receive-pack` (push). The response content-type
// depends on which.

const Service = enum { upload_pack, receive_pack, unknown };

fn parseServiceParam(target: []const u8) Service {
    const q_idx = std.mem.indexOfScalar(u8, target, '?') orelse return .unknown;
    const query = target[q_idx + 1 ..];
    var iter = std.mem.tokenizeScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "service=")) {
            const val = pair["service=".len..];
            if (std.mem.eql(u8, val, "git-upload-pack")) return .upload_pack;
            if (std.mem.eql(u8, val, "git-receive-pack")) return .receive_pack;
        }
    }
    return .unknown;
}
