// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! OpenAI GPT client
//! Supports GPT-5.2 and other OpenAI models
//!
//! API Documentation: https://platform.openai.com/docs

const std = @import("std");

/// Pure Zig timer using Io.Timestamp (no libc)
const Timer = struct {
    start_ts: std.Io.Timestamp,
    io: std.Io,

    pub fn start(io: std.Io) Timer {
        return .{ .start_ts = std.Io.Timestamp.now(io, .awake), .io = io };
    }

    pub fn read(self: *const Timer) u64 {
        const elapsed = self.start_ts.untilNow(self.io, .awake);
        const ns = elapsed.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// Get current Unix timestamp in seconds (pure Zig via Io)
fn getCurrentTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const OpenAIClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const OPENAI_API_BASE = "https://api.openai.com/v1";
    const MAX_TURNS = 100;

    /// Available OpenAI models
    pub const Models = struct {
        // GPT-5 series
        pub const GPT_5_2 = "gpt-5.2";
        pub const GPT_5_1 = "gpt-5.1";
        pub const GPT_5 = "gpt-5";
        pub const GPT_5_MINI = "gpt-5-mini";
        pub const GPT_5_NANO = "gpt-5-nano";
        // GPT-5 Pro (extended thinking)
        pub const GPT_5_2_PRO = "gpt-5.2-pro";
        pub const GPT_5_PRO = "gpt-5-pro";
        // Codex series (agentic coding)
        pub const GPT_5_2_CODEX = "gpt-5.2-codex";
        pub const GPT_5_1_CODEX_MAX = "gpt-5.1-codex-max";
        pub const GPT_5_1_CODEX = "gpt-5.1-codex";
        pub const GPT_5_1_CODEX_MINI = "gpt-5.1-codex-mini";
        pub const GPT_5_CODEX = "gpt-5-codex";
        pub const CODEX_MINI_LATEST = "codex-mini-latest";
        // O-series (reasoning)
        pub const O3 = "o3";
        pub const O3_PRO = "o3-pro";
        pub const O3_MINI = "o3-mini";
        pub const O4_MINI = "o4-mini";
        pub const O1 = "o1";
        pub const O1_MINI = "o1-mini";
        // GPT-4.1 series
        pub const GPT_4_1 = "gpt-4.1";
        pub const GPT_4_1_MINI = "gpt-4.1-mini";
        pub const GPT_4_1_NANO = "gpt-4.1-nano";
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenAIClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAIClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *OpenAIClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a streaming message — calls callback for each text chunk
    pub fn sendMessageStreaming(
        self: *OpenAIClient,
        prompt: []const u8,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        context: ?*anyopaque,
    ) !void {
        // Build simple payload with stream: true
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        const model_part = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","stream":true,"input":"{s}"
        , .{ config.model, escaped });
        defer self.allocator.free(model_part);
        try payload.appendSlice(self.allocator, model_part);

        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\,"instructions":"{s}"
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        try payload.appendSlice(self.allocator, "}");

        // Make streaming request
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{OPENAI_API_BASE});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, payload.items);
        defer stream.deinit();

        if (@intFromEnum(stream.status) >= 400) {
            return common.AIError.ApiRequestFailed;
        }

        // Parse SSE events — OpenAI Responses API format:
        // data: {"type":"response.output_text.delta","delta":"..."}
        // data: {"type":"response.completed",...}
        // data: [DONE]
        while (stream.next()) |event| {
            if (event.done) break;

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                event.data,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const obj = parsed.value.object;
            const event_type = obj.get("type") orelse continue;
            if (event_type != .string) continue;

            if (std.mem.eql(u8, event_type.string, "response.output_text.delta")) {
                const delta = obj.get("delta") orelse continue;
                if (delta != .string) continue;

                if (!callback(delta.string, context)) break;
            } else if (std.mem.eql(u8, event_type.string, "response.completed")) {
                break;
            }
        }
    }

    /// Send a message with conversation context
    /// Uses Responses API for all requests (tools and text-only)
    pub fn sendMessageWithContext(
        self: *OpenAIClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        // Use Responses API with structured input when tools are present
        if (config.tools != null) {
            return self.sendMessageWithTools(prompt, context, config);
        }

        var timer = Timer.start(self.http_client.io());

        // Build input string (concatenate context + prompt for Responses API)
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(self.allocator);

        // Add system prompt if present
        if (config.system_prompt) |system| {
            try input.appendSlice(self.allocator, system);
            try input.appendSlice(self.allocator, "\n\n");
        }

        // Add context messages
        for (context) |msg| {
            const role_prefix = switch (msg.role) {
                .user => "User: ",
                .assistant => "Assistant: ",
                .system => "System: ",
                .tool => "Tool: ",
            };
            try input.appendSlice(self.allocator, role_prefix);
            try input.appendSlice(self.allocator, msg.content);
            try input.appendSlice(self.allocator, "\n\n");
        }

        // Add current prompt
        try input.appendSlice(self.allocator, prompt);

        var turn_count: u32 = 0;
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(input.items, config);
            defer self.allocator.free(payload);

            const response = try self.makeRequest(payload);
            defer self.allocator.free(response);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage from Responses API format
            if (parsed.value.object.get("usage")) |usage| {
                if (usage.object.get("input_tokens")) |inp| {
                    total_input_tokens = @intCast(inp.integer);
                }
                if (usage.object.get("output_tokens")) |outp| {
                    total_output_tokens = @intCast(outp.integer);
                }
            }

            // Extract output from Responses API format
            // Response has "output" array with items containing "content" array
            const output = parsed.value.object.get("output") orelse
                return common.AIError.InvalidResponse;

            if (output.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            // Find the text content in the output
            var text_content: std.ArrayList(u8) = .empty;
            defer text_content.deinit(self.allocator);

            for (output.array.items) |item| {
                if (item.object.get("type")) |item_type| {
                    if (std.mem.eql(u8, item_type.string, "message")) {
                        if (item.object.get("content")) |content_arr| {
                            for (content_arr.array.items) |content_item| {
                                if (content_item.object.get("type")) |ct| {
                                    if (std.mem.eql(u8, ct.string, "output_text")) {
                                        if (content_item.object.get("text")) |text| {
                                            try text_content.appendSlice(self.allocator, text.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (text_content.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const elapsed_ns = timer.read();

            return common.AIResponse{
                .message = .{
                    .id = if (parsed.value.object.get("id")) |id|
                        try self.allocator.dupe(u8, id.string)
                    else
                        try common.generateId(self.allocator, self.http_client.io()),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(self.allocator),
                    .timestamp = getCurrentTimestamp(self.http_client.io()),
                    .allocator = self.allocator,
                },
                .usage = .{
                    .input_tokens = total_input_tokens,
                    .output_tokens = total_output_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "openai"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .stop_reason = if (parsed.value.object.get("status")) |status|
                        try self.allocator.dupe(u8, status.string)
                    else
                        null,
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    /// Send a message with tools using the Responses API
    /// Uses structured input items and function_call/function_call_output format
    fn sendMessageWithTools(
        self: *OpenAIClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = Timer.start(self.http_client.io());

        // Build structured input for Responses API
        var input_json: std.ArrayList(u8) = .empty;
        defer input_json.deinit(self.allocator);

        if (context.len == 0) {
            // First turn: simple string input
            const escaped = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped);
            const input_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            defer self.allocator.free(input_str);
            try input_json.appendSlice(self.allocator, input_str);
        } else {
            // Multi-turn: structured input array with conversation history
            try input_json.appendSlice(self.allocator, "[");
            var first = true;
            for (context) |msg| {
                try self.appendResponsesApiItem(&input_json, msg, &first);
            }
            if (prompt.len > 0) {
                if (!first) try input_json.appendSlice(self.allocator, ",");
                const escaped = try common.escapeJsonString(self.allocator, prompt);
                defer self.allocator.free(escaped);
                const user_msg = try std.fmt.allocPrint(self.allocator,
                    \\{{"role":"user","content":"{s}"}}
                , .{escaped});
                defer self.allocator.free(user_msg);
                try input_json.appendSlice(self.allocator, user_msg);
            }
            try input_json.appendSlice(self.allocator, "]");
        }

        // Build tools JSON array (Responses API format: flat, not nested)
        var tools_json: std.ArrayList(u8) = .empty;
        defer tools_json.deinit(self.allocator);
        try tools_json.appendSlice(self.allocator, "[");
        if (config.tools) |tool_defs| {
            for (tool_defs, 0..) |tool, i| {
                if (i > 0) try tools_json.appendSlice(self.allocator, ",");
                const escaped_name = try common.escapeJsonString(self.allocator, tool.name);
                defer self.allocator.free(escaped_name);
                const escaped_desc = try common.escapeJsonString(self.allocator, tool.description);
                defer self.allocator.free(escaped_desc);
                const tool_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"function","name":"{s}","description":"{s}","parameters":{s}}}
                , .{ escaped_name, escaped_desc, tool.input_schema });
                defer self.allocator.free(tool_json);
                try tools_json.appendSlice(self.allocator, tool_json);
            }
        }
        try tools_json.appendSlice(self.allocator, "]");

        // Build optional parts (instructions, verbosity, etc.)
        var optional_parts: std.ArrayList(u8) = .empty;
        defer optional_parts.deinit(self.allocator);

        if (config.system_prompt) |system| {
            const escaped_sys = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped_sys);
            const inst = try std.fmt.allocPrint(self.allocator,
                \\,"instructions":"{s}"
            , .{escaped_sys});
            defer self.allocator.free(inst);
            try optional_parts.appendSlice(self.allocator, inst);
        }

        // Build full payload
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","input":{s},"tools":{s},"reasoning":{{"effort":"{s}"}},"max_output_tokens":{}{s}}}
        , .{
            config.model,
            input_json.items,
            tools_json.items,
            config.reasoning_effort.toString(),
            config.max_tokens,
            optional_parts.items,
        });
        defer self.allocator.free(payload);

        // Make request to /v1/responses
        const response_body = try self.makeRequest(payload);
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Extract usage
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;
        if (parsed.value.object.get("usage")) |usage| {
            if (usage.object.get("input_tokens")) |inp| {
                total_input_tokens = @intCast(inp.integer);
            }
            if (usage.object.get("output_tokens")) |outp| {
                total_output_tokens = @intCast(outp.integer);
            }
        }

        // Extract output items — handle both "message" (text) and "function_call" (tools)
        const output = parsed.value.object.get("output") orelse
            return common.AIError.InvalidResponse;

        var text_content: std.ArrayList(u8) = .empty;
        defer text_content.deinit(self.allocator);

        var tool_calls_list: std.ArrayList(common.ToolCall) = .empty;
        errdefer {
            for (tool_calls_list.items) |*tc| tc.deinit();
            tool_calls_list.deinit(self.allocator);
        }

        for (output.array.items) |item| {
            const item_type = (item.object.get("type") orelse continue).string;

            if (std.mem.eql(u8, item_type, "message")) {
                // Text content from message output
                if (item.object.get("content")) |content_arr| {
                    for (content_arr.array.items) |content_item| {
                        if (content_item.object.get("type")) |ct| {
                            if (std.mem.eql(u8, ct.string, "output_text")) {
                                if (content_item.object.get("text")) |text| {
                                    try text_content.appendSlice(self.allocator, text.string);
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                // Tool call — Responses API uses call_id (not nested function object)
                const call_id = (item.object.get("call_id") orelse continue).string;
                const fn_name = (item.object.get("name") orelse continue).string;
                const fn_args = (item.object.get("arguments") orelse continue).string;

                try tool_calls_list.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, call_id),
                    .name = try self.allocator.dupe(u8, fn_name),
                    .arguments = try self.allocator.dupe(u8, fn_args),
                    .allocator = self.allocator,
                });
            }
        }

        const elapsed_ns = timer.read();

        return common.AIResponse{
            .message = .{
                .id = if (parsed.value.object.get("id")) |id|
                    try self.allocator.dupe(u8, id.string)
                else
                    try common.generateId(self.allocator, self.http_client.io()),
                .role = .assistant,
                .content = if (text_content.items.len > 0)
                    try text_content.toOwnedSlice(self.allocator)
                else
                    try self.allocator.dupe(u8, ""),
                .timestamp = getCurrentTimestamp(self.http_client.io()),
                .tool_calls = if (tool_calls_list.items.len > 0)
                    try tool_calls_list.toOwnedSlice(self.allocator)
                else
                    null,
                .allocator = self.allocator,
            },
            .usage = .{
                .input_tokens = total_input_tokens,
                .output_tokens = total_output_tokens,
            },
            .metadata = .{
                .model = try self.allocator.dupe(u8, config.model),
                .provider = try self.allocator.dupe(u8, "openai"),
                .turns_used = 1,
                .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                .stop_reason = if (parsed.value.object.get("status")) |status|
                    try self.allocator.dupe(u8, status.string)
                else
                    null,
                .allocator = self.allocator,
            },
        };
    }

    fn buildRequestPayload(
        self: *OpenAIClient,
        input: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        // GPT-5.2 uses the Responses API with different format
        const escaped = try common.escapeJsonString(self.allocator, input);
        defer self.allocator.free(escaped);

        // Build optional parameters
        var optional_parts: std.ArrayList(u8) = .empty;
        defer optional_parts.deinit(self.allocator);

        // Add verbosity setting (GPT-5.2 feature)
        const verbosity_part = try std.fmt.allocPrint(self.allocator,
            \\,"text":{{"verbosity":"{s}"}}
        , .{config.verbosity.toString()});
        defer self.allocator.free(verbosity_part);
        try optional_parts.appendSlice(self.allocator, verbosity_part);

        // Add temperature and top_p only when reasoning effort is none
        // (These are not supported with reasoning enabled in GPT-5.2)
        if (config.reasoning_effort == .none) {
            if (config.temperature != 1.0) {
                const temp_part = try std.fmt.allocPrint(self.allocator,
                    \\,"temperature":{d:.2}
                , .{config.temperature});
                defer self.allocator.free(temp_part);
                try optional_parts.appendSlice(self.allocator, temp_part);
            }
            if (config.top_p != 1.0) {
                const top_p_part = try std.fmt.allocPrint(self.allocator,
                    \\,"top_p":{d:.2}
                , .{config.top_p});
                defer self.allocator.free(top_p_part);
                try optional_parts.appendSlice(self.allocator, top_p_part);
            }
        }

        // Add previous_response_id for multi-turn conversations
        if (config.previous_response_id) |prev_id| {
            const prev_part = try std.fmt.allocPrint(self.allocator,
                \\,"previous_response_id":"{s}"
            , .{prev_id});
            defer self.allocator.free(prev_part);
            try optional_parts.appendSlice(self.allocator, prev_part);
        }

        // Build input - either simple string or multimodal array
        if (config.images) |images| {
            // Multimodal input with images
            var input_builder: std.ArrayList(u8) = .empty;
            defer input_builder.deinit(self.allocator);

            try input_builder.appendSlice(self.allocator, "[");

            // Add text input
            const text_input = try std.fmt.allocPrint(self.allocator,
                \\{{"type":"input_text","text":"{s}"}}
            , .{escaped});
            defer self.allocator.free(text_input);
            try input_builder.appendSlice(self.allocator, text_input);

            // Add image inputs
            for (images) |img| {
                const image_url = try img.toImageUrl(self.allocator);
                defer self.allocator.free(image_url);
                const img_input = try std.fmt.allocPrint(self.allocator,
                    \\,{{"type":"input_image","image_url":"{s}"}}
                , .{image_url});
                defer self.allocator.free(img_input);
                try input_builder.appendSlice(self.allocator, img_input);
            }

            try input_builder.appendSlice(self.allocator, "]");

            return std.fmt.allocPrint(self.allocator,
                \\{{"model":"{s}","input":{s},"reasoning":{{"effort":"{s}"}},"max_output_tokens":{}{s}}}
            , .{
                config.model,
                input_builder.items,
                config.reasoning_effort.toString(),
                config.max_tokens,
                optional_parts.items,
            });
        } else {
            // Simple text-only input
            return std.fmt.allocPrint(self.allocator,
                \\{{"model":"{s}","input":"{s}","reasoning":{{"effort":"{s}"}},"max_output_tokens":{}{s}}}
            , .{
                config.model,
                escaped,
                config.reasoning_effort.toString(),
                config.max_tokens,
                optional_parts.items,
            });
        }
    }

    fn makeRequest(self: *OpenAIClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/responses",
            .{OPENAI_API_BASE},
        );
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        );
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *OpenAIClient,
        status: std.http.Status,
        body: []const u8,
    ) common.AIError {
        _ = self;

        return switch (status) {
            .unauthorized, .forbidden => common.AIError.AuthenticationFailed,
            .too_many_requests => common.AIError.RateLimitExceeded,
            .bad_request => common.parseApiError(body),
            else => common.AIError.ApiRequestFailed,
        };
    }

    /// Map an AIMessage to Responses API input item format
    /// function_call items for tool calls, function_call_output for results
    fn appendResponsesApiItem(
        self: *OpenAIClient,
        writer: *std.ArrayList(u8),
        msg: common.AIMessage,
        first: *bool,
    ) !void {
        if (msg.tool_calls) |tool_calls| {
            // Emit function_call items (one per tool call)
            for (tool_calls) |call| {
                if (!first.*) try writer.appendSlice(self.allocator, ",");
                first.* = false;
                const escaped_args = try common.escapeJsonString(self.allocator, call.arguments);
                defer self.allocator.free(escaped_args);
                const item = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"function_call","call_id":"{s}","name":"{s}","arguments":"{s}"}}
                , .{ call.id, call.name, escaped_args });
                defer self.allocator.free(item);
                try writer.appendSlice(self.allocator, item);
            }
        } else if (msg.tool_results) |tool_results| {
            // Emit function_call_output items
            for (tool_results) |result| {
                if (!first.*) try writer.appendSlice(self.allocator, ",");
                first.* = false;
                const escaped = try common.escapeJsonString(self.allocator, result.content);
                defer self.allocator.free(escaped);
                const item = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"function_call_output","call_id":"{s}","output":"{s}"}}
                , .{ result.tool_call_id, escaped });
                defer self.allocator.free(item);
                try writer.appendSlice(self.allocator, item);
            }
        } else {
            // Regular text message
            if (!first.*) try writer.appendSlice(self.allocator, ",");
            first.* = false;
            const role = msg.role.toString();
            const escaped = try common.escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped);
            const msg_json = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"{s}","content":"{s}"}}
            , .{ role, escaped });
            defer self.allocator.free(msg_json);
            try writer.appendSlice(self.allocator, msg_json);
        }
    }

    /// Helper: Create default config for GPT-5.2
    /// Uses none reasoning (lowest latency) and medium verbosity
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_2,
            .max_tokens = 65536,
            .reasoning_effort = .none,
            .verbosity = .medium,
        };
    }

    /// Helper: Create config for GPT-5.2 with medium reasoning
    /// Good for complex tasks requiring step-by-step thinking
    pub fn reasoningConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_2,
            .max_tokens = 65536,
            .reasoning_effort = .medium,
            .verbosity = .medium,
        };
    }

    /// Helper: Create config for GPT-5.2-pro (hard problems)
    /// Uses high reasoning for tough problems that need harder thinking
    pub fn proConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_2_PRO,
            .max_tokens = 65536,
            .reasoning_effort = .high,
            .verbosity = .medium,
        };
    }

    /// Helper: Create config for GPT-5.2-codex (agentic coding)
    /// Optimized for coding tasks in Codex-like environments
    pub fn codexConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_2_CODEX,
            .max_tokens = 65536,
            .reasoning_effort = .medium,
            .verbosity = .low, // Concise code output
        };
    }

    /// Helper: Create config for GPT-5-mini (cost-optimized)
    pub fn miniConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_MINI,
            .max_tokens = 65536,
            .reasoning_effort = .none,
            .verbosity = .medium,
        };
    }

    /// Helper: Create config for GPT-5-nano (fast, cheap)
    pub fn nanoConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_NANO,
            .max_tokens = 65536,
            .reasoning_effort = .none,
            .verbosity = .low,
        };
    }

    /// Helper: Create config with xhigh reasoning (GPT-5.2 only)
    /// Maximum reasoning effort for the most complex problems
    pub fn xhighReasoningConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_2,
            .max_tokens = 65536,
            .reasoning_effort = .xhigh,
            .verbosity = .high,
        };
    }

    /// Helper: Create config for GPT-5.1-Codex-Max (long-running agentic coding)
    /// Optimized for complex, multi-step coding tasks
    /// 400k context, 128k max output, reasoning token support
    pub fn codexMaxConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_1_CODEX_MAX,
            .max_tokens = 65536,
            .reasoning_effort = .medium,
            .verbosity = .low,
        };
    }

    /// Helper: Create config for GPT-5-Codex
    pub fn gpt5CodexConfig() common.RequestConfig {
        return .{
            .model = Models.GPT_5_CODEX,
            .max_tokens = 65536,
            .reasoning_effort = .medium,
            .verbosity = .low,
        };
    }
};

