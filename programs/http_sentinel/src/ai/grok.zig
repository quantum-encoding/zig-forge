// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! X.AI Grok client — Responses API
//! Text generation, tool calling, and server-side agentic tools
//!
//! API Documentation: https://docs.x.ai/api
//!
//! Supports:
//!   - Client-side function tools (local execution via function_call/function_call_output)
//!   - Server-side tools: web_search, x_search, code_interpreter (auto-executed by xAI)
//!   - Mixed tool requests (server-side + client-side in same tools array)
//!   - Multi-turn via previous_response_id and store parameter
//!   - server_max_turns to limit server-side agentic loop turns
//!
//! Key constraint: `instructions` parameter is NOT supported —
//! system prompts must use {"role":"system","content":"..."} in the input array.

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

pub const GrokClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    base_url: []const u8,
    allocator: std.mem.Allocator,

    pub const DEFAULT_BASE_URL = "https://api.x.ai/v1";
    const MAX_TURNS = 100;

    pub const Config = struct {
        api_key: []const u8,
        base_url: []const u8 = DEFAULT_BASE_URL,
    };

    /// Available Grok models
    pub const Models = struct {
        pub const FAST = "grok-4-1-fast-non-reasoning";
        pub const REASONING = "grok-4-1-fast-reasoning";
        pub const GROK_4 = "grok-4-0709";
        pub const CODE = "grok-code-fast-1";
        pub const IMAGE_PRO = "grok-imagine-image-pro";
        pub const IMAGE = "grok-imagine-image";
        pub const VIDEO = "grok-imagine-video";
        // Legacy aliases
        pub const CODE_FAST_1 = FAST;
        pub const CODE_DEEP_1 = REASONING;
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GrokClient {
        return initWithConfig(allocator, .{ .api_key = api_key });
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !GrokClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = config.api_key,
            .base_url = config.base_url,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GrokClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *GrokClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a streaming message — calls callback for each text chunk
    pub fn sendMessageStreaming(
        self: *GrokClient,
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
            \\{{"model":"{s}","stream":true,"input":[
        , .{config.model});
        defer self.allocator.free(model_part);
        try payload.appendSlice(self.allocator, model_part);

        // System prompt as input item (xAI does NOT support `instructions`)
        var has_item = false;
        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
            has_item = true;
        }

        if (has_item) try payload.appendSlice(self.allocator, ",");
        const msg_part = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","content":"{s}"}}]}}
        , .{escaped});
        defer self.allocator.free(msg_part);
        try payload.appendSlice(self.allocator, msg_part);

        // Make streaming request
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
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

        // Parse SSE events — xAI Responses API format:
        // data: {"type":"response.output_text.delta","delta":"..."}
        // data: {"type":"response.completed",...}
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

    /// Send a streaming message with full conversation history.
    /// xAI Responses API with structured `input` array — role boundaries preserved.
    pub fn sendMessageStreamingWithContext(
        self: *GrokClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        const head = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","stream":true,"input":[
        , .{config.model});
        defer self.allocator.free(head);
        try payload.appendSlice(self.allocator, head);

        var first = true;

        // System prompt as the first input item (xAI does NOT support `instructions`).
        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
            first = false;
        }

        // Conversation history.
        for (history) |msg| {
            if (!first) try payload.appendSlice(self.allocator, ",");
            first = false;
            const role = msg.role.toString();
            const escaped = try common.escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped);
            const item = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"{s}","content":"{s}"}}
            , .{ role, escaped });
            defer self.allocator.free(item);
            try payload.appendSlice(self.allocator, item);
        }

        // Current user turn.
        if (prompt.len > 0) {
            if (!first) try payload.appendSlice(self.allocator, ",");
            const escaped = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped);
            const item = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","content":"{s}"}}
            , .{escaped});
            defer self.allocator.free(item);
            try payload.appendSlice(self.allocator, item);
        }

        try payload.appendSlice(self.allocator, "]}");

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
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

    /// Tool-aware streaming SSE handler for the xAI Responses API.
    /// Translates output_item.added / function_call_arguments.delta /
    /// function_call_arguments.done / output_text.delta / response.completed
    /// into the unified `common.StreamEvent` variants.
    const EventCtx = struct {
        user_callback: common.StreamEventCallback,
        user_context: ?*anyopaque,
    };

    fn eventStreamHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
        const ctx: *EventCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
        if (event.done) return false;

        var arena_buf: [16 * 1024]u8 = undefined;
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
            // Pull stop reason out of response.status if present.
            const sr: ?[]const u8 = blk: {
                if (obj.get("response")) |r| {
                    if (r == .object) {
                        if (r.object.get("status")) |s| if (s == .string) break :blk s.string;
                    }
                }
                break :blk null;
            };
            return ctx.user_callback(.{ .message_stop = .{ .stop_reason = sr } }, ctx.user_context);
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
        self: *GrokClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        // Build structured input array: system → history → user prompt.
        var input_json: std.ArrayList(u8) = .empty;
        defer input_json.deinit(self.allocator);
        try input_json.appendSlice(self.allocator, "[");
        var first = true;

        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{sys_escaped});
            defer self.allocator.free(sys_msg);
            try input_json.appendSlice(self.allocator, sys_msg);
            first = false;
        }

        for (history) |msg| {
            try self.appendResponsesApiItem(&input_json, msg, &first);
        }

        if (prompt.len > 0) {
            if (!first) try input_json.appendSlice(self.allocator, ",");
            const escaped = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped);
            const um = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","content":"{s}"}}
            , .{escaped});
            defer self.allocator.free(um);
            try input_json.appendSlice(self.allocator, um);
        }
        try input_json.appendSlice(self.allocator, "]");

        // Build tools array (Responses API: flat function_call descriptors).
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
                const tj = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"function","name":"{s}","description":"{s}","parameters":{s}}}
                , .{ escaped_name, escaped_desc, tool.input_schema });
                defer self.allocator.free(tj);
                try tools_json.appendSlice(self.allocator, tj);
            }
        }
        try tools_json.appendSlice(self.allocator, "]");

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","stream":true,"input":{s},"tools":{s},"max_output_tokens":{}}}
        , .{ config.model, input_json.items, tools_json.items, config.max_tokens });
        defer self.allocator.free(payload);

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

    /// Send a message with conversation context
    /// Uses Responses API for all requests
    pub fn sendMessageWithContext(
        self: *GrokClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        // Delegate to tools path when any tools are present (client-side, server-side, MCP, or file attachments)
        if (config.tools != null or config.server_tools != null or config.mcp_tools != null or config.collection_ids != null or config.file_ids != null) {
            return self.sendMessageWithTools(prompt, context, config);
        }

        var timer = Timer.start(self.http_client.io());

        // Build input array for Responses API
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(self.allocator);

        try input.appendSlice(self.allocator, "[");

        // System message (xAI does NOT support `instructions` — must be in input array)
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{escaped});
            defer self.allocator.free(sys_msg);
            try input.appendSlice(self.allocator, sys_msg);
        }

        // Context messages
        for (context) |msg| {
            if (input.items.len > 1) try input.appendSlice(self.allocator, ",");
            try self.appendInputItem(&input, msg);
        }

        // Current prompt (with images if provided)
        if (input.items.len > 1) try input.appendSlice(self.allocator, ",");
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);

        if (config.images != null or config.file_ids != null) {
            // Multimodal content array (images and/or file attachments)
            var content_builder: std.ArrayList(u8) = .empty;
            defer content_builder.deinit(self.allocator);

            try content_builder.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":[");

            // Add text part
            const text_part = try std.fmt.allocPrint(self.allocator,
                \\{{"type":"input_text","text":"{s}"}}
            , .{escaped_prompt});
            defer self.allocator.free(text_part);
            try content_builder.appendSlice(self.allocator, text_part);

            // Add image parts (supports both base64 data URIs and direct HTTPS URLs)
            if (config.images) |images| {
                for (images) |img| {
                    const img_url = try img.toImageUrl(self.allocator);
                    defer self.allocator.free(img_url);
                    const img_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"type":"image_url","image_url":{{"url":"{s}"}}}}
                    , .{img_url});
                    defer self.allocator.free(img_part);
                    try content_builder.appendSlice(self.allocator, img_part);
                }
            }

            // Add file attachment parts (triggers automatic attachment_search)
            if (config.file_ids) |fids| {
                for (fids) |fid| {
                    const escaped_fid = try common.escapeJsonString(self.allocator, fid);
                    defer self.allocator.free(escaped_fid);
                    const file_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"type":"input_file","file_id":"{s}"}}
                    , .{escaped_fid});
                    defer self.allocator.free(file_part);
                    try content_builder.appendSlice(self.allocator, file_part);
                }
            }

            try content_builder.appendSlice(self.allocator, "]}");
            try input.appendSlice(self.allocator, content_builder.items);
        } else {
            // Simple text content
            const prompt_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","content":"{s}"}}
            , .{escaped_prompt});
            defer self.allocator.free(prompt_msg);
            try input.appendSlice(self.allocator, prompt_msg);
        }

        try input.appendSlice(self.allocator, "]");

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

            // Extract usage (Responses API format)
            if (parsed.value.object.get("usage")) |usage| {
                if (usage.object.get("input_tokens")) |inp| {
                    total_input_tokens = @intCast(inp.integer);
                }
                if (usage.object.get("output_tokens")) |outp| {
                    total_output_tokens = @intCast(outp.integer);
                }
            }

            // Extract output from Responses API format
            const output = parsed.value.object.get("output") orelse
                return common.AIError.InvalidResponse;

            if (output.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            // Find text content in output items
            var text_content: std.ArrayList(u8) = .empty;
            defer text_content.deinit(self.allocator);

            for (output.array.items) |item| {
                const item_type_str = ((item.object.get("type")) orelse continue).string;
                const item_type = common.OutputItemType.fromString(item_type_str);
                if (item_type == .message) {
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
                // Server-side tool calls and other types: skip
            }

            if (text_content.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            // Parse citations
            const citations = try self.parseCitations(parsed.value);
            const inline_citations = try self.parseInlineCitations(output);

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
                    .provider = try self.allocator.dupe(u8, "grok"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .stop_reason = if (parsed.value.object.get("status")) |status|
                        try self.allocator.dupe(u8, status.string)
                    else
                        null,
                    .allocator = self.allocator,
                },
                .citations = citations,
                .inline_citations = inline_citations,
                .allocator = self.allocator,
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    /// Send a message with tools using the Responses API
    /// Uses structured input items and function_call/function_call_output format
    fn sendMessageWithTools(
        self: *GrokClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = Timer.start(self.http_client.io());

        // Build structured input for Responses API
        var input_json: std.ArrayList(u8) = .empty;
        defer input_json.deinit(self.allocator);

        try input_json.appendSlice(self.allocator, "[");
        var first = true;

        // System prompt as first input item (xAI does NOT support `instructions`)
        if (config.system_prompt) |system| {
            const escaped_sys = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped_sys);
            const sys_item = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}}
            , .{escaped_sys});
            defer self.allocator.free(sys_item);
            try input_json.appendSlice(self.allocator, sys_item);
            first = false;
        }

        if (context.len == 0) {
            // First turn: add user message (with optional file attachments)
            if (!first) try input_json.appendSlice(self.allocator, ",");
            try self.appendUserMessage(&input_json, prompt, config);
        } else {
            // Multi-turn: structured input array with conversation history
            for (context) |msg| {
                try self.appendResponsesApiItem(&input_json, msg, &first);
            }
            if (prompt.len > 0) {
                if (!first) try input_json.appendSlice(self.allocator, ",");
                try self.appendUserMessage(&input_json, prompt, config);
            }
        }

        try input_json.appendSlice(self.allocator, "]");

        // Build tools JSON array (Responses API format)
        // Server-side tools: {"type":"web_search"}, {"type":"x_search"}, {"type":"code_interpreter"}
        // Client-side tools: {"type":"function","name":"...","description":"...","parameters":{...}}
        var tools_json: std.ArrayList(u8) = .empty;
        defer tools_json.deinit(self.allocator);
        try tools_json.appendSlice(self.allocator, "[");
        var tool_count: usize = 0;

        // Server-side tools (auto-executed by xAI)
        if (config.server_tools) |server_tools| {
            for (server_tools) |st| {
                if (tool_count > 0) try tools_json.appendSlice(self.allocator, ",");
                const st_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"{s}"}}
                , .{st.toJsonType()});
                defer self.allocator.free(st_json);
                try tools_json.appendSlice(self.allocator, st_json);
                tool_count += 1;
            }
        }

        // Client-side function tools (require local execution)
        if (config.tools) |tool_defs| {
            for (tool_defs) |tool| {
                if (tool_count > 0) try tools_json.appendSlice(self.allocator, ",");
                const escaped_name = try common.escapeJsonString(self.allocator, tool.name);
                defer self.allocator.free(escaped_name);
                const escaped_desc = try common.escapeJsonString(self.allocator, tool.description);
                defer self.allocator.free(escaped_desc);
                const tool_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"function","name":"{s}","description":"{s}","parameters":{s}}}
                , .{ escaped_name, escaped_desc, tool.input_schema });
                defer self.allocator.free(tool_json);
                try tools_json.appendSlice(self.allocator, tool_json);
                tool_count += 1;
            }
        }

        // Remote MCP tools (xAI connects to external MCP servers)
        if (config.mcp_tools) |mcp_tools| {
            for (mcp_tools) |mcp| {
                if (tool_count > 0) try tools_json.appendSlice(self.allocator, ",");

                // Build MCP tool JSON with required server_url and optional fields
                var mcp_json: std.ArrayList(u8) = .empty;
                defer mcp_json.deinit(self.allocator);

                const escaped_url = try common.escapeJsonString(self.allocator, mcp.server_url);
                defer self.allocator.free(escaped_url);
                const base = try std.fmt.allocPrint(self.allocator,
                    \\{{"type":"mcp","server_url":"{s}"
                , .{escaped_url});
                defer self.allocator.free(base);
                try mcp_json.appendSlice(self.allocator, base);

                if (mcp.server_label) |label| {
                    const escaped = try common.escapeJsonString(self.allocator, label);
                    defer self.allocator.free(escaped);
                    const part = try std.fmt.allocPrint(self.allocator,
                        \\,"server_label":"{s}"
                    , .{escaped});
                    defer self.allocator.free(part);
                    try mcp_json.appendSlice(self.allocator, part);
                }

                if (mcp.server_description) |desc| {
                    const escaped = try common.escapeJsonString(self.allocator, desc);
                    defer self.allocator.free(escaped);
                    const part = try std.fmt.allocPrint(self.allocator,
                        \\,"server_description":"{s}"
                    , .{escaped});
                    defer self.allocator.free(part);
                    try mcp_json.appendSlice(self.allocator, part);
                }

                if (mcp.authorization) |auth| {
                    const escaped = try common.escapeJsonString(self.allocator, auth);
                    defer self.allocator.free(escaped);
                    const part = try std.fmt.allocPrint(self.allocator,
                        \\,"authorization":"{s}"
                    , .{escaped});
                    defer self.allocator.free(part);
                    try mcp_json.appendSlice(self.allocator, part);
                }

                if (mcp.allowed_tool_names) |names| {
                    try mcp_json.appendSlice(self.allocator, ",\"allowed_tool_names\":[");
                    for (names, 0..) |name, ni| {
                        if (ni > 0) try mcp_json.appendSlice(self.allocator, ",");
                        const escaped = try common.escapeJsonString(self.allocator, name);
                        defer self.allocator.free(escaped);
                        const part = try std.fmt.allocPrint(self.allocator,
                            \\"{s}"
                        , .{escaped});
                        defer self.allocator.free(part);
                        try mcp_json.appendSlice(self.allocator, part);
                    }
                    try mcp_json.appendSlice(self.allocator, "]");
                }

                try mcp_json.appendSlice(self.allocator, "}");
                try tools_json.appendSlice(self.allocator, mcp_json.items);
                tool_count += 1;
            }
        }

        // Collections search (file_search) tool
        if (config.collection_ids) |col_ids| {
            if (col_ids.len > 0) {
                if (tool_count > 0) try tools_json.appendSlice(self.allocator, ",");
                try tools_json.appendSlice(self.allocator, "{\"type\":\"file_search\",\"vector_store_ids\":[");
                for (col_ids, 0..) |cid, ci| {
                    if (ci > 0) try tools_json.appendSlice(self.allocator, ",");
                    try tools_json.appendSlice(self.allocator, "\"");
                    const escaped_cid = try common.escapeJsonString(self.allocator, cid);
                    defer self.allocator.free(escaped_cid);
                    try tools_json.appendSlice(self.allocator, escaped_cid);
                    try tools_json.appendSlice(self.allocator, "\"");
                }
                try tools_json.appendSlice(self.allocator, "]");
                if (config.collection_max_results != 10) {
                    const mr = try std.fmt.allocPrint(self.allocator, ",\"max_num_results\":{d}", .{config.collection_max_results});
                    defer self.allocator.free(mr);
                    try tools_json.appendSlice(self.allocator, mr);
                }
                try tools_json.appendSlice(self.allocator, "}");
                tool_count += 1;
            }
        }

        try tools_json.appendSlice(self.allocator, "]");

        // Build optional payload parameters
        var optional_parts: std.ArrayList(u8) = .empty;
        defer optional_parts.deinit(self.allocator);

        // Conversation chaining via previous_response_id
        if (config.previous_response_id) |prev_id| {
            const prev_part = try std.fmt.allocPrint(self.allocator,
                \\,"previous_response_id":"{s}"
            , .{prev_id});
            defer self.allocator.free(prev_part);
            try optional_parts.appendSlice(self.allocator, prev_part);
        }

        // Store conversations server-side for multi-turn
        if (config.store) |store| {
            if (store) {
                try optional_parts.appendSlice(self.allocator, ",\"store\":true");
            } else {
                try optional_parts.appendSlice(self.allocator, ",\"store\":false");
            }
        }

        // Limit server-side agentic loop turns
        if (config.server_max_turns) |smt| {
            const smt_part = try std.fmt.allocPrint(self.allocator,
                \\,"max_turns":{d}
            , .{smt});
            defer self.allocator.free(smt_part);
            try optional_parts.appendSlice(self.allocator, smt_part);
        }

        // Tool choice control
        if (config.tool_choice) |tc| {
            if (tc == .function) {
                if (config.tool_choice_function) |func_name| {
                    const escaped_fn = try common.escapeJsonString(self.allocator, func_name);
                    defer self.allocator.free(escaped_fn);
                    const tc_part = try std.fmt.allocPrint(self.allocator,
                        \\,"tool_choice":{{"type":"function","name":"{s}"}}
                    , .{escaped_fn});
                    defer self.allocator.free(tc_part);
                    try optional_parts.appendSlice(self.allocator, tc_part);
                }
            } else {
                const tc_part = try std.fmt.allocPrint(self.allocator,
                    \\,"tool_choice":{s}
                , .{tc.toJsonValue()});
                defer self.allocator.free(tc_part);
                try optional_parts.appendSlice(self.allocator, tc_part);
            }
        }

        // Parallel tool calls control
        if (config.parallel_tool_calls) |ptc| {
            if (ptc) {
                try optional_parts.appendSlice(self.allocator, ",\"parallel_tool_calls\":true");
            } else {
                try optional_parts.appendSlice(self.allocator, ",\"parallel_tool_calls\":false");
            }
        }

        // Include additional response data (e.g., inline_citations, tool outputs)
        const include_json = try self.buildIncludeParam(config);
        defer if (include_json) |ij| self.allocator.free(ij);
        if (include_json) |ij| {
            try optional_parts.appendSlice(self.allocator, ij);
        }

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","input":{s},"tools":{s},"temperature":{d},"max_output_tokens":{}{s}}}
        , .{
            config.model,
            input_json.items,
            tools_json.items,
            config.temperature,
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

        // Extract output items — classify by OutputItemType:
        // - "message": text response with output_text content
        // - "function_call": client-side tool call (requires local execution)
        // - "web_search_call", "x_search_call", etc.: server-side (auto-executed by xAI, skip)
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
            const item_type_str = (item.object.get("type") orelse continue).string;
            const item_type = common.OutputItemType.fromString(item_type_str);

            switch (item_type) {
                .message => {
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
                },
                .function_call => {
                    // Client-side tool call — requires local execution
                    const call_id = (item.object.get("call_id") orelse continue).string;
                    const fn_name = (item.object.get("name") orelse continue).string;
                    const fn_args = (item.object.get("arguments") orelse continue).string;

                    try tool_calls_list.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, call_id),
                        .name = try self.allocator.dupe(u8, fn_name),
                        .arguments = try self.allocator.dupe(u8, fn_args),
                        .allocator = self.allocator,
                    });
                },
                .web_search_call, .x_search_call, .code_interpreter_call, .file_search_call, .mcp_call => {
                    // Server-side tool calls — auto-executed by xAI, no client action needed
                    continue;
                },
                .unknown => continue,
            }
        }

        // Parse citations
        const citations = try self.parseCitations(parsed.value);
        const inline_citations = try self.parseInlineCitations(output);

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
                .provider = try self.allocator.dupe(u8, "grok"),
                .turns_used = 1,
                .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                .stop_reason = if (parsed.value.object.get("status")) |status|
                    try self.allocator.dupe(u8, status.string)
                else
                    null,
                .allocator = self.allocator,
            },
            .citations = citations,
            .inline_citations = inline_citations,
            .allocator = self.allocator,
        };
    }

    fn buildRequestPayload(
        self: *GrokClient,
        input: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        // Build optional parameters
        var optional_parts: std.ArrayList(u8) = .empty;
        defer optional_parts.deinit(self.allocator);

        // Add previous_response_id for conversation chaining
        if (config.previous_response_id) |prev_id| {
            const prev_part = try std.fmt.allocPrint(self.allocator,
                \\,"previous_response_id":"{s}"
            , .{prev_id});
            defer self.allocator.free(prev_part);
            try optional_parts.appendSlice(self.allocator, prev_part);
        }

        // Store conversations server-side for multi-turn via previous_response_id
        if (config.store) |store| {
            if (store) {
                try optional_parts.appendSlice(self.allocator, ",\"store\":true");
            } else {
                try optional_parts.appendSlice(self.allocator, ",\"store\":false");
            }
        }

        // Limit server-side agentic loop turns
        if (config.server_max_turns) |smt| {
            const smt_part = try std.fmt.allocPrint(self.allocator,
                \\,"max_turns":{d}
            , .{smt});
            defer self.allocator.free(smt_part);
            try optional_parts.appendSlice(self.allocator, smt_part);
        }

        // Include additional response data (e.g., inline_citations, tool outputs)
        const include_json = try self.buildIncludeParam(config);
        defer if (include_json) |ij| self.allocator.free(ij);
        if (include_json) |ij| {
            try optional_parts.appendSlice(self.allocator, ij);
        }

        return std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","input":{s},"temperature":{d},"max_output_tokens":{}{s}}}
        , .{ config.model, input, config.temperature, config.max_tokens, optional_parts.items });
    }

    fn makeRequest(self: *GrokClient, payload: []const u8) ![]u8 {
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
        self: *GrokClient,
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

    /// Build a user message with optional file attachments and images
    /// Uses content array format when file_ids or images are present
    fn appendUserMessage(self: *GrokClient, writer: *std.ArrayList(u8), prompt: []const u8, config: common.RequestConfig) !void {
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        if (config.file_ids != null or config.images != null) {
            // Content array with text + file attachments + images
            try writer.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":[");

            // Text part
            const text_part = try std.fmt.allocPrint(self.allocator,
                \\{{"type":"input_text","text":"{s}"}}
            , .{escaped});
            defer self.allocator.free(text_part);
            try writer.appendSlice(self.allocator, text_part);

            // File attachment parts (triggers automatic attachment_search)
            if (config.file_ids) |fids| {
                for (fids) |fid| {
                    const escaped_fid = try common.escapeJsonString(self.allocator, fid);
                    defer self.allocator.free(escaped_fid);
                    const file_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"type":"input_file","file_id":"{s}"}}
                    , .{escaped_fid});
                    defer self.allocator.free(file_part);
                    try writer.appendSlice(self.allocator, file_part);
                }
            }

            // Image parts
            if (config.images) |images| {
                for (images) |img| {
                    const img_url = try img.toImageUrl(self.allocator);
                    defer self.allocator.free(img_url);
                    const img_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"type":"image_url","image_url":{{"url":"{s}"}}}}
                    , .{img_url});
                    defer self.allocator.free(img_part);
                    try writer.appendSlice(self.allocator, img_part);
                }
            }

            try writer.appendSlice(self.allocator, "]}");
        } else {
            // Simple text content
            const user_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","content":"{s}"}}
            , .{escaped});
            defer self.allocator.free(user_msg);
            try writer.appendSlice(self.allocator, user_msg);
        }
    }

    // ========================================
    // File Management API (xAI /v1/files)
    // ========================================

    /// Upload a file to xAI for use in chat conversations.
    /// Returns the file ID on success.
    pub fn uploadFile(self: *GrokClient, file_data: []const u8, filename: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/files", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        // Build multipart/form-data body
        const boundary = "----ZigAIFileBoundary9f2e3d";
        const content_type = "multipart/form-data; boundary=" ++ boundary;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        // Part 1: purpose field
        try body.appendSlice(self.allocator, "--" ++ boundary ++ "\r\n");
        try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n");
        try body.appendSlice(self.allocator, "assistants\r\n");

        // Part 2: file field
        try body.appendSlice(self.allocator, "--" ++ boundary ++ "\r\n");
        const file_header = try std.fmt.allocPrint(self.allocator,
            "Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
            .{filename},
        );
        defer self.allocator.free(file_header);
        try body.appendSlice(self.allocator, file_header);
        try body.appendSlice(self.allocator, file_data);
        try body.appendSlice(self.allocator, "\r\n");

        // Closing boundary
        try body.appendSlice(self.allocator, "--" ++ boundary ++ "--\r\n");

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.post(endpoint, &headers, body.items);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        // Parse file ID from response
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (parsed.value.object.get("id")) |id_val| {
            if (id_val == .string) {
                return try self.allocator.dupe(u8, id_val.string);
            }
        }

        return common.AIError.ApiRequestFailed;
    }

    /// List uploaded files
    pub fn listFiles(self: *GrokClient) ![]u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/files", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.get(endpoint, &headers);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    /// Delete a file by ID
    pub fn deleteFile(self: *GrokClient, file_id: []const u8) !void {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/files/{s}", .{ self.base_url, file_id });
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.delete(endpoint, &headers);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }
    }

    /// Append a simple input item (user/assistant text) for the text-only path
    fn appendInputItem(self: *GrokClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
        const role = msg.role.toString();
        const escaped = try common.escapeJsonString(self.allocator, msg.content);
        defer self.allocator.free(escaped);

        const msg_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"{s}","content":"{s}"}}
        , .{ role, escaped });
        defer self.allocator.free(msg_json);
        try writer.appendSlice(self.allocator, msg_json);
    }

    /// Map an AIMessage to Responses API input item format for tool calling
    /// function_call items for tool calls, function_call_output for results
    fn appendResponsesApiItem(
        self: *GrokClient,
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

    /// Build the `"include":[...]` JSON parameter for the request payload
    fn buildIncludeParam(self: *GrokClient, config: common.RequestConfig) !?[]u8 {
        const includes = config.include orelse return null;
        if (includes.len == 0) return null;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, ",\"include\":[");
        for (includes, 0..) |inc, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "\"");
            try buf.appendSlice(self.allocator, inc);
            try buf.appendSlice(self.allocator, "\"");
        }
        try buf.appendSlice(self.allocator, "]");

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Parse top-level `citations` array (list of source URLs) from Responses API
    fn parseCitations(self: *GrokClient, parsed: std.json.Value) !?[][]const u8 {
        const citations_val = parsed.object.get("citations") orelse return null;
        if (citations_val != .array) return null;
        if (citations_val.array.items.len == 0) return null;

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |url| self.allocator.free(url);
            list.deinit(self.allocator);
        }

        for (citations_val.array.items) |item| {
            if (item == .string) {
                try list.append(self.allocator, try self.allocator.dupe(u8, item.string));
            }
        }

        if (list.items.len == 0) {
            list.deinit(self.allocator);
            return null;
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// Parse inline citation annotations from output_text content blocks
    fn parseInlineCitations(
        self: *GrokClient,
        output: std.json.Value,
    ) !?[]common.InlineCitation {
        var list: std.ArrayList(common.InlineCitation) = .empty;
        errdefer {
            for (list.items) |*ic| @constCast(ic).deinit();
            list.deinit(self.allocator);
        }

        for (output.array.items) |item| {
            const item_type_str = ((item.object.get("type")) orelse continue).string;
            if (!std.mem.eql(u8, item_type_str, "message")) continue;

            const content_arr = item.object.get("content") orelse continue;
            for (content_arr.array.items) |content_item| {
                const ct = (content_item.object.get("type") orelse continue).string;
                if (!std.mem.eql(u8, ct, "output_text")) continue;

                // Parse annotations array on output_text items
                const annotations = content_item.object.get("annotations") orelse continue;
                if (annotations != .array) continue;

                for (annotations.array.items) |ann| {
                    if (ann != .object) continue;
                    const ann_type = (ann.object.get("type") orelse continue).string;
                    if (!std.mem.eql(u8, ann_type, "url_citation")) continue;

                    const url = (ann.object.get("url") orelse continue).string;
                    const title = if (ann.object.get("title")) |t|
                        (if (t == .string) t.string else "")
                    else
                        "";
                    const start_idx: u32 = if (ann.object.get("start_index")) |si|
                        (if (si == .integer) @intCast(si.integer) else 0)
                    else
                        0;
                    const end_idx: u32 = if (ann.object.get("end_index")) |ei|
                        (if (ei == .integer) @intCast(ei.integer) else 0)
                    else
                        0;

                    try list.append(self.allocator, .{
                        .url = try self.allocator.dupe(u8, url),
                        .title = try self.allocator.dupe(u8, title),
                        .start_index = start_idx,
                        .end_index = end_idx,
                        .allocator = self.allocator,
                    });
                }
            }
        }

        if (list.items.len == 0) {
            list.deinit(self.allocator);
            return null;
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// Helper: Create default config for Grok (fast, non-reasoning)
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.FAST,
            .max_tokens = 65536,
            .temperature = 0.7,
        };
    }

    /// Helper: Create config for Grok reasoning model
    pub fn reasoningConfig() common.RequestConfig {
        return .{
            .model = Models.REASONING,
            .max_tokens = 65536,
            .temperature = 0.7,
        };
    }

    /// Helper: Create config for deep code analysis (alias for reasoningConfig)
    pub fn deepConfig() common.RequestConfig {
        return reasoningConfig();
    }
};

test "GrokClient initialization" {
    const allocator = std.testing.allocator;

    var client = try GrokClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "GrokClient config helpers" {
    const default_cfg = GrokClient.defaultConfig();
    try std.testing.expectEqualStrings(GrokClient.Models.FAST, default_cfg.model);

    const reasoning_cfg = GrokClient.reasoningConfig();
    try std.testing.expectEqualStrings(GrokClient.Models.REASONING, reasoning_cfg.model);

    const deep_cfg = GrokClient.deepConfig();
    try std.testing.expectEqualStrings(GrokClient.Models.REASONING, deep_cfg.model);
}
