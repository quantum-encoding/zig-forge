// Vertex AI Provider — multi-model gateway via GCP auth
// Routes to: Gemini (native), DeepSeek/GLM-5/Qwen (MaaS OpenAI), Codestral/Mistral (MaaS rawPredict)
// Uses gcp-auth directly — no subprocess, no SDK, pure Zig HTTP + GCP tokens.
//
// Endpoint patterns:
//   Gemini:  https://{region}-aiplatform.googleapis.com/v1/projects/{proj}/locations/{region}/publishers/google/models/{model}:generateContent
//   MaaS:    https://aiplatform.googleapis.com/v1beta1/projects/{proj}/locations/global/endpoints/openapi/chat/completions
//   Mistral: https://europe-west4-aiplatform.googleapis.com/v1/projects/{proj}/locations/europe-west4/publishers/mistralai/models/{model}:rawPredict

const std = @import("std");
const gcp = @import("gcp.zig");
const chat_mod = @import("chat.zig");
const billing = @import("billing.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const security = @import("security.zig");
const json_util = @import("json.zig");
const router = @import("router.zig");
const ledger_mod = @import("ledger.zig");
const http = std.http;
const Response = router.Response;

const PROJECT_ID = "metatron-cloud-prod-v1";
const DEFAULT_REGION = "us-central1";
const MISTRAL_REGION = "europe-west4";

// ── Model Routing ───────────────────────────────────────────

const ModelRoute = enum {
    gemini, // Vertex generateContent API (GCP auth)
    maas_openai, // Global OpenAI-compatible endpoint (GCP auth)
    maas_mistral, // Regional rawPredict (GCP auth)
    dedicated, // Self-hosted on Vertex dedicated endpoint (GCP auth)
    genai, // Google GenAI / AI Studio (API key auth)
};

/// Dedicated endpoint registry — dynamic, managed via admin API.
/// Users deploy models on GPU clusters, register the endpoint ID here.
pub const DedicatedEndpoint = struct {
    model_name: []const u8, // e.g., "qwen3.5-35b" — what the user passes as model
    endpoint_id: []const u8, // Vertex endpoint ID from deploy response
    region: []const u8, // e.g., "europe-west4", "us-east1"
    display_name: []const u8, // e.g., "Qwen 3.5 35B on RTX 6000"
    /// Inject into request body (e.g., GLM-5.1 thinking mode)
    extra_params: ?[]const u8 = null,
    active: bool = true,
};

/// Runtime endpoint registry (thread-safe via store spinlock)
var endpoint_registry: std.ArrayListUnmanaged(DedicatedEndpoint) = .empty;
var registry_allocator: ?std.mem.Allocator = null;

const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),
    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};
var registry_lock: SpinLock = .{};

pub fn initRegistry(allocator: std.mem.Allocator) void {
    registry_allocator = allocator;
}

/// Register a dedicated endpoint (called from admin API)
pub fn registerEndpoint(ep: DedicatedEndpoint) !void {
    const alloc = registry_allocator orelse return error.OutOfMemory;
    registry_lock.lock();
    defer registry_lock.unlock();

    // Check for duplicate model name — update if exists
    for (endpoint_registry.items) |*existing| {
        if (std.mem.eql(u8, existing.model_name, ep.model_name)) {
            existing.endpoint_id = try alloc.dupe(u8, ep.endpoint_id);
            existing.region = try alloc.dupe(u8, ep.region);
            existing.display_name = try alloc.dupe(u8, ep.display_name);
            existing.extra_params = if (ep.extra_params) |p| try alloc.dupe(u8, p) else null;
            existing.active = ep.active;
            return;
        }
    }

    // New entry
    try endpoint_registry.append(alloc, .{
        .model_name = try alloc.dupe(u8, ep.model_name),
        .endpoint_id = try alloc.dupe(u8, ep.endpoint_id),
        .region = try alloc.dupe(u8, ep.region),
        .display_name = try alloc.dupe(u8, ep.display_name),
        .extra_params = if (ep.extra_params) |p| try alloc.dupe(u8, p) else null,
        .active = ep.active,
    });
}

/// Remove a dedicated endpoint
pub fn removeEndpoint(model_name: []const u8) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    for (endpoint_registry.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.model_name, model_name)) {
            _ = endpoint_registry.orderedRemove(i);
            return;
        }
    }
}

/// List all dedicated endpoints (for admin API)
pub fn listEndpoints() []const DedicatedEndpoint {
    return endpoint_registry.items;
}

