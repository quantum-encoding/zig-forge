// Vision endpoints — multimodal image analysis
//
//   POST /qai/v1/vision/analyze   (profile "combined")
//   POST /qai/v1/vision/describe  (profile "scene")
//   POST /qai/v1/vision/detect    (profile "objects")
//   POST /qai/v1/vision/ocr       (profile "ocr")
//   POST /qai/v1/vision/quality   (profile "quality")
//
// Wire-compatible with the Go /qai/v1/vision/* handlers: each takes
//   { image_base64? | image_url?, model?, profile?, context? }
// builds a profile-specific prompt, sends a multimodal (image + prompt)
// message to a vision-capable model with a JSON-only system instruction, and
// returns the model's structured JSON merged with { model, cost_ticks,
// balance_after }.
//
// Provider scope: the in-tree chat path (chat.zig) is text-only — it has no
// multimodal Message shape to reuse — so vision makes a direct OpenAI
// chat/completions multimodal call (same staged-provider pattern as
// images.zig/embeddings.zig). OpenAI vision models are live; other providers
// return 501. NOTE the default model differs from the Go gateway: Go defaults
// to gemini-2.5-flash, but since only OpenAI is wired here the Zig default is
// an OpenAI vision model. Pass an explicit OpenAI `model` for deterministic
// behaviour.
//
// Billing mirrors images.zig: reserve a conservative token estimate, call the
// provider, settle the exact cost from reported usage. Integer math only.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const models_mod = @import("models.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const TICKS_PER_USD: i64 = 10_000_000_000;
const MAX_VISION_BODY: usize = 8 * 1024 * 1024; // base64 images run large
const DEFAULT_MODEL = "gpt-5.4-mini"; // OpenAI vision-capable; in models.csv

const SYSTEM_PROMPT =
    "You are an image analysis system. Always respond with valid JSON matching " ++
    "the requested schema. No markdown, no explanation outside the JSON.";

pub const Profile = enum { combined, scene, objects, ocr, quality };

const VisionContext = struct {
    installation_type: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    expected_items: ?[]const []const u8 = null,
};

const VisionRequest = struct {
    image_base64: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    context: ?VisionContext = null,
};

// ── Public entry points (one per route) ──────────────────────────────

pub fn handleAnalyze(r: *http.Server.Request, a: std.mem.Allocator, e: *const std.process.Environ.Map, io: ?std.Io, s: ?*store_mod.Store, au: ?*const types.AuthContext, l: ?*ledger_mod.Ledger) Response {
    return handle(.combined, r, a, e, io, s, au, l);
}
pub fn handleDescribe(r: *http.Server.Request, a: std.mem.Allocator, e: *const std.process.Environ.Map, io: ?std.Io, s: ?*store_mod.Store, au: ?*const types.AuthContext, l: ?*ledger_mod.Ledger) Response {
    return handle(.scene, r, a, e, io, s, au, l);
}
pub fn handleDetect(r: *http.Server.Request, a: std.mem.Allocator, e: *const std.process.Environ.Map, io: ?std.Io, s: ?*store_mod.Store, au: ?*const types.AuthContext, l: ?*ledger_mod.Ledger) Response {
    return handle(.objects, r, a, e, io, s, au, l);
}
pub fn handleOCR(r: *http.Server.Request, a: std.mem.Allocator, e: *const std.process.Environ.Map, io: ?std.Io, s: ?*store_mod.Store, au: ?*const types.AuthContext, l: ?*ledger_mod.Ledger) Response {
    return handle(.ocr, r, a, e, io, s, au, l);
}
pub fn handleQuality(r: *http.Server.Request, a: std.mem.Allocator, e: *const std.process.Environ.Map, io: ?std.Io, s: ?*store_mod.Store, au: ?*const types.AuthContext, l: ?*ledger_mod.Ledger) Response {
    return handle(.quality, r, a, e, io, s, au, l);
}

// ── Core ─────────────────────────────────────────────────────────────

