// Video generation — Veo via the genai predictLongRunning endpoint.
//
// Dispatched as the "video/generate" job type (the cosmic-duck client submits
// it through POST /qai/v1/jobs), so this core is invoked by the job worker on
// a background thread — blocking on the long poll is fine there.
//
// Flow (Veo on generativelanguage.googleapis.com, GEMINI_API_KEY):
//   submit:  POST  /v1beta/models/<model>:predictLongRunning?key=KEY
//            body { instances:[{prompt, image?}], parameters:{aspectRatio,…} }
//            → { name: "operations/…" }
//   poll:    GET   /v1beta/<op>?key=KEY  until { done:true }
//            → response.generateVideoResponse.generatedSamples[].video.uri
//   fetch:   GET   <uri>?key=KEY  → raw mp4 bytes → base64
//
// Result (matches the client): { videos:[{base64,format,size_bytes,index}],
// model, cost_ticks, balance_after }. Billed per second from the registry's
// per_unit_ticks (veo-3.1 $0.40/s). Integer math.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const models_mod = @import("models.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const router = @import("router.zig");
const Response = router.Response;

const BASE = "https://generativelanguage.googleapis.com";
const POLL_INTERVAL_NS: u64 = 10 * std.time.ns_per_s;
const MAX_POLL_ATTEMPTS: u32 = 60; // ~10 min at 10s
const DEFAULT_MODEL = "veo-3.1-generate-preview";

const VideoParams = struct {
    model: ?[]const u8 = null,
    prompt: []const u8 = "",
    duration_seconds: ?u32 = null,
    aspect_ratio: ?[]const u8 = null,
    image_base64: ?[]const []const u8 = null,
};

const VideoOut = struct {
    base64: []const u8,
    format: []const u8,
    size_bytes: usize,
    index: u32,
};