fn routeModel(model: []const u8) ModelRoute {
    // Check dynamic dedicated endpoints first
    if (getDedicatedEndpoint(model) != null) return .dedicated;
    if (std.mem.startsWith(u8, model, "deepseek-ai/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "zai-org/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "qwen/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "codestral")) return .maas_mistral;
    if (std.mem.startsWith(u8, model, "mistral-")) return .maas_mistral;
    if (std.mem.startsWith(u8, model, "gemma-")) return .genai;
    if (std.mem.startsWith(u8, model, "imagen-")) return .genai;
    return .gemini;
}

fn getDedicatedEndpoint(model: []const u8) ?DedicatedEndpoint {
    registry_lock.lock();
    defer registry_lock.unlock();
    for (endpoint_registry.items) |ep| {
        if (ep.active and std.mem.eql(u8, ep.model_name, model)) return ep;
    }
    return null;
}

fn providerName(model: []const u8) []const u8 {
    if (std.mem.startsWith(u8, model, "deepseek")) return "deepseek";
    if (std.mem.startsWith(u8, model, "zai-org/")) return "zai";
    if (std.mem.startsWith(u8, model, "qwen/")) return "qwen";
    if (std.mem.startsWith(u8, model, "codestral") or std.mem.startsWith(u8, model, "mistral-")) return "mistral";
    if (std.mem.startsWith(u8, model, "gemma-")) return "google-genai";
    if (std.mem.startsWith(u8, model, "imagen-")) return "google-genai";
    return "google";
}

// ── Endpoint URL builders ───────────────────────────────────

fn buildGeminiUrl(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:generateContent",
        .{ DEFAULT_REGION, PROJECT_ID, DEFAULT_REGION, model },
    );
}

fn buildMaasUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "https://aiplatform.googleapis.com/v1beta1/projects/{s}/locations/global/endpoints/openapi/chat/completions",
        .{PROJECT_ID},
    );
}

fn buildDedicatedUrl(allocator: std.mem.Allocator, ep: DedicatedEndpoint) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/endpoints/{s}:predict",
        .{ ep.region, PROJECT_ID, ep.region, ep.endpoint_id },
    );
}

fn buildGenaiUrl(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent",
        .{model},
    );
}

fn buildMistralUrl(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/mistralai/models/{s}:rawPredict",
        .{ MISTRAL_REGION, PROJECT_ID, MISTRAL_REGION, model },
    );
}

// ── Chat Request Types ──────────────────────────────────────

const VertexChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?i32 = null,
    system_prompt: ?[]const u8 = null,
    stream: ?bool = null,
};

const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
};

// ── Handler ─────────────────────────────────────────────────

pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    io: ?std.Io,
    ledger: ?*ledger_mod.Ledger,
    environ_map: *const std.process.Environ.Map,
) Response {
    const ctx = gcp_ctx orelse {
        return .{ .status = .service_unavailable, .body =
            \\{"error":"no_gcp","message":"GCP authentication not available. Vertex AI requires GCP credentials."}
        };
    };

    // Parse request
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch |err| {
        return chatError(err);
    };
    defer allocator.free(body);
    if (body.len == 0) return chatError(error.EmptyBody);

    const parsed = std.json.parseFromSlice(VertexChatRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return chatError(error.OutOfMemory);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0 or req.model.len > security.Limits.max_model_name) {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_model","message":"Model name required"}
        };
    }

    // Billing reserve
    const max_tokens: u32 = if (req.max_tokens) |mt|
        if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap))) @intCast(mt) else 8192
    else
        8192;

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        reservation_id = billing.reserve(s, io_handle, a, req.model, max_tokens, "/qai/v1/vertex/chat") catch {
            return .{ .status = .payment_required, .body =
                \\{"error":"insufficient_balance","message":"Not enough balance for this request"}
            };
        };
    };

    // Route and build request
    const route = routeModel(req.model);
    const result = switch (route) {
        .gemini => callGemini(allocator, ctx, req, max_tokens),
        .maas_openai, .maas_mistral => callMaas(allocator, ctx, req, max_tokens, route),
        .dedicated => callDedicated(allocator, ctx, req, max_tokens),
        .genai => callGenai(allocator, req, max_tokens, environ_map),
    };

    if (result) |resp| {
        // Commit billing
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
            const tier = if (auth) |a| a.account.tier else types.DevTier.free;
            billing.commit(s, io_handle, rid, req.model, resp.input_tokens, resp.output_tokens, tier);

            if (ledger) |l| {
                const bill = billing.actualCost(req.model, resp.input_tokens, resp.output_tokens, tier);
                l.recordBilling(io_handle, if (auth) |a| a.account.id.slice() else "anonymous",
                    if (auth) |a| a.key.prefix.slice() else "none", bill.cost, bill.margin,
                    if (auth) |a| a.account.balance_ticks else 0,
                    "/qai/v1/vertex/chat", req.model, resp.input_tokens, resp.output_tokens, 0);
            }
        };

        return .{ .body = resp.json };
    } else |_| {
        // Rollback
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return .{ .status = .bad_gateway, .body =
            \\{"error":"provider_error","message":"Vertex AI request failed"}
        };
    }
}