fn handle(
    default_profile: Profile,
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    const body = json_util.readBody(request, allocator, MAX_VISION_BODY) catch {
        return errResp(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return errResp(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(VisionRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errResp(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    const has_b64 = req.image_base64 != null and req.image_base64.?.len > 0;
    const has_url = req.image_url != null and req.image_url.?.len > 0;
    if (!has_b64 and !has_url) {
        return errResp(.bad_request, "image_base64 or image_url required");
    }

    const profile = parseProfile(req.profile) orelse default_profile;
    const model = if (req.model) |m| (if (m.len > 0) m else DEFAULT_MODEL) else DEFAULT_MODEL;

    const registry_model = models_mod.getModel(model) orelse {
        return errResp(.bad_request, "Model not found in registry; check /qai/v1/models");
    };
    if (!std.mem.eql(u8, registry_model.provider, "OpenAI")) {
        return errResp(.not_implemented, "Vision for this provider isn't wired up on the Zig server yet. Live: OpenAI vision models (e.g. gpt-5.4-mini). Use the Go gateway for Gemini vision.");
    }

    // Resolve the image source as an OpenAI image_url value.
    const image_url_value = buildImageUrlValue(allocator, req) catch {
        return errResp(.bad_request, "invalid image data");
    };
    defer allocator.free(image_url_value);

    // Build the profile prompt (plain text; escaped at the JSON boundary).
    const prompt = buildPrompt(allocator, profile, req.context) catch {
        return errResp(.internal_server_error, "failed to build prompt");
    };
    defer allocator.free(prompt);

    return callOpenAI(allocator, environ_map, io, store, auth, ledger, registry_model, model, profile, prompt, image_url_value);
}

fn callOpenAI(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    registry_model: models_mod.Model,
    model: []const u8,
    profile: Profile,
    prompt: []const u8,
    image_url_value: []const u8,
) Response {
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, "OPENAI_API_KEY") catch {
        return errResp(.internal_server_error, "Server missing OPENAI_API_KEY");
    };

    // Pre-flight: an image is worth a lot of input tokens; estimate high so
    // under-funded callers are rejected before we burn provider quota. The
    // reservation absorbs the delta; exact cost settled from reported usage.
    const est_input_tokens: i64 = 2000 + @as(i64, @intCast(prompt.len / 4));
    const est_output_tokens: i64 = 1500; // structured JSON reply
    const est = costFromTokens(registry_model, est_input_tokens, est_output_tokens);
    const estimate_ticks = est.cost + est.margin;

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        if (a.account.role != .admin) {
            reservation_id = s.reserve(
                io_handle,
                a.account.id.slice(),
                a.key_hash,
                estimate_ticks,
                endpointPath(profile),
                model,
            ) catch |err| switch (err) {
                error.InsufficientBalance => return errResp(.payment_required, "Account balance is too low for this vision request"),
                else => return errResp(.internal_server_error, "Failed to reserve credits"),
            };
        }
    };

    const request_body = buildOpenAIBody(allocator, model, prompt, image_url_value) catch {
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

    var resp = http_client.post("https://api.openai.com/v1/chat/completions", &headers, request_body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "OpenAI vision request failed");
    };
    defer resp.deinit();

    if (resp.status != .ok) {
        rollback(store, io, reservation_id);
        return errResp(if (resp.status == .too_many_requests) .too_many_requests else .bad_gateway, "OpenAI rejected the vision request");
    }

    const decoded = decodeChatResponse(allocator, resp.body) catch {
        rollback(store, io, reservation_id);
        return errResp(.bad_gateway, "Could not parse OpenAI vision response");
    };
    defer allocator.free(decoded.content);

    const cost = costFromTokens(registry_model, @intCast(decoded.input_tokens), @intCast(decoded.output_tokens));

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
        l.recordBilling(io_handle, acct_id, key_pfx, cost.cost, cost.margin, balance_after, endpointPath(profile), model, decoded.input_tokens, decoded.output_tokens, 0);
    };

    const out = buildResponseJson(allocator, decoded.content, model, cost.cost + cost.margin, balance_after) catch {
        return errResp(.internal_server_error, "Failed to build response JSON");
    };
    return .{ .status = .ok, .body = out };
}

// ── Billing ──────────────────────────────────────────────────────────

fn costFromTokens(model: models_mod.Model, input_tokens: i64, output_tokens: i64) struct { cost: i64, margin: i64 } {
    const in_ticks = @divTrunc(model.input_ticks_per_million * input_tokens, 1_000_000);
    const out_ticks = @divTrunc(model.output_ticks_per_million * output_tokens, 1_000_000);
    const cost = in_ticks + out_ticks;
    const margin = @divFloor(cost * model.margin_bps, 10000);
    return .{ .cost = cost, .margin = margin };
}

// ── Image source ─────────────────────────────────────────────────────

/// Produce the OpenAI `image_url.url` value. A URL is passed through; base64
/// is wrapped as a data URI (passed through verbatim if already prefixed),
/// sniffing PNG vs JPEG from the leading base64 bytes so the declared MIME
/// type is right.
fn buildImageUrlValue(allocator: std.mem.Allocator, req: VisionRequest) ![]u8 {
    if (req.image_url) |u| if (u.len > 0) return allocator.dupe(u8, u);

    const b64 = req.image_base64 orelse return error.NoImage;
    if (std.mem.startsWith(u8, b64, "data:")) return allocator.dupe(u8, b64);

    const mime = if (std.mem.startsWith(u8, b64, "iVBOR"))
        "image/png"
    else if (std.mem.startsWith(u8, b64, "R0lGOD"))
        "image/gif"
    else if (std.mem.startsWith(u8, b64, "UklGR"))
        "image/webp"
    else
        "image/jpeg"; // /9j/ and unknown default

    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, b64 });
}

