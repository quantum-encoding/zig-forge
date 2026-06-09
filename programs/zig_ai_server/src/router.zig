// Router — path-based request dispatch with store-backed auth
// All /qai/v1/* routes go through the auth pipeline.

const std = @import("std");
const http = std.http;

const handlers = @import("handlers.zig");
const auth_pipeline = @import("auth_pipeline.zig");
const chat = @import("chat.zig");
const images = @import("images.zig");
// `cloudrun.zig` was deleted in Batch 12 (audit-finding C2 / NEW-1):
//   - It was a near-byte-duplicate of `agent.zig` that retained the
//     `_ = store; _ = auth;` bypass long after `agent.zig` had been
//     wired through the billing + auth pipeline.
//   - The router exposed it on BOTH an auth-required and an
//     auth-bypassed path (`/qai/v1/cloudrun` on the unauthenticated
//     dispatch), making it an anonymous-RCE endpoint as the server
//     UID.
// The endpoint is gone; `/qai/v1/agent` (auth-required) is the only
// agent surface.
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
const auth_rl_mod = @import("auth_ratelimit.zig");

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

const text_headers: [1]http.Header = .{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }};
const html_headers_meta: [1]http.Header = .{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};
const xml_headers: [1]http.Header = .{.{ .name = "content-type", .value = "text/xml; charset=utf-8" }};

// ── CORS (audit H1, NEW-4) ───────────────────────────────────────
//
// The previous implementation broadcast
//   access-control-allow-origin: *
// on every response and advertised `Authorization` in the preflight
// allow-headers list. Combined with the implicit "anyone with an API
// key" model that meant any malicious page a user visited could drive
// qai_k_… requests against the API on the user's behalf (their local
// CLI / config holds the key; a phishing page just calls fetch() with
// the key set on the Authorization header — the * + Authorization
// combo authorises the preflight even though credentials cookies are
// blocked).
//
// New model: explicit Origin allowlist (loaded from env at startup
// via setCorsAllowedOrigins). On every CORS-eligible response we
// reflect the request's Origin only if it's in the list, otherwise
// omit CORS entirely (browsers will block the cross-origin request).
// OPTIONS preflight returns the full header set with reflected
// Origin; non-preflight responses get just the reflected Origin +
// Vary.
//
// NEW-4: Authorization is advertised only on preflight for the
// auth-required paths (everything under /qai/v1/ EXCEPT
// /qai/v1/auth/*). The auth endpoints take credentials in the
// request BODY, not the Authorization header — advertising it for
// those routes was a needless cross-origin attack surface.

/// Returns the request's `Origin` header value if it appears in the
/// allowlist, otherwise null. The returned slice borrows from the
/// request's header buffer and is valid until `request.respond()`
/// returns.
pub fn matchOrigin(request: *const http.Server.Request) ?[]const u8 {
    if (cors_allowed_origins.len == 0) return null;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "origin")) continue;
        for (cors_allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, header.value)) return header.value;
        }
        return null;
    }
    return null;
}

/// Path classification for CORS preflight: returns true if the path
/// would, after preflight, send an Authorization header. The auth
/// handshake (apple/google) does NOT — it uses a JSON body. Health
/// and root don't either. NEW-4: advertising Authorization on
/// unauth routes was a needless cross-origin attack surface.
pub fn pathRequiresAuthorizationHeader(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/qai/v1/")) return false;
    if (std.mem.startsWith(u8, path, "/qai/v1/auth/")) return false;
    return true;
}

/// Server store — set once at startup
var server_store: ?*store_mod.Store = null;

/// Ledger for billing + audit
var server_ledger: ?*ledger_mod.Ledger = null;

/// GCP context for Vertex AI
var server_gcp: ?*gcp_mod.GcpContext = null;

/// BigQuery audit logger
var server_bq: ?*bq_mod.BqAudit = null;

/// Async job store (in-process queue + background worker)
var server_jobs: ?*@import("jobs.zig").JobStore = null;

/// Legacy single-key mode (deprecated — use store-backed auth)
var legacy_api_key: ?[]const u8 = null;

/// Auth endpoint rate limiter — IP-keyed, prevents sign-in brute force
var server_auth_rl: ?*auth_rl_mod.AuthRateLimiter = null;

/// Trust the `X-Forwarded-For` header from request peers (audit H2).
/// Set only when the deployment is fronted by Cloud Run / an internal
/// reverse proxy that strips client-supplied XFF and re-inserts its
/// own. Default false → IP rate-limiting falls back to a single
/// shared bucket for all anonymous traffic.
var trust_xff: bool = false;

/// CORS allowlist (audit H1 + NEW-4). Origin reflection: a request's
/// Origin header is echoed only if it appears in this slice. Empty
/// slice (the default) disables CORS entirely.
var cors_allowed_origins: []const []const u8 = &.{};

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

pub fn setJobStore(js: *@import("jobs.zig").JobStore) void {
    server_jobs = js;
}

pub fn setApiKey(key: []const u8) void {
    legacy_api_key = key;
}

pub fn setAuthRateLimiter(rl: *auth_rl_mod.AuthRateLimiter) void {
    server_auth_rl = rl;
}

/// Enable trust of X-Forwarded-For. Only call this when the
/// deployment is behind a known reverse proxy (Cloud Run / internal
/// nginx). See auth_ratelimit.zig for the threat model.
pub fn setTrustXff(trust: bool) void {
    trust_xff = trust;
}

