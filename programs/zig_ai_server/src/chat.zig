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
const billing = @import("billing.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const vertex = @import("vertex.zig");
const genai = @import("genai.zig");
const gcp_mod = @import("gcp.zig");
const Response = router.Response;

/// Inbound chat request (matches quantum-sdk ChatRequest)
pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f64 = null,
    max_tokens: ?i32 = null,
    stream: ?bool = null,
    system_prompt: ?[]const u8 = null,
    tools: ?[]const Tool = null,
    /// Optional explicit provider override: "anthropic", "vertex", "genai", "openai", etc.
    /// When null, the model is looked up in models.csv to determine the default route.
    provider: ?[]const u8 = null,
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

/// Resolve the route for a model: explicit provider override → models.csv registry → prefix match.
fn resolveRoute(model: []const u8, explicit_provider: ?[]const u8) models_mod.Route {
    // Explicit provider override (highest priority)
    if (explicit_provider) |p| {
        if (std.mem.eql(u8, p, "vertex")) return .vertex_native;
        if (std.mem.eql(u8, p, "vertex-maas")) return .vertex_maas;
        if (std.mem.eql(u8, p, "genai") or std.mem.eql(u8, p, "google-genai")) return .google_genai;
        if (std.mem.eql(u8, p, "anthropic") or std.mem.eql(u8, p, "deepseek") or
            std.mem.eql(u8, p, "openai") or std.mem.eql(u8, p, "xai")) return .direct;
        // Unknown provider name — fall through to registry
    }

    // Registry lookup (models.csv has provider + route for every known model)
    const route = models_mod.getRoute(model);
    if (route != .unknown) return route;

    // Fallback: if model prefix matches a direct provider, use direct
    if (resolveProvider(model) != null) return .direct;

    return .unknown;
}

/// Resolve which direct provider to use based on the model name (prefix match).
/// Also used by agent.zig and stream.zig for their own provider dispatch.
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

/// Handle POST /qai/v1/chat with pre-read body (called from router).
pub fn handleWithBody(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    gcp_ctx: ?*gcp_mod.GcpContext,
    body: []const u8,
) Response {
    return handleCore(allocator, environ_map, io, store, auth, ledger, gcp_ctx, body);
}

/// Handle POST /qai/v1/chat (reads body from request).
pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    gcp_ctx: ?*gcp_mod.GcpContext,
) Response {
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch |err| {
        return errorResp(allocator, err);
    };
    defer allocator.free(body);
    return handleCore(allocator, environ_map, io, store, auth, ledger, gcp_ctx, body);
}

