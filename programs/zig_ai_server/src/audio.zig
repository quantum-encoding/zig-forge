// Audio endpoints — text-to-speech
//
//   POST /qai/v1/audio/tts   (OpenAI /v1/audio/speech)
//
// Wire-compatible with the Go /qai/v1/audio/tts handler:
//   request:  { model, text, voice?, format? }
//   response: { audio_base64, format, size_bytes, model, cost_ticks, balance_after }
//
// OpenAI TTS is a clean JSON-in / audio-bytes-out call, so it's implemented
// here directly (same staged-provider pattern as images.zig). ElevenLabs and
// other speech providers return 501. STT, voice-clone, dub, and the other
// ElevenLabs media endpoints need multipart/form-data uploads, which the
// in-tree HTTP client doesn't support yet — they remain stubs.
//
// Billing: per-character for the per-1M-char models (tts-1, tts-1-hd) using
// the registry's per_unit_ticks (ticks per 1M chars); token-estimated for the
// token-priced models (gpt-4o-mini-tts) since /v1/audio/speech reports no
// usage. Integer math only; cost is known up-front (text length), so we
// reserve the exact amount and commit it.

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
const MAX_TTS_TEXT: usize = 100_000; // generous; OpenAI caps ~4096 chars/call but we validate softly
const MAX_STT_BODY: usize = 40 * 1024 * 1024; // base64 audio (OpenAI caps the file at 25 MB → ~33 MB b64)

const TtsRequest = struct {
    model: []const u8,
    text: []const u8,
    voice: ?[]const u8 = null,
    format: ?[]const u8 = null,
};

pub fn handleTts(
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
    return ttsCore(allocator, environ_map, io, store, auth, ledger, body);
}

/// Body-taking core (also invoked by the async job worker, which holds the
/// raw params rather than an http.Request).
pub fn ttsCore(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(TtsRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return errResp(.bad_request, "model is required");
    }
    if (req.text.len == 0) return errResp(.bad_request, "text is required");
    if (req.text.len > MAX_TTS_TEXT) return errResp(.bad_request, "text too long");

    const model = models_mod.getModel(req.model) orelse {
        return errResp(.bad_request, "Model not found in registry; check /qai/v1/models");
    };
    if (!std.mem.eql(u8, model.provider, "OpenAI")) {
        return errResp(.not_implemented, "TTS for this provider isn't wired up on the Zig server yet. Live: OpenAI (tts-1, tts-1-hd, gpt-4o-mini-tts). Use the Go gateway for ElevenLabs.");
    }

    return speakOpenAI(allocator, environ_map, io, store, auth, ledger, req, model);
}

fn speakOpenAI(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    req: TtsRequest,
    model: models_mod.Model,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch {
        return errResp(.internal_server_error, "Server missing OPENAI_API_KEY");
    };

    // Cost is known up-front from the character count.
    const cost = ttsCost(model, req.text.len);
    const reserve_ticks = cost.cost + cost.margin;

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(
                io_handle,
                a.account.id.slice(),
                a.key_hash,
                @max(reserve_ticks, 1000),
                "/qai/v1/audio/tts",
                req.model,
            ) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this TTS request"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    const format = req.format orelse "mp3";
    const voice = req.voice orelse "alloy";

    // OpenAI /v1/audio/speech body. All caller-controlled strings escaped by
    // std.json.Stringify (JSON-IN-FMT).
    const request_body = std.json.Stringify.valueAlloc(allocator, .{
        .model = req.model,
        .input = req.text,
        .voice = voice,
        .response_format = format,
    }, .{}) catch {
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

    var resp = http_client.post("https://api.openai.com/v1/audio/speech", &headers, request_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "OpenAI TTS request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "OpenAI rejected the TTS request");
    }

    // Response body is the raw audio. Base64-encode for JSON transport.
    const audio_bytes = resp.body;
    const b64_len = std.base64.standard.Encoder.calcSize(audio_bytes.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to encode audio");
    };
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, audio_bytes);

    // Commit billing (estimate == actual; char count is exact).
    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        s.commitReservation(io_handle, rid, cost.cost, cost.margin) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io_handle, acct_id, key_pfx, cost.cost, cost.margin, balance_after, "/qai/v1/audio/tts", req.model, 0, 0, 0);
    };

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .audio_base64 = audio_b64,
        .format = format,
        .size_bytes = audio_bytes.len,
        .model = req.model,
        .cost_ticks = cost.cost + cost.margin,
        .balance_after = balance_after,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

// ── ElevenLabs voice transforms (isolate / speech-to-speech / voice-design)
//
// isolate + speech-to-speech are multipart audio-in → audio-out; voice-design
// is JSON-in → preview clips. All billed flat (the registry has no per-op
// entry for these yet — conservative flat estimates, noted for follow-up).

const ISOLATE_COST: i64 = 500_000_000; // $0.05
const S2S_COST: i64 = 500_000_000; // $0.05
const VOICE_DESIGN_COST: i64 = 1_000_000_000; // $0.10
const ELEVEN_MARGIN_BPS: i64 = 1250;

const IsolateRequest = struct { audio_base64: []const u8 = "", format: ?[]const u8 = null };
const S2SRequest = struct {
    audio_base64: []const u8 = "",
    voice_id: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    model: ?[]const u8 = null,
    format: ?[]const u8 = null,
};
const VoiceDesignRequest = struct {
    voice_description: []const u8 = "",
    sample_text: []const u8 = "",
    format: ?[]const u8 = null,
};

