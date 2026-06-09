// HeyGen catalog endpoints — read-only GET proxies.
//
//   GET /qai/v1/video/avatars        → HeyGen /v2/avatars
//   GET /qai/v1/video/templates      → HeyGen /v2/templates
//   GET /qai/v1/video/heygen-voices  → HeyGen /v2/voices
//
// These are free catalog reads. The HeyGen API is JSON over HTTPS with an
// `x-api-key` header; we pass the upstream response straight through. The
// HeyGen video-generation endpoints (studio/translate/photo-avatar/
// digital-twin) are async and route through the job queue — separate work.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const BASE = "https://api.heygen.com";
const STARFISH_COST: i64 = 200_000_000; // $0.02 flat
const HEYGEN_MARGIN_BPS: i64 = 1250;

pub fn handleAvatars(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) Response {
    return proxy(allocator, environ_map, BASE ++ "/v2/avatars");
}

pub fn handleTemplates(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) Response {
    return proxy(allocator, environ_map, BASE ++ "/v2/templates");
}

pub fn handleVoices(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) Response {
    return proxy(allocator, environ_map, BASE ++ "/v2/voices");
}

// ── POST /qai/v1/audio/starfish-tts — HeyGen Starfish TTS (sync JSON) ─

const StarfishRequest = struct {
    text: []const u8 = "",
    voice_id: []const u8 = "",
    input_type: ?[]const u8 = null,
    speed: ?f64 = null,
    language: ?[]const u8 = null,
    locale: ?[]const u8 = null,
};

pub fn handleStarfishTts(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    const body = json_util.readBody(request, allocator, 256 * 1024) catch return err(.bad_gateway);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(StarfishRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errMsg(.bad_request);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.text.len == 0 or req.voice_id.len == 0) return errMsg(.bad_request);

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "HEYGEN_API_KEY") catch return err(.service_unavailable);

    const cost = STARFISH_COST;
    const margin = @divFloor(cost * HEYGEN_MARGIN_BPS, 10000);
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |ioh| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(ioh, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/audio/starfish-tts", "heygen_starfish") catch |e| switch (e) {
                error.InsufficientBalance => return errMsg(.payment_required),
                else => return err(.internal_server_error),
            };
        }
    };

    // Re-encode the body via Stringify (caller-controlled strings escaped).
    const out_body = std.json.Stringify.valueAlloc(allocator, .{
        .text = req.text,
        .voice_id = req.voice_id,
        .input_type = req.input_type,
        .speed = req.speed,
        .language = req.language,
        .locale = req.locale,
    }, .{ .emit_null_optional_fields = false }) catch {
        rb(store, io, reservation_id);
        return err(.internal_server_error);
    };
    defer allocator.free(out_body);

    var client = hs.HttpClient.init(allocator) catch {
        rb(store, io, reservation_id);
        return err(.internal_server_error);
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "x-api-key", .value = api_key } };
    var resp = client.post(BASE ++ "/v1/audio/text_to_speech", &headers, out_body) catch {
        rb(store, io, reservation_id);
        return err(.bad_gateway);
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        rb(store, io, reservation_id);
        return err(.bad_gateway);
    }

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |ioh| s.commitReservation(ioh, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| if (io) |ioh| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(ioh, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/audio/starfish-tts", "heygen_starfish", 0, 0, 0);
    };

    const out = mergeCost(allocator, resp.body, cost + margin, balance_after) catch return err(.internal_server_error);
    return .{ .status = .ok, .body = out };
}

fn mergeCost(allocator: std.mem.Allocator, upstream: []const u8, cost_ticks: i64, balance_after: i64) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, upstream, .{}) catch return allocator.dupe(u8, upstream);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, upstream);
    const arena = parsed.arena.allocator();
    var obj = parsed.value.object;
    try obj.put(arena, "cost_ticks", .{ .integer = cost_ticks });
    try obj.put(arena, "balance_after", .{ .integer = balance_after });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{});
}

fn rb(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |ioh| s.rollbackReservation(ioh, rid);
}

fn errMsg(status: http.Status) Response {
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"text and voice_id are required\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low\"}" },
        else => err(status),
    };
}

// ── video/translate — HeyGen video translation (async; job worker) ───
//
// Submit POST /v2/video_translate → {data:{video_translate_id}}, poll
// GET /v2/video_translate/{id} → {data:{status, url}} until status "success".
// Billed flat. Invoked by the job worker (the sync route enqueues it).

const TRANSLATE_COST: i64 = 2_000_000_000; // $0.20 flat
const TR_POLL_INTERVAL_NS: u64 = 8 * std.time.ns_per_s;
const TR_MAX_POLLS: u32 = 75; // ~10 min