fn handleCore(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    gcp_ctx: ?*gcp_mod.GcpContext,
    body: []const u8,
) Response {
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

    // ── Provider Routing ──────────────────────────────────
    // 1. If request has explicit "provider" field → route by provider name
    // 2. Else look up model in models.csv → get route (direct, vertex-maas, google-genai, etc.)
    // 3. Dispatch to the isolated provider handler

    const route = resolveRoute(chat_req.model, chat_req.provider);

    switch (route) {
        .vertex_maas, .vertex_native, .vertex_dedicated => {
            return vertex.handleParsed(allocator, gcp_ctx, store, auth, io, ledger, environ_map, body);
        },
        .google_genai => {
            return genai.handleParsed(allocator, store, auth, io, ledger, environ_map, body);
        },
        .direct, .unknown => {}, // fall through to direct provider handling below
    }

    // Direct provider dispatch (API key auth via http-sentinel)
    const provider_info = resolveProvider(chat_req.model) orelse {
        return .{
            .status = .bad_request,
            .body = makeError(allocator,
                \\{"error":"unknown_model","message":"Model not found in registry. Check /qai/v1/models for available models, or pass \"provider\" field to route explicitly."}
            ),
        };
    };

    // Get API key from env
    const api_key = hs.ai.getApiKeyFromEnv(environ_map, provider_info.env_var) catch {
        return .{
            .status = .internal_server_error,
            .body = makeError(allocator, std.fmt.allocPrint(allocator,
                \\{{"error":"config_error","message":"Server missing env var: {s}"}}
            , .{provider_info.env_var}) catch
                \\{"error":"config_error","message":"Missing API key env var"}
            ),
        };
    };
    // api_key is borrowed from environ_map — no free needed

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

    // Build request config — max_tokens starts at provider default,
    // then gets dynamically capped by billing to what the user can afford.
    var config = hs.ai.RequestConfig{
        .model = chat_req.model,
    };
    if (chat_req.max_tokens) |mt| {
        if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap))) {
            config.max_tokens = @intCast(mt);
        }
    }
    if (chat_req.temperature) |t| {
        config.temperature = @floatCast(t);
    }
    if (chat_req.system_prompt) |sp| {
        config.system_prompt = sp;
    }

    // Pass tools to provider (convert our Tool → http_sentinel ToolDefinition)
    var tool_defs: std.ArrayListUnmanaged(hs.ai.common.ToolDefinition) = .empty;
    defer tool_defs.deinit(allocator);
    if (chat_req.tools) |tools| {
        for (tools) |tool| {
            tool_defs.append(allocator, .{
                .name = tool.name,
                .description = tool.description,
                .input_schema = tool.input_schema orelse "{}",
            }) catch continue;
        }
        if (tool_defs.items.len > 0) {
            config.tools = tool_defs.items;
            config.tool_choice = .auto;
        }
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

    // Dynamic output capping: calculate affordable tokens based on balance,
    // cap max_tokens to what the user can afford, then reserve that amount.
    var reservation_id: ?u64 = null;
    if (store) |s| {
        if (auth) |a| {
            if (io) |io_handle| {
                // Estimate input tokens from message payload size (~4 chars/token)
                const input_estimate = billing.estimateInputTokens(body.len);
                const result = billing.reserveWithCap(
                    s, io_handle, a, chat_req.model,
                    config.max_tokens, input_estimate, "/qai/v1/chat",
                ) catch {
                    return .{
                        .status = .payment_required,
                        .body =
                        \\{"error":"insufficient_balance","message":"Not enough balance for this request"}
                        ,
                    };
                };
                reservation_id = result.reservation_id;
                config.max_tokens = result.capped_max_tokens;
            }
        }
    }

    // Call the AI provider
    var response = if (context_messages.items.len > 0)
        client.sendMessageWithContext(prompt, context_messages.items, config) catch |err| {
            // ROLLBACK on provider failure
            if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
            return providerError(allocator, err);
        }
    else
        client.sendMessage(prompt, config) catch |err| {
            if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
            return providerError(allocator, err);
        };
    defer response.deinit();

    // COMMIT billing with actual token usage
    const bill = billing.actualCost(
        chat_req.model,
        response.usage.input_tokens,
        response.usage.output_tokens,
        if (auth) |a| a.account.tier else types.DevTier.free,
    );

    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        billing.commit(s, io_handle, rid, chat_req.model, response.usage.input_tokens, response.usage.output_tokens, if (auth) |a| a.account.tier else types.DevTier.free);
    };

    // Write ledger entry
    if (ledger) |l| if (io) |io_handle| {
        const acct_id = if (auth) |a| a.account.id.slice() else "anonymous";
        const key_pfx = if (auth) |a| a.key.prefix.slice() else "none";
        const bal = if (auth) |a| a.account.balance_ticks else 0;
        l.recordBilling(io_handle, acct_id, key_pfx, bill.cost, bill.margin, bal, "/qai/v1/chat", chat_req.model, response.usage.input_tokens, response.usage.output_tokens, 0);
    };

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
    const escaped_content = try jsonEscape(allocator, response.message.content);
    defer allocator.free(escaped_content);

    const stop_reason = response.metadata.stop_reason orelse "end_turn";
    const ticks = costTicks(response, model);

    // Build tool_calls array if present
    var tool_calls_json: []u8 = "";
    var tool_calls_alloc = false;
    if (response.message.tool_calls) |calls| {
        if (calls.len > 0) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(allocator);
            buf.appendSlice(allocator, ",\"tool_calls\":[") catch {};
            for (calls, 0..) |call, i| {
                if (i > 0) buf.append(allocator, ',') catch continue;
                const escaped_args = jsonEscape(allocator, call.arguments) catch continue;
                defer allocator.free(escaped_args);
                const tc = std.fmt.allocPrint(allocator,
                    \\{{"id":"{s}","name":"{s}","arguments":"{s}"}}
                , .{ call.id, call.name, escaped_args }) catch continue;
                defer allocator.free(tc);
                buf.appendSlice(allocator, tc) catch continue;
            }
            buf.append(allocator, ']') catch {};
            tool_calls_json = buf.toOwnedSlice(allocator) catch "";
            tool_calls_alloc = true;
        }
    }
    defer if (tool_calls_alloc) allocator.free(tool_calls_json);

    return std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","model":"{s}","content":[{{"type":"text","text":"{s}"}}],"usage":{{"input_tokens":{d},"output_tokens":{d},"cost_ticks":{d}}},"stop_reason":"{s}","cost_ticks":{d}{s}}}
    , .{
        response.message.id,
        model,
        escaped_content,
        response.usage.input_tokens,
        response.usage.output_tokens,
        ticks,
        stop_reason,
        ticks,
        tool_calls_json,
    });
}

fn costTicks(response: *hs.ai.AIResponse, model: []const u8) i64 {
    const cost = billing.actualCost(model, response.usage.input_tokens, response.usage.output_tokens, .free);
    return cost.cost + cost.margin;
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
                    // Encode control chars as \u00XX (JSON spec requirement)
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

fn providerError(allocator: std.mem.Allocator, err: anyerror) Response {
    // Sanitize: map to generic categories, never leak raw error names
    // which could reveal internal provider details or API key issues
    _ = allocator;
    const body = switch (err) {
        error.AuthenticationFailed, error.InvalidApiKey =>
            \\{"error":"provider_auth_error","message":"Provider authentication failed. Check server API key configuration."}
        ,
        error.RateLimitExceeded =>
            \\{"error":"rate_limited","message":"Provider rate limit exceeded. Try again shortly."}
        ,
        error.RequestTimeout, error.ConnectionTimeout =>
            \\{"error":"timeout","message":"Provider request timed out."}
        ,
        error.InvalidModel =>
            \\{"error":"invalid_model","message":"The specified model is not available from the provider."}
        ,
        error.ServiceUnavailable, error.ProviderUnavailable =>
            \\{"error":"provider_unavailable","message":"AI provider is temporarily unavailable."}
        ,
        else =>
            \\{"error":"provider_error","message":"AI provider request failed."}
        ,
    };
    return .{
        .status = .bad_gateway,
        .body = body,
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