/// POST /qai/v1/audio/isolate — strip background noise from a voice clip.
pub fn handleIsolate(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(IsolateRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    if (parsed.value.audio_base64.len == 0) return errResp(.bad_request, "audio_base64 is required");

    const audio = decodeB64(allocator, parsed.value.audio_base64) catch return errResp(.bad_request, "invalid base64 audio");
    defer allocator.free(audio);

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addFile("audio", "audio.mp3", "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    return elevenAudioOut(allocator, environ_map, io_handle, store, auth, ledger, &mp, "https://api.elevenlabs.io/v1/audio-isolation", "/qai/v1/audio/isolate", "eleven_isolate", ISOLATE_COST);
}

/// POST /qai/v1/audio/speech-to-speech — re-voice a clip with a target voice.
pub fn handleSpeechToSpeech(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(S2SRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.audio_base64.len == 0) return errResp(.bad_request, "audio_base64 is required");
    const voice_id = req.voice_id orelse req.voice orelse return errResp(.bad_request, "voice_id is required");

    const audio = decodeB64(allocator, req.audio_base64) catch return errResp(.bad_request, "invalid base64 audio");
    defer allocator.free(audio);

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addFile("audio", "audio.mp3", "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    mp.addField("model_id", req.model orelse "eleven_multilingual_sts_v2") catch return errResp(.internal_server_error, "build");

    const url = std.fmt.allocPrint(allocator, "https://api.elevenlabs.io/v1/speech-to-speech/{s}", .{voice_id}) catch return errResp(.internal_server_error, "alloc");
    defer allocator.free(url);
    return elevenAudioOut(allocator, environ_map, io_handle, store, auth, ledger, &mp, url, "/qai/v1/audio/speech-to-speech", "eleven_s2s", S2S_COST);
}

/// POST /qai/v1/audio/voice-design — generate candidate voices from a prompt.
pub fn handleVoiceDesign(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(VoiceDesignRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.voice_description.len == 0) return errResp(.bad_request, "voice_description is required");
    if (req.sample_text.len == 0) return errResp(.bad_request, "sample_text is required");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");

    const cost = VOICE_DESIGN_COST;
    const margin = @divFloor(cost * ELEVEN_MARGIN_BPS, 10000);
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |ioh| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(ioh, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/audio/voice-design", "eleven_voice_design") catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    const el_body = std.json.Stringify.valueAlloc(allocator, .{ .voice_description = req.voice_description, .text = req.sample_text }, .{}) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "build");
    };
    defer allocator.free(el_body);

    var client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "http init");
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "xi-api-key", .value = api_key } };
    var resp = client.post("https://api.elevenlabs.io/v1/text-to-voice/create-previews", &headers, el_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs rejected the request");
    }

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |ioh| s.commitReservation(ioh, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| if (io) |ioh| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(ioh, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/audio/voice-design", "eleven_voice_design", 0, 0, 0);
    };

    // Merge the ElevenLabs previews response with billing fields.
    const out = mergeBilling(allocator, resp.body, cost + margin, balance_after) catch {
        return errResp(.internal_server_error, "serialize");
    };
    return .{ .status = .ok, .body = out };
}

/// Shared multipart-in → audio-bytes-out flow for isolate / speech-to-speech.
fn elevenAudioOut(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    mp: *@import("multipart.zig").Builder,
    url: []const u8,
    endpoint: []const u8,
    model_id: []const u8,
    cost: i64,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");
    const margin = @divFloor(cost * ELEVEN_MARGIN_BPS, 10000);

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), endpoint, model_id) catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    const req_body = mp.finish() catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "build");
    };
    defer allocator.free(req_body);
    const content_type = mp.contentType(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "build");
    };
    defer allocator.free(content_type);

    var client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "http init");
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = content_type }, .{ .name = "xi-api-key", .value = api_key } };
    var resp = client.post(url, &headers, req_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs rejected the request");
    }

    const b64_len = std.base64.standard.Encoder.calcSize(resp.body.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "encode");
    };
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, resp.body);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| s.commitReservation(io, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, endpoint, model_id, 0, 0, 0);
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .audio_base64 = audio_b64,
        .format = "mp3",
        .size_bytes = resp.body.len,
        .model = model_id,
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch return errResp(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

fn decodeB64(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(b64);
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    try decoder.decode(buf, b64);
    return buf;
}

/// Parse an upstream JSON object and inject cost_ticks/balance_after.
fn mergeBilling(allocator: std.mem.Allocator, upstream: []const u8, cost_ticks: i64, balance_after: i64) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, upstream, .{}) catch
        return allocator.dupe(u8, upstream);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, upstream);
    const arena = parsed.arena.allocator();
    var obj = parsed.value.object;
    try obj.put(arena, "cost_ticks", .{ .integer = cost_ticks });
    try obj.put(arena, "balance_after", .{ .integer = balance_after });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{});
}

// ── ElevenLabs dialogue / align / remix / voice-clone ────────────────

const DIALOGUE_COST: i64 = 500_000_000; // $0.05 flat
const ALIGN_COST: i64 = 500_000_000;
const REMIX_COST: i64 = 1_000_000_000; // $0.10

const DialogueVoice = struct { voice_id: []const u8 = "", name: []const u8 = "" };
const DialogueRequest = struct {
    text: []const u8 = "",
    voices: []const DialogueVoice = &.{},
    model: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    seed: ?i64 = null,
};