/// Job-worker entry point for "video/generate".
pub fn generateCore(
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    io_opt: ?std.Io,
    st: ?*store_mod.Store,
    au: ?*const types.AuthContext,
    lg: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    const io = io_opt orelse return errStatus(.internal_server_error, "io unavailable");

    const parsed = std.json.parseFromSlice(VideoParams, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return errStatus(.bad_request, "invalid video params");
    const p = parsed.value;
    if (p.prompt.len == 0) return errStatus(.bad_request, "prompt is required");

    const model = p.model orelse DEFAULT_MODEL;
    const duration = p.duration_seconds orelse 8;

    const api_key = hs.ai.getApiKeyFromEnv(env, "GEMINI_API_KEY") catch
        return errStatus(.service_unavailable, "video generation not configured (GEMINI_API_KEY unset)");

    // Cost: per-second from the registry × duration.
    const reg = models_mod.getModel(model);
    const per_sec: i64 = if (reg) |m| m.per_unit_ticks else 4_000_000_000; // $0.40/s default
    const margin_bps: i64 = if (reg) |m| m.margin_bps else 2500;
    const cost = per_sec * @as(i64, duration);
    const margin = @divFloor(cost * margin_bps, 10000);

    var reservation_id: ?u64 = null;
    if (st) |s| if (au) |auth| {
        if (auth.account.role != .admin) {
            reservation_id = s.reserve(io, auth.account.id.slice(), auth.key_hash, @max(cost + margin, 1000), "video/generate", model) catch |e| switch (e) {
                error.InsufficientBalance => return errStatus(.payment_required, "Account balance is too low for this video"),
                else => return errStatus(.internal_server_error, "reserve failed"),
            };
        }
    };

    var client = hs.HttpClient.init(a) catch return rollbackErr(st, io, reservation_id, "http init");
    defer client.deinit();

    const headers = [_]http.Header{.{ .name = "Content-Type", .value = "application/json" }};

    // Submit.
    const submit_body = buildSubmitBody(a, p, duration) catch return rollbackErr(st, io, reservation_id, "build");
    const submit_url = std.fmt.allocPrint(a, "{s}/v1beta/models/{s}:predictLongRunning?key={s}", .{ BASE, model, api_key }) catch return rollbackErr(st, io, reservation_id, "alloc");
    var sresp = client.post(submit_url, &headers, submit_body) catch return rollbackErr(st, io, reservation_id, "Veo submit failed");
    const op_name = blk: {
        defer sresp.deinit();
        if (sresp.status != .ok) return rollbackErr(st, io, reservation_id, "Veo rejected the submit");
        const S = struct { name: []const u8 = "" };
        const sp = std.json.parseFromSlice(S, a, sresp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return rollbackErr(st, io, reservation_id, "parse submit");
        defer sp.deinit();
        if (sp.value.name.len == 0) return rollbackErr(st, io, reservation_id, "no operation name");
        break :blk a.dupe(u8, sp.value.name) catch return rollbackErr(st, io, reservation_id, "alloc");
    };

    // Poll.
    const poll_url = std.fmt.allocPrint(a, "{s}/v1beta/{s}?key={s}", .{ BASE, op_name, api_key }) catch return rollbackErr(st, io, reservation_id, "alloc");
    var attempt: u32 = 0;
    while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
        io.sleep(.{ .nanoseconds = POLL_INTERVAL_NS }, .real) catch {};
        var presp = client.get(poll_url, &headers) catch continue;
        const Poll = struct {
            done: bool = false,
            response: ?struct {
                generateVideoResponse: ?struct {
                    generatedSamples: []const struct {
                        video: struct { uri: []const u8 = "" } = .{},
                    } = &.{},
                } = null,
            } = null,
        };
        const pp = std.json.parseFromSlice(Poll, a, presp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            presp.deinit();
            continue;
        };
        if (!pp.value.done) {
            presp.deinit();
            continue;
        }
        // Done — collect sample URIs (dup before freeing presp).
        var uris: std.ArrayListUnmanaged([]const u8) = .empty;
        if (pp.value.response) |r| if (r.generateVideoResponse) |gvr| {
            for (gvr.generatedSamples) |s| {
                if (s.video.uri.len > 0) uris.append(a, a.dupe(u8, s.video.uri) catch continue) catch break;
            }
        };
        presp.deinit();
        if (uris.items.len == 0) return rollbackErr(st, io, reservation_id, "Veo returned no videos");

        // Download each video and base64-encode.
        var videos: std.ArrayListUnmanaged(VideoOut) = .empty;
        for (uris.items, 0..) |uri, i| {
            const dl_url = std.fmt.allocPrint(a, "{s}?key={s}", .{ uri, api_key }) catch continue;
            var dresp = client.get(dl_url, &.{}) catch continue;
            defer dresp.deinit();
            if (dresp.status != .ok) continue;
            const b64_len = std.base64.standard.Encoder.calcSize(dresp.body.len);
            const b64 = a.alloc(u8, b64_len) catch continue;
            _ = std.base64.standard.Encoder.encode(b64, dresp.body);
            videos.append(a, .{ .base64 = b64, .format = "mp4", .size_bytes = dresp.body.len, .index = @intCast(i) }) catch break;
        }
        if (videos.items.len == 0) return rollbackErr(st, io, reservation_id, "Veo video download failed");

        // Commit billing.
        var balance_after: i64 = 0;
        if (reservation_id) |rid| if (st) |s| s.commitReservation(io, rid, cost, margin) catch {};
        if (au) |auth| if (st) |s| {
            if (s.getAccount(auth.account.id.slice())) |acct| balance_after = acct.balance_ticks;
        };
        if (lg) |l| {
            const acct_id = if (au) |auth| auth.account.id.slice() else "anonymous";
            const key_pfx = if (au) |auth| auth.key.prefix.slice() else "none";
            l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, "video/generate", model, 0, 0, 0);
        }

        const out = std.json.Stringify.valueAlloc(a, .{
            .videos = videos.items,
            .model = model,
            .cost_ticks = cost + margin,
            .balance_after = balance_after,
        }, .{}) catch return errStatus(.internal_server_error, "serialize failed");
        return .{ .status = .ok, .body = out };
    }
    return rollbackErr(st, io, reservation_id, "Veo timed out");
}

fn buildSubmitBody(a: std.mem.Allocator, p: VideoParams, duration: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();

    try jw.objectField("instances");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("prompt");
    try jw.write(p.prompt);
    // Optional first-frame image conditioning (first element of image_base64).
    if (p.image_base64) |imgs| if (imgs.len > 0 and imgs[0].len > 0) {
        try jw.objectField("image");
        try jw.beginObject();
        try jw.objectField("inlineData");
        try jw.beginObject();
        try jw.objectField("mimeType");
        try jw.write("image/jpeg");
        try jw.objectField("data");
        try jw.write(imgs[0]);
        try jw.endObject();
        try jw.endObject();
    };
    try jw.endObject();
    try jw.endArray();

    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("personGeneration");
    try jw.write("allow_all");
    try jw.objectField("aspectRatio");
    try jw.write(p.aspect_ratio orelse "16:9");
    try jw.objectField("sampleCount");
    try jw.write(@as(u32, 1));
    try jw.objectField("durationSeconds");
    try jw.write(duration);
    try jw.objectField("resolution");
    try jw.write("720p");
    try jw.objectField("generateAudio");
    try jw.write(false);
    try jw.endObject();

    try jw.endObject();
    return aw.toOwnedSlice();
}

fn rollbackErr(st: ?*store_mod.Store, io: std.Io, reservation_id: ?u64, msg: []const u8) Response {
    if (reservation_id) |rid| if (st) |s| s.rollbackReservation(io, rid);
    _ = msg;
    return .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Video generation failed\"}" };
}

fn errStatus(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Video request rejected\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"Video generation is not configured on this server\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this video\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Video generation failed\"}" },
    };
}