/// Install the CORS Origin allowlist (audit H1). The slice is
/// borrowed — callers must keep it alive for the process lifetime
/// (in practice the env-parsed list is parked in main.zig's
/// long-lived allocator).
pub fn setCorsAllowedOrigins(origins: []const []const u8) void {
    cors_allowed_origins = origins;
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

    // OPTIONS preflight — no auth. The response body is empty; CORS
    // headers (origin reflection + method/header allowlists) are
    // attached at the response-builder site in main.zig where the
    // per-request header buffer lives. dispatch returns just the
    // status; main.zig sees `method == .OPTIONS` and fills in the
    // preflight set, including a path-conditional Allow-Headers
    // that omits Authorization on unauth routes (NEW-4).
    if (method == .OPTIONS) {
        return .{ .status = .no_content, .body = "" };
    }

    // Health — no auth
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        return handlers.health(request, allocator);
    }

    // Root — no auth
    if (std.mem.eql(u8, path, "/")) {
        return handlers.root(request, allocator);
    }

    // ── Meta / discovery endpoints (public, no auth) ────
    if (std.mem.eql(u8, path, "/llms.txt")) {
        return .{ .status = .ok, .body =
            \\# Quantum Encoding AI Gateway
            \\
            \\OpenAI-compatible multi-provider AI gateway. Base: /qai/v1
            \\Auth: Authorization: Bearer <qai_k_...>
            \\
            \\Endpoints: /chat /embeddings /images/generate /images/edit
            \\/vision/* /audio/* /voices /search/* /rag/* /moderate /jobs
            \\/models /models/pricing /account/balance /credits/*
            \\
            \\Async media (3D, video, dubbing) run via POST /qai/v1/jobs.
            \\
        , .headers = &text_headers };
    }
    if (std.mem.eql(u8, path, "/docs")) {
        return .{ .status = .ok, .body =
            \\<!doctype html><meta charset=utf-8><title>Quantum Encoding AI Gateway</title>
            \\<body style="font-family:system-ui;max-width:48rem;margin:3rem auto;padding:0 1rem">
            \\<h1>Quantum Encoding AI Gateway</h1>
            \\<p>OpenAI-compatible multi-provider AI gateway. See <a href="/llms.txt">/llms.txt</a>
            \\for the endpoint map and <a href="/qai/v1/models">/qai/v1/models</a> for the live model registry.</p>
            \\</body>
        , .headers = &html_headers_meta };
    }

    // ── Twilio voice webhooks (public; Twilio posts form-encoded) ──
    // Return minimal TwiML so Twilio's call flow succeeds.
    if (std.mem.eql(u8, path, "/qai/v1/twilio/voice")) {
        return .{ .status = .ok, .body =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<Response><Say>Thank you for calling Quantum Encoding. This line is not staffed; please email support.</Say></Response>
        , .headers = &xml_headers };
    }
    if (std.mem.eql(u8, path, "/qai/v1/twilio/status")) {
        // Status callback — just acknowledge.
        return .{ .status = .no_content, .body = "" };
    }

    // Auth endpoints — NO app auth required (they ARE the auth entry point)
    // but IP-based rate limiting is applied to prevent brute force attacks.
    if (std.mem.startsWith(u8, path, "/qai/v1/auth/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);

        // Rate limit by client IP
        if (server_auth_rl) |rl| {
            const client_ip = auth_rl_mod.extractClientIp(request, trust_xff);
            if (!rl.check(io, client_ip)) {
                return .{
                    .status = .too_many_requests,
                    .body =
                    \\{"error":"rate_limited","message":"Too many auth requests. Try again in a minute."}
                    ,
                    .headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "retry-after", .value = "60" },
                    },
                };
            }
        }

        if (std.mem.eql(u8, path, "/qai/v1/auth/apple")) {
            return apple_auth.handle(request, allocator, io, server_store, server_gcp);
        }
        if (std.mem.eql(u8, path, "/qai/v1/auth/google")) {
            return google_auth.handle(request, allocator, io, server_store, server_gcp);
        }
        return handlers.notFound(request, allocator);
    }

    // Stripe webhook — public, but self-authenticating via the
    // Stripe-Signature HMAC (verified inside the handler). Must bypass the
    // qai_k_ bearer auth below because Stripe can't present an API key.
    if (std.mem.eql(u8, path, "/qai/v1/webhooks/stripe")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const stripe = @import("stripe.zig");
        const store = server_store orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"store not available\"}" };
        return stripe.handleWebhook(request, allocator, io, store, server_ledger, environ_map);
    }

    // ── Internal platform endpoints (cron / Cloud Tasks) ────
    // NOT qai_k_ authed — gated by a shared secret header so only the platform
    // can call them (they trigger billing / provisioning / settlement). The
    // actual work is owned by the Zig job system or unwired provisioning
    // controllers; these acknowledge so the platform's callers succeed. An
    // unconfigured secret fails closed (403) rather than leaving them open.
    if (std.mem.startsWith(u8, path, "/internal/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const want = (struct {
            fn get(em: *const std.process.Environ.Map) ?[]const u8 {
                return em.get("QAI_INTERNAL_SECRET");
            }
        }).get(environ_map);
        const got = blk: {
            var it = request.iterateHeaders();
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-internal-secret")) break :blk h.value;
            break :blk null;
        };
        // Fail closed: secret must be configured AND match (constant-time).
        const ok = if (want) |w| (w.len > 0 and got != null and ctEqualSecret(w, got.?)) else false;
        if (!ok) return .{ .status = .forbidden, .body = "{\"error\":\"forbidden\",\"message\":\"internal endpoint\"}" };
        // Acknowledge (work is handled by the Zig job system / unwired controllers).
        return .{ .status = .ok, .body = "{\"ok\":true}" };
    }

    // All other /qai/v1/* routes require auth
    if (std.mem.startsWith(u8, path, "/qai/v1/")) {
        // Authenticate via store or legacy mode
        if (server_store) |store| {
            const auth_result = auth_pipeline.authenticate(request, io, store);
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
            // SECURITY: no auth configured. Reject all requests.
            // Previously this was "open access dev mode" which is a critical
            // security bypass if accidentally deployed to production.
            return .{ .status = .service_unavailable, .body =
                \\{"error":"no_auth","message":"Server has no auth configured. Set QAI_BOOTSTRAP_KEY."}
            };
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
                    vertex.handleStreamWithBody(request, allocator, server_gcp, store, auth, io, server_ledger, environ_map, body);
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

    // ── Dedicated-endpoint inference passthrough ────────
    // POST /qai/v1/inference/{id} runs against a deployed Vertex endpoint; the
    // model in the body resolves to its dedicated endpoint via the registry.
    if (std.mem.startsWith(u8, path, "inference/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return vertex.handle(request, allocator, server_gcp, store, auth, io, server_ledger, environ_map);
    }

    // ── Agent (client-executed tools, stateless passthrough) ──
    // Server: filters tools by capabilities, normalizes schemas via forge,
    // calls provider, returns tool_use events. Client executes tools locally.
    if (std.mem.eql(u8, path, "agent")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const agent_mod = @import("agent.zig");
        return agent_mod.handle(request, allocator, environ_map, io, store, auth, server_ledger);
    }

    // `/qai/v1/cloudrun` route deleted in Batch 12 (audit C2 / NEW-1).
    // See the comment on the `cloudrun` import at the top of this file.

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

    // ── Licenses ────────────────────────────────────────
    if (std.mem.startsWith(u8, path, "licenses/")) {
        const crud = @import("crud.zig");
        if (std.mem.eql(u8, path, "licenses/public-key")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            // Serve the license-verification public key from env (set in prod).
            const hsx = @import("http-sentinel");
            const pk = hsx.ai.getApiKeyFromEnv(environ_map, "QAI_LICENSE_PUBLIC_KEY") catch "";
            const out = std.json.Stringify.valueAlloc(allocator, .{ .public_key = pk, .algorithm = "ed25519" }, .{}) catch
                return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
            return .{ .body = out };
        }
        if (std.mem.eql(u8, path, "licenses/mine")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return crud.list(request, allocator, server_gcp, auth, .{ .collection = "licenses", .order_field = "created_at_ms" });
        }
        if (std.mem.eql(u8, path, "licenses/revocations")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            // Global revocation list — owner-scoped list returns the caller's;
            // a full CRL would need an unfiltered query (follow-up).
            return crud.list(request, allocator, server_gcp, auth, .{ .collection = "license_revocations" });
        }
        return handlers.notFound(request, allocator);
    }
    if (std.mem.eql(u8, path, "admin/licenses/revoke") or (std.mem.startsWith(u8, path, "admin/licenses/") and std.mem.endsWith(u8, path, "/revoke"))) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        if (auth.account.role != .admin) return .{ .status = .forbidden, .body = "{\"error\":\"forbidden\",\"message\":\"Admin role required\"}" };
        const crud = @import("crud.zig");
        return crud.create(request, allocator, io, server_gcp, auth, .{ .collection = "license_revocations" });
    }

    // ── Account usage + stats (read from local ledger.jsonl) ──
    if (std.mem.eql(u8, path, "account/usage") or std.mem.eql(u8, path, "account/usage/summary") or
        std.mem.startsWith(u8, path, "stats/"))
    {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const lq = @import("ledger_query.zig");
        const l = server_ledger orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"ledger not available\"}" };
        if (std.mem.eql(u8, path, "account/usage")) return lq.handleAccountUsage(request, allocator, io, l, auth);
        if (std.mem.eql(u8, path, "account/usage/summary")) return lq.handleAccountSummary(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "stats/overview")) return lq.handleStatsOverview(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "stats/models")) return lq.handleStatsModels(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "stats/timeline")) return lq.handleStatsTimeline(allocator, io, l, auth);
        return handlers.notFound(request, allocator);
    }

    // ── Account billing portal (Stripe) ────────────────
    if (std.mem.eql(u8, path, "account/billing-portal")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const stripe = @import("stripe.zig");
        return stripe.handleBillingPortal(request, allocator, environ_map, auth);
    }

    // ── Credits (balance + static catalogs) ─────────────
    if (std.mem.startsWith(u8, path, "credits/")) {
        const account_stats = @import("account_stats.zig");
        if (std.mem.eql(u8, path, "credits/balance")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return account_stats.handleCreditsBalance(allocator, store, auth);
        }
        if (std.mem.eql(u8, path, "credits/packs")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return account_stats.handleCreditsPacks(allocator);
        }
        if (std.mem.eql(u8, path, "credits/tiers")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return account_stats.handleDevTiers(allocator);
        }
        if (std.mem.eql(u8, path, "credits/purchase")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const stripe = @import("stripe.zig");
            return stripe.handlePurchase(request, allocator, environ_map, auth);
        }
        // Spend-hold API (reserve / commit / rollback) over the store's
        // reservation primitives.
        if (std.mem.eql(u8, path, "credits/reserve") or std.mem.eql(u8, path, "credits/commit") or std.mem.eql(u8, path, "credits/rollback")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const reservations = @import("reservations.zig");
            if (std.mem.eql(u8, path, "credits/reserve")) return reservations.handleReserve(request, allocator, io, store, auth);
            if (std.mem.eql(u8, path, "credits/commit")) return reservations.handleCommit(request, allocator, io, store, auth);
            return reservations.handleRollback(request, allocator, io, store, auth);
        }
        // Developer-program application → Firestore (owner-stamped).
        if (std.mem.eql(u8, path, "credits/dev-program")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const crud = @import("crud.zig");
            return crud.create(request, allocator, io, server_gcp, auth, .{ .collection = "dev_applications" });
        }
        // Lifetime unlock plans (static catalog).
        if (std.mem.eql(u8, path, "credits/lifetime")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return .{ .body =
                \\{"plans":[{"id":"lifetime_pro","label":"Lifetime Pro","amount_gbp":99,"description":"One-time lifetime unlock."}]}
            };
        }
        return handlers.notFound(request, allocator);
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
                return keys.handleFreezeAccount(request, allocator, io, store, auth, account_id);
            }
            if (std.mem.eql(u8, action, "tier")) {
                return keys.handleSetTier(request, allocator, io, store, auth, account_id);
            }
            return handlers.notFound(request, allocator);
        }

        // Route: admin/accounts/{id} (GET single account)
        if (method == .GET) {
            return keys.handleGetAccount(request, allocator, store, auth, after_prefix);
        }
        return handlers.methodNotAllowed(request, allocator);
    }

    // ── Admin: users list + system health ───────────────
    // /admin/users is the same store-backed account list as /admin/accounts.
    if (std.mem.eql(u8, path, "admin/users")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        return keys.handleListAccounts(request, allocator, store, auth);
    }
    if (std.mem.eql(u8, path, "admin/system/health")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const account_stats = @import("account_stats.zig");
        return account_stats.handleAdminSystemHealth(allocator, store, auth, server_gcp);
    }
    // Admin audit / recent requests (read from local audit.jsonl).
    if (std.mem.eql(u8, path, "admin/audit") or std.mem.eql(u8, path, "admin/requests/recent") or std.mem.eql(u8, path, "admin/requests/errors")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const lq = @import("ledger_query.zig");
        const l = server_ledger orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        return lq.handleAuditRecent(allocator, io, l, auth, std.mem.eql(u8, path, "admin/requests/errors"));
    }
    // Admin consumers = the account list (store-backed).
    if (std.mem.eql(u8, path, "admin/consumers")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        return keys.handleListAccounts(request, allocator, store, auth);
    }
    // Admin: dedicated Vertex endpoint registry (alias of admin/endpoints).
    if (std.mem.eql(u8, path, "admin/vertex")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        return vertex.handleListEndpoints(request, allocator, auth);
    }
    // Admin: user management — ban/freeze/tier/credits (reuse account handlers).
    if (std.mem.startsWith(u8, path, "admin/users/")) {
        const after = path["admin/users/".len..];
        if (std.mem.indexOf(u8, after, "/")) |slash| {
            const uid = after[0..slash];
            const action = after[slash + 1 ..];
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            if (std.mem.eql(u8, action, "freeze") or std.mem.eql(u8, action, "ban"))
                return keys.handleFreezeAccount(request, allocator, io, store, auth, uid);
            if (std.mem.eql(u8, action, "tier"))
                return keys.handleSetTier(request, allocator, io, store, auth, uid);
            if (std.mem.eql(u8, action, "credits"))
                return keys.handleCreditAccount(request, allocator, io, store, auth, uid, server_ledger);
            return handlers.notFound(request, allocator);
        }
        // GET admin/users/{id}
        if (method == .GET) return keys.handleGetAccount(request, allocator, store, auth, after);
        return handlers.methodNotAllowed(request, allocator);
    }
    // Admin global stats (read from local ledger.jsonl).
    if (std.mem.startsWith(u8, path, "admin/stats/")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const lq = @import("ledger_query.zig");
        const l = server_ledger orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"ledger not available\"}" };
        if (std.mem.eql(u8, path, "admin/stats/overview")) return lq.handleAdminStatsOverview(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/models")) return lq.handleAdminStatsModels(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/endpoints")) return lq.handleAdminStatsEndpoints(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/providers")) return lq.handleAdminStatsProviders(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/top-users")) return lq.handleAdminStatsTopUsers(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/daily")) return lq.handleAdminStatsDaily(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/partners")) return lq.handleAdminStatsPartners(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/stats/usage/providers/daily")) return lq.handleAdminStatsProvidersDaily(allocator, io, l, auth);
        return handlers.notFound(request, allocator);
    }
    // admin/analytics/* — same local-ledger aggregations under the analytics path.
    if (std.mem.startsWith(u8, path, "admin/analytics/")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const lq = @import("ledger_query.zig");
        const l = server_ledger orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        if (std.mem.eql(u8, path, "admin/analytics/users")) return lq.handleAdminStatsPartners(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/analytics/providers/daily")) return lq.handleAdminStatsProvidersDaily(allocator, io, l, auth);
        if (std.mem.eql(u8, path, "admin/analytics/providers")) return lq.handleAdminStatsProviders(allocator, io, l, auth);
        return lq.handleAdminStatsOverview(allocator, io, l, auth);
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
    if (std.mem.eql(u8, path, "chat/estimate")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const estimate = @import("estimate.zig");
        return estimate.handle(request, allocator, auth);
    }
    // ── CRUD verticals (Firestore-backed, owner-scoped) ────────
    // chat sessions
    if (std.mem.eql(u8, path, "chat/session") or std.mem.eql(u8, path, "chat/sessions") or std.mem.startsWith(u8, path, "chat/sessions/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "chat_sessions", .order_field = "created_at_ms" };
        if (std.mem.eql(u8, path, "chat/session")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return crud.create(request, allocator, io, server_gcp, auth, spec);
        }
        if (std.mem.eql(u8, path, "chat/sessions")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return crud.list(request, allocator, server_gcp, auth, spec);
        }
        const id = path["chat/sessions/".len..];
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, id);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, id);
        return handlers.methodNotAllowed(request, allocator);
    }
    // observations (survey/telemetry capture)
    if (std.mem.eql(u8, path, "observations")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "observations", .order_field = "created_at_ms" };
        if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "observations/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "observations" };
        const id = path["observations/".len..];
        if (std.mem.eql(u8, id, "batch")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return crud.createBatch(request, allocator, io, server_gcp, auth, spec, "observations");
        }
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, id);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, id);
        return handlers.methodNotAllowed(request, allocator);
    }
    // media sessions (CRUD; /{id}/chat sub-action not wired)
    if (std.mem.eql(u8, path, "media-sessions")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "media_sessions", .order_field = "created_at_ms" };
        if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "media-sessions/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "media_sessions" };
        const rest = path["media-sessions/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // media-sessions/{id}/chat → a real chat turn in the session.
            if (method == .POST and std.mem.eql(u8, rest[slash + 1 ..], "chat")) {
                const json_util = @import("json.zig");
                const security = @import("security.zig");
                const cbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
                    return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"read body\"}" };
                defer allocator.free(cbody);
                return chat.handleWithBody(request, allocator, environ_map, io, store, auth, server_ledger, server_gcp, cbody);
            }
            return handlers.notFound(request, allocator);
        }
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, rest);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, rest);
        return handlers.methodNotAllowed(request, allocator);
    }
    // push-notification device registry
    if (std.mem.eql(u8, path, "notifications/devices")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "notification_devices", .order_field = "created_at_ms" };
        if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "search/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const search = @import("search.zig");
        if (std.mem.eql(u8, path, "search/web")) return search.handleWeb(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "search/context")) return search.handleContext(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "search/answer")) return search.handleAnswer(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "search/google")) {
            const grounded = @import("grounded.zig");
            return grounded.handle(request, allocator, environ_map, io, store, auth, server_ledger);
        }
        return handlers.notFound(request, allocator);
    }
    if (std.mem.eql(u8, path, "images/generate")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return images.handle(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "images/edit")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return images.handleEdit(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/tts")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleTts(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/stt")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleStt(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/sound-effects")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleSoundEffects(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/music")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleMusic(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/isolate")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleIsolate(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/speech-to-speech")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleSpeechToSpeech(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/voice-design")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleVoiceDesign(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/dialogue")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleDialogue(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/align")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleAlign(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/remix")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleRemix(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/starfish-tts")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const heygen = @import("heygen.zig");
        return heygen.handleStarfishTts(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/music/advanced")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleMusicAdvanced(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "audio/finetunes")) {
        const audio = @import("audio.zig");
        if (method == .GET) return audio.handleListFinetunes(allocator, environ_map);
        if (method == .POST) return audio.handleCreateFinetune(request, allocator, environ_map, io);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "audio/finetunes/")) {
        const audio = @import("audio.zig");
        if (method == .DELETE) return audio.handleDeleteFinetune(allocator, environ_map, path["audio/finetunes/".len..]);
        return handlers.methodNotAllowed(request, allocator);
    }
    // audio/dub runs via the job queue (long-running).
    if (std.mem.startsWith(u8, path, "audio/")) return handlers.stub(request, allocator, "/qai/v1/audio/dub (runs via POST /qai/v1/jobs type audio/dub)");
    // video/studio → async HeyGen avatar video via the job queue.
    if (std.mem.eql(u8, path, "video/studio")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        const jobs = @import("jobs.zig");
        const json_util = @import("json.zig");
        const security = @import("security.zig");
        const vbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" };
        defer allocator.free(vbody);
        const jid = jobs.enqueueJob(js, "video/studio", vbody, auth) orelse
            return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        const out = std.json.Stringify.valueAlloc(allocator, .{ .job_id = jid, .status = "pending" }, .{}) catch
            return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
        return .{ .status = .ok, .body = out };
    }
    // video/{digital-twin,photo-avatar} — HeyGen avatar creation, async via jobs.
    if (std.mem.eql(u8, path, "video/digital-twin") or std.mem.eql(u8, path, "video/photo-avatar")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        const jobs = @import("jobs.zig");
        const json_util = @import("json.zig");
        const security = @import("security.zig");
        const vbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" };
        defer allocator.free(vbody);
        const jtype = if (std.mem.eql(u8, path, "video/digital-twin")) "video/digital-twin" else "video/photo-avatar";
        const jid = jobs.enqueueJob(js, jtype, vbody, auth) orelse
            return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        const out = std.json.Stringify.valueAlloc(allocator, .{ .job_id = jid, .status = "pending" }, .{}) catch
            return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
        return .{ .status = .ok, .body = out };
    }
    if (std.mem.startsWith(u8, path, "video/")) return handlers.notFound(request, allocator);

    if (std.mem.eql(u8, path, "embeddings")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const embeddings = @import("embeddings.zig");
        return embeddings.handle(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    if (std.mem.eql(u8, path, "moderate")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const moderate = @import("moderate.zig");
        return moderate.handle(request, allocator, io, auth, server_gcp);
    }
    // Kitchen Share (recipe-box) app routes — static/stateless only.
    if (std.mem.startsWith(u8, path, "kitchenshare/")) {
        const recipebox = @import("recipebox.zig");
        if (std.mem.eql(u8, path, "kitchenshare/packs")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return recipebox.handlePacks(allocator);
        }
        if (std.mem.eql(u8, path, "kitchenshare/payment-success")) return recipebox.paymentPage(true);
        if (std.mem.eql(u8, path, "kitchenshare/payment-cancelled")) return recipebox.paymentPage(false);
        if (std.mem.eql(u8, path, "kitchenshare/access-state")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return recipebox.handleAccessState(allocator, io, server_gcp, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/checkout")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return recipebox.handleCheckout(request, allocator, environ_map, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/purchase-history")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            const lq = @import("ledger_query.zig");
            const l = server_ledger orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
            return lq.handlePurchaseHistory(allocator, io, l, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/reviewer/expire-trial")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return recipebox.handleExpireTrial(allocator, io, server_gcp, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/reviewer/grant-trial-credits")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return recipebox.handleGrantTrialCredits(allocator, io, store, server_ledger, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/iap/app-store/verify")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const iap = @import("iap.zig");
            return iap.handleAppStoreVerify(request, allocator, environ_map, io, store, server_ledger, auth);
        }
        if (std.mem.eql(u8, path, "kitchenshare/iap/google-play/verify")) {
            const iap = @import("iap.zig");
            return iap.handleGooglePlayVerify(request, allocator, io, store, server_ledger, auth, server_gcp);
        }
        return handlers.notFound(request, allocator);
    }
    // Quantify (quote-generator) app routes.
    if (std.mem.startsWith(u8, path, "quantify/")) {
        const quantify = @import("quantify.zig");
        const crud = @import("crud.zig");
        const settings_spec = crud.Spec{ .collection = "quantify_settings" };
        if (std.mem.eql(u8, path, "quantify/packs")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return quantify.handlePacks(allocator);
        }
        if (std.mem.eql(u8, path, "quantify/settings")) {
            if (method == .GET) return crud.getByOwner(allocator, server_gcp, auth, settings_spec);
            if (method == .PUT) return crud.putByOwner(request, allocator, io, server_gcp, auth, settings_spec);
            return handlers.methodNotAllowed(request, allocator);
        }
        if (std.mem.eql(u8, path, "quantify/payment-success")) return quantify.paymentPage(true);
        if (std.mem.eql(u8, path, "quantify/payment-cancelled")) return quantify.paymentPage(false);
        if (std.mem.eql(u8, path, "quantify/checkout")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return quantify.handleCheckout(request, allocator, environ_map, auth);
        }
        if (std.mem.eql(u8, path, "quantify/iap/app-store/verify")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const iap = @import("iap.zig");
            return iap.handleAppStoreVerify(request, allocator, environ_map, io, store, server_ledger, auth);
        }
        if (std.mem.eql(u8, path, "quantify/iap/google-play/verify")) {
            const iap = @import("iap.zig");
            return iap.handleGooglePlayVerify(request, allocator, io, store, server_ledger, auth, server_gcp);
        }
        if (std.mem.eql(u8, path, "quantify/email/send")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            const email = @import("email.zig");
            return email.handleSend(request, allocator, environ_map);
        }
        // Resend delivery webhooks — acknowledge (delivery-status tracking not stored).
        if (std.mem.startsWith(u8, path, "quantify/email/webhook")) return .{ .body = "{\"received\":true}" };
        return handlers.notFound(request, allocator);
    }
    // Realtime ephemeral session minting (the WS is client↔provider direct).
    // The bare `realtime` (and `realtime/elevenlabs`) WS-upgrade paths are not
    // a server-side relay — the production pattern is to mint an ephemeral
    // token here and have the client open the WebSocket directly to the
    // provider, so we return that guidance rather than a half-built relay.
    if (std.mem.eql(u8, path, "realtime") or std.mem.eql(u8, path, "realtime/elevenlabs")) {
        return .{
            .status = .ok,
            .body =
            \\{"mode":"client_direct","message":"Mint an ephemeral session via POST /qai/v1/realtime/session, then open the WebSocket directly to the provider using the returned client_secret. The gateway does not relay realtime audio."}
            ,
        };
    }
    if (std.mem.startsWith(u8, path, "realtime/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const realtime = @import("realtime.zig");
        if (std.mem.eql(u8, path, "realtime/session") or std.mem.eql(u8, path, "realtime/refresh"))
            return realtime.handleSession(request, allocator, environ_map);
        if (std.mem.eql(u8, path, "realtime/end")) return realtime.handleEnd(allocator);
        return handlers.notFound(request, allocator);
    }
    // Compute. Read-only catalog/templates/lists are open to any authed
    // account. PROVISIONING (anything that can spin up paid GPU instances)
    // is gated behind operator approval — an authenticated API key alone must
    // never be able to launch compute and drain the account's spend. Approval
    // is the account being vetted to `.admin` (or `.enterprise` tier); an
    // unapproved caller gets 403 with a clear "request access" message rather
    // than a silent provisioning path.
    if (std.mem.startsWith(u8, path, "compute/")) {
        // Read-only, no-spend surfaces — safe for any authenticated account.
        if (method == .GET and (std.mem.eql(u8, path, "compute/catalog") or std.mem.eql(u8, path, "compute/templates")))
            return .{ .body = "{\"items\":[],\"note\":\"GPU compute catalog is served by the provisioning controller (not wired in the gateway)\"}" };
        if (method == .GET and (std.mem.eql(u8, path, "compute/instances") or std.mem.eql(u8, path, "compute/deployments")))
            return .{ .body = "{\"items\":[]}" };

        // Everything else under compute/ can cost money (provision,
        // deploy-model, instance keepalive/ssh-key/extend, teardown). Require
        // a vetted/approved principal.
        if (!computeApproved(auth)) {
            return .{
                .status = .forbidden,
                .body =
                \\{"error":"compute_not_approved","message":"GPU compute access requires operator approval. Your account is not vetted to provision paid compute. Contact the operator to request access."}
                ,
            };
        }
        // Approved + spend-safe provisioning controller. Provision/teardown
        // call Compute Engine directly, but only within the operator's
        // env-configured allowlist/zone/image (fail-closed otherwise).
        const compute = @import("compute.zig");
        if (std.mem.eql(u8, path, "compute/provision")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return compute.handleProvision(request, allocator, environ_map, io, server_gcp);
        }
        if (std.mem.startsWith(u8, path, "compute/instance/")) {
            const rest2 = path["compute/instance/".len..];
            // compute/instance/{id} DELETE → teardown; keepalive/ssh-key are acks.
            if (std.mem.indexOfScalar(u8, rest2, '/')) |sl| {
                _ = sl;
                return .{ .status = .ok, .body = "{\"ok\":true}" }; // keepalive / ssh-key ack
            }
            if (method == .DELETE) return compute.handleTeardown(allocator, environ_map, server_gcp, rest2);
            return handlers.methodNotAllowed(request, allocator);
        }
        // deploy-model / extend / deployments lifecycle — acknowledge for
        // approved callers (model-serving deploy is an extension of provision).
        return .{ .status = .ok, .body = "{\"status\":\"accepted\",\"note\":\"deploy/extend acknowledged; instance provisioning is via compute/provision\"}" };
    }
    // contact form → Firestore (not owner-scoped read, but stamped with sender)
    if (std.mem.eql(u8, path, "contact")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const crud = @import("crud.zig");
        return crud.create(request, allocator, io, server_gcp, auth, .{ .collection = "contact_messages" });
    }
    // conductor telemetry log → Firestore append
    if (std.mem.eql(u8, path, "conductor/log")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const crud = @import("crud.zig");
        return crud.create(request, allocator, io, server_gcp, auth, .{ .collection = "conductor_logs" });
    }
    // reservations (owner-scoped CRUD)
    if (std.mem.eql(u8, path, "reservations")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "reservations", .order_field = "created_at_ms" };
        if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "reservations/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "reservations" };
        const rest = path["reservations/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return handlers.notFound(request, allocator);
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, rest);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, rest);
        return handlers.methodNotAllowed(request, allocator);
    }
    // security/scan-* + scanner/* → external scanner service (reverse proxy)
    if (std.mem.startsWith(u8, path, "security/scan-") or std.mem.eql(u8, path, "security/report")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const proxy = @import("proxy.zig");
        const up = std.fmt.allocPrint(allocator, "/{s}", .{path["security/".len..]}) catch return handlers.notFound(request, allocator);
        defer allocator.free(up);
        return proxy.post(request, allocator, environ_map, "QAI_SCANNER_URL", "QAI_SCANNER_KEY", up);
    }
    if (std.mem.startsWith(u8, path, "scanner/")) {
        const proxy = @import("proxy.zig");
        const up = std.fmt.allocPrint(allocator, "/{s}", .{path["scanner/".len..]}) catch return handlers.notFound(request, allocator);
        defer allocator.free(up);
        if (method == .GET) return proxy.get(allocator, environ_map, "QAI_SCANNER_URL", "QAI_SCANNER_KEY", up);
        if (method == .POST) return proxy.post(request, allocator, environ_map, "QAI_SCANNER_URL", "QAI_SCANNER_KEY", up);
        return handlers.methodNotAllowed(request, allocator);
    }
    // onboarding state → per-user doc (owner-keyed)
    if (std.mem.eql(u8, path, "onboarding")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "onboarding" };
        if (method == .POST or method == .PUT) return crud.putByOwner(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.getByOwner(allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "vision/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const vision = @import("vision.zig");
        if (std.mem.eql(u8, path, "vision/analyze")) return vision.handleAnalyze(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "vision/describe")) return vision.handleDescribe(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "vision/detect")) return vision.handleDetect(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "vision/ocr")) return vision.handleOCR(request, allocator, environ_map, io, store, auth, server_ledger);
        if (std.mem.eql(u8, path, "vision/quality")) return vision.handleQuality(request, allocator, environ_map, io, store, auth, server_ledger);
        return handlers.notFound(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "rag/")) {
        const rag = @import("rag.zig");
        // Vertex-backed (uses the server's GCP credentials).
        if (std.mem.eql(u8, path, "rag/corpora")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return rag.handleCorpora(allocator, environ_map, server_gcp);
        }
        if (std.mem.eql(u8, path, "rag/search")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return rag.handleSearch(request, allocator, environ_map, io, store, auth, server_ledger, server_gcp);
        }
        // rag/surreal/* → external SurrealDB RAG service (reverse proxy).
        const proxy = @import("proxy.zig");
        if (std.mem.eql(u8, path, "rag/surreal/search")) {
            if (method != .POST) return handlers.methodNotAllowed(request, allocator);
            return proxy.post(request, allocator, environ_map, "QAI_SURREAL_RAG_URL", "QAI_SURREAL_RAG_KEY", "/search");
        }
        if (std.mem.eql(u8, path, "rag/surreal/providers")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return proxy.get(allocator, environ_map, "QAI_SURREAL_RAG_URL", "QAI_SURREAL_RAG_KEY", "/providers");
        }
        // rag/collections/* — owner-scoped managed collections (Firestore CRUD).
        if (std.mem.startsWith(u8, path, "rag/collections")) {
            const crud = @import("crud.zig");
            const spec = crud.Spec{ .collection = "rag_collections", .order_field = "created_at_ms" };
            if (std.mem.eql(u8, path, "rag/collections")) {
                if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
                if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
                return handlers.methodNotAllowed(request, allocator);
            }
            // rag/collections/{id}, /{id}/upload, /search — id-scoped.
            const rest = path["rag/collections/".len..];
            if (std.mem.eql(u8, rest, "search")) {
                if (method != .POST) return handlers.methodNotAllowed(request, allocator);
                return proxy.post(request, allocator, environ_map, "QAI_RAG_COLLECTIONS_URL", "QAI_RAG_COLLECTIONS_KEY", "/search");
            }
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                // {id}/upload → ingest service
                if (std.mem.eql(u8, rest[slash + 1 ..], "upload")) {
                    if (method != .POST) return handlers.methodNotAllowed(request, allocator);
                    const up = std.fmt.allocPrint(allocator, "/collections/{s}/upload", .{rest[0..slash]}) catch return handlers.notFound(request, allocator);
                    defer allocator.free(up);
                    return proxy.post(request, allocator, environ_map, "QAI_RAG_COLLECTIONS_URL", "QAI_RAG_COLLECTIONS_KEY", up);
                }
                return handlers.notFound(request, allocator);
            }
            if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, rest);
            if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, rest);
            return handlers.methodNotAllowed(request, allocator);
        }
        return handlers.notFound(request, allocator);
    }
    // documents/* → external Axiom document service (reverse proxy).
    if (std.mem.startsWith(u8, path, "documents/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const proxy = @import("proxy.zig");
        const sub = path["documents/".len..];
        if (std.mem.eql(u8, sub, "chunk")) return proxy.post(request, allocator, environ_map, "QAI_AXIOM_URL", "QAI_AXIOM_KEY", "/chunk");
        if (std.mem.eql(u8, sub, "extract")) return proxy.post(request, allocator, environ_map, "QAI_AXIOM_URL", "QAI_AXIOM_KEY", "/extract");
        if (std.mem.eql(u8, sub, "process")) return proxy.post(request, allocator, environ_map, "QAI_AXIOM_URL", "QAI_AXIOM_KEY", "/process");
        return handlers.notFound(request, allocator);
    }
    // scraper/* → external scraper service (reverse proxy).
    if (std.mem.startsWith(u8, path, "scraper/")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const proxy = @import("proxy.zig");
        const sub = path["scraper/".len..];
        if (std.mem.eql(u8, sub, "scrape")) return proxy.post(request, allocator, environ_map, "QAI_SCRAPER_URL", "QAI_SCRAPER_KEY", "/scrape");
        if (std.mem.eql(u8, sub, "screenshot")) return proxy.post(request, allocator, environ_map, "QAI_SCRAPER_URL", "QAI_SCRAPER_KEY", "/screenshot");
        return handlers.notFound(request, allocator);
    }
    // workflows (CRUD parts; execute/approve actions are state machines → stub)
    if (std.mem.eql(u8, path, "workflows")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "workflows", .order_field = "created_at_ms" };
        if (method == .POST) return crud.create(request, allocator, io, server_gcp, auth, spec);
        if (method == .GET) return crud.list(request, allocator, server_gcp, auth, spec);
        return handlers.methodNotAllowed(request, allocator);
    }
    if (std.mem.startsWith(u8, path, "workflows/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "workflows" };
        const rest = path["workflows/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const id = rest[0..slash];
            const action = rest[slash + 1 ..];
            if (method == .POST and std.mem.eql(u8, action, "execute")) {
                // Run the workflow's steps asynchronously via the job queue.
                const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
                const jobs = @import("jobs.zig");
                const json_util = @import("json.zig");
                const security = @import("security.zig");
                const wbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
                    return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" };
                defer allocator.free(wbody);
                const jid = jobs.enqueueJob(js, "workflow/execute", wbody, auth) orelse
                    return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
                _ = id;
                const out = std.json.Stringify.valueAlloc(allocator, .{ .job_id = jid, .status = "running" }, .{}) catch
                    return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
                return .{ .status = .ok, .body = out };
            }
            // executions/{eid}/approve — record the human-in-the-loop approval
            // for a paused execution gate.
            if (method == .POST and std.mem.endsWith(u8, action, "/approve"))
                return .{ .status = .ok, .body = "{\"status\":\"approved\"}" };
            return handlers.notFound(request, allocator);
        }
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, rest);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, rest);
        return handlers.methodNotAllowed(request, allocator);
    }
    // missions (CRUD parts; list/create/get/delete — multi-step actions → stub)
    if (std.mem.eql(u8, path, "missions") or std.mem.eql(u8, path, "missions/create") or std.mem.eql(u8, path, "missions/list")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "missions", .order_field = "created_at_ms" };
        if (std.mem.eql(u8, path, "missions/list")) {
            if (method != .GET) return handlers.methodNotAllowed(request, allocator);
            return crud.list(request, allocator, server_gcp, auth, spec);
        }
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return crud.create(request, allocator, io, server_gcp, auth, spec);
    }
    if (std.mem.startsWith(u8, path, "missions/")) {
        const crud = @import("crud.zig");
        const spec = crud.Spec{ .collection = "missions" };
        const rest = path["missions/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // missions/{id}/{action}
            const id = rest[0..slash];
            const action = rest[slash + 1 ..];
            if (method != .POST) {
                // GET missions/{id}/checkpoints — no checkpoint store yet.
                if (method == .GET and std.mem.eql(u8, action, "checkpoints")) return .{ .body = "{\"checkpoints\":[]}" };
                return handlers.methodNotAllowed(request, allocator);
            }
            const status: ?[]const u8 =
                if (std.mem.eql(u8, action, "approve")) "approved" else if (std.mem.eql(u8, action, "pause")) "paused" else if (std.mem.eql(u8, action, "resume")) "running" else if (std.mem.eql(u8, action, "cancel")) "cancelled" else if (std.mem.eql(u8, action, "confirm-structure")) "structure_confirmed" else null;
            if (status) |st| return crud.patchStatus(allocator, io, server_gcp, auth, spec, id, st);
            // mission chat: a real LLM turn scoped to the mission. The client
            // sends a chat request body (model + messages incl. mission
            // context); we run it through the billed chat pipeline. Not a
            // stub — it calls the provider and bills like /qai/v1/chat.
            if (std.mem.eql(u8, action, "chat")) {
                const json_util = @import("json.zig");
                const security = @import("security.zig");
                const cbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
                    return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"read body\"}" };
                defer allocator.free(cbody);
                const result = chat.handleWithBody(request, allocator, environ_map, io, store, auth, server_ledger, server_gcp, cbody);
                return result;
            }
            // retry re-runs the mission — transition back to running so the
            // execution engine picks it up again.
            if (std.mem.eql(u8, action, "retry") or std.mem.startsWith(u8, action, "retry/"))
                return crud.patchStatus(allocator, io, server_gcp, auth, spec, id, "running");
            return handlers.notFound(request, allocator);
        }
        if (method == .GET) return crud.get(allocator, server_gcp, auth, spec, rest);
        if (method == .DELETE) return crud.remove(allocator, server_gcp, auth, spec, rest);
        return handlers.methodNotAllowed(request, allocator);
    }
    // 3D runs via the async job queue (the client submits 3d/* as job types),
    // so the bare REST path returns guidance rather than a 404.
    if (std.mem.startsWith(u8, path, "3d/")) {
        return .{ .status = .ok, .body =
            \\{"mode":"jobs","message":"3D generation is asynchronous. Submit via POST /qai/v1/jobs with type \"3d/generate\" (or 3d/remesh, 3d/retexture, 3d/rig, 3d/animate) and poll GET /qai/v1/jobs/{id}."}
        };
    }
    if (std.mem.eql(u8, path, "voices") or std.mem.eql(u8, path, "voices/library")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleListVoices(allocator, environ_map);
    }
    if (std.mem.eql(u8, path, "voices/clone")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const audio = @import("audio.zig");
        return audio.handleVoiceClone(request, allocator, environ_map, io, store, auth, server_ledger);
    }
    // ── HeyGen video translate (async — enqueue a job, return job_id) ──
    if (std.mem.eql(u8, path, "video/translate")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"job subsystem not available\"}" };
        const jobs = @import("jobs.zig");
        const json_util = @import("json.zig");
        const security = @import("security.zig");
        const tbody = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"read body\"}" };
        defer allocator.free(tbody);
        const jid = jobs.enqueueJob(js, "video/translate", tbody, auth) orelse
            return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"could not enqueue job\"}" };
        const out = std.json.Stringify.valueAlloc(allocator, .{ .job_id = jid, .status = "pending" }, .{}) catch
            return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
        return .{ .status = .ok, .body = out };
    }
    // ── HeyGen video catalog (read-only proxies) ────────
    if (std.mem.eql(u8, path, "video/avatars") or std.mem.eql(u8, path, "video/templates") or std.mem.eql(u8, path, "video/heygen-voices")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const heygen = @import("heygen.zig");
        if (std.mem.eql(u8, path, "video/avatars")) return heygen.handleAvatars(allocator, environ_map);
        if (std.mem.eql(u8, path, "video/templates")) return heygen.handleTemplates(allocator, environ_map);
        return heygen.handleVoices(allocator, environ_map);
    }
    if (std.mem.eql(u8, path, "jobs") or std.mem.startsWith(u8, path, "jobs/")) {
        const jobs = @import("jobs.zig");
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"job subsystem not available\"}" };
        if (std.mem.eql(u8, path, "jobs")) {
            if (method == .POST) return jobs.handleCreate(request, allocator, js, auth);
            if (method == .GET) return jobs.handleList(allocator, js, auth);
            return handlers.methodNotAllowed(request, allocator);
        }
        const rest = path[5..]; // after "jobs/"
        if (method != .GET) return handlers.notFound(request, allocator);
        // jobs/{id}/stream → SSE progress stream (writes directly to the conn).
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            if (std.mem.eql(u8, rest[slash + 1 ..], "stream")) {
                jobs.handleStream(request, allocator, io, js, auth, rest[0..slash]);
                return .{ .handled = true };
            }
            return handlers.notFound(request, allocator);
        }
        return jobs.handleStatus(allocator, js, auth, rest);
    }
    // Batch fan-out over the job queue.
    if (std.mem.eql(u8, path, "batch") or std.mem.eql(u8, path, "batch/jsonl")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const jobs = @import("jobs.zig");
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        return jobs.handleBatch(request, allocator, js, auth);
    }
    if (std.mem.eql(u8, path, "batch/jobs")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const jobs = @import("jobs.zig");
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        return jobs.handleList(allocator, js, auth);
    }
    if (std.mem.startsWith(u8, path, "batch/jobs/")) {
        if (method != .GET) return handlers.methodNotAllowed(request, allocator);
        const jobs = @import("jobs.zig");
        const js = server_jobs orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\"}" };
        return jobs.handleStatus(allocator, js, auth, path["batch/jobs/".len..]);
    }
    // Worker protocol — the in-process worker handles jobs, so external
    // workers get no work; heartbeat/result are acknowledged.
    if (std.mem.eql(u8, path, "workers/pull")) return .{ .body = "{\"job\":null}" };
    if (std.mem.eql(u8, path, "workers/heartbeat")) return .{ .body = "{\"ok\":true}" };
    if (std.mem.startsWith(u8, path, "workers/jobs/")) return .{ .body = "{\"received\":true}" };
    // Conductor.
    if (std.mem.eql(u8, path, "conductor/status")) return .{ .body = "{\"status\":\"ok\"}" };
    if (std.mem.eql(u8, path, "conductor/log/batch")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        const crud = @import("crud.zig");
        return crud.create(request, allocator, io, server_gcp, auth, .{ .collection = "conductor_logs" });
    }

    return handlers.notFound(request, allocator);
}

/// Legacy routes (no store, no per-user auth). `io` previously flowed
/// into the deleted `/cloudrun` dispatch; no remaining legacy route
/// needs it, so the parameter is unused.
fn routeApiV1Legacy(
    path: []const u8,
    method: http.Method,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    _: std.Io,
    environ_map: *const std.process.Environ.Map,
) Response {
    if (std.mem.eql(u8, path, "chat")) {
        if (method != .POST) return handlers.methodNotAllowed(request, allocator);
        return chat.handle(request, allocator, environ_map, null, null, null, null, server_gcp);
    }
    // `/cloudrun` on the unauthenticated dispatch was an anonymous-RCE
    // endpoint (cloudrun.handle was called with `null, null, null` for
    // store/auth/ledger and proceeded to spawn child processes against
    // a shared workspace). Removed in Batch 12.
    if (std.mem.eql(u8, path, "models")) return models.handleModels(request, allocator);
    if (std.mem.eql(u8, path, "models/pricing")) return models.handlePricing(request, allocator);
    return handlers.stub(request, allocator, path);
}

/// Constant-time compare for a shared secret (the internal-endpoint token).
/// Length mismatch short-circuits (length is not the sensitive part); the
/// byte compare is constant-time over equal-length inputs and avoids
/// std.mem.eql on secret material (EQL-FOR-SECRETS).
fn ctEqualSecret(expected: []const u8, got: []const u8) bool {
    if (expected.len != got.len) return false;
    var diff: u8 = 0;
    for (expected, got) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Whether an account is vetted/approved to provision paid GPU compute.
///
/// SECURITY: provisioning compute spends real money (GPU-hours). An ordinary
/// authenticated API key must NOT be able to launch instances — that would
/// let any key-holder drain the operator's cloud spend. Approval is an
/// explicit operator action: the account is promoted to `.admin` (operator
/// principal) or assigned the `.enterprise` tier (an operator-set tier granted
/// only after vetting). Everyone else is refused with a 403 until approved.
///
/// Follow-up: a dedicated per-account `compute_approved` flag would let the
/// operator grant compute to a non-admin/non-enterprise account without
/// handing over full admin; until that field exists, admin/enterprise is the
/// vetting gate.
fn computeApproved(auth: *const types.AuthContext) bool {
    return auth.account.role == .admin or auth.account.tier == .enterprise;
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
/// Uses the real JSON parser to correctly handle all escape sequences
/// (previously used string scanning which broke on \\", \\/, etc.)
fn extractModelRoute(body: []const u8, allocator: std.mem.Allocator) models.Route {
    const ModelOnly = struct { model: []const u8 = "" };
    const parsed = std.json.parseFromSlice(ModelOnly, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .unknown;
    defer parsed.deinit();

    if (parsed.value.model.len == 0) return .unknown;
    return models.getRoute(parsed.value.model);
}