/// POST /qai/v1/audio/dialogue — multi-speaker dialogue from a "Speaker: line"
/// script + a voices roster. Parses the script into ElevenLabs `inputs[]`.
pub fn handleDialogue(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(DialogueRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.text.len == 0) return errResp(.bad_request, "text is required");
    if (req.voices.len == 0) return errResp(.bad_request, "voices is required");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");

    // Build inputs[]: parse "Speaker: text" lines, map speaker→voice_id; lines
    // without a known speaker fall back to the first voice.
    const el_body = buildDialogueBody(allocator, req) catch return errResp(.internal_server_error, "build");
    defer allocator.free(el_body);

    const cost = DIALOGUE_COST;
    const margin = @divFloor(cost * ELEVEN_MARGIN_BPS, 10000);
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |ioh| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(ioh, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/audio/dialogue", "eleven_v3") catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    const out_fmt = req.output_format orelse "mp3_44100_128";
    const url = std.fmt.allocPrint(allocator, "https://api.elevenlabs.io/v1/text-to-dialogue?output_format={s}", .{out_fmt}) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "alloc");
    };
    defer allocator.free(url);

    var client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "http init");
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "xi-api-key", .value = api_key } };
    var resp = client.post(url, &headers, el_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs rejected the request");
    }

    return audioResponse(allocator, resp.body, "eleven_v3", cost, margin, store, auth, ledger, io, reservation_id);
}

