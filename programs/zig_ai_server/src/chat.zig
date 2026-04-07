// Chat endpoint — POST /qai/v1/chat
// Routes to AI providers via http_sentinel

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const models_mod = @import("models.zig");
const account_mod = @import("account.zig");
const security = @import("security.zig");
const Response = router.Response;

/// Inbound chat request (matches quantum-sdk ChatRequest)
const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?i32 = null,
    stream: ?bool = null,
    system_prompt: ?[]const u8 = null,
    tools: ?[]const Tool = null,
};

const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    is_error: ?bool = null,
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ?[]const u8 = null,
};

/// Provider env var mapping
pub const ProviderInfo = struct {
    provider: hs.ai.Provider,
    env_var: []const u8,
    default_model: []const u8,
};

const providers = [_]ProviderInfo{
    .{ .provider = .claude, .env_var = "ANTHROPIC_API_KEY", .default_model = "claude-sonnet-4-6-20250929" },
    .{ .provider = .deepseek, .env_var = "DEEPSEEK_API_KEY", .default_model = "deepseek-chat" },
    .{ .provider = .gemini, .env_var = "GEMINI_API_KEY", .default_model = "gemini-2.5-flash" },
    .{ .provider = .grok, .env_var = "XAI_API_KEY", .default_model = "grok-3-mini" },
    .{ .provider = .openai, .env_var = "OPENAI_API_KEY", .default_model = "gpt-4.1-mini" },
};

/// Resolve which provider to use based on the model name
pub fn resolveProvider(model: []const u8) ?ProviderInfo {
    // Match by model prefix
    if (std.mem.startsWith(u8, model, "claude")) {
        return providers[0]; // claude
    } else if (std.mem.startsWith(u8, model, "deepseek")) {
        return providers[1]; // deepseek
    } else if (std.mem.startsWith(u8, model, "gemini")) {
        return providers[2]; // gemini
    } else if (std.mem.startsWith(u8, model, "grok")) {
        return providers[3]; // grok
    } else if (std.mem.startsWith(u8, model, "gpt") or std.mem.startsWith(u8, model, "o1") or std.mem.startsWith(u8, model, "o3") or std.mem.startsWith(u8, model, "o4")) {
        return providers[4]; // openai
    }
    return null;
}

/// Handle POST /qai/v1/chat
pub fn handle(request: *http.Server.Request, allocator: std.mem.Allocator) Response {
    // Parse JSON body (1MB limit for chat)
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch |err| {
        return errorResp(allocator, err);
    };
    defer allocator.free(body);

    if (body.len == 0) return errorResp(allocator, error.EmptyBody);

    const parsed = std.json.parseFromSlice(ChatRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errorResp(allocator, error.OutOfMemory);
    };
    defer parsed.deinit();
    const chat_req = parsed.value;

    // Validate model name length
    if (chat_req.model.len > security.Limits.max_model_name) {
        return .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"Model name too long"}
            ,
        };
    }

    // Cap messages array
    if (chat_req.messages.len > security.Limits.max_messages) {
        return .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"Too many messages (max 200)"}
            ,
        };
    }

    // Resolve provider from model name
    const provider_info = resolveProvider(chat_req.model) orelse {
        return .{
            .status = .bad_request,
            .body = makeError(allocator,
                \\{"error":"invalid_model","message":"Unknown model. Prefix with: claude, deepseek, gemini, grok, gpt"}
            ),
        };
    };

    // Get API key from env
    const api_key = hs.ai.getApiKeyFromEnv(allocator, provider_info.env_var) catch {
        return .{
            .status = .internal_server_error,
            .body = makeError(allocator, std.fmt.allocPrint(allocator,
                \\{{"error":"config_error","message":"Server missing env var: {s}"}}
            , .{provider_info.env_var}) catch
                \\{"error":"config_error","message":"Missing API key env var"}
            ),
        };
    };
    defer allocator.free(api_key);

    // Initialize provider client
    var client = hs.ai.AIClient.init(allocator, provider_info.provider, .{
        .api_key = api_key,
    }) catch {
        return .{
            .status = .internal_server_error,
            .body =
            \\{"error":"provider_error","message":"Failed to initialize AI provider client"}
            ,
        };
    };
    defer client.deinit();

    // Build request config
    var config = hs.ai.RequestConfig{
        .model = chat_req.model,
    };
    if (chat_req.max_tokens) |mt| {
        config.max_tokens = if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap)))
            @intCast(mt)
        else
            4096;
    }
    if (chat_req.temperature) |t| {
        config.temperature = @floatCast(t);
    }
    if (chat_req.system_prompt) |sp| {
        config.system_prompt = sp;
    }

    // Extract the last user message as the prompt
    // Build conversation context from previous messages
    var prompt: []const u8 = "";
    var context_messages: std.ArrayListUnmanaged(hs.ai.AIMessage) = .empty;
    defer {
        for (context_messages.items) |*msg| {
            msg.deinit();
        }
        context_messages.deinit(allocator);
    }

    for (chat_req.messages, 0..) |msg, i| {
        const content = msg.content orelse "";
        if (i == chat_req.messages.len - 1 and std.mem.eql(u8, msg.role, "user")) {
            // Last message is the prompt
            prompt = content;
        } else {
            // Earlier messages become context
            const role = if (std.mem.eql(u8, msg.role, "assistant"))
                hs.ai.common.MessageRole.assistant
            else if (std.mem.eql(u8, msg.role, "system"))
                hs.ai.common.MessageRole.system
            else
                hs.ai.common.MessageRole.user;

            context_messages.append(allocator, .{
                .id = allocator.dupe(u8, "") catch continue,
                .role = role,
                .content = allocator.dupe(u8, content) catch continue,
                .timestamp = 0,
                .allocator = allocator,
            }) catch continue;
        }
    }

    if (prompt.len == 0) {
        return .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"No user message found in messages array"}
            ,
        };
    }

    // Call the AI provider
    var response = if (context_messages.items.len > 0)
        client.sendMessageWithContext(prompt, context_messages.items, config) catch |err| {
            return providerError(allocator, err);
        }
    else
        client.sendMessage(prompt, config) catch |err| {
            return providerError(allocator, err);
        };
    defer response.deinit();

    // Build JSON response (matches quantum-sdk ChatResponse)
    const response_json = buildResponse(allocator, &response, chat_req.model) catch {
        return .{
            .status = .internal_server_error,
            .body =
            \\{"error":"serialization_error","message":"Failed to build response JSON"}
            ,
        };
    };

    return .{
        .status = .ok,
        .body = response_json,
    };
}

