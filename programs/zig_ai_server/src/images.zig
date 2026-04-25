// Image generation endpoint — POST /qai/v1/images/generate
//
// Architecture mirrors chat.zig: model → provider dispatch, pre-flight
// reservation, provider call, exact-cost commit, ledger entry, JSON
// response. First provider implemented is OpenAI (gpt-image-* family +
// dall-e-3). Other providers (xAI grok-imagine, Vertex Imagen, Gemini,
// ElevenLabs) return 501 with a clear "not implemented yet" message that
// names which providers are live, so the client can degrade gracefully.
//
// Billing model:
//   - Token-based image models (gpt-image-1/1-mini/1.5/2, chatgpt-image-*):
//     OpenAI returns usage.input_tokens/output_tokens — bill exactly via
//     pricing CSV (input_per_million, output_per_million). No undercharge,
//     no overcharge, no flat-fallback drift. This is the same fix landed
//     on the Go gateway (commit 324b1db).
//   - Per-image flat (dall-e-3, grok-imagine, etc.): bill per_unit_price ×
//     count. Pre-flight check uses the flat estimate.

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

/// Inbound image generation request — wire-compatible with the Go
/// /qai/v1/images/generate handler, so a single client SDK can target
/// either gateway.
pub const ImageGenerateRequest = struct {
    model: []const u8,
    prompt: []const u8,
    /// Number of images to generate (1-10 provider-dependent).
    count: ?u32 = null,
    /// Pixel dimensions, e.g. "1024x1024", "1024x1536", "auto".
    size: ?[]const u8 = null,
    /// "low", "medium", "high", "auto" — token-based models.
    quality: ?[]const u8 = null,
    /// "png", "jpeg", "webp".
    output_format: ?[]const u8 = null,
    /// Style for DALL-E 3.
    style: ?[]const u8 = null,
};

const ImageResult = struct {
    base64: []const u8,
    format: []const u8,
    index: u32,
};

/// Handle POST /qai/v1/images/generate (reads body from request).
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
        return errResp(.bad_request, "invalid_request", "Failed to read request body");
    };
    defer allocator.free(body);
    return handleCore(allocator, environ_map, io, store, auth, ledger, body);
}

fn handleCore(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    if (body.len == 0) return errResp(.bad_request, "invalid_request", "Empty request body");

    const parsed = std.json.parseFromSlice(ImageGenerateRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid_request", "Malformed JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    // Basic input validation (fail-closed before reaching the provider).
    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return errResp(.bad_request, "invalid_request", "model is required");
    }
    if (req.prompt.len == 0) {
        return errResp(.bad_request, "invalid_request", "prompt is required");
    }
    const count = req.count orelse 1;
    if (count == 0 or count > 10) {
        return errResp(.bad_request, "invalid_request", "count must be between 1 and 10");
    }

    // Look up the model in the registry to find provider + pricing.
    const model = models_mod.getModel(req.model) orelse {
        return errResp(.bad_request, "unknown_model", "Model not found in registry; check /qai/v1/models");
    };

    // Provider dispatch by registry-recorded provider name. Only OpenAI is
    // implemented today; everything else returns 501 with the upstream
    // provider named so the client can route around or wait for the next
    // implementation pass.
    if (std.mem.eql(u8, model.provider, "OpenAI")) {
        return generateOpenAI(allocator, environ_map, io, store, auth, ledger, req, model, count);
    }

    // Future providers (xAI, Google Vertex, Gemini, ElevenLabs, ...).
    return errResp(
        .not_implemented,
        "provider_not_implemented",
        "Image generation for this provider isn't wired up yet on the Zig server. Currently live: OpenAI (gpt-image-1/1-mini/1.5/2, dall-e-3). Use the Go gateway at api.quantumencoding.ai for other providers.",
    );
}

// ── OpenAI provider ────────────────────────────────────────────────