fn buildDialogueBody(allocator: std.mem.Allocator, req: DialogueRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("inputs");
    try jw.beginArray();
    var any_line = false;
    var it = std.mem.splitScalar(u8, req.text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // "Speaker: text" → match speaker to a voice; else first voice.
        var speaker: []const u8 = "";
        var text = line;
        if (std.mem.indexOfScalar(u8, line, ':')) |c| {
            speaker = std.mem.trim(u8, line[0..c], " \t");
            text = std.mem.trim(u8, line[c + 1 ..], " \t");
        }
        var voice_id: []const u8 = req.voices[0].voice_id;
        for (req.voices) |v| {
            if (speaker.len > 0 and std.mem.eql(u8, v.name, speaker)) {
                voice_id = v.voice_id;
                break;
            }
        }
        if (text.len == 0) continue;
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(text);
        try jw.objectField("voice_id");
        try jw.write(voice_id);
        try jw.endObject();
        any_line = true;
    }
    if (!any_line) {
        // No parsable lines — single input with the whole text + first voice.
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(req.text);
        try jw.objectField("voice_id");
        try jw.write(req.voices[0].voice_id);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("model_id");
    try jw.write(req.model orelse "eleven_v3");
    if (req.seed) |s| {
        try jw.objectField("seed");
        try jw.write(s);
    }
    try jw.endObject();
    return aw.toOwnedSlice();
}

const AlignRequest = struct { audio_base64: []const u8 = "", text: []const u8 = "", language: ?[]const u8 = null };

/// POST /qai/v1/audio/align — word-level timestamps for audio + transcript.
pub fn handleAlign(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(AlignRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.audio_base64.len == 0) return errResp(.bad_request, "audio_base64 is required");
    if (req.text.len == 0) return errResp(.bad_request, "text is required");

    const audio = decodeB64(allocator, req.audio_base64) catch return errResp(.bad_request, "invalid base64 audio");
    defer allocator.free(audio);

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addFile("file", "audio.mp3", "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    mp.addField("text", req.text) catch return errResp(.internal_server_error, "build");
    if (req.language) |l| mp.addField("language_code", l) catch return errResp(.internal_server_error, "build");

    // forced-alignment returns JSON (not audio) — pass through + cost.
    return elevenJsonOut(allocator, environ_map, io_handle, store, auth, ledger, &mp, "https://api.elevenlabs.io/v1/forced-alignment", "/qai/v1/audio/align", "eleven_forced_alignment", ALIGN_COST);
}

const RemixRequest = struct {
    audio_base64: []const u8 = "",
    gender: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    style: ?[]const u8 = null,
    pacing: ?[]const u8 = null,
    audio_quality: ?[]const u8 = null,
    prompt_strength: ?[]const u8 = null,
    script: ?[]const u8 = null,
};

/// POST /qai/v1/audio/remix — re-style a voice clip (ElevenLabs voice remix).
pub fn handleRemix(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(RemixRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.audio_base64.len == 0) return errResp(.bad_request, "audio_base64 is required");

    const audio = decodeB64(allocator, req.audio_base64) catch return errResp(.bad_request, "invalid base64 audio");
    defer allocator.free(audio);

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addFile("audio", "audio.mp3", "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    if (req.gender) |v| mp.addField("gender", v) catch {};
    if (req.accent) |v| mp.addField("accent", v) catch {};
    if (req.style) |v| mp.addField("style", v) catch {};
    if (req.pacing) |v| mp.addField("pacing", v) catch {};
    if (req.audio_quality) |v| mp.addField("audio_quality", v) catch {};
    if (req.prompt_strength) |v| mp.addField("prompt_strength", v) catch {};
    if (req.script) |v| mp.addField("script", v) catch {};

    return elevenAudioOut(allocator, environ_map, io_handle, store, auth, ledger, &mp, "https://api.elevenlabs.io/v1/voice-generation/remix", "/qai/v1/audio/remix", "eleven_voice_remix", REMIX_COST);
}

const CloneRequest = struct {
    name: []const u8 = "",
    description: ?[]const u8 = null,
    /// One or more base64-encoded audio samples.
    samples: []const []const u8 = &.{},
};

/// POST /qai/v1/voices/clone — create a cloned voice from audio samples.
pub fn handleVoiceClone(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(CloneRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.name.len == 0) return errResp(.bad_request, "name is required");
    if (req.samples.len == 0) return errResp(.bad_request, "samples is required");

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addField("name", req.name) catch return errResp(.internal_server_error, "build");
    if (req.description) |d| mp.addField("description", d) catch {};
    var decoded: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (decoded.items) |d| allocator.free(d);
        decoded.deinit(allocator);
    }
    for (req.samples, 0..) |b64, i| {
        const audio = decodeB64(allocator, b64) catch return errResp(.bad_request, "invalid base64 sample");
        decoded.append(allocator, audio) catch return errResp(.internal_server_error, "alloc");
        var fnbuf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&fnbuf, "sample_{d}.mp3", .{i}) catch "sample.mp3";
        mp.addFile("files", fname, "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    }

    // Voice cloning is free (no per-call charge); pass the JSON result through.
    return elevenJsonOut(allocator, environ_map, io_handle, store, auth, ledger, &mp, "https://api.elevenlabs.io/v1/voices/add", "/qai/v1/voices/clone", "eleven_voice_clone", 0);
}

/// Multipart-in → JSON-out flow (align, voice-clone): bill flat, pass the
/// upstream JSON through with cost fields merged.
fn elevenJsonOut(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    mp: *@import("multipart.zig").Builder,
    url: []const u8,
    endpoint: []const u8,
    model_id: []const u8,
    cost: i64,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");
    const margin = @divFloor(cost * ELEVEN_MARGIN_BPS, 10000);

    var reservation_id: ?u64 = null;
    if (cost > 0) if (store) |s| if (auth) |a| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), endpoint, model_id) catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    const req_body = mp.finish() catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "build");
    };
    defer allocator.free(req_body);
    const content_type = mp.contentType(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "build");
    };
    defer allocator.free(content_type);

    var client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "http init");
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = content_type }, .{ .name = "xi-api-key", .value = api_key } };
    var resp = client.post(url, &headers, req_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();
    if (resp.status != .ok and resp.status != .created) {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs rejected the request");
    }

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| s.commitReservation(io, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (cost > 0) if (ledger) |l| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, endpoint, model_id, 0, 0, 0);
    };

    const out = mergeBilling(allocator, resp.body, cost + margin, balance_after) catch return errResp(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

/// Shared tail for ElevenLabs audio-bytes responses (dialogue): base64-encode,
/// commit billing, build the standard audio response.
fn audioResponse(
    allocator: std.mem.Allocator,
    audio_bytes: []const u8,
    model_id: []const u8,
    cost: i64,
    margin: i64,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    io: ?std.Io,
    reservation_id: ?u64,
) Response {
    const b64_len = std.base64.standard.Encoder.calcSize(audio_bytes.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "encode");
    };
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, audio_bytes);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |ioh| s.commitReservation(ioh, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| if (io) |ioh| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(ioh, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/audio/dialogue", model_id, 0, 0, 0);
    };

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .audio_base64 = audio_b64,
        .format = "mp3",
        .size_bytes = audio_bytes.len,
        .model = model_id,
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch return errResp(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

// ── audio/dub — ElevenLabs dubbing (async; job-worker only) ──────────
//
// Dubbing is long-running (submit → poll → download per language), so it runs
// as the "audio/dub" job type on the background worker, not as a sync route
// (a multi-minute dub would exceed the 30s socket idle timeout). Submit is
// multipart; poll GET /v1/dubbing/{id} until status "dubbed"; download
// GET /v1/dubbing/{id}/audio/{lang}.

const DUB_COST: i64 = 3_000_000_000; // $0.30 flat
const DUB_POLL_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;
const DUB_MAX_POLLS: u32 = 120;

const DubParams = struct {
    audio_base64: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    target_lang: []const u8 = "",
    source_lang: ?[]const u8 = null,
    num_speakers: ?u32 = null,
    filename: ?[]const u8 = null,
};

pub fn dubCore(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io_opt: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger, body: []const u8) Response {
    const io = io_opt orelse return errResp(.internal_server_error, "io unavailable");
    const parsed = std.json.parseFromSlice(DubParams, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid dub params");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.target_lang.len == 0) return errResp(.bad_request, "target_lang is required");
    if (req.audio_base64 == null and req.source_url == null) return errResp(.bad_request, "audio_base64 or source_url is required");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");

    const cost = DUB_COST;
    const margin = @divFloor(cost * ELEVEN_MARGIN_BPS, 10000);
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/audio/dub", "eleven_dubbing") catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    // Build the multipart submit.
    var mp = @import("multipart.zig").Builder.init(allocator, io);
    defer mp.deinit();
    var decoded_audio: ?[]u8 = null;
    defer if (decoded_audio) |d| allocator.free(d);
    if (req.audio_base64) |b64| {
        const audio = decodeB64(allocator, b64) catch {
            rollback(store, io, reservation_id);
            return errResp(.bad_request, "invalid base64 audio");
        };
        decoded_audio = audio;
        mp.addFile("file", req.filename orelse "audio.mp3", "application/octet-stream", audio) catch return dubFail(store, io, reservation_id);
    } else if (req.source_url) |url| {
        mp.addField("source_url", url) catch return dubFail(store, io, reservation_id);
    }
    mp.addField("target_lang", req.target_lang) catch return dubFail(store, io, reservation_id);
    if (req.source_lang) |sl| mp.addField("source_lang", sl) catch return dubFail(store, io, reservation_id);
    if (req.num_speakers) |n| {
        var nb: [10]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch "1";
        mp.addField("num_speakers", ns) catch return dubFail(store, io, reservation_id);
    }
    mp.addField("highest_resolution", "true") catch return dubFail(store, io, reservation_id);

    const submit_body = mp.finish() catch return dubFail(store, io, reservation_id);
    defer allocator.free(submit_body);
    const content_type = mp.contentType(allocator) catch return dubFail(store, io, reservation_id);
    defer allocator.free(content_type);

    var client = hs.HttpClient.init(allocator) catch return dubFail(store, io, reservation_id);
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = content_type }, .{ .name = "xi-api-key", .value = api_key } };

    var sresp = client.post("https://api.elevenlabs.io/v1/dubbing", &headers, submit_body) catch return dubFail(store, io, reservation_id);
    const dubbing_id = blk: {
        defer sresp.deinit();
        if (sresp.status != .ok) return dubFail(store, io, reservation_id);
        const S = struct { dubbing_id: []const u8 = "" };
        const sp = std.json.parseFromSlice(S, allocator, sresp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return dubFail(store, io, reservation_id);
        defer sp.deinit();
        if (sp.value.dubbing_id.len == 0) return dubFail(store, io, reservation_id);
        break :blk allocator.dupe(u8, sp.value.dubbing_id) catch return dubFail(store, io, reservation_id);
    };
    defer allocator.free(dubbing_id);

    // Poll status.
    const status_url = std.fmt.allocPrint(allocator, "https://api.elevenlabs.io/v1/dubbing/{s}", .{dubbing_id}) catch return dubFail(store, io, reservation_id);
    defer allocator.free(status_url);
    const json_headers = [_]http.Header{.{ .name = "xi-api-key", .value = api_key }};
    var attempt: u32 = 0;
    var done = false;
    while (attempt < DUB_MAX_POLLS) : (attempt += 1) {
        io.sleep(.{ .nanoseconds = DUB_POLL_INTERVAL_NS }, .real) catch {};
        var presp = client.get(status_url, &json_headers) catch continue;
        const St = struct { status: []const u8 = "" };
        const stp = std.json.parseFromSlice(St, allocator, presp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            presp.deinit();
            continue;
        };
        const status = stp.value.status;
        const finished = std.mem.eql(u8, status, "dubbed");
        const failed = std.mem.eql(u8, status, "failed");
        stp.deinit();
        presp.deinit();
        if (finished) {
            done = true;
            break;
        }
        if (failed) return dubFail(store, io, reservation_id);
    }
    if (!done) return dubFail(store, io, reservation_id);

    // Download the dubbed audio for the target language.
    const dl_url = std.fmt.allocPrint(allocator, "https://api.elevenlabs.io/v1/dubbing/{s}/audio/{s}", .{ dubbing_id, req.target_lang }) catch return dubFail(store, io, reservation_id);
    defer allocator.free(dl_url);
    var dresp = client.get(dl_url, &json_headers) catch return dubFail(store, io, reservation_id);
    defer dresp.deinit();
    if (dresp.status != .ok) return dubFail(store, io, reservation_id);

    const b64_len = std.base64.standard.Encoder.calcSize(dresp.body.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch return dubFail(store, io, reservation_id);
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, dresp.body);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| s.commitReservation(io, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/audio/dub", "eleven_dubbing", 0, 0, 0);
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .dubbing_id = dubbing_id,
        .audio_base64 = audio_b64,
        .format = "mp3",
        .target_lang = req.target_lang,
        .status = "dubbed",
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch return errResp(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

fn dubFail(store: ?*store_mod.Store, io: std.Io, reservation_id: ?u64) Response {
    rollback(store, io, reservation_id);
    return .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Dubbing failed\"}" };
}

// ── GET /qai/v1/voices — ElevenLabs voice catalog (pass-through) ─────

/// GET /qai/v1/audio/finetunes — list ElevenLabs music fine-tunes (pass-through).
pub fn handleListFinetunes(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch
        return errResp(.service_unavailable, "ElevenLabs not configured");
    var client = hs.HttpClient.init(allocator) catch return errResp(.internal_server_error, "http init");
    defer client.deinit();
    const headers = [_]http.Header{
        .{ .name = "xi-api-key", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };
    var resp = client.get("https://api.elevenlabs.io/v1/music/finetunes", &headers) catch return errResp(.bad_gateway, "ElevenLabs request failed");
    defer resp.deinit();
    if (resp.status != .ok) return errResp(.bad_gateway, "ElevenLabs rejected the request");
    const out = allocator.dupe(u8, resp.body) catch return errResp(.internal_server_error, "buffer");
    return .{ .status = .ok, .body = out };
}

const FinetuneCreate = struct {
    name: []const u8 = "",
    samples: []const []const u8 = &.{},
};

/// POST /qai/v1/audio/finetunes — create a music fine-tune from audio samples
/// (multipart: name + files). Pass-through of the ElevenLabs response.
pub fn handleCreateFinetune(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io) Response {
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(FinetuneCreate, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return errResp(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.name.len == 0 or req.samples.len == 0) return errResp(.bad_request, "name and samples are required");

    var mp = @import("multipart.zig").Builder.init(allocator, io_handle);
    defer mp.deinit();
    mp.addField("name", req.name) catch return errResp(.internal_server_error, "build");
    var decoded: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (decoded.items) |d| allocator.free(d);
        decoded.deinit(allocator);
    }
    for (req.samples, 0..) |b64, i| {
        const audio = decodeB64(allocator, b64) catch return errResp(.bad_request, "invalid base64 sample");
        decoded.append(allocator, audio) catch return errResp(.internal_server_error, "alloc");
        var fnbuf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&fnbuf, "sample_{d}.mp3", .{i}) catch "sample.mp3";
        mp.addFile("files", fname, "application/octet-stream", audio) catch return errResp(.internal_server_error, "build");
    }
    const req_body = mp.finish() catch return errResp(.internal_server_error, "build");
    defer allocator.free(req_body);
    const content_type = mp.contentType(allocator) catch return errResp(.internal_server_error, "build");
    defer allocator.free(content_type);

    var client = hs.HttpClient.init(allocator) catch return errResp(.internal_server_error, "http init");
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = content_type }, .{ .name = "xi-api-key", .value = api_key } };
    var resp = client.post("https://api.elevenlabs.io/v1/music/finetunes", &headers, req_body) catch return errResp(.bad_gateway, "ElevenLabs request failed");
    defer resp.deinit();
    if (resp.status != .ok and resp.status != .created) return errResp(.bad_gateway, "ElevenLabs rejected the request");
    const out = allocator.dupe(u8, resp.body) catch return errResp(.internal_server_error, "buffer");
    return .{ .status = .ok, .body = out };
}

/// DELETE /qai/v1/audio/finetunes/{id} — delete a music fine-tune.
pub fn handleDeleteFinetune(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, id: []const u8) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");
    var client = hs.HttpClient.init(allocator) catch return errResp(.internal_server_error, "http init");
    defer client.deinit();
    const headers = [_]http.Header{.{ .name = "xi-api-key", .value = api_key }};
    const url = std.fmt.allocPrint(allocator, "https://api.elevenlabs.io/v1/music/finetunes/{s}", .{id}) catch return errResp(.internal_server_error, "alloc");
    defer allocator.free(url);
    var resp = client.delete(url, &headers) catch return errResp(.bad_gateway, "ElevenLabs request failed");
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return errResp(.bad_gateway, "ElevenLabs rejected the request");
    return .{ .status = .ok, .body = "{\"status\":\"deleted\"}" };
}

pub fn handleListVoices(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch {
        return errResp(.service_unavailable, "ElevenLabs not configured (ELEVENLABS_API_KEY unset)");
    };

    var http_client = hs.HttpClient.init(allocator) catch {
        return errResp(.internal_server_error, "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const headers = [_]http.Header{
        .{ .name = "xi-api-key", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };

    var resp = http_client.get("https://api.elevenlabs.io/v1/voices", &headers) catch {
        return errResp(.bad_gateway, "ElevenLabs voices request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        return errResp(.bad_gateway, "ElevenLabs rejected the voices request");
    }

    // Pass the voice catalog straight through (own the bytes before deinit).
    const out = allocator.dupe(u8, resp.body) catch {
        return errResp(.internal_server_error, "Failed to buffer voices response");
    };
    return .{ .status = .ok, .body = out };
}

// ── ElevenLabs generative audio (sound-effects, music) ───────────────
//
// Both are JSON-in / audio-bytes-out POSTs to api.elevenlabs.io with an
// `xi-api-key` header — no multipart, no async — so they're implemented here.
// Billed flat per generation from the registry's per_unit_ticks
// (eleven_sfx_v2 / eleven_music_v1, $0.04 each).

const ElevenAudioRequest = struct {
    prompt: []const u8 = "",
    duration_seconds: ?f64 = null,
};

/// POST /qai/v1/audio/sound-effects
pub fn handleSoundEffects(
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
    return soundEffectsCore(allocator, environ_map, io, store, auth, ledger, body);
}

pub fn soundEffectsCore(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger, body: []const u8) Response {
    return elevenGen(allocator, environ_map, io, store, auth, ledger, body, .{
        .el_url = "https://api.elevenlabs.io/v1/sound-generation",
        .prompt_field = "text",
        .model_id = "eleven_sfx_v2",
        .endpoint = "/qai/v1/audio/sound-effects",
    });
}

/// POST /qai/v1/audio/music
pub fn handleMusic(
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
    return musicCore(allocator, environ_map, io, store, auth, ledger, body);
}

pub fn musicCore(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger, body: []const u8) Response {
    return elevenGen(allocator, environ_map, io, store, auth, ledger, body, .{
        .el_url = "https://api.elevenlabs.io/v1/music",
        .prompt_field = "prompt",
        .model_id = "eleven_music_v1",
        .endpoint = "/qai/v1/audio/music",
    });
}

/// POST /qai/v1/audio/music/advanced — composition-plan music. The client
/// body (prompt + sections/lyrics/style/finetune_id/…) is forwarded verbatim
/// to ElevenLabs /v1/music; billed flat per generation like basic music.
pub fn handleMusicAdvanced(request: *http.Server.Request, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, io: ?std.Io, store: ?*store_mod.Store, auth: ?*const types.AuthContext, ledger: ?*ledger_mod.Ledger) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch return errResp(.bad_request, "read body");
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch return errResp(.service_unavailable, "ElevenLabs not configured");
    const model = models_mod.getModel("eleven_music_v1") orelse return errResp(.internal_server_error, "pricing missing");
    const cost = model.per_unit_ticks;
    const margin = @divFloor(cost * model.margin_bps, 10000);

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |ioh| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(ioh, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), "/qai/v1/audio/music/advanced", "eleven_music_v1") catch |e| switch (e) {
                error.InsufficientBalance => return errResp(.payment_required, "balance too low"),
                else => return errResp(.internal_server_error, "reserve failed"),
            };
        }
    };

    var client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "http init");
    };
    defer client.deinit();
    const headers = [_]http.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "xi-api-key", .value = api_key } };
    // Forward the client's composition body verbatim (it's already valid JSON).
    var resp = client.post("https://api.elevenlabs.io/v1/music", &headers, body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs rejected the request");
    }

    const b64_len = std.base64.standard.Encoder.calcSize(resp.body.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "encode");
    };
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, resp.body);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |ioh| s.commitReservation(ioh, rid, cost, margin) catch {};
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| if (io) |ioh| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(ioh, acct_id, key_pfx, cost, margin, balance_after, "/qai/v1/audio/music/advanced", "eleven_music_v1", 0, 0, 0);
    };

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .audio_base64 = audio_b64,
        .format = "mp3",
        .size_bytes = resp.body.len,
        .model = "eleven_music_v1",
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch return errResp(.internal_server_error, "serialize");
    return .{ .status = .ok, .body = out };
}