// ── Provider request body ────────────────────────────────────────────

/// Stream the OpenAI chat/completions multimodal body. The content array is
/// heterogeneous (text part + image_url part), so it's streamed rather than
/// built from a homogeneous slice. Every caller-controlled value (prompt,
/// image URL/data) is written via jw.write(), which escapes it (JSON-IN-FMT).
fn buildOpenAIBody(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8, image_url_value: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);

    try jw.objectField("messages");
    try jw.beginArray();

    // system message
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("system");
    try jw.objectField("content");
    try jw.write(SYSTEM_PROMPT);
    try jw.endObject();

    // user message with multimodal content array
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.beginArray();

    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(prompt);
    try jw.endObject();

    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("image_url");
    try jw.objectField("image_url");
    try jw.beginObject();
    try jw.objectField("url");
    try jw.write(image_url_value);
    try jw.endObject();
    try jw.endObject();

    try jw.endArray(); // content
    try jw.endObject(); // user message

    try jw.endArray(); // messages

    // Force a JSON object reply.
    try jw.objectField("response_format");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("json_object");
    try jw.endObject();

    try jw.endObject();
    return aw.toOwnedSlice();
}

// ── Provider response ────────────────────────────────────────────────

const DecodedChat = struct {
    content: []u8, // owned
    input_tokens: u32,
    output_tokens: u32,
};

fn decodeChatResponse(allocator: std.mem.Allocator, body: []const u8) !DecodedChat {
    const Parsed = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
            },
        },
        usage: ?struct {
            prompt_tokens: u32 = 0,
            completion_tokens: u32 = 0,
        } = null,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.NoChoices;
    const raw = parsed.value.choices[0].message.content orelse "";
    const content = try allocator.dupe(u8, raw);

    var in_t: u32 = 0;
    var out_t: u32 = 0;
    if (parsed.value.usage) |u| {
        in_t = u.prompt_tokens;
        out_t = u.completion_tokens;
    }
    return .{ .content = content, .input_tokens = in_t, .output_tokens = out_t };
}

// ── Response assembly ────────────────────────────────────────────────

/// Merge the model's analysis JSON with the billing envelope. The model was
/// instructed to return a JSON object matching the profile schema; we parse
/// it (stripping any stray markdown fences), inject model/cost/balance, and
/// re-serialize. If the content isn't a JSON object (model misbehaved), we
/// fall back to an envelope carrying the raw text under `raw` so the caller
/// still gets a well-formed, billable response.
fn buildResponseJson(allocator: std.mem.Allocator, content: []const u8, model: []const u8, cost_ticks: i64, balance_after: i64) ![]u8 {
    const trimmed = stripFences(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return fallbackEnvelope(allocator, content, model, cost_ticks, balance_after);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return fallbackEnvelope(allocator, content, model, cost_ticks, balance_after);
    }

    // Inject billing fields into the parsed object, then stringify. The map
    // is unmanaged, so put() takes the arena allocator that `parsed` owns —
    // the additions are freed with parsed.deinit() after we serialize.
    const arena = parsed.arena.allocator();
    var obj = parsed.value.object;
    try obj.put(arena, "model", .{ .string = model });
    try obj.put(arena, "cost_ticks", .{ .integer = cost_ticks });
    try obj.put(arena, "balance_after", .{ .integer = balance_after });

    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{});
}