const VertexResponse = struct {
    json: []u8,
    input_tokens: u32,
    output_tokens: u32,
};

// ── Gemini Native (generateContent) ─────────────────────────

fn callGemini(allocator: std.mem.Allocator, ctx: *gcp.GcpContext, req: VertexChatRequest, max_tokens: u32) !VertexResponse {
    const url = try buildGeminiUrl(allocator, req.model);
    defer allocator.free(url);

    // Build Gemini request payload
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    // Contents array
    try payload.appendSlice(allocator, "{\"contents\":[");
    var first = true;
    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue; // Handled separately
        if (!first) try payload.append(allocator, ',');
        first = false;

        const role = if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user";
        const escaped = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(escaped);
        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
        , .{ role, escaped });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }
    try payload.appendSlice(allocator, "]");

    // System instruction
    if (req.system_prompt) |sys| {
        const sys_escaped = try chat_mod.jsonEscape(allocator, sys);
        defer allocator.free(sys_escaped);
        const sys_part = try std.fmt.allocPrint(allocator,
            \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
        , .{sys_escaped});
        defer allocator.free(sys_part);
        try payload.appendSlice(allocator, sys_part);
    }

    // Generation config
    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const gen_config = try std.fmt.allocPrint(allocator,
        \\,"generationConfig":{{"temperature":{d:.2},"maxOutputTokens":{d}}}}}
    , .{ temp, max_tokens });
    defer allocator.free(gen_config);
    try payload.appendSlice(allocator, gen_config);

    // Call Vertex
    var resp = try ctx.post(url, payload.items);
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) return error.ApiRequestFailed;

    // Parse Gemini response
    return parseGeminiResponse(allocator, resp.body, req.model);
}

fn parseGeminiResponse(allocator: std.mem.Allocator, body: []u8, model: []const u8) !VertexResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Extract token counts (Gemini provides separate prompt/candidate counts)
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (obj.get("usageMetadata")) |usage| {
        if (usage == .object) {
            if (usage.object.get("promptTokenCount")) |pt| {
                if (pt == .integer) input_tokens = @intCast(pt.integer);
            }
            if (usage.object.get("candidatesTokenCount")) |ct| {
                if (ct == .integer) output_tokens = @intCast(ct.integer);
            }
            // Fallback to total if split not available
            if (input_tokens == 0 and output_tokens == 0) {
                if (usage.object.get("totalTokenCount")) |tc| {
                    if (tc == .integer) {
                        const total: u32 = @intCast(tc.integer);
                        output_tokens = @divFloor(total, 3);
                        input_tokens = total - output_tokens;
                    }
                }
            }
        }
    }

    // Extract text from candidates[0].content.parts[*].text
    // Concatenate ALL text parts — thinking models put thoughts in early parts,
    // actual response in later parts. We take the LAST text part (the final answer).
    var text: []const u8 = "";
    if (obj.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const candidate = candidates.array.items[0];
            if (candidate == .object) {
                if (candidate.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                // Take the last text part (thinking models: last part = final answer)
                                var i = parts.array.items.len;
                                while (i > 0) {
                                    i -= 1;
                                    const part = parts.array.items[i];
                                    if (part == .object) {
                                        if (part.object.get("text")) |t| {
                                            if (t == .string and t.string.len > 0) {
                                                text = t.string;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    const escaped = try chat_mod.jsonEscape(allocator, text);
    defer allocator.free(escaped);

    const json = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","provider":"google","content":[{{"type":"text","text":"{s}"}}],"usage":{{"input_tokens":{d},"output_tokens":{d}}},"stop_reason":"end_turn"}}
    , .{ model, escaped, input_tokens, output_tokens });

    return .{ .json = json, .input_tokens = input_tokens, .output_tokens = output_tokens };
}

// ── MaaS (OpenAI chat/completions + Mistral rawPredict) ─────

fn callMaas(allocator: std.mem.Allocator, ctx: *gcp.GcpContext, req: VertexChatRequest, max_tokens: u32, route: ModelRoute) !VertexResponse {
    const url = switch (route) {
        .maas_mistral => try buildMistralUrl(allocator, req.model),
        else => try buildMaasUrl(allocator),
    };
    defer allocator.free(url);

    // Build OpenAI-format payload
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    const model_escaped = try chat_mod.jsonEscape(allocator, req.model);
    defer allocator.free(model_escaped);

    try payload.appendSlice(allocator, "{\"model\":\"");
    try payload.appendSlice(allocator, model_escaped);
    try payload.appendSlice(allocator, "\",\"messages\":[");

    // System prompt (default English for Chinese models)
    const sys = req.system_prompt orelse "You are a helpful assistant. Respond in English unless the user explicitly writes in another language.";
    const sys_escaped = try chat_mod.jsonEscape(allocator, sys);
    defer allocator.free(sys_escaped);
    try payload.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
    try payload.appendSlice(allocator, sys_escaped);
    try payload.appendSlice(allocator, "\"}");

    // Messages
    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue;

        try payload.append(allocator, ',');
        const role = if (std.mem.eql(u8, msg.role, "assistant")) "assistant" else "user";
        const msg_escaped = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(msg_escaped);

        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","content":"{s}"}}
        , .{ role, msg_escaped });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }

    // Close messages, add config
    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const config_part = try std.fmt.allocPrint(allocator,
        \\],"max_tokens":{d},"temperature":{d:.2},"stream":false}}
    , .{ max_tokens, temp });
    defer allocator.free(config_part);
    try payload.appendSlice(allocator, config_part);

    // Call Vertex MaaS
    var resp = try ctx.post(url, payload.items);
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) return error.ApiRequestFailed;

    // Parse OpenAI-format response
    return parseMaasResponse(allocator, resp.body, req.model);
}