fn buildResponse(
    allocator: std.mem.Allocator,
    response: *hs.ai.AIResponse,
    model: []const u8,
) ![]u8 {
    // Escape the content for JSON
    const escaped_content = try jsonEscape(allocator, response.message.content);
    defer allocator.free(escaped_content);

    const stop_reason = response.metadata.stop_reason orelse "end_turn";

    const ticks = costTicks(response, model);

    return std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","model":"{s}","content":[{{"type":"text","text":"{s}"}}],"usage":{{"input_tokens":{d},"output_tokens":{d},"cost_ticks":{d}}},"stop_reason":"{s}","cost_ticks":{d},"request_id":""}}
    , .{
        response.message.id,
        model,
        escaped_content,
        response.usage.input_tokens,
        response.usage.output_tokens,
        ticks,
        stop_reason,
        ticks,
    });
}

fn costTicks(response: *hs.ai.AIResponse, model: []const u8) i64 {
    const pricing = models_mod.getPricing(model);
    const cost = response.usage.estimateCost(pricing.input, pricing.output);
    // Record for account balance tracking
    account_mod.recordCost(cost);
    return @intFromFloat(cost * 10_000_000_000.0);
}

pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
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
                    // Skip control chars
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn providerError(allocator: std.mem.Allocator, err: anyerror) Response {
    const msg = std.fmt.allocPrint(allocator,
        \\{{"error":"provider_error","message":"AI provider returned error: {s}"}}
    , .{@errorName(err)}) catch
        \\{"error":"provider_error","message":"AI provider request failed"}
    ;
    return .{
        .status = .bad_gateway,
        .body = msg,
    };
}

fn errorResp(allocator: std.mem.Allocator, err: anyerror) Response {
    _ = allocator;
    return switch (err) {
        error.PayloadTooLarge => .{
            .status = .payload_too_large,
            .body =
            \\{"error":"payload_too_large","message":"Request body exceeds 10MB limit"}
            ,
        },
        error.EmptyBody => .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"Request body is empty. Send JSON with model and messages."}
            ,
        },
        else => .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_json","message":"Failed to parse request body as JSON"}
            ,
        },
    };
}

fn makeError(allocator: std.mem.Allocator, msg: anytype) []const u8 {
    _ = allocator;
    return msg;
}