const ElevenSpec = struct {
    el_url: []const u8,
    prompt_field: []const u8,
    model_id: []const u8,
    endpoint: []const u8,
};

fn elevenGen(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
    spec: ElevenSpec,
) Response {
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(ElevenAudioRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    if (req.prompt.len == 0) return errResp(.bad_request, "prompt is required");

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "ELEVENLABS_API_KEY") catch {
        return errResp(.service_unavailable, "ElevenLabs not configured (ELEVENLABS_API_KEY unset)");
    };

    // Flat per-generation cost from the registry.
    const model = models_mod.getModel(spec.model_id) orelse {
        return errResp(.internal_server_error, "pricing model missing from registry");
    };
    const cost = model.per_unit_ticks;
    const margin = @divFloor(cost * model.margin_bps, 10000);

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io_handle, a.account.id.slice(), a.key_hash, @max(cost + margin, 1000), spec.endpoint, spec.model_id) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this generation"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // Build the ElevenLabs request body. The prompt field name differs
    // (sound-generation: "text"; music: "prompt"); duration is optional.
    const request_body = buildElevenBody(allocator, spec.prompt_field, req.prompt, req.duration_seconds) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to build provider request");
    };
    defer allocator.free(request_body);

    var http_client = hs.HttpClient.init(allocator) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to initialize HTTP client");
    };
    defer http_client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "xi-api-key", .value = api_key },
    };

    var resp = http_client.post(spec.el_url, &headers, request_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "ElevenLabs request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "ElevenLabs rejected the request");
    }

    const audio_bytes = resp.body;
    const b64_len = std.base64.standard.Encoder.calcSize(audio_bytes.len);
    const audio_b64 = allocator.alloc(u8, b64_len) catch {
        rollback(store, io, reservation_id);
        return errResp(.internal_server_error, "Failed to encode audio");
    };
    defer allocator.free(audio_b64);
    _ = std.base64.standard.Encoder.encode(audio_b64, audio_bytes);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        s.commitReservation(io_handle, rid, cost, margin) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };
    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io_handle, acct_id, key_pfx, cost, margin, balance_after, spec.endpoint, spec.model_id, 0, 0, 0);
    };

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .audio_base64 = audio_b64,
        .format = "mp3",
        .size_bytes = audio_bytes.len,
        .model = spec.model_id,
        .cost_ticks = cost + margin,
        .balance_after = balance_after,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

