// Embeddings endpoint — POST /qai/v1/embeddings
//
// Architecture mirrors images.zig: model → provider dispatch, pre-flight
// reservation, provider call, exact-cost commit, ledger entry, JSON
// response. First provider implemented is OpenAI (text-embedding-3-small,
// text-embedding-3-large, text-embedding-ada-002). Other providers (Google
// gemini-embedding-001, Z.ai embedding-3) return 501 with a clear message
// naming which providers are live, so the client can degrade gracefully.
//
// Wire-compatible with the Go /qai/v1/embeddings handler:
//   request:  { "model": "...", "input": ["..."], "dimensions": 1536? }
//   response: { "embeddings": [[...]], "model": "...", "cost_ticks": N, ... }
//
// Billing model: embeddings are priced on INPUT tokens only — the CSV
// carries `input_per_million` for each embedding model and no output/unit
// price. Pre-flight reserves a token estimate derived from the input byte
// count (≈ bytes/4 + 1); the exact cost is settled from the provider's
// reported `usage.prompt_tokens`. All integer math (Batch 31
// FLOAT-OBSESSION) — no f64 in the billing path.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const models_mod = @import("models.zig");
const security = @import("security.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;

/// Inbound embeddings request — wire-compatible with the Go
/// /qai/v1/embeddings handler so a single client SDK can target either
/// gateway.
pub const EmbeddingRequest = struct {
    model: []const u8,
    /// One or more strings to embed. OpenAI accepts a single string or an
    /// array; we require the array form (matches the Go handler's []string).
    input: []const []const u8,
    /// Matryoshka output dimension (768/1536/3072). Forwarded only when set.
    dimensions: ?u32 = null,
};

/// One returned embedding vector + its position in the input batch.
const EmbeddingVector = struct {
    embedding: []f64,
    index: u32,
};

/// Handle POST /qai/v1/embeddings (reads body from request).
pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    return handleCore(allocator, environ_map, io, store, auth, ledger, body);
}

pub fn handleCore(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(EmbeddingRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "Malformed JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    // Input validation (fail-closed before reaching the provider).
    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return errResp(.bad_request, "model is required");
    }
    if (req.input.len == 0) {
        return errResp(.bad_request, "input is required (non-empty array of strings)");
    }
    if (req.input.len > 2048) {
        return errResp(.bad_request, "input batch too large (max 2048 items)");
    }
    var total_input_bytes: usize = 0;
    for (req.input) |s| {
        if (s.len == 0) return errResp(.bad_request, "input items must be non-empty");
        total_input_bytes += s.len;
    }

    // Look up the model in the registry to find provider + pricing.
    const model = models_mod.getModel(req.model) orelse {
        return errResp(.bad_request, "Model not found in registry; check /qai/v1/models");
    };

    // Provider dispatch by registry-recorded provider name. Only OpenAI is
    // implemented today; everything else returns 501 with the upstream
    // provider named so the client can route around or wait for the next pass.
    if (std.mem.eql(u8, model.provider, "OpenAI")) {
        return embedOpenAI(allocator, environ_map, io, store, auth, ledger, req, model, total_input_bytes);
    }

    return errResp(
        .not_implemented,
        "Embeddings for this provider isn't wired up yet on the Zig server. Currently live: OpenAI (text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002). Use the Go gateway for Google/Z.ai embeddings.",
    );
}

// ── OpenAI provider ────────────────────────────────────────────────

fn embedOpenAI(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    req: EmbeddingRequest,
    model: models_mod.Model,
    total_input_bytes: usize,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch {
        return errResp(.internal_server_error, "Server missing OPENAI_API_KEY");
    };

    // Pre-flight estimate. We don't know the exact token count until the
    // provider responds, so we approximate from the input byte count
    // (≈ 4 bytes/token for English text) and err slightly high with a +1
    // floor per item so empty-ish batches still reserve something. The
    // reservation absorbs the difference; the exact cost is settled from
    // the provider's reported usage post-call.
    const est_tokens: i64 = @intCast(total_input_bytes / 4 + req.input.len);
    const est = costFromTokens(model, est_tokens);
    const estimate_ticks: i64 = est.cost + est.margin;

    // Reserve against account balance. Skip when no auth/store wired
    // (test harness, local dev) or for admin accounts.
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(
                io_handle,
                a.account.id.slice(),
                a.key_hash,
                estimate_ticks,
                "/qai/v1/embeddings",
                req.model,
            ) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this embeddings request"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // Build the JSON body for OpenAI /v1/embeddings. The input array,
    // dimensions, and model all go through std.json.Stringify (JSON-IN-FMT:
    // input strings are caller-controlled and must be escaped by the stdlib,
    // never hand-interpolated). `dimensions` is omitted when null so OpenAI's
    // native dimension applies.
    const request_body = std.json.Stringify.valueAlloc(allocator, .{
        .model = req.model,
        .input = req.input,
        .dimensions = req.dimensions,
        .encoding_format = "float",
    }, .{ .emit_null_optional_fields = false }) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to build provider request");
    };
    defer allocator.free(request_body);

    var http_client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to build auth header");
    };
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    var resp = http_client.post(
        "https://api.openai.com/v1/embeddings",
        &headers,
        request_body,
    ) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "OpenAI embeddings request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        // Surface OpenAI's status directly so rate-limit / quota signals
        // (429, 5xx) reach the caller intact.
        return errResp(resp.status, "OpenAI rejected the embeddings request");
    }

    const decoded = decodeOpenAIResponse(allocator, resp.body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "Could not parse OpenAI embeddings response");
    };
    defer freeDecoded(allocator, decoded);

    // Exact cost from reported usage (input tokens only for embeddings).
    const cost = costFromTokens(model, @intCast(decoded.prompt_tokens));

    // Commit billing. The reservation absorbs the estimate↔actual delta.
    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        s.commitReservation(io_handle, rid, cost.cost, cost.margin) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    // Audit ledger.
    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(
            io_handle,
            acct_id,
            key_pfx,
            cost.cost,
            cost.margin,
            balance_after,
            "/qai/v1/embeddings",
            req.model,
            decoded.prompt_tokens,
            0,
            0,
        );
    };

    const json_resp = buildResponseJson(
        allocator,
        decoded.vectors,
        req.model,
        decoded.prompt_tokens,
        cost.cost + cost.margin,
        balance_after,
    ) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = json_resp };
}