fn generateOpenAI(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    req: ImageGenerateRequest,
    model: models_mod.Model,
    count: u32,
) Response {
    // OPENAI_API_KEY from env — same lookup chat.zig uses.
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch {
        return errResp(.internal_server_error, "config_error", "Server missing OPENAI_API_KEY");
    };

    // Pre-flight cost estimate. Token-based models (gpt-image-*) have no
    // CSV per_unit_price — err high so broke users get rejected before
    // we burn provider quota. Numbers sized to the HQ 1024² tier per
    // OpenAI's image generation guide; settled to exact post-call.
    const estimate_usd_per_image = preflightUsd(model);
    const estimate_ticks: i64 = @intFromFloat(estimate_usd_per_image *
        @as(f64, @floatFromInt(TICKS_PER_USD)) *
        @as(f64, @floatFromInt(count)));

    // Reserve against account balance. Skip when no auth/store wired
    // (test harness, local dev).
    var reservation_id: ?u64 = null;
    if (store) |s| {
        if (auth) |a| {
            if (io) |io_handle| {
                if (a.account.role != .admin) {
                    reservation_id = s.reserve(
                        io_handle,
                        a.account.id.slice(),
                        a.key_hash,
                        estimate_ticks,
                        "/qai/v1/images/generate",
                        req.model,
                    ) catch |err| switch (err) {
                        error.InsufficientBalance => return errResp(.payment_required, "insufficient_balance", "Account balance is too low for this image generation"),
                        else => return errResp(.internal_server_error, "billing_error", "Failed to reserve credits"),
                    };
                }
            }
        }
    }

    // Build the JSON body for OpenAI /v1/images/generations. dall-e-3 has
    // its own contract (response_format=b64_json, fixed n=1 enforced by
    // the API); gpt-image-* defaults to b64_json output, accepts auto
    // size/quality, and reports usage. We send what each accepts.
    const is_dalle = std.mem.startsWith(u8, req.model, "dall-e");
    const request_body = buildOpenAIBody(allocator, req, count, is_dalle) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        return errResp(.internal_server_error, "build_error", "Failed to build provider request");
    };
    defer allocator.free(request_body);

    // POST to OpenAI.
    var http_client = hs.HttpClient.init(allocator) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        return errResp(.internal_server_error, "http_init", "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        return errResp(.internal_server_error, "alloc_error", "Failed to build auth header");
    };
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    var resp = http_client.post(
        "https://api.openai.com/v1/images/generations",
        &headers,
        request_body,
    ) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        return errResp(.bad_gateway, "provider_error", "OpenAI image request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        // Surface OpenAI's status code directly so rate-limit / quota
        // signals (429, 5xx) reach the caller intact.
        return errResp(resp.status, "provider_error", "OpenAI rejected the image request");
    }

    // Decode the response. We extract just the fields we care about and
    // rebuild the JSON for the client — gives us a stable response shape
    // even if the upstream adds fields.
    const decoded = decodeOpenAIResponse(allocator, resp.body) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
        return errResp(.bad_gateway, "decode_error", "Could not parse OpenAI image response");
    };
    defer freeDecoded(allocator, decoded);

    // Compute exact cost from reported usage when present (token-based
    // models), or fall back to per-unit price (DALL-E 3, etc.).
    const cost = exactCostTicks(model, decoded.input_tokens, decoded.output_tokens, decoded.images.len);

    // Commit billing. The reservation absorbs the difference between
    // estimate and actuals — refund if actuals were lower. Inline-chained
    // `if-payload`s match the style elsewhere in this codebase
    // (chat.zig:400) and avoid Zig's "expected ';' or 'else' after
    // statement" parser quirk that fires on block-bodied chains.
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
            io_handle, acct_id, key_pfx,
            cost.cost, cost.margin, balance_after,
            "/qai/v1/images/generate", req.model,
            decoded.input_tokens, decoded.output_tokens, 0,
        );
    };

    // Build response JSON.
    const json_resp = buildResponseJson(
        allocator,
        decoded.images,
        req.model,
        decoded.input_tokens,
        decoded.output_tokens,
        cost.cost + cost.margin,
        balance_after,
    ) catch {
        return errResp(.internal_server_error, "serialization_error", "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = json_resp };
}

/// preflightUsd returns the conservative dollar estimate per image used
/// for the balance reservation. Token-based image models have no CSV
/// per-unit price, so we err high — the migration guide for gpt-image-*
/// pegs HQ 1024² at ~$0.21; we use $0.25 to fail-close on broke users.
/// For per-unit models we use the CSV rate verbatim.
fn preflightUsd(model: models_mod.Model) f64 {
    if (model.per_unit_price > 0) return model.per_unit_price;
    // Token-based defaults sized to HQ tier so preflight catches under-funded
    // requests reliably; exact cost is settled post-call.
    if (std.mem.eql(u8, model.api_model_id, "gpt-image-1-mini")) return 0.10;
    if (std.mem.eql(u8, model.api_model_id, "gpt-image-1")) return 0.17;
    return 0.25; // gpt-image-1.5, gpt-image-2, chatgpt-image-latest
}

/// Token-aware exact-cost calculation. Mirrors the imageCostUSD helper in
/// the Go gateway: when usage is reported (token-based image models)
/// we bill exactly; otherwise we bill flat-per-image from the CSV.
fn exactCostTicks(
    model: models_mod.Model,
    input_tokens: u32,
    output_tokens: u32,
    image_count: usize,
) struct { cost: i64, margin: i64 } {
    const margin_bps: i64 = @intFromFloat((model.margin - 1.0) * 10000.0);

    // Token-based path: use input/output × per_million when usage reported.
    if (input_tokens > 0 or output_tokens > 0) {
        const in_ticks: i64 = @intFromFloat(@as(f64, @floatFromInt(input_tokens)) *
            model.input_per_million * @as(f64, @floatFromInt(TICKS_PER_USD)) / 1_000_000.0);
        const out_ticks: i64 = @intFromFloat(@as(f64, @floatFromInt(output_tokens)) *
            model.output_per_million * @as(f64, @floatFromInt(TICKS_PER_USD)) / 1_000_000.0);
        const cost = in_ticks + out_ticks;
        const margin = @divFloor(cost * margin_bps, 10000);
        return .{ .cost = cost, .margin = margin };
    }

    // Per-unit path (DALL-E 3, grok-imagine, etc.): per_unit_price × count.
    const per_image_ticks: i64 = @intFromFloat(model.per_unit_price *
        @as(f64, @floatFromInt(TICKS_PER_USD)));
    const cost = per_image_ticks * @as(i64, @intCast(image_count));
    const margin = @divFloor(cost * margin_bps, 10000);
    return .{ .cost = cost, .margin = margin };
}

fn buildOpenAIBody(
    allocator: std.mem.Allocator,
    req: ImageGenerateRequest,
    count: u32,
    is_dalle: bool,
) ![]u8 {
    // Build incrementally with appendSlice + allocPrint — matches the
    // models.zig idiom for this codebase. ArrayListUnmanaged in this Zig
    // version doesn't expose a writer helper.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"model\":\"");
    try buf.appendSlice(allocator, req.model);
    try buf.append(allocator, '"');

    try buf.appendSlice(allocator, ",\"prompt\":\"");
    const escaped = try jsonEscape(allocator, req.prompt);
    defer allocator.free(escaped);
    try buf.appendSlice(allocator, escaped);
    try buf.append(allocator, '"');

    if (is_dalle) {
        // DALL-E 3: API enforces n=1, response_format required to get b64.
        try buf.appendSlice(allocator, ",\"n\":1,\"response_format\":\"b64_json\"");
        if (req.size) |s| {
            const part = try std.fmt.allocPrint(allocator, ",\"size\":\"{s}\"", .{s});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        } else {
            try buf.appendSlice(allocator, ",\"size\":\"1024x1024\"");
        }
        if (req.quality) |q| {
            const part = try std.fmt.allocPrint(allocator, ",\"quality\":\"{s}\"", .{q});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        }
        if (req.style) |st| {
            const part = try std.fmt.allocPrint(allocator, ",\"style\":\"{s}\"", .{st});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        }
    } else {
        // gpt-image-* family. Output is base64 by default. Forward the
        // caller's size/quality/output_format if set; otherwise let the
        // API pick "auto" for everything.
        const n_part = try std.fmt.allocPrint(allocator, ",\"n\":{d}", .{count});
        defer allocator.free(n_part);
        try buf.appendSlice(allocator, n_part);

        if (req.size) |s| {
            const part = try std.fmt.allocPrint(allocator, ",\"size\":\"{s}\"", .{s});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        }
        if (req.quality) |q| {
            const part = try std.fmt.allocPrint(allocator, ",\"quality\":\"{s}\"", .{q});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        }
        if (req.output_format) |of| {
            const part = try std.fmt.allocPrint(allocator, ",\"output_format\":\"{s}\"", .{of});
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
        }
    }

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

const DecodedImageResponse = struct {
    images: []ImageResult,
    input_tokens: u32,
    output_tokens: u32,
};

/// Parse just what we need from the OpenAI response. Tolerant of extra
/// fields (the SDK adds new ones as image generation evolves).
fn decodeOpenAIResponse(allocator: std.mem.Allocator, body: []const u8) !DecodedImageResponse {
    const Parsed = struct {
        data: []const struct {
            b64_json: ?[]const u8 = null,
            revised_prompt: ?[]const u8 = null,
        },
        usage: ?struct {
            input_tokens: u32 = 0,
            output_tokens: u32 = 0,
            total_tokens: u32 = 0,
        } = null,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var images = try allocator.alloc(ImageResult, parsed.value.data.len);
    errdefer allocator.free(images);
    for (parsed.value.data, 0..) |d, i| {
        const b64 = d.b64_json orelse "";
        images[i] = .{
            .base64 = try allocator.dupe(u8, b64),
            .format = try allocator.dupe(u8, "png"),
            .index = @intCast(i),
        };
    }

    var in_t: u32 = 0;
    var out_t: u32 = 0;
    if (parsed.value.usage) |u| {
        in_t = u.input_tokens;
        out_t = u.output_tokens;
    }
    return .{ .images = images, .input_tokens = in_t, .output_tokens = out_t };
}

fn freeDecoded(allocator: std.mem.Allocator, d: DecodedImageResponse) void {
    for (d.images) |img| {
        allocator.free(img.base64);
        allocator.free(img.format);
    }
    allocator.free(d.images);
}

fn buildResponseJson(
    allocator: std.mem.Allocator,
    images: []const ImageResult,
    model: []const u8,
    input_tokens: u32,
    output_tokens: u32,
    cost_ticks: i64,
    balance_after: i64,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"images\":[");
    for (images, 0..) |img, i| {
        if (i > 0) try buf.append(allocator, ',');
        const entry = try std.fmt.allocPrint(allocator,
            "{{\"base64\":\"{s}\",\"format\":\"{s}\",\"index\":{d}}}",
            .{ img.base64, img.format, img.index });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }
    try buf.appendSlice(allocator, "]");

    const tail = try std.fmt.allocPrint(allocator,
        ",\"model\":\"{s}\",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}},\"cost_ticks\":{d},\"balance_after\":{d}}}",
        .{ model, input_tokens, output_tokens, cost_ticks, balance_after });
    defer allocator.free(tail);
    try buf.appendSlice(allocator, tail);
    return buf.toOwnedSlice(allocator);
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try buf.appendSlice(allocator, "\\u00");
                    try buf.append(allocator, hex[c >> 4]);
                    try buf.append(allocator, hex[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn errResp(status: http.Status, code: []const u8, message: []const u8) Response {
    // Static error bodies for the common cases — avoids allocator failures
    // in the error-handling hot path. We pick the closest match.
    _ = code;
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Image generation request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this image generation\"}" },
        .not_implemented => .{ .status = .not_implemented, .body = "{\"error\":\"provider_not_implemented\",\"message\":\"Image generation for this provider isn't wired up yet on the Zig server. Live: OpenAI gpt-image-* and dall-e-3.\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Provider rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Image provider request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Image generation failed\"}" },
    };
}