fn fallbackEnvelope(allocator: std.mem.Allocator, content: []const u8, model: []const u8, cost_ticks: i64, balance_after: i64) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .raw = content,
        .model = model,
        .cost_ticks = cost_ticks,
        .balance_after = balance_after,
    }, .{});
}

/// Strip a leading ```json / ``` fence and trailing ``` if the model wrapped
/// its JSON in markdown despite the system instruction.
fn stripFences(s: []const u8) []const u8 {
    var out = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.startsWith(u8, out, "```")) {
        // drop the opening fence line
        if (std.mem.indexOfScalar(u8, out, '\n')) |nl| out = out[nl + 1 ..];
        if (std.mem.endsWith(u8, out, "```")) out = out[0 .. out.len - 3];
        out = std.mem.trim(u8, out, " \t\r\n");
    }
    return out;
}

// ── Prompts ──────────────────────────────────────────────────────────

fn parseProfile(s: ?[]const u8) ?Profile {
    const v = s orelse return null;
    if (v.len == 0) return null;
    if (std.mem.eql(u8, v, "combined")) return .combined;
    if (std.mem.eql(u8, v, "scene")) return .scene;
    if (std.mem.eql(u8, v, "objects")) return .objects;
    if (std.mem.eql(u8, v, "ocr")) return .ocr;
    if (std.mem.eql(u8, v, "quality")) return .quality;
    return null; // unknown → caller's default
}

fn endpointPath(profile: Profile) []const u8 {
    return switch (profile) {
        .combined => "/qai/v1/vision/combined",
        .scene => "/qai/v1/vision/scene",
        .objects => "/qai/v1/vision/objects",
        .ocr => "/qai/v1/vision/ocr",
        .quality => "/qai/v1/vision/quality",
    };
}

const PROMPT_SCENE =
    \\Analyze this image and return JSON:
    \\{
    \\  "caption": "detailed scene description",
    \\  "tags": ["tag1", "tag2", "tag3"]
    \\}
    \\Provide 5-15 relevant tags as lowercase_snake_case.
;

const PROMPT_OBJECTS =
    \\Detect all objects in this image. Return JSON:
    \\{
    \\  "objects": [
    \\    {"label": "object_name", "confidence": 0.95, "bounding_box": [y_min, x_min, y_max, x_max]}
    \\  ]
    \\}
    \\Bounding box coordinates are normalised to 0-1000 scale.
    \\Include all visible objects with confidence > 0.3.
;

const PROMPT_OCR =
    \\Extract all visible text and metadata overlays from this image. Return JSON:
    \\{
    \\  "ocr": {
    \\    "text": "all visible text concatenated",
    \\    "metadata": {"gps": "lat,lng if visible", "timestamp": "if visible", "address": "if visible"},
    \\    "overlays": [
    \\      {"text": "overlay text", "bounding_box": [y_min, x_min, y_max, x_max], "type": "gps|timestamp|address|label|other"}
    \\    ]
    \\  }
    \\}
    \\Bounding box coordinates normalised to 0-1000. Include compliance camera overlays (GPS, address, timestamp).
;

const PROMPT_QUALITY =
    \\Assess the quality of this image for documentation/compliance purposes. Return JSON:
    \\{
    \\  "quality": {
    \\    "overall": "good|acceptable|poor",
    \\    "score": 0.85,
    \\    "blur": "none|slight|significant",
    \\    "darkness": "well_lit|dim|dark",
    \\    "resolution": "high|adequate|low",
    \\    "exposure": "correct|over|under",
    \\    "issues": ["list of specific issues if any"]
    \\  }
    \\}
;