fn parseMaasResponse(allocator: std.mem.Allocator, body: []u8, model: []const u8) !VertexResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Extract text from choices[0].message.content
    // Fallback chain: content → reasoning_content → choices[0].text
    // GLM-5 uses reasoning_content when in reasoning mode (content is null)
    var text: []const u8 = "";
    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                // Standard: choices[0].message.content
                if (choice.object.get("message")) |message| {
                    if (message == .object) {
                        if (message.object.get("content")) |c| {
                            if (c == .string) text = c.string;
                        }
                        // Fallback: reasoning_content (GLM-5, DeepSeek Reasoner)
                        if (text.len == 0) {
                            if (message.object.get("reasoning_content")) |rc| {
                                if (rc == .string) text = rc.string;
                            }
                        }
                    }
                }
                // Fallback: choices[0].text (completions-style)
                if (text.len == 0) {
                    if (choice.object.get("text")) |t| {
                        if (t == .string) text = t.string;
                    }
                }
            }
        }
    }

    // Extract usage
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (obj.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) input_tokens = @intCast(pt.integer);
            }
            if (usage.object.get("completion_tokens")) |ct| {
                if (ct == .integer) output_tokens = @intCast(ct.integer);
            }
        }
    }

    const escaped = try chat_mod.jsonEscape(allocator, text);
    defer allocator.free(escaped);

    const provider = providerName(model);
    const json = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","provider":"{s}","content":[{{"type":"text","text":"{s}"}}],"usage":{{"input_tokens":{d},"output_tokens":{d}}},"stop_reason":"end_turn"}}
    , .{ model, provider, escaped, input_tokens, output_tokens });

    return .{ .json = json, .input_tokens = input_tokens, .output_tokens = output_tokens };
}

// ── Dedicated Endpoint (self-hosted on Vertex GPU cluster) ───
// Uses OpenAI chat/completions format at a private endpoint URL.
// Supports model-specific config injection (e.g., GLM-5.1 thinking mode).

fn callDedicated(allocator: std.mem.Allocator, ctx: *gcp.GcpContext, req: VertexChatRequest, max_tokens: u32) !VertexResponse {
    const ep = getDedicatedEndpoint(req.model) orelse return error.ApiRequestFailed;

    const url = try buildDedicatedUrl(allocator, ep);
    defer allocator.free(url);

    // Build OpenAI-format payload with optional extra params
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    const me = try chat_mod.jsonEscape(allocator, req.model);
    defer allocator.free(me);
    try payload.appendSlice(allocator, "{\"model\":\"");
    try payload.appendSlice(allocator, me);
    try payload.appendSlice(allocator, "\",\"messages\":[");

    // System prompt
    const sys = req.system_prompt orelse "You are a helpful assistant. Respond in English unless the user explicitly writes in another language.";
    const se = try chat_mod.jsonEscape(allocator, sys);
    defer allocator.free(se);
    try payload.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
    try payload.appendSlice(allocator, se);
    try payload.appendSlice(allocator, "\"}");

    // Messages
    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue;
        try payload.append(allocator, ',');
        const role = if (std.mem.eql(u8, msg.role, "assistant")) "assistant" else "user";
        const ce = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(ce);
        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","content":"{s}"}}
        , .{ role, ce });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }

    // Close messages + config
    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const cfg = try std.fmt.allocPrint(allocator,
        \\],"max_tokens":{d},"temperature":{d:.2},"stream":false
    , .{ max_tokens, temp });
    defer allocator.free(cfg);
    try payload.appendSlice(allocator, cfg);

    // Inject model-specific extra params (e.g., GLM-5.1 thinking mode)
    if (ep.extra_params) |extra| {
        try payload.append(allocator, ',');
        try payload.appendSlice(allocator, extra);
    }

    try payload.append(allocator, '}');

    // Call dedicated endpoint
    var resp = try ctx.post(url, payload.items);
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) return error.ApiRequestFailed;

    // Parse OpenAI-format response (same as MaaS)
    return parseMaasResponse(allocator, resp.body, req.model);
}

