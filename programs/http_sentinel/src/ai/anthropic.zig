// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Anthropic API client implementation
//! Used by both Claude and DeepSeek (DeepSeek supports Anthropic API format)
//!
//! API Documentation:
//! - Claude: https://docs.anthropic.com/
//! - DeepSeek: https://api-docs.deepseek.com/guides/anthropic_api

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

/// Anthropic API client (protocol implementation)
pub const AnthropicClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    base_url: []const u8,
    provider_name: []const u8,
    allocator: std.mem.Allocator,

    const DEFAULT_ANTHROPIC_VERSION = "2023-06-01";
    const MAX_TURNS = 100;

    pub const Config = struct {
        api_key: []const u8,
        base_url: []const u8 = "https://api.anthropic.com",
        provider_name: []const u8 = "anthropic",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !AnthropicClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = config.api_key,
            .base_url = config.base_url,
            .provider_name = config.provider_name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnthropicClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *AnthropicClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *AnthropicClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = Timer.start(self.http_client.io());

        // Build messages array
        var messages: std.ArrayList(std.json.Value) = .empty;
        defer messages.deinit(self.allocator);

        // Track parsed JSON objects for cleanup
        var parsed_objects: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_objects.items) |*parsed| {
                parsed.deinit();
            }
            parsed_objects.deinit(self.allocator);
        }

        // Add context messages
        for (context) |msg| {
            const parsed = try self.buildMessageJson(msg);
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        // Add current prompt if non-empty (empty means caller manages all messages via context)
        if (prompt.len > 0) {
            const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped_prompt);

            var prompt_json: []u8 = undefined;
            if (config.images) |images| {
                // Build multimodal content array
                var content_builder: std.ArrayList(u8) = .empty;
                defer content_builder.deinit(self.allocator);

                try content_builder.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":[");

                // Add text part first
                const text_part = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"text","text":"{s}"}}
                , .{escaped_prompt});
                defer self.allocator.free(text_part);
                try content_builder.appendSlice(self.allocator, text_part);

                // Add image parts
                for (images) |img| {
                    if (img.isUrl()) {
                        // URL-based image
                        const img_part = try std.fmt.allocPrint(self.allocator,
                            \\,{{"type":"image","source":{{"type":"url","url":"{s}"}}}}
                        , .{img.url.?});
                        defer self.allocator.free(img_part);
                        try content_builder.appendSlice(self.allocator, img_part);
                    } else {
                        // Base64-encoded image
                        const img_part = try std.fmt.allocPrint(self.allocator,
                            \\,{{"type":"image","source":{{"type":"base64","media_type":"{s}","data":"{s}"}}}}
                        , .{ img.media_type, img.data });
                        defer self.allocator.free(img_part);
                        try content_builder.appendSlice(self.allocator, img_part);
                    }
                }

                try content_builder.appendSlice(self.allocator, "]}");
                prompt_json = try content_builder.toOwnedSlice(self.allocator);
            } else {
                // Simple text-only message
                prompt_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"role":"user","content":"{s}"}}
                , .{escaped_prompt});
            }
            defer self.allocator.free(prompt_json);

            const prompt_parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                prompt_json,
                .{},
            );
            try parsed_objects.append(self.allocator, prompt_parsed);
            try messages.append(self.allocator, prompt_parsed.value);
        }

        var turn_count: u32 = 0;
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            // Build request payload
            const payload = try self.buildRequestPayload(messages.items, config);
            defer self.allocator.free(payload);

            // Make API request
            const response = try self.makeRequest(payload);
            defer self.allocator.free(response);

            // Parse response
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usage")) |usage_obj| {
                if (usage_obj.object.get("input_tokens")) |input| {
                    total_input_tokens = @intCast(input.integer);
                }
                if (usage_obj.object.get("output_tokens")) |output| {
                    total_output_tokens = @intCast(output.integer);
                }
            }

            // Extract content
            const content_array = parsed.value.object.get("content") orelse
                return common.AIError.InvalidResponse;

            // Extract text content and tool calls from response
            var text_content: std.ArrayList(u8) = .empty;
            defer text_content.deinit(self.allocator);

            var tool_calls: std.ArrayList(common.ToolCall) = .empty;
            errdefer {
                for (tool_calls.items) |*tc| tc.deinit();
                tool_calls.deinit(self.allocator);
            }

            for (content_array.array.items) |block| {
                if (block.object.get("type")) |type_val| {
                    if (std.mem.eql(u8, type_val.string, "text")) {
                        if (block.object.get("text")) |text_val| {
                            if (text_content.items.len > 0) {
                                try text_content.appendSlice(self.allocator, "\n");
                            }
                            try text_content.appendSlice(self.allocator, text_val.string);
                        }
                    } else if (std.mem.eql(u8, type_val.string, "tool_use")) {
                        // Extract tool call
                        const tool_id = block.object.get("id") orelse continue;
                        const tool_name = block.object.get("name") orelse continue;
                        const tool_input = block.object.get("input") orelse continue;

                        // Serialize input back to JSON string
                        var input_writer: std.Io.Writer.Allocating = .init(self.allocator);
                        defer input_writer.deinit();
                        var write_stream: std.json.Stringify = .{
                            .writer = &input_writer.writer,
                            .options = .{},
                        };
                        try write_stream.write(tool_input);
                        const input_json = input_writer.written();

                        try tool_calls.append(self.allocator, .{
                            .id = try self.allocator.dupe(u8, tool_id.string),
                            .name = try self.allocator.dupe(u8, tool_name.string),
                            .arguments = try self.allocator.dupe(u8, input_json),
                            .allocator = self.allocator,
                        });
                    }
                }
            }

            const elapsed_ns = timer.read();

            // Get stop reason
            const stop_reason_str = if (parsed.value.object.get("stop_reason")) |sr|
                try self.allocator.dupe(u8, sr.string)
            else
                null;

            // Build response
            return common.AIResponse{
                .message = .{
                    .id = try self.allocator.dupe(u8,
                        parsed.value.object.get("id").?.string),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(self.allocator),
                    .timestamp = getCurrentTimestamp(self.http_client.io()),
                    .tool_calls = if (tool_calls.items.len > 0)
                        try tool_calls.toOwnedSlice(self.allocator)
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
                    .provider = try self.allocator.dupe(u8, self.provider_name),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .max_turns_reached = false,
                    .stop_reason = stop_reason_str,
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *AnthropicClient,
        messages: []const std.json.Value,
        config: common.RequestConfig,
    ) ![]u8 {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{");

        const model_part = try std.fmt.allocPrint(self.allocator, "\"model\":\"{s}\",", .{config.model});
        defer self.allocator.free(model_part);
        try payload.appendSlice(self.allocator, model_part);

        const tokens_part = try std.fmt.allocPrint(self.allocator, "\"max_tokens\":{},", .{config.max_tokens});
        defer self.allocator.free(tokens_part);
        try payload.appendSlice(self.allocator, tokens_part);

        // System prompt
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator, "\"system\":\"{s}\",", .{escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Temperature
        const temp_part = try std.fmt.allocPrint(self.allocator, "\"temperature\":{d},", .{config.temperature});
        defer self.allocator.free(temp_part);
        try payload.appendSlice(self.allocator, temp_part);

        // Tools (if provided)
        if (config.tools) |tools| {
            try payload.appendSlice(self.allocator, "\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try payload.appendSlice(self.allocator, ",");
                const escaped_name = try common.escapeJsonString(self.allocator, tool.name);
                defer self.allocator.free(escaped_name);
                const escaped_desc = try common.escapeJsonString(self.allocator, tool.description);
                defer self.allocator.free(escaped_desc);

                const tool_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"name":"{s}","description":"{s}","input_schema":{s}}}
                , .{ escaped_name, escaped_desc, tool.input_schema });
                defer self.allocator.free(tool_json);
                try payload.appendSlice(self.allocator, tool_json);
            }
            try payload.appendSlice(self.allocator, "],");
        }

        // Messages
        try payload.appendSlice(self.allocator, "\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try payload.appendSlice(self.allocator, ",");

            // Serialize message using a temporary buffer
            var msg_buf: std.ArrayList(u8) = .empty;
            defer msg_buf.deinit(self.allocator);

            var msg_writer = std.Io.Writer.Allocating.init(self.allocator);
            defer msg_writer.deinit();

            var stringify: std.json.Stringify = .{
                .writer = &msg_writer.writer,
                .options = .{},
            };
            try stringify.write(msg);

            try payload.appendSlice(self.allocator, msg_writer.written());
        }
        try payload.appendSlice(self.allocator, "]");

        try payload.appendSlice(self.allocator, "}");

        return payload.toOwnedSlice(self.allocator);
    }

    fn makeRequest(self: *AnthropicClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v1/messages",
            .{self.base_url},
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = DEFAULT_ANTHROPIC_VERSION },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        // Check status
        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    /// SSE callback context — bridges raw SSE events to user's StreamCallback
    const SseCtx = struct {
        allocator: std.mem.Allocator,
        user_callback: common.StreamCallback,
        user_context: ?*anyopaque,
    };

    /// Raw SSE event handler — parses Claude JSON, extracts text deltas
    fn sseEventHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
        const ctx: *SseCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
        if (event.done) return false;

        // Parse JSON from SSE data line
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            ctx.allocator,
            event.data,
            .{},
        ) catch return true; // Skip unparseable events
        defer parsed.deinit();

        const obj = parsed.value.object;
        const event_type = obj.get("type") orelse return true;
        if (event_type != .string) return true;

        if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
            const delta = obj.get("delta") orelse return true;
            if (delta != .object) return true;
            const text = delta.object.get("text") orelse return true;
            if (text != .string) return true;

            return ctx.user_callback(text.string, ctx.user_context);
        }

        return true; // Continue for non-delta events
    }

    /// Send a streaming message — true incremental SSE, first token in milliseconds.
    /// Request stays on the stack (TLS pointers valid). Calls callback per text chunk.
    pub fn sendMessageStreaming(
        self: *AnthropicClient,
        prompt: []const u8,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        context: ?*anyopaque,
    ) !void {
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        const model_part = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","max_tokens":{d},"stream":true,
        , .{ config.model, config.max_tokens });
        defer self.allocator.free(model_part);
        try payload.appendSlice(self.allocator, model_part);

        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\"system":"{s}",
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        const msg_part = try std.fmt.allocPrint(self.allocator,
            \\"messages":[{{"role":"user","content":"{s}"}}]}}
        , .{escaped});
        defer self.allocator.free(msg_part);
        try payload.appendSlice(self.allocator, msg_part);

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.base_url});
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = DEFAULT_ANTHROPIC_VERSION },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        // True incremental streaming — Request stays on stack, TLS pointers valid
        var sse_ctx = SseCtx{
            .allocator = self.allocator,
            .user_callback = callback,
            .user_context = context,
        };

        const status = try self.http_client.postSseStream(
            endpoint,
            &headers,
            payload.items,
            sseEventHandler,
            &sse_ctx,
        );

        if (@intFromEnum(status) >= 400) {
            return common.AIError.ApiRequestFailed;
        }
    }

    fn handleErrorResponse(
        self: *AnthropicClient,
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

    fn buildMessageJson(self: *AnthropicClient, msg: common.AIMessage) !std.json.Parsed(std.json.Value) {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        // Handle different message types
        if (msg.tool_calls) |tool_calls| {
            // Assistant message with tool use
            try json_buf.appendSlice(self.allocator, "{\"role\":\"assistant\",\"content\":[");

            var has_content = false;

            // Add text content if present
            if (msg.content.len > 0) {
                const escaped = try common.escapeJsonString(self.allocator, msg.content);
                defer self.allocator.free(escaped);
                const text_part = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"text","text":"{s}"}}
                , .{escaped});
                defer self.allocator.free(text_part);
                try json_buf.appendSlice(self.allocator, text_part);
                has_content = true;
            }

            // Add tool use blocks
            for (tool_calls, 0..) |call, i| {
                if (i > 0 or has_content) try json_buf.appendSlice(self.allocator, ",");

                const escaped_name = try common.escapeJsonString(self.allocator, call.name);
                defer self.allocator.free(escaped_name);

                const tool_part = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"tool_use","id":"{s}","name":"{s}","input":{s}}}
                , .{ call.id, escaped_name, call.arguments });
                defer self.allocator.free(tool_part);
                try json_buf.appendSlice(self.allocator, tool_part);
            }

            try json_buf.appendSlice(self.allocator, "]}");
        } else if (msg.tool_results) |tool_results| {
            // User message with tool results
            try json_buf.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":[");

            for (tool_results, 0..) |result, i| {
                if (i > 0) try json_buf.appendSlice(self.allocator, ",");

                const escaped = try common.escapeJsonString(self.allocator, result.content);
                defer self.allocator.free(escaped);

                const result_part = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"tool_result","tool_use_id":"{s}","content":"{s}"}}
                , .{ result.tool_call_id, escaped });
                defer self.allocator.free(result_part);
                try json_buf.appendSlice(self.allocator, result_part);
            }

            try json_buf.appendSlice(self.allocator, "]}");
        } else {
            // Simple text message
            const role_str = msg.role.toString();
            const escaped_content = try common.escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped_content);

            const json_str = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"{s}","content":"{s}"}}
            , .{ role_str, escaped_content });
            defer self.allocator.free(json_str);
            try json_buf.appendSlice(self.allocator, json_str);
        }

        return try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_buf.items,
            .{},
        );
    }
};

test "AnthropicClient initialization" {
    const allocator = std.testing.allocator;

    var client = try AnthropicClient.init(allocator, .{
        .api_key = "test-key",
        .base_url = "https://test.example.com",
        .provider_name = "test",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("https://test.example.com", client.base_url);
}
