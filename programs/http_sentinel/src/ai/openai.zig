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
    base_url: []const u8,
    allocator: std.mem.Allocator,

    pub const DEFAULT_BASE_URL = "https://api.openai.com/v1";
    const MAX_TURNS = 100;

    pub const Config = struct {
        api_key: []const u8,
        base_url: []const u8 = DEFAULT_BASE_URL,
    };

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
        return initWithConfig(allocator, .{ .api_key = api_key });
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !OpenAIClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = config.api_key,
            .base_url = config.base_url,
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
        // Payload goes through std.json.Stringify on a streaming writer —
        // escaping and UTF-8 handling are owned by the standard library.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);
        try jw.objectField("stream");
        try jw.write(true);
        try jw.objectField("input");
        try jw.write(prompt);
        if (config.system_prompt) |system| {
            try jw.objectField("instructions");
            try jw.write(system);
        }
        try jw.endObject();

        const payload_bytes = aw.written();

        // Make streaming request
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, payload_bytes);
        defer stream.deinit();

        if (@intFromEnum(stream.status) >= 400) {
            self.http_client.captureError(stream.body);
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

    /// Tool-aware streaming SSE handler for the OpenAI Responses API.
    /// Translates output_item.added (function_call) /
    /// function_call_arguments.delta / function_call_arguments.done /
    /// output_text.delta / response.completed into common.StreamEvent.
    const EventCtx = struct {
        user_callback: common.StreamEventCallback,
        user_context: ?*anyopaque,
    };

    fn eventStreamHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
        const ctx: *EventCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
        if (event.done) return false;

        // 128 KB — response.completed events for OpenAI Responses API can
        // include the full response shell + usage + tools and easily exceed
        // 16 KB. Using a generous stack buffer keeps the path allocation-free.
        var arena_buf: [128 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        const a = fba.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, a, event.data, .{}) catch return true;
        defer parsed.deinit();

        const obj = parsed.value.object;
        const type_v = obj.get("type") orelse return true;
        if (type_v != .string) return true;
        const t = type_v.string;

        if (std.mem.eql(u8, t, "response.output_text.delta")) {
            const delta_v = obj.get("delta") orelse return true;
            if (delta_v != .string) return true;
            const idx = readU32(obj, "output_index") orelse 0;
            return ctx.user_callback(.{ .text_delta = .{ .index = idx, .text = delta_v.string } }, ctx.user_context);
        }

        if (std.mem.eql(u8, t, "response.output_item.added")) {
            const item = obj.get("item") orelse return true;
            if (item != .object) return true;
            const item_type = item.object.get("type") orelse return true;
            if (item_type != .string) return true;
            if (!std.mem.eql(u8, item_type.string, "function_call")) return true;

            const call_id_v = item.object.get("call_id") orelse return true;
            const name_v = item.object.get("name") orelse return true;
            if (call_id_v != .string or name_v != .string) return true;
            const idx = readU32(obj, "output_index") orelse 0;

            return ctx.user_callback(.{ .tool_use_start = .{
                .index = idx,
                .id = call_id_v.string,
                .name = name_v.string,
            } }, ctx.user_context);
        }

        if (std.mem.eql(u8, t, "response.function_call_arguments.delta")) {
            const delta_v = obj.get("delta") orelse return true;
            if (delta_v != .string) return true;
            const idx = readU32(obj, "output_index") orelse 0;
            return ctx.user_callback(.{ .tool_input_delta = .{ .index = idx, .partial_json = delta_v.string } }, ctx.user_context);
        }

        if (std.mem.eql(u8, t, "response.function_call_arguments.done")) {
            const idx = readU32(obj, "output_index") orelse 0;
            return ctx.user_callback(.{ .block_stop = .{ .index = idx } }, ctx.user_context);
        }

        if (std.mem.eql(u8, t, "response.completed")) {
            var sr: ?[]const u8 = null;
            var in_t: u32 = 0;
            var out_t: u32 = 0;
            if (obj.get("response")) |r| {
                if (r == .object) {
                    if (r.object.get("status")) |s| if (s == .string) {
                        sr = s.string;
                    };
                    if (r.object.get("usage")) |u| if (u == .object) {
                        if (u.object.get("input_tokens")) |it| if (it == .integer and it.integer >= 0) {
                            in_t = @intCast(it.integer);
                        };
                        if (u.object.get("output_tokens")) |ot| if (ot == .integer and ot.integer >= 0) {
                            out_t = @intCast(ot.integer);
                        };
                    };
                }
            }
            return ctx.user_callback(.{ .message_stop = .{
                .stop_reason = sr,
                .input_tokens = in_t,
                .output_tokens = out_t,
            } }, ctx.user_context);
        }

        return true;
    }

    fn readU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            else => null,
        };
    }

    /// Tool-aware streaming with full conversation history.
    /// Mirrors AnthropicClient.sendMessageStreamingWithEvents — emits structured
    /// events through `StreamEventCallback` so callers can drive an agent loop.
    pub fn sendMessageStreamingWithEvents(
        self: *OpenAIClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);
        try jw.objectField("stream");
        try jw.write(true);

        try jw.objectField("input");
        try jw.beginArray();
        for (history) |msg| try self.writeResponsesApiItem(&jw, msg);
        if (prompt.len > 0) {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.write(prompt);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("tools");
        try jw.beginArray();
        if (config.tools) |tool_defs| {
            for (tool_defs) |tool| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function");
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("description");
                try jw.write(tool.description);
                try jw.objectField("parameters");
                try jw.beginWriteRaw();
                try aw.writer.writeAll(tool.input_schema);
                jw.endWriteRaw();
                try jw.endObject();
            }
        }
        try jw.endArray();

        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write(config.reasoning_effort.toString());
        try jw.endObject();

        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);

        if (config.system_prompt) |system| {
            try jw.objectField("instructions");
            try jw.write(system);
        }
        try jw.endObject();

        const payload = aw.written();

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var ev_ctx = EventCtx{
            .user_callback = callback,
            .user_context = cb_context,
        };

        const status = try self.http_client.postSseStream(
            endpoint,
            &headers,
            payload,
            eventStreamHandler,
            &ev_ctx,
        );

        if (@intFromEnum(status) >= 400) {
            return common.AIError.ApiRequestFailed;
        }
    }

    /// Send a streaming message with full conversation history.
    /// Uses Responses API with structured `input` array so role boundaries are preserved.
    /// Tools are not supported in this path — use sendMessageWithContext for tool flows.
    pub fn sendMessageStreamingWithContext(
        self: *OpenAIClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);
        try jw.objectField("stream");
        try jw.write(true);

        try jw.objectField("input");
        try jw.beginArray();
        for (history) |msg| try self.writeResponsesApiItem(&jw, msg);
        if (prompt.len > 0) {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.write(prompt);
            try jw.endObject();
        }
        try jw.endArray();

        if (config.system_prompt) |system| {
            try jw.objectField("instructions");
            try jw.write(system);
        }
        try jw.endObject();

        const payload = aw.written();

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, payload);
        defer stream.deinit();

        if (@intFromEnum(stream.status) >= 400) {
            self.http_client.captureError(stream.body);
            return common.AIError.ApiRequestFailed;
        }

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
                if (!callback(delta.string, cb_context)) break;
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

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);

        try jw.objectField("input");
        if (context.len == 0) {
            // First turn: simple string input
            try jw.write(prompt);
        } else {
            // Multi-turn: structured input array with conversation history
            try jw.beginArray();
            for (context) |msg| try self.writeResponsesApiItem(&jw, msg);
            if (prompt.len > 0) {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(prompt);
                try jw.endObject();
            }
            try jw.endArray();
        }

        try jw.objectField("tools");
        try jw.beginArray();
        if (config.tools) |tool_defs| {
            for (tool_defs) |tool| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function");
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("description");
                try jw.write(tool.description);
                try jw.objectField("parameters");
                try jw.beginWriteRaw();
                try aw.writer.writeAll(tool.input_schema);
                jw.endWriteRaw();
                try jw.endObject();
            }
        }
        try jw.endArray();

        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write(config.reasoning_effort.toString());
        try jw.endObject();

        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);

        if (config.system_prompt) |system| {
            try jw.objectField("instructions");
            try jw.write(system);
        }
        try jw.endObject();

        const payload = aw.written();

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
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);

        try jw.objectField("input");
        if (config.images) |images| {
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_text");
            try jw.objectField("text");
            try jw.write(input);
            try jw.endObject();
            for (images) |img| {
                const image_url = try img.toImageUrl(self.allocator);
                defer self.allocator.free(image_url);
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_image");
                try jw.objectField("image_url");
                try jw.write(image_url);
                try jw.endObject();
            }
            try jw.endArray();
        } else {
            try jw.write(input);
        }

        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write(config.reasoning_effort.toString());
        try jw.endObject();

        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);

        try jw.objectField("text");
        try jw.beginObject();
        try jw.objectField("verbosity");
        try jw.write(config.verbosity.toString());
        try jw.endObject();

        if (config.reasoning_effort == .none) {
            if (config.temperature != 1.0) {
                try jw.objectField("temperature");
                try jw.write(config.temperature);
            }
            if (config.top_p != 1.0) {
                try jw.objectField("top_p");
                try jw.write(config.top_p);
            }
        }

        if (config.previous_response_id) |prev_id| {
            try jw.objectField("previous_response_id");
            try jw.write(prev_id);
        }

        try jw.endObject();

        return aw.toOwnedSlice();
    }

    fn makeRequest(self: *OpenAIClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/responses",
            .{self.base_url},
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

    /// Emit one or more Responses API input items via the supplied
    /// std.json.Stringify writer. The writer must already be inside an
    /// array context (beginArray was called). Array commas are managed
    /// by Stringify, so no `first` bookkeeping is needed any more.
    fn writeResponsesApiItem(
        self: *OpenAIClient,
        jw: *std.json.Stringify,
        msg: common.AIMessage,
    ) !void {
        _ = self;
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |call| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call");
                try jw.objectField("call_id");
                try jw.write(call.id);
                try jw.objectField("name");
                try jw.write(call.name);
                // Per the Responses API the `arguments` value is a
                // JSON-encoded string (not an object). Stringify will
                // escape and quote — correct shape.
                try jw.objectField("arguments");
                try jw.write(call.arguments);
                try jw.endObject();
            }
        } else if (msg.tool_results) |tool_results| {
            for (tool_results) |result| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call_output");
                try jw.objectField("call_id");
                try jw.write(result.tool_call_id);
                try jw.objectField("output");
                try jw.write(result.content);
                try jw.endObject();
            }
        } else {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(msg.role.toString());
            try jw.objectField("content");
            try jw.write(msg.content);
            try jw.endObject();
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