// ── Google GenAI (generativelanguage.googleapis.com) ─────────
// API key auth (not GCP tokens). Used for Gemma 4, Imagen, consumer models.
// Same generateContent format as Vertex Gemini, but different auth.

fn callGenai(allocator: std.mem.Allocator, req: VertexChatRequest, max_tokens: u32, environ_map: *const std.process.Environ.Map) !VertexResponse {
    const api_key = environ_map.get("GEMINI_API_KEY") orelse
        return error.ApiRequestFailed;

    const base_url = try buildGenaiUrl(allocator, req.model);
    defer allocator.free(base_url);

    // Append API key as query param
    const url = try std.fmt.allocPrint(allocator, "{s}?key={s}", .{ base_url, api_key });
    defer allocator.free(url);

    // Build Gemini-format payload (same as Vertex generateContent)
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"contents\":[");
    var first = true;
    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue;
        if (!first) try payload.append(allocator, ',');
        first = false;

        const role = if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user";
        const escaped = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(escaped);
        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
        , .{ role, escaped });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }
    try payload.appendSlice(allocator, "]");

    // System instruction
    if (req.system_prompt) |sys| {
        const sys_escaped = try chat_mod.jsonEscape(allocator, sys);
        defer allocator.free(sys_escaped);
        const sys_part = try std.fmt.allocPrint(allocator,
            \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
        , .{sys_escaped});
        defer allocator.free(sys_part);
        try payload.appendSlice(allocator, sys_part);
    }

    // Generation config
    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const gen_config = try std.fmt.allocPrint(allocator,
        \\,"generationConfig":{{"temperature":{d:.2},"maxOutputTokens":{d}}}}}
    , .{ temp, max_tokens });
    defer allocator.free(gen_config);
    try payload.appendSlice(allocator, gen_config);

    // Call GenAI — plain HTTP POST with API key in URL (no bearer token)
    var http_client = @import("http-sentinel").HttpClient.init(allocator) catch
        return error.ApiRequestFailed;
    defer http_client.deinit();

    var resp = http_client.post(url, &.{
        .{ .name = "Content-Type", .value = "application/json" },
    }, payload.items) catch return error.ApiRequestFailed;
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) return error.ApiRequestFailed;

    // Same Gemini response format
    return parseGeminiResponse(allocator, resp.body, req.model);
}

// ── Vertex Streaming (SSE) ───────────────────────────────────
// POST /qai/v1/vertex/chat/stream
// Same routing as blocking, but uses streaming endpoints + SSE output.