test "OpenAIClient initialization" {
    const allocator = std.testing.allocator;

    var client = try OpenAIClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "OpenAIClient config helpers" {
    const default_cfg = OpenAIClient.defaultConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_2, default_cfg.model);
    try std.testing.expectEqual(common.ReasoningEffort.none, default_cfg.reasoning_effort);
    try std.testing.expectEqual(common.Verbosity.medium, default_cfg.verbosity);

    const reasoning_cfg = OpenAIClient.reasoningConfig();
    try std.testing.expectEqual(common.ReasoningEffort.medium, reasoning_cfg.reasoning_effort);

    const pro_cfg = OpenAIClient.proConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_2_PRO, pro_cfg.model);
    try std.testing.expectEqual(common.ReasoningEffort.high, pro_cfg.reasoning_effort);

    const codex_cfg = OpenAIClient.codexConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_2_CODEX, codex_cfg.model);
    try std.testing.expectEqual(common.Verbosity.low, codex_cfg.verbosity);

    const mini_cfg = OpenAIClient.miniConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_MINI, mini_cfg.model);

    const nano_cfg = OpenAIClient.nanoConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_NANO, nano_cfg.model);

    const xhigh_cfg = OpenAIClient.xhighReasoningConfig();
    try std.testing.expectEqual(common.ReasoningEffort.xhigh, xhigh_cfg.reasoning_effort);

    const codex_max_cfg = OpenAIClient.codexMaxConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_1_CODEX_MAX, codex_max_cfg.model);
    try std.testing.expectEqual(@as(u32, 65536), codex_max_cfg.max_tokens);

    const gpt5_codex_cfg = OpenAIClient.gpt5CodexConfig();
    try std.testing.expectEqualStrings(OpenAIClient.Models.GPT_5_CODEX, gpt5_codex_cfg.model);
}
