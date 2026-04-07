// Google AI Studio (GenAI) — generativelanguage.googleapis.com
// API key auth (GEMINI_API_KEY env var). NOT GCP service account tokens.
// Used for: Gemma 4, consumer Gemini, Imagen, and any model on Google AI Studio.
//
// This is architecturally separate from vertex.zig:
//   - vertex.zig = aiplatform.googleapis.com = GCP token auth (enterprise)
//   - genai.zig  = generativelanguage.googleapis.com = API key auth (developer)
// Same generateContent wire format, different auth and endpoints.

const std = @import("std");
const hs = @import("http-sentinel");
const router = @import("router.zig");
const chat_mod = @import("chat.zig");
const billing = @import("billing.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

const GENAI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

/// Shared request type — same as OpenAI-compat format
pub const GenaiRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?i32 = null,
    system_prompt: ?[]const u8 = null,

    const Message = struct {
        role: []const u8,
        content: ?[]const u8 = null,
    };
};

pub const GenaiResponse = struct {
    json: []u8,
    input_tokens: u32,
    output_tokens: u32,
};

/// Handle a GenAI request with pre-read body (called from chat.zig routing).
pub fn handleParsed(
    allocator: std.mem.Allocator,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    io: ?std.Io,
    ledger: ?*ledger_mod.Ledger,
    environ_map: *const std.process.Environ.Map,
    body: []const u8,
) Response {
    const api_key = environ_map.get("GEMINI_API_KEY") orelse {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"config_error","message":"Server missing GEMINI_API_KEY"}
        };
    };

    if (body.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_request","message":"Empty request body"}
    };

    const parsed = std.json.parseFromSlice(GenaiRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Invalid JSON in request body"}
        };
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_model","message":"Model name required"}
    };

    // Dynamic output capping
    var max_tokens: u32 = if (req.max_tokens) |mt|
        if (mt > 0 and mt <= 1_000_000) @intCast(mt) else 8192
    else
        8192;

    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        const input_estimate = billing.estimateInputTokens(body.len);
        const result = billing.reserveWithCap(
            s, io_handle, a, req.model,
            max_tokens, input_estimate, "/qai/v1/chat",
        ) catch {
            return .{ .status = .payment_required, .body =
                \\{"error":"insufficient_balance","message":"Not enough balance for this request"}
            };
        };
        reservation_id = result.reservation_id;
        max_tokens = result.capped_max_tokens;
    };

    // Call Google AI Studio
    const result = callGenai(allocator, api_key, req, max_tokens);

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
                    "/qai/v1/chat", req.model, resp.input_tokens, resp.output_tokens, 0);
            }
        };
        return .{ .body = resp.json };
    } else |_| {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return .{ .status = .bad_gateway, .body =
            \\{"error":"provider_error","message":"Google AI Studio request failed"}
        };
    }
}

// ── API Call ───────────────────────────────────────────────────

fn callGenai(allocator: std.mem.Allocator, api_key: []const u8, req: GenaiRequest, max_tokens: u32) !GenaiResponse {
    // Build URL: generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}
    const url = try std.fmt.allocPrint(allocator,
        "{s}/{s}:generateContent?key={s}",
        .{ GENAI_BASE, req.model, api_key },
    );
    defer allocator.free(url);

    // Build Gemini-format payload
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    // Contents array
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

    // System instruction (omitted if null — some models reject it)
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

    // Plain HTTP POST with API key in URL (no bearer token)
    var http_client = hs.HttpClient.init(allocator) catch return error.ApiRequestFailed;
    defer http_client.deinit();

    var resp = http_client.post(url, &.{
        .{ .name = "Content-Type", .value = "application/json" },
    }, payload.items) catch return error.ApiRequestFailed;
    defer resp.deinit();

    if (@intFromEnum(resp.status) >= 400) return error.ApiRequestFailed;

    return parseGenaiResponse(allocator, resp.body, req.model);
}

// ── Response Parsing ──────────────────────────────────────────

fn parseGenaiResponse(allocator: std.mem.Allocator, body: []u8, model: []const u8) !GenaiResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;

    // Extract token counts
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

    // Extract text from candidates[0].content.parts — take last text part
    var text: []const u8 = "";
    if (obj.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const candidate = candidates.array.items[0];
            if (candidate == .object) {
                if (candidate.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
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

    // Build OpenAI-compat response
    const escaped = chat_mod.jsonEscape(allocator, text) catch return error.InvalidResponse;
    defer allocator.free(escaped);

    const model_escaped = chat_mod.jsonEscape(allocator, model) catch return error.InvalidResponse;
    defer allocator.free(model_escaped);

    const json = std.fmt.allocPrint(allocator,
        \\{{"id":"genai-0","object":"chat.completion","model":"{s}","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
    , .{ model_escaped, escaped, input_tokens, output_tokens, input_tokens + output_tokens }) catch
        return error.InvalidResponse;

    return .{
        .json = json,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    };
}
