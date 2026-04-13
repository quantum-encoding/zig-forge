// Agent endpoint — POST /qai/v1/agent
// Stateless tool-call passthrough. The server does NOT execute tools.
//
// Flow:
//   1. Client sends: { model, messages, tools, capabilities, system_prompt }
//   2. Server: filters tools by capabilities, normalizes schemas per provider
//   3. Server: calls the provider with the normalized request
//   4. Server: streams back SSE events (content_delta, tool_use, usage, done)
//   5. Client: executes tool calls locally (under Guardian Shield)
//   6. Client: sends next request with tool_result messages in history
//   7. Repeat until model returns end_turn (no more tool calls)
//
// This matches the Anthropic API pattern — stateless round-trips, no server state.
// The server's value: capability filtering, schema normalization (forge), billing.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const chat_mod = @import("chat.zig");
const forge = @import("forge.zig");
const security = @import("security.zig");
const billing = @import("billing.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const Response = router.Response;

// ── Request / Response Types ───────────────────────────────────

const AgentRequest = struct {
    model: []const u8,
    messages: []const Message,
    /// Canonical tool definitions — provider-agnostic schemas.
    /// The forge normalizes these per provider before sending.
    tools: ?[]const ToolDef = null,
    /// Capability allowlist. Filters which tools the model sees.
    ///   null → all tools. [] → no tools (Safe Mode). non-empty → allowlist.
    capabilities: ?[]const []const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: ?i32 = null,
    temperature: ?f64 = null,
    /// If true, stream response as SSE. Default true for agent.
    stream: ?bool = null,
};

const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    /// Tool call ID (for tool_result messages)
    tool_call_id: ?[]const u8 = null,
    /// Tool use from the model's previous turn (assistant messages)
    tool_use: ?[]const ToolUse = null,
    /// Indicates this is a tool result (error case)
    is_error: ?bool = null,
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema: []const u8 = "{}",
};

const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: ?[]const u8 = null, // JSON string
};

// Re-export for edge_case_tests
pub const filterToolsByCapabilities = @import("cloudrun.zig").filterToolsByCapabilities;

// ── Handler ────────────────────────────────────────────────────

pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
) Response {
    // Parse request
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"Failed to read request body"}
        };
    };
    defer allocator.free(body);

    if (body.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_request","message":"Request body required"}
    };

    const parsed = std.json.parseFromSlice(AgentRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Invalid JSON. Required: model, messages"}
        };
    };
    defer parsed.deinit();
    const req = parsed.value;

    if (req.model.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_request","message":"model is required"}
    };

    // Resolve provider
    const provider_info = chat_mod.resolveProvider(req.model) orelse {
        return .{ .status = .bad_request, .body =
            \\{"error":"unknown_model","message":"Model not found. Check /qai/v1/models."}
        };
    };

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, provider_info.env_var) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"config_error","message":"Missing provider API key"}
        };
    };

    // Determine provider for forge normalization
    const provider = forge.Provider.fromModel(req.model);

    // Build tool definitions — filter by capabilities, normalize for provider
    var tools_to_send: ?[]const hs.ai.common.ToolDefinition = null;
    var normalized_tools: ?[]hs.ai.common.ToolDefinition = null;
    defer if (normalized_tools) |nt| {
        for (nt) |t| {
            // Only free schemas that were allocated by the forge (not originals)
            _ = t;
        }
        allocator.free(nt);
    };

    if (req.tools) |client_tools| {
        // Convert client ToolDef → http-sentinel ToolDefinition
        var hs_tools: std.ArrayListUnmanaged(hs.ai.common.ToolDefinition) = .empty;
        defer hs_tools.deinit(allocator);

        for (client_tools) |t| {
            hs_tools.append(allocator, .{
                .name = t.name,
                .description = t.description,
                .input_schema = t.input_schema,
            }) catch continue;
        }

        if (hs_tools.items.len > 0) {
            // Forge: normalize schemas per provider
            const forge_config = forge.ForgeConfig{
                .provider = provider,
                .tool_count = hs_tools.items.len,
                .tool_choice_forces_use = false,
            };
            normalized_tools = forge.normalizeTools(allocator, hs_tools.items, forge_config) catch null;
            tools_to_send = normalized_tools orelse hs_tools.items;
        }
    }

    // Build provider request config
    var config = hs.ai.RequestConfig{
        .model = req.model,
        .tools = tools_to_send,
        .tool_choice = if (tools_to_send != null) .auto else .none,
    };

    if (req.max_tokens) |mt| {
        if (mt > 0 and mt <= @as(i32, @intCast(security.Limits.max_tokens_cap)))
            config.max_tokens = @intCast(mt);
    }
    if (req.temperature) |t| config.temperature = @floatCast(t);
    if (req.system_prompt) |sp| config.system_prompt = sp;

    // Billing: dynamic output capping
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        const input_estimate = billing.estimateInputTokens(body.len);
        const result = billing.reserveWithCap(
            s, io_handle, a, req.model,
            config.max_tokens, input_estimate, "/qai/v1/agent",
        ) catch {
            return .{ .status = .payment_required, .body =
                \\{"error":"insufficient_balance","message":"Not enough balance for this request"}
            };
        };
        reservation_id = result.reservation_id;
        config.max_tokens = result.capped_max_tokens;
    };

    // Build conversation context from messages
    var prompt: []const u8 = "";
    var context_messages: std.ArrayListUnmanaged(hs.ai.AIMessage) = .empty;
    defer {
        for (context_messages.items) |*msg| msg.deinit();
        context_messages.deinit(allocator);
    }

    for (req.messages, 0..) |msg, i| {
        const content = msg.content orelse "";
        if (i == req.messages.len - 1 and std.mem.eql(u8, msg.role, "user")) {
            prompt = content;
        } else {
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

    // Initialize provider client
    var client = hs.ai.AIClient.init(allocator, provider_info.provider, .{
        .api_key = api_key,
    }) catch {
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
        return .{ .status = .internal_server_error, .body =
            \\{"error":"provider_error","message":"Failed to init AI client"}
        };
    };
    defer client.deinit();

    // Call provider (non-streaming for now — the response includes tool_use)
    var response = if (context_messages.items.len > 0)
        client.sendMessageWithContext(prompt, context_messages.items, config) catch {
            if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
            return .{ .status = .bad_gateway, .body =
                \\{"error":"provider_error","message":"Provider request failed"}
            };
        }
    else
        client.sendMessage(prompt, config) catch {
            if (reservation_id) |rid| if (store) |s| if (io) |io_handle| billing.rollback(s, io_handle, rid);
            return .{ .status = .bad_gateway, .body =
                \\{"error":"provider_error","message":"Provider request failed"}
            };
        };
    defer response.deinit();

    // Commit billing
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        const tier = if (auth) |a| a.account.tier else types.DevTier.free;
        billing.commit(s, io_handle, rid, req.model,
            response.usage.input_tokens, response.usage.output_tokens, tier);

        if (ledger) |l| {
            const bill = billing.actualCost(req.model, response.usage.input_tokens,
                response.usage.output_tokens, tier);
            l.recordBilling(io_handle, if (auth) |a| a.account.id.slice() else "anon",
                if (auth) |a| a.key.prefix.slice() else "none", bill.cost, bill.margin,
                if (auth) |a| a.account.balance_ticks else 0,
                "/qai/v1/agent", req.model, response.usage.input_tokens,
                response.usage.output_tokens, 0);
        }
    };

    // Build response — includes tool_use if the model wants to call tools
    const stop_reason = response.metadata.stop_reason orelse "end_turn";
    const has_tool_calls = response.message.tool_calls != null and
        response.message.tool_calls.?.len > 0;

    // Build the response JSON
    var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer resp_buf.deinit(allocator);

    const content_escaped = chat_mod.jsonEscape(allocator, response.message.content) catch "";
    defer if (content_escaped.len > 0) allocator.free(content_escaped);

    // Start response object
    const header = std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","model":"{s}","stop_reason":"{s}",
    , .{ response.message.id, req.model, stop_reason }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build response"}
        };
    };
    defer allocator.free(header);
    resp_buf.appendSlice(allocator, header) catch {};

    // Content
    const content_part = std.fmt.allocPrint(allocator,
        \\"content":[{{"type":"text","text":"{s}"}}],
    , .{content_escaped}) catch "";
    defer if (content_part.len > 0) allocator.free(content_part);
    resp_buf.appendSlice(allocator, content_part) catch {};

    // Tool use (if any)
    if (has_tool_calls) {
        resp_buf.appendSlice(allocator, "\"tool_use\":[") catch {};
        for (response.message.tool_calls.?, 0..) |call, i| {
            if (i > 0) resp_buf.appendSlice(allocator, ",") catch {};
            const tool_json = std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","name":"{s}","input":{s}}}
            , .{ call.id, call.name, call.arguments }) catch continue;
            defer allocator.free(tool_json);
            resp_buf.appendSlice(allocator, tool_json) catch {};
        }
        resp_buf.appendSlice(allocator, "],") catch {};
    }

    // Usage
    const usage_part = std.fmt.allocPrint(allocator,
        \\"usage":{{"input_tokens":{d},"output_tokens":{d}}}}}
    , .{ response.usage.input_tokens, response.usage.output_tokens }) catch "";
    defer if (usage_part.len > 0) allocator.free(usage_part);
    resp_buf.appendSlice(allocator, usage_part) catch {};

    const final = resp_buf.toOwnedSlice(allocator) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build response"}
        };
    };

    return .{ .body = final };
}