/// Input-token cost for an embeddings call. Embeddings have no output or
/// per-unit price, so cost is `input_ticks_per_million × tokens / 1M` plus
/// the configured margin. All integer math (Batch 31 FLOAT-OBSESSION).
fn costFromTokens(model: models_mod.Model, input_tokens: i64) struct { cost: i64, margin: i64 } {
    const cost = @divTrunc(model.input_ticks_per_million * input_tokens, 1_000_000);
    const margin = @divFloor(cost * model.margin_bps, 10000);
    return .{ .cost = cost, .margin = margin };
}

const DecodedEmbeddingResponse = struct {
    vectors: []EmbeddingVector,
    prompt_tokens: u32,
};

/// Parse just what we need from the OpenAI response. Tolerant of extra
/// fields the SDK may add over time.
fn decodeOpenAIResponse(allocator: std.mem.Allocator, body: []const u8) !DecodedEmbeddingResponse {
    const Parsed = struct {
        data: []const struct {
            embedding: []const f64,
            index: u32 = 0,
        },
        usage: ?struct {
            prompt_tokens: u32 = 0,
            total_tokens: u32 = 0,
        } = null,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var vectors = try allocator.alloc(EmbeddingVector, parsed.value.data.len);
    var built: usize = 0;
    errdefer {
        for (vectors[0..built]) |v| allocator.free(v.embedding);
        allocator.free(vectors);
    }
    for (parsed.value.data, 0..) |d, i| {
        const vec = try allocator.dupe(f64, d.embedding);
        vectors[i] = .{ .embedding = vec, .index = @intCast(i) };
        built += 1;
    }

    const prompt_tokens: u32 = if (parsed.value.usage) |u| u.prompt_tokens else 0;
    return .{ .vectors = vectors, .prompt_tokens = prompt_tokens };
}

fn freeDecoded(allocator: std.mem.Allocator, d: DecodedEmbeddingResponse) void {
    for (d.vectors) |v| allocator.free(v.embedding);
    allocator.free(d.vectors);
}

fn buildResponseJson(
    allocator: std.mem.Allocator,
    vectors: []const EmbeddingVector,
    model: []const u8,
    prompt_tokens: u32,
    cost_ticks: i64,
    balance_after: i64,
) ![]u8 {
    // Build the bare `[][]f64` array the Go handler returns under
    // `embeddings`, then assemble the envelope. All via std.json.Stringify —
    // no hand-formatted JSON (JSON-IN-FMT).
    const flat = try allocator.alloc([]const f64, vectors.len);
    defer allocator.free(flat);
    for (vectors, 0..) |v, i| flat[i] = v.embedding;

    return std.json.Stringify.valueAlloc(allocator, .{
        .embeddings = flat,
        .model = model,
        .usage = .{ .prompt_tokens = prompt_tokens },
        .cost_ticks = cost_ticks,
        .balance_after = balance_after,
    }, .{});
}

/// Roll back a reservation on the provider/error path. No-op when any of
/// store/io/reservation is absent (test harness, admin, unauthenticated).
fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Embeddings request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this embeddings request\"}" },
        .not_implemented => .{ .status = .not_implemented, .body = "{\"error\":\"provider_not_implemented\",\"message\":\"Embeddings for this provider isn't wired up yet on the Zig server. Live: OpenAI text-embedding-3-small/large and text-embedding-ada-002.\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Provider rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Embeddings provider request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Embeddings request failed\"}" },
    };
}