const PROMPT_COMBINED_HEAD =
    \\Perform comprehensive analysis of this image. Return JSON with ALL of these sections:
    \\{
    \\  "caption": "detailed scene description",
    \\  "tags": ["tag1", "tag2"],
    \\  "objects": [
    \\    {"label": "object_name", "confidence": 0.95, "bounding_box": [y_min, x_min, y_max, x_max]}
    \\  ],
    \\  "quality": {
    \\    "overall": "good|acceptable|poor",
    \\    "score": 0.85,
    \\    "blur": "none|slight|significant",
    \\    "darkness": "well_lit|dim|dark",
    \\    "resolution": "high|adequate|low",
    \\    "exposure": "correct|over|under",
    \\    "issues": []
    \\  },
    \\  "ocr": {
    \\    "text": "all visible text",
    \\    "metadata": {"gps": "", "timestamp": "", "address": ""},
    \\    "overlays": [{"text": "", "bounding_box": [0,0,0,0], "type": ""}]
    \\  }
;

const COMBINED_TAIL =
    "\nBounding boxes: [y_min, x_min, y_max, x_max] normalised to 0-1000. Tags as lowercase_snake_case.";

/// Build the prompt for a profile. For the combined profile an optional
/// domain context appends a relevance section + plain-text guidance. Context
/// strings are caller-controlled but go into the *prompt text* (escaped later
/// at the JSON boundary by jw.write), so allocPrint here is safe — this is not
/// JSON-structure construction.
fn buildPrompt(allocator: std.mem.Allocator, profile: Profile, ctx: ?VisionContext) ![]u8 {
    switch (profile) {
        .scene => return allocator.dupe(u8, PROMPT_SCENE),
        .objects => return allocator.dupe(u8, PROMPT_OBJECTS),
        .ocr => return allocator.dupe(u8, PROMPT_OCR),
        .quality => return allocator.dupe(u8, PROMPT_QUALITY),
        .combined => {},
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, PROMPT_COMBINED_HEAD);

    if (ctx) |c| {
        // expected_items as a JSON array, encoded safely.
        const items_json = if (c.expected_items) |items|
            try std.json.Stringify.valueAlloc(allocator, items, .{})
        else
            try allocator.dupe(u8, "[]");
        defer allocator.free(items_json);

        const relevance = try std.fmt.allocPrint(allocator,
            \\,
            \\  "relevance": {{
            \\    "relevant": true,
            \\    "score": 0.9,
            \\    "expected_items": {s},
            \\    "found_items": ["items actually found"],
            \\    "missing_items": ["expected but not found"],
            \\    "unexpected_items": ["found but not expected"],
            \\    "notes": "explanation"
            \\  }}
            \\}}
        , .{items_json});
        defer allocator.free(relevance);
        try buf.appendSlice(allocator, relevance);

        const install_type = c.installation_type orelse "general";
        const ctx_line = if (c.phase) |ph|
            try std.fmt.allocPrint(allocator, "\nContext: This is a {s} installation photo from the {s} phase. Check relevance against the expected items.", .{ install_type, ph })
        else
            try std.fmt.allocPrint(allocator, "\nContext: This is a {s} installation photo. Check relevance against the expected items.", .{install_type});
        defer allocator.free(ctx_line);
        try buf.appendSlice(allocator, ctx_line);
    } else {
        try buf.appendSlice(allocator, "\n}");
    }

    try buf.appendSlice(allocator, COMBINED_TAIL);
    return buf.toOwnedSlice(allocator);
}

// ── Misc ─────────────────────────────────────────────────────────────

fn rollback(store: ?*store_mod.Store, io: ?std.Io, reservation_id: ?u64) void {
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| s.rollbackReservation(io_handle, rid);
}

fn errResp(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Vision request rejected\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this vision request\"}" },
        .not_implemented => .{ .status = .not_implemented, .body = "{\"error\":\"provider_not_implemented\",\"message\":\"Vision for this provider isn't wired up on the Zig server yet. Live: OpenAI vision models.\"}" },
        .too_many_requests => .{ .status = .too_many_requests, .body = "{\"error\":\"rate_limited\",\"message\":\"Provider rate limit exceeded\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Vision provider request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Vision request failed\"}" },
    };
}