pub fn handleStream(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    gcp_ctx: ?*gcp.GcpContext,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    io: ?std.Io,
    _ledger: ?*ledger_mod.Ledger,
    environ_map: *const std.process.Environ.Map,
) void {
    _ = _ledger; // Ledger recorded in billing.commit
    const ctx = gcp_ctx orelse {
        sendSseError(request, "GCP auth not available");
        return;
    };

    // Parse request
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        sendSseError(request, "invalid request body");
        return;
    };
    defer allocator.free(body);
    if (body.len == 0) { sendSseError(request, "empty body"); return; }

    const parsed = std.json.parseFromSlice(VertexChatRequest, allocator, body, .{
        .ignore_unknown_fields = true, .allocate = .alloc_always,
    }) catch { sendSseError(request, "invalid JSON"); return; };
    defer parsed.deinit();
    const req = parsed.value;

    const max_tokens: u32 = if (req.max_tokens) |mt|
        if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap))) @intCast(mt) else 8192
    else 8192;

    // Billing reserve
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        reservation_id = billing.reserve(s, io_handle, a, req.model, max_tokens, "/qai/v1/vertex/chat/stream") catch {
            sendSseError(request, "insufficient balance");
            return;
        };
    };

    // Start SSE response
    var stream_buf: [4096]u8 = undefined;
    var body_writer = request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
            .keep_alive = false,
        },
    }) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return;
    };

    const route = routeModel(req.model);

    // MaaS uses real SSE (data: prefix) → use postStreaming for token-by-token.
    // MaaS/Dedicated use real SSE. Gemini/GenAI use JSON array → blocking + SSE output.
    switch (route) {
        .maas_openai, .maas_mistral, .dedicated => {
            const sr = buildStreamingRequest(allocator, ctx, req, max_tokens, route, environ_map) catch {
                if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
                body_writer.writer.writeAll("data: {\"error\":\"request_build_failed\"}\n\n") catch {};
                body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
                body_writer.end() catch {};
                return;
            };
            defer allocator.free(sr.url);
            defer allocator.free(sr.payload);

            if (ctx.postStreaming(sr.url, sr.payload)) |stream| {
                defer stream.deinit();

                var chunk_count: u32 = 0;
                while (stream.next()) |event| {
                    if (event.done) break;
                    if (extractDelta(allocator, event.data, route)) |delta| {
                        defer allocator.free(delta);
                        if (delta.len > 0) {
                            chunk_count += 1;
                            const escaped = chat_mod.jsonEscape(allocator, delta) catch continue;
                            defer allocator.free(escaped);
                            const sse_event = std.fmt.allocPrint(allocator,
                                "data: {{\"delta\":\"{s}\",\"index\":{d}}}\n\n", .{ escaped, chunk_count },
                            ) catch continue;
                            defer allocator.free(sse_event);
                            body_writer.writer.writeAll(sse_event) catch break;
                            body_writer.flush() catch break;
                        }
                    }
                }

                if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
                    const tier = if (auth) |a| a.account.tier else types.DevTier.free;
                    const est_in: u32 = @intCast(@min(@divFloor(body.len, 4) + 10, 100000));
                    billing.commit(s, io_handle, rid, req.model, est_in, @max(chunk_count * 2, 1), tier);
                };
            } else |_| {
                if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
                body_writer.writer.writeAll("data: {\"error\":\"streaming_failed\"}\n\n") catch {};
            }
        },
        .gemini, .genai => {
            // Gemini/GenAI return JSON array stream (not SSE format).
            // Use blocking call + output as SSE event.
            const result = switch (route) {
                .genai => callGenai(allocator, req, max_tokens, environ_map),
                else => callGemini(allocator, ctx, req, max_tokens),
            };
            if (result) |resp| {
                defer allocator.free(resp.json);
                const ev = std.fmt.allocPrint(allocator, "data: {s}\n\n", .{resp.json}) catch "";
                if (ev.len > 0) {
                    defer allocator.free(ev);
                    body_writer.writer.writeAll(ev) catch {};
                    body_writer.flush() catch {};
                }
                if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
                    const tier = if (auth) |a| a.account.tier else types.DevTier.free;
                    billing.commit(s, io_handle, rid, req.model, resp.input_tokens, resp.output_tokens, tier);
                };
            } else |_| {
                if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
                body_writer.writer.writeAll("data: {\"error\":\"provider_error\"}\n\n") catch {};
            }
        },
    }

    body_writer.writer.writeAll("data: [DONE]\n\n") catch {};
    body_writer.end() catch {};
}

const StreamReq = struct {
    url: []u8,
    payload: []u8,
    use_gcp_auth: bool,
};

fn buildStreamingRequest(
    allocator: std.mem.Allocator,
    ctx: *gcp.GcpContext,
    req: VertexChatRequest,
    max_tokens: u32,
    route: ModelRoute,
    environ_map: *const std.process.Environ.Map,
) !StreamReq {
    _ = ctx;
    switch (route) {
        .gemini => {
            // Vertex streaming: streamGenerateContent
            const url = try std.fmt.allocPrint(allocator,
                "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent",
                .{ DEFAULT_REGION, PROJECT_ID, DEFAULT_REGION, req.model });
            const payload = try buildGeminiPayload(allocator, req, max_tokens);
            return .{ .url = url, .payload = payload, .use_gcp_auth = true };
        },
        .maas_openai => {
            const url = try buildMaasUrl(allocator);
            const payload = try buildMaasPayload(allocator, req, max_tokens, true); // stream=true
            return .{ .url = url, .payload = payload, .use_gcp_auth = true };
        },
        .maas_mistral => {
            // Mistral streaming: streamRawPredict
            const url = try std.fmt.allocPrint(allocator,
                "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/mistralai/models/{s}:streamRawPredict",
                .{ MISTRAL_REGION, PROJECT_ID, MISTRAL_REGION, req.model });
            const payload = try buildMaasPayload(allocator, req, max_tokens, true);
            return .{ .url = url, .payload = payload, .use_gcp_auth = true };
        },
        .dedicated => {
            const ep = getDedicatedEndpoint(req.model) orelse return error.ApiRequestFailed;
            // Dedicated endpoints use same URL for streaming (SGLang handles stream param)
            const url = try buildDedicatedUrl(allocator, ep);
            const payload = try buildMaasPayload(allocator, req, max_tokens, true);
            return .{ .url = url, .payload = payload, .use_gcp_auth = true };
        },
        .genai => {
            const api_key = environ_map.get("GEMINI_API_KEY") orelse return error.ApiRequestFailed;
            const url = try std.fmt.allocPrint(allocator,
                "https://generativelanguage.googleapis.com/v1beta/models/{s}:streamGenerateContent?key={s}",
                .{ req.model, api_key });
            const payload = try buildGeminiPayload(allocator, req, max_tokens);
            return .{ .url = url, .payload = payload, .use_gcp_auth = false };
        },
    }
}

