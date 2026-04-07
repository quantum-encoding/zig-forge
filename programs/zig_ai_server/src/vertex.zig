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
    gemini, // Vertex generateContent API
    maas_openai, // Global OpenAI-compatible endpoint
    maas_mistral, // Regional rawPredict (Mistral publisher)
};

fn routeModel(model: []const u8) ModelRoute {
    if (std.mem.startsWith(u8, model, "deepseek-ai/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "zai-org/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "qwen/")) return .maas_openai;
    if (std.mem.startsWith(u8, model, "codestral")) return .maas_mistral;
    if (std.mem.startsWith(u8, model, "mistral-")) return .maas_mistral;
    return .gemini;
}

fn providerName(model: []const u8) []const u8 {
    if (std.mem.startsWith(u8, model, "deepseek")) return "deepseek";
    if (std.mem.startsWith(u8, model, "zai-org/")) return "zai";
    if (std.mem.startsWith(u8, model, "qwen/")) return "qwen";
    if (std.mem.startsWith(u8, model, "codestral") or std.mem.startsWith(u8, model, "mistral-")) return "mistral";
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

    // Extract token count
    var total_tokens: u32 = 0;
    if (obj.get("usageMetadata")) |usage| {
        if (usage == .object) {
            if (usage.object.get("totalTokenCount")) |tc| {
                if (tc == .integer) total_tokens = @intCast(tc.integer);
            }
        }
    }

    // Extract text from candidates[0].content.parts[0].text
    var text: []const u8 = "";
    if (obj.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const candidate = candidates.array.items[0];
            if (candidate == .object) {
                if (candidate.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array and parts.array.items.len > 0) {
                                const part = parts.array.items[0];
                                if (part == .object) {
                                    if (part.object.get("text")) |t| {
                                        if (t == .string) text = t.string;
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

    // Estimate input/output split (Gemini only gives total)
    const output_est: u32 = @divFloor(total_tokens, 3);
    const input_est: u32 = total_tokens - output_est;

    const json = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","provider":"google","content":[{{"type":"text","text":"{s}"}}],"usage":{{"input_tokens":{d},"output_tokens":{d}}},"stop_reason":"end_turn"}}
    , .{ model, escaped, input_est, output_est });

    return .{ .json = json, .input_tokens = input_est, .output_tokens = output_est };
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
    var text: []const u8 = "";
    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("message")) |message| {
                    if (message == .object) {
                        if (message.object.get("content")) |c| {
                            if (c == .string) text = c.string;
                        }
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