fn buildElevenBody(allocator: std.mem.Allocator, prompt_field: []const u8, prompt: []const u8, duration: ?f64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField(prompt_field);
    try jw.write(prompt);
    if (duration) |d| {
        try jw.objectField("duration_seconds");
        try jw.write(d);
    }
    try jw.endObject();
    return aw.toOwnedSlice();
}

// ── STT (speech-to-text) ─────────────────────────────────────────────

const SttRequest = struct {
    model: []const u8,
    audio_base64: []const u8,
    filename: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

pub fn handleStt(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    const body = json_util.readBody(request, allocator, MAX_STT_BODY) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    return sttCore(allocator, environ_map, io, store, auth, ledger, body);
}

pub fn sttCore(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
    // Need a real io for the multipart boundary CSPRNG.
    const io_handle = io orelse return errResp(.internal_server_error, "io unavailable");
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(SttRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return errResp(.bad_request, "model is required");
    }
    if (req.audio_base64.len == 0) return errResp(.bad_request, "audio_base64 is required");

    const model = models_mod.getModel(req.model) orelse {
        return errResp(.bad_request, "Model not found in registry; check /qai/v1/models");
    };
    if (!std.mem.eql(u8, model.provider, "OpenAI")) {
        return errResp(.not_implemented, "STT for this provider isn't wired up on the Zig server yet. Live: OpenAI (whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe).");
    }

    // Decode the base64 audio.
    const decoder = std.base64.standard.Decoder;
    const audio_len = decoder.calcSizeForSlice(req.audio_base64) catch {
        return errResp(.bad_request, "invalid base64 audio data");
    };
    const audio = allocator.alloc(u8, audio_len) catch {
        return errResp(.internal_server_error, "alloc failed");
    };
    defer allocator.free(audio);
    decoder.decode(audio, req.audio_base64) catch {
        return errResp(.bad_request, "invalid base64 audio data");
    };

    return transcribeOpenAI(allocator, environ_map, io_handle, store, auth, ledger, req, model, audio);
}

fn transcribeOpenAI(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    req: SttRequest,
    model: models_mod.Model,
    audio: []const u8,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch {
        return errResp(.internal_server_error, "Server missing OPENAI_API_KEY");
    };

    // Pre-flight: estimate duration from the encoded size (~128 kbps mp3 →
    // ~960 KB/min) and reserve at 2× for safety. Settled from the actual
    // reported duration / token usage after the call.
    const est_minutes: i64 = @max(1, @divTrunc(@as(i64, @intCast(audio.len)), 960_000));
    const est = sttCost(model, est_minutes * 60, 0, 0);
    const reserve_ticks = (est.cost + est.margin) * 2;

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(io, a.account.id.slice(), a.key_hash, @max(reserve_ticks, 1000), "/qai/v1/audio/stt", req.model) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this transcription"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    // whisper-1 supports verbose_json (gives duration); the gpt-4o-transcribe
    // family only supports plain json.
    const is_whisper = std.mem.eql(u8, req.model, "whisper-1");
    const response_format = if (is_whisper) "verbose_json" else "json";
    const filename = req.filename orelse "audio.mp3";

    var mp = @import("multipart.zig").Builder.init(allocator, io);
    defer mp.deinit();
    mp.addField("model", req.model) catch return reserveFail(store, io, reservation_id);
    mp.addField("response_format", response_format) catch return reserveFail(store, io, reservation_id);
    if (req.language) |lang| mp.addField("language", lang) catch return reserveFail(store, io, reservation_id);
    mp.addFile("file", filename, "application/octet-stream", audio) catch return reserveFail(store, io, reservation_id);
    const request_body = mp.finish() catch return reserveFail(store, io, reservation_id);
    defer allocator.free(request_body);

    const content_type = mp.contentType(allocator) catch return reserveFail(store, io, reservation_id);
    defer allocator.free(content_type);

    var http_client = hs.HttpClient.init(allocator) catch return reserveFail(store, io, reservation_id);
    defer http_client.deinit();

    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch return reserveFail(store, io, reservation_id);
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Authorization", .value = auth_header },
    };

    var resp = http_client.post("https://api.openai.com/v1/audio/transcriptions", &headers, request_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "OpenAI transcription request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "OpenAI rejected the transcription request");
    }

    const decoded = decodeSttResponse(allocator, resp.body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "Could not parse OpenAI transcription response");
    };
    defer {
        allocator.free(decoded.text);
        allocator.free(decoded.language);
    }

    const cost = sttCost(model, decoded.duration_seconds_x1000, decoded.input_tokens, decoded.output_tokens);

    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (store) |s| {
        s.commitReservation(io, rid, cost.cost, cost.margin) catch {};
    };
    if (auth) |a| if (store) |s| {
        if (s.getAccount(a.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    if (ledger) |l| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        l.recordBilling(io, acct_id, key_pfx, cost.cost, cost.margin, balance_after, "/qai/v1/audio/stt", req.model, decoded.input_tokens, decoded.output_tokens, 0);
    }

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .text = decoded.text,
        .model = req.model,
        // duration_seconds_x1000 is milliseconds; expose seconds as a float.
        .duration_seconds = @as(f64, @floatFromInt(decoded.duration_seconds_x1000)) / 1000.0,
        .language = decoded.language,
        .cost_ticks = cost.cost + cost.margin,
        .balance_after = balance_after,
    }, .{}) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