fn buildGeminiPayload(allocator: std.mem.Allocator, req: VertexChatRequest, max_tokens: u32) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"contents\":[");
    var first = true;
    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue;
        if (!first) try payload.append(allocator, ',');
        first = false;
        const role = if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user";
        const escaped = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(escaped);
        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
        , .{ role, escaped });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }
    try payload.appendSlice(allocator, "]");

    if (req.system_prompt) |sys| {
        const se = try chat_mod.jsonEscape(allocator, sys);
        defer allocator.free(se);
        const sp = try std.fmt.allocPrint(allocator,
            \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
        , .{se});
        defer allocator.free(sp);
        try payload.appendSlice(allocator, sp);
    }

    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const gc = try std.fmt.allocPrint(allocator,
        \\,"generationConfig":{{"temperature":{d:.2},"maxOutputTokens":{d}}}}}
    , .{ temp, max_tokens });
    defer allocator.free(gc);
    try payload.appendSlice(allocator, gc);

    return payload.toOwnedSlice(allocator);
}

fn buildMaasPayload(allocator: std.mem.Allocator, req: VertexChatRequest, max_tokens: u32, stream: bool) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);

    const me = try chat_mod.jsonEscape(allocator, req.model);
    defer allocator.free(me);
    try payload.appendSlice(allocator, "{\"model\":\"");
    try payload.appendSlice(allocator, me);
    try payload.appendSlice(allocator, "\",\"messages\":[");

    const sys = req.system_prompt orelse "You are a helpful assistant. Respond in English unless the user explicitly writes in another language.";
    const se = try chat_mod.jsonEscape(allocator, sys);
    defer allocator.free(se);
    try payload.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
    try payload.appendSlice(allocator, se);
    try payload.appendSlice(allocator, "\"}");

    for (req.messages) |msg| {
        const content = msg.content orelse continue;
        if (std.mem.eql(u8, msg.role, "system")) continue;
        try payload.append(allocator, ',');
        const role = if (std.mem.eql(u8, msg.role, "assistant")) "assistant" else "user";
        const ce = try chat_mod.jsonEscape(allocator, content);
        defer allocator.free(ce);
        const part = try std.fmt.allocPrint(allocator,
            \\{{"role":"{s}","content":"{s}"}}
        , .{ role, ce });
        defer allocator.free(part);
        try payload.appendSlice(allocator, part);
    }

    const temp: f64 = if (req.temperature) |t| t else 0.7;
    const cfg = try std.fmt.allocPrint(allocator,
        \\],"max_tokens":{d},"temperature":{d:.2},"stream":{s}}}
    , .{ max_tokens, temp, if (stream) "true" else "false" });
    defer allocator.free(cfg);
    try payload.appendSlice(allocator, cfg);

    return payload.toOwnedSlice(allocator);
}

/// Extract text delta from a streaming SSE JSON event.
/// Handles Gemini format (candidates[0].content.parts[*].text)
/// and OpenAI format (choices[0].delta.content).
fn extractDelta(allocator: std.mem.Allocator, data: []const u8, route: ModelRoute) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const obj = parsed.value.object;

    switch (route) {
        .gemini, .genai => {
            // Gemini streaming: candidates[0].content.parts[*].text
            if (obj.get("candidates")) |candidates| {
                if (candidates == .array and candidates.array.items.len > 0) {
                    const c = candidates.array.items[0];
                    if (c == .object) if (c.object.get("content")) |content| {
                        if (content == .object) if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                // Take last text part
                                var i = parts.array.items.len;
                                while (i > 0) {
                                    i -= 1;
                                    if (parts.array.items[i] == .object) {
                                        if (parts.array.items[i].object.get("text")) |t| {
                                            if (t == .string and t.string.len > 0)
                                                return allocator.dupe(u8, t.string) catch null;
                                        }
                                    }
                                }
                            }
                        };
                    };
                }
            }
            return null;
        },
        .maas_openai, .maas_mistral, .dedicated => {
            // OpenAI streaming: choices[0].delta.content
            if (obj.get("choices")) |choices| {
                if (choices == .array and choices.array.items.len > 0) {
                    const c = choices.array.items[0];
                    if (c == .object) if (c.object.get("delta")) |delta| {
                        if (delta == .object) {
                            if (delta.object.get("content")) |ct| {
                                if (ct == .string and ct.string.len > 0)
                                    return allocator.dupe(u8, ct.string) catch null;
                            }
                            // Fallback: reasoning_content (GLM-5)
                            if (delta.object.get("reasoning_content")) |rc| {
                                if (rc == .string and rc.string.len > 0)
                                    return allocator.dupe(u8, rc.string) catch null;
                            }
                        }
                    };
                }
            }
            return null;
        },
    }
}