const TranslateParams = struct {
    video_url: []const u8 = "",
    output_language: []const u8 = "",
    source_language: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub fn translateCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io_opt: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const io = io_opt orelse return err(.internal_server_error);
    const parsed = std.json.parseFromSlice(TranslateParams, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errMsg(.bad_request);
    defer parsed.deinit();
    const p = parsed.value;
    if (p.video_url.len == 0 or p.output_language.len == 0) return errMsg(.bad_request);

    const api_key = hs.ai.getApiKeyFromEnv(env, "HEYGEN_API_KEY") catch return err(.service_unavailable);

    const cost = TRANSLATE_COST;
    const margin = @divFloor(cost * HEYGEN_MARGIN_BPS, 10000);
    var reservation_id: ?u64 = null;
    if (st) |s| if (au) |auth| {
        if (auth.account.role != .admin) {
            reservation_id = s.reserve(io, auth.account.id.slice(), auth.key_hash, @max(cost + margin, 1000), "video/translate", "heygen_translate") catch |e| switch (e) {
                error.InsufficientBalance => return errMsg(.payment_required),
                else => return err(.internal_server_error),
            };
        }
    };

    const submit_body = std.json.Stringify.valueAlloc(a, .{
        .video_url = p.video_url,
        .output_language = p.output_language,
        .source_language = p.source_language,
        .title = p.title,
    }, .{ .emit_null_optional_fields = false }) catch return rbErr(st, io, reservation_id);

    var client = hs.HttpClient.init(a) catch return rbErr(st, io, reservation_id);
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "x-api-key", .value = api_key } };

    var sresp = client.post(BASE ++ "/v2/video_translate", &headers, submit_body) catch return rbErr(st, io, reservation_id);
    const tr_id = blk: {
        defer sresp.deinit();
        if (sresp.status != .ok) return rbErr(st, io, reservation_id);
        const S = struct { data: struct { video_translate_id: []const u8 = "" } = .{} };
        const sp = std.json.parseFromSlice(S, a, sresp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return rbErr(st, io, reservation_id);
        defer sp.deinit();
        if (sp.value.data.video_translate_id.len == 0) return rbErr(st, io, reservation_id);
        break :blk a.dupe(u8, sp.value.data.video_translate_id) catch return rbErr(st, io, reservation_id);
    };

    const poll_url = std.fmt.allocPrint(a, "{s}/v2/video_translate/{s}", .{ BASE, tr_id }) catch return rbErr(st, io, reservation_id);
    const poll_headers = [_]http.Header{.{ .name = "x-api-key", .value = api_key }};
    var attempt: u32 = 0;
    while (attempt < TR_MAX_POLLS) : (attempt += 1) {
        io.sleep(.{ .nanoseconds = TR_POLL_INTERVAL_NS }, .real) catch {};
        var presp = client.get(poll_url, &poll_headers) catch continue;
        const P = struct { data: struct { status: []const u8 = "", url: []const u8 = "" } = .{} };
        const pp = std.json.parseFromSlice(P, a, presp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            presp.deinit();
            continue;
        };
        const status = pp.value.data.status;
        const url_owned = a.dupe(u8, pp.value.data.url) catch "";
        const done = std.mem.eql(u8, status, "success");
        const failed = std.mem.eql(u8, status, "failed");
        presp.deinit();
        if (done) {
            var balance_after: i64 = 0;
            if (reservation_id) |rid| if (st) |s| s.commitReservation(io, rid, cost, margin) catch {};
            if (au) |auth| if (st) |s| {
                if (s.getAccount(auth.account.id.slice())) |acct| balance_after = acct.balance_ticks;
            };
            if (lg) |l| {
                const acct_id = if (au) |auth| auth.account.id.slice() else "anonymous";
                const key_pfx = if (au) |auth| auth.key.prefix.slice() else "none";
                l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, "video/translate", "heygen_translate", 0, 0, 0);
            }
            const out = std.json.Stringify.valueAlloc(a, .{
                .video_translate_id = tr_id,
                .status = "success",
                .video_url = url_owned,
                .cost_ticks = cost + margin,
                .balance_after = balance_after,
            }, .{}) catch return err(.internal_server_error);
            return .{ .status = .ok, .body = out };
        }
        if (failed) return rbErr(st, io, reservation_id);
    }
    return rbErr(st, io, reservation_id);
}

fn rbErr(st: ?*store_mod.Store, io: std.Io, reservation_id: ?u64) Response {
    if (reservation_id) |rid| if (st) |s| s.rollbackReservation(io, rid);
    return err(.bad_gateway);
}

fn proxy(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, url: []const u8) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "HEYGEN_API_KEY") catch
        return err(.service_unavailable);

    var client = hs.HttpClient.init(allocator) catch return err(.internal_server_error);
    defer client.deinit();

    const headers = [_]http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };

    var resp = client.get(url, &headers) catch return err(.bad_gateway);
    defer resp.deinit();
    if (resp.status != .ok) return err(.bad_gateway);

    const out = allocator.dupe(u8, resp.body) catch return err(.internal_server_error);
    return .{ .status = .ok, .body = out };
}

fn err(status: http.Status) Response {
    return switch (status) {
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"HeyGen is not configured on this server\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"HeyGen request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"HeyGen request failed\"}" },
    };
}