const DecodedStt = struct {
    text: []u8,
    language: []u8,
    duration_seconds_x1000: i64, // duration in milliseconds (integer)
    input_tokens: u32,
    output_tokens: u32,
};

fn decodeSttResponse(allocator: std.mem.Allocator, body: []const u8) !DecodedStt {
    const Parsed = struct {
        text: []const u8 = "",
        language: []const u8 = "",
        duration: f64 = 0, // verbose_json (whisper-1), seconds
        usage: ?struct {
            input_tokens: u32 = 0,
            output_tokens: u32 = 0,
            prompt_tokens: u32 = 0,
            completion_tokens: u32 = 0,
        } = null,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var in_t: u32 = 0;
    var out_t: u32 = 0;
    if (parsed.value.usage) |u| {
        in_t = if (u.input_tokens > 0) u.input_tokens else u.prompt_tokens;
        out_t = if (u.output_tokens > 0) u.output_tokens else u.completion_tokens;
    }
    return .{
        .text = try allocator.dupe(u8, parsed.value.text),
        .language = try allocator.dupe(u8, parsed.value.language),
        .duration_seconds_x1000 = @intFromFloat(parsed.value.duration * 1000.0),
        .input_tokens = in_t,
        .output_tokens = out_t,
    };
}

/// STT cost. Token-based models bill on reported usage; per-minute models
/// (whisper-1, per_unit_ticks = ticks/minute) bill on duration; otherwise a
/// flat per-unit fallback. `duration_ms` is integer milliseconds.
fn sttCost(model: models_mod.Model, duration_ms: i64, input_tokens: u32, output_tokens: u32) struct { cost: i64, margin: i64 } {
    var cost: i64 = 0;
    if (input_tokens > 0 or output_tokens > 0) {
        const in_ticks = @divTrunc(model.input_ticks_per_million * @as(i64, input_tokens), 1_000_000);
        const out_ticks = @divTrunc(model.output_ticks_per_million * @as(i64, output_tokens), 1_000_000);
        cost = in_ticks + out_ticks;
    } else if (model.per_unit_ticks > 0) {
        // per_unit_ticks is ticks-per-minute; duration_ms / 60000 minutes.
        cost = @divTrunc(model.per_unit_ticks * duration_ms, 60_000);
    }
    const margin = @divFloor(cost * model.margin_bps, 10000);
    return .{ .cost = cost, .margin = margin };
}

fn reserveFail(store: ?*store_mod.Store, io: std.Io, reservation_id: ?u64) Response {
    rollback(store, io, reservation_id);
    return errResp(.internal_server_error, "Failed to build transcription request");
}

/// TTS cost. Per-1M-char models (tts-1, tts-1-hd) carry per_unit_ticks as
/// ticks-per-1M-chars → bill by exact character count. Token-priced models
/// (gpt-4o-mini-tts) report no usage from /v1/audio/speech, so estimate input
/// tokens at ~4 chars/token and add a same-magnitude audio-output estimate.
/// Integer math throughout.
fn ttsCost(model: models_mod.Model, char_count: usize) struct { cost: i64, margin: i64 } {
    const chars: i64 = @intCast(char_count);
    var cost: i64 = 0;
    if (model.per_unit_ticks > 0) {
        // per_unit_ticks is ticks per 1,000,000 characters.
        cost = @divTrunc(model.per_unit_ticks * chars, 1_000_000);
    } else {
        const est_tokens = @divTrunc(chars, 4) + 1;
        const in_ticks = @divTrunc(model.input_ticks_per_million * est_tokens, 1_000_000);
        const out_ticks = @divTrunc(model.output_ticks_per_million * est_tokens, 1_000_000);
        cost = in_ticks + out_ticks;
    }
    const margin = @divFloor(cost * model.margin_bps, 10000);
    return .{ .cost = cost, .margin = margin };
}

fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"TTS request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this TTS request\"}" },
        .not_implemented => .{ .status = .not_implemented, .body = "{\"error\":\"provider_not_implemented\",\"message\":\"TTS for this provider isn't wired up on the Zig server yet. Live: OpenAI tts-1/tts-1-hd/gpt-4o-mini-tts.\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Provider rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"TTS provider request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"TTS request failed\"}" },
    };
}