fn sendSseError(request: *http.Server.Request, message: []const u8) void {
    var buf: [1024]u8 = undefined;
    var bw = request.respondStreaming(&buf, .{
        .respond_options = .{ .status = .bad_request, .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        }, .keep_alive = false },
    }) catch return;
    var eb: [256]u8 = undefined;
    const ev = std.fmt.bufPrint(&eb, "data: {{\"error\":\"{s}\"}}\n\ndata: [DONE]\n\n", .{message}) catch "data: {\"error\":\"unknown\"}\n\ndata: [DONE]\n\n";
    bw.writer.writeAll(ev) catch {};
    bw.end() catch {};
}

// ── Admin: Endpoint Management API ───────────────────────────

const RegisterEndpointRequest = struct {
    model_name: []const u8,
    endpoint_id: []const u8,
    region: []const u8,
    display_name: []const u8 = "",
    extra_params: ?[]const u8 = null,
};

/// POST /qai/v1/admin/endpoints — register a dedicated endpoint
pub fn handleRegisterEndpoint(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    auth: ?*const types.AuthContext,
) Response {
    if (auth) |a| { if (a.account.role != .admin) return .{ .status = .forbidden, .body =
        \\{"error":"forbidden","message":"Admin required"}
    }; } else return .{ .status = .unauthorized, .body =
        \\{"error":"unauthorized"}
    };

    const parsed = json_util.parseBody(RegisterEndpointRequest, request, allocator) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Required: model_name, endpoint_id, region"}
        };
    };
    defer parsed.deinit();
    const req = parsed.value;

    registerEndpoint(.{
        .model_name = req.model_name,
        .endpoint_id = req.endpoint_id,
        .region = req.region,
        .display_name = if (req.display_name.len > 0) req.display_name else req.model_name,
        .extra_params = req.extra_params,
    }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to register endpoint"}
        };
    };

    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"registered","model_name":"{s}","endpoint_id":"{s}","region":"{s}"}}
    , .{ req.model_name, req.endpoint_id, req.region }) catch
        \\{"status":"registered"}
    };
}

/// GET /qai/v1/admin/endpoints — list all dedicated endpoints
pub fn handleListEndpoints(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    auth: ?*const types.AuthContext,
) Response {
    if (auth) |a| { if (a.account.role != .admin) return .{ .status = .forbidden, .body =
        \\{"error":"forbidden"}
    }; } else return .{ .status = .unauthorized, .body =
        \\{"error":"unauthorized"}
    };

    const endpoints = listEndpoints();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"endpoints\":[") catch return .{ .body = "[]" };
    for (endpoints, 0..) |ep, i| {
        if (i > 0) buf.append(allocator, ',') catch continue;
        const entry = std.fmt.allocPrint(allocator,
            \\{{"model_name":"{s}","endpoint_id":"{s}","region":"{s}","display_name":"{s}","active":{s}}}
        , .{ ep.model_name, ep.endpoint_id, ep.region, ep.display_name, if (ep.active) "true" else "false" }) catch continue;
        defer allocator.free(entry);
        buf.appendSlice(allocator, entry) catch continue;
    }
    buf.appendSlice(allocator, "]}") catch {};
    return .{ .body = buf.toOwnedSlice(allocator) catch "[]" };
}

/// DELETE /qai/v1/admin/endpoints/{model_name} — remove a dedicated endpoint
pub fn handleRemoveEndpoint(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    auth: ?*const types.AuthContext,
    model_name: []const u8,
) Response {
    if (auth) |a| { if (a.account.role != .admin) return .{ .status = .forbidden, .body =
        \\{"error":"forbidden"}
    }; } else return .{ .status = .unauthorized, .body =
        \\{"error":"unauthorized"}
    };

    removeEndpoint(model_name);
    return .{ .body = std.fmt.allocPrint(allocator,
        \\{{"status":"removed","model_name":"{s}"}}
    , .{model_name}) catch
        \\{"status":"removed"}
    };
}

fn chatError(err: anyerror) Response {
    return switch (err) {
        error.EmptyBody => .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"Request body is empty"}
        },
        else => .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Failed to parse request body"}
        },
    };
}
