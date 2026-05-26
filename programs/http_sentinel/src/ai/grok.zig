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
        if (config.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("system");
            try jw.objectField("content");
            try jw.write(system);
            try jw.endObject();
        }
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("user");
        try jw.objectField("content");
        try jw.write(prompt);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();

        // Make streaming request
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, aw.written());
        defer stream.deinit();

        if (@intFromEnum(stream.status) >= 400) {
            self.http_client.captureError(stream.body);
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

        if (config.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("system");
            try jw.objectField("content");
            try jw.write(system);
            try jw.endObject();
        }

        for (history) |msg| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(msg.role.toString());
            try jw.objectField("content");
            try jw.write(msg.content);
            try jw.endObject();
        }

        if (prompt.len > 0) {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.write(prompt);
            try jw.endObject();
        }

        try jw.endArray();
        try jw.endObject();

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{self.base_url});
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, aw.written());
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

        // 128 KB — response.completed events for the xAI Responses API can
        // include the full response shell + usage and easily exceed 16 KB.
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
        self: *GrokClient,
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
        if (config.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("system");
            try jw.objectField("content");
            try jw.write(system);
            try jw.endObject();
        }
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

        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);
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

        // Build the `input` array (Responses API) via streaming Stringify.
        var input_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer input_aw.deinit();
        var input_jw: std.json.Stringify = .{ .writer = &input_aw.writer, .options = .{} };

        try input_jw.beginArray();

        if (config.system_prompt) |system| {
            try input_jw.beginObject();
            try input_jw.objectField("role");
            try input_jw.write("system");
            try input_jw.objectField("content");
            try input_jw.write(system);
            try input_jw.endObject();
        }

        for (context) |msg| try self.writeInputItem(&input_jw, msg);

        if (config.images != null or config.file_ids != null) {
            try input_jw.beginObject();
            try input_jw.objectField("role");
            try input_jw.write("user");
            try input_jw.objectField("content");
            try input_jw.beginArray();
            try input_jw.beginObject();
            try input_jw.objectField("type");
            try input_jw.write("input_text");
            try input_jw.objectField("text");
            try input_jw.write(prompt);
            try input_jw.endObject();
            if (config.images) |images| {
                for (images) |img| {
                    const img_url = try img.toImageUrl(self.allocator);
                    defer self.allocator.free(img_url);
                    try input_jw.beginObject();
                    try input_jw.objectField("type");
                    try input_jw.write("image_url");
                    try input_jw.objectField("image_url");
                    try input_jw.beginObject();
                    try input_jw.objectField("url");
                    try input_jw.write(img_url);
                    try input_jw.endObject();
                    try input_jw.endObject();
                }
            }
            if (config.file_ids) |fids| {
                for (fids) |fid| {
                    try input_jw.beginObject();
                    try input_jw.objectField("type");
                    try input_jw.write("input_file");
                    try input_jw.objectField("file_id");
                    try input_jw.write(fid);
                    try input_jw.endObject();
                }
            }
            try input_jw.endArray();
            try input_jw.endObject();
        } else {
            try input_jw.beginObject();
            try input_jw.objectField("role");
            try input_jw.write("user");
            try input_jw.objectField("content");
            try input_jw.write(prompt);
            try input_jw.endObject();
        }

        try input_jw.endArray();
        const input_json = input_aw.written();

        var turn_count: u32 = 0;
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(input_json, config);
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

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);

        // input array
        try jw.objectField("input");
        try jw.beginArray();
        if (config.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("system");
            try jw.objectField("content");
            try jw.write(system);
            try jw.endObject();
        }
        if (context.len == 0) {
            try self.writeUserMessage(&jw, prompt, config);
        } else {
            for (context) |msg| try self.writeResponsesApiItem(&jw, msg);
            if (prompt.len > 0) try self.writeUserMessage(&jw, prompt, config);
        }
        try jw.endArray();

        // tools array
        try jw.objectField("tools");
        try jw.beginArray();
        if (config.server_tools) |server_tools| {
            for (server_tools) |st| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write(st.toJsonType());
                try jw.endObject();
            }
        }
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
        if (config.mcp_tools) |mcp_tools| {
            for (mcp_tools) |mcp| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("mcp");
                try jw.objectField("server_url");
                try jw.write(mcp.server_url);
                if (mcp.server_label) |label| {
                    try jw.objectField("server_label");
                    try jw.write(label);
                }
                if (mcp.server_description) |desc| {
                    try jw.objectField("server_description");
                    try jw.write(desc);
                }
                if (mcp.authorization) |auth| {
                    try jw.objectField("authorization");
                    try jw.write(auth);
                }
                if (mcp.allowed_tool_names) |names| {
                    try jw.objectField("allowed_tool_names");
                    try jw.beginArray();
                    for (names) |name| try jw.write(name);
                    try jw.endArray();
                }
                try jw.endObject();
            }
        }
        if (config.collection_ids) |col_ids| {
            if (col_ids.len > 0) {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("file_search");
                try jw.objectField("vector_store_ids");
                try jw.beginArray();
                for (col_ids) |cid| try jw.write(cid);
                try jw.endArray();
                if (config.collection_max_results != 10) {
                    try jw.objectField("max_num_results");
                    try jw.write(config.collection_max_results);
                }
                try jw.endObject();
            }
        }
        try jw.endArray();

        // scalar / structural params
        try jw.objectField("temperature");
        try jw.write(config.temperature);
        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);

        if (config.previous_response_id) |prev_id| {
            try jw.objectField("previous_response_id");
            try jw.write(prev_id);
        }
        if (config.store) |store| {
            try jw.objectField("store");
            try jw.write(store);
        }
        if (config.server_max_turns) |smt| {
            try jw.objectField("max_turns");
            try jw.write(smt);
        }
        if (config.tool_choice) |tc| {
            if (tc == .function) {
                if (config.tool_choice_function) |func_name| {
                    try jw.objectField("tool_choice");
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("function");
                    try jw.objectField("name");
                    try jw.write(func_name);
                    try jw.endObject();
                }
            } else {
                // tc.toJsonValue() returns a JSON literal ("auto" / "none"
                // / "required"); splice raw.
                try jw.objectField("tool_choice");
                try jw.beginWriteRaw();
                try aw.writer.writeAll(tc.toJsonValue());
                jw.endWriteRaw();
            }
        }
        if (config.parallel_tool_calls) |ptc| {
            try jw.objectField("parallel_tool_calls");
            try jw.write(ptc);
        }
        if (config.include) |includes| {
            if (includes.len > 0) {
                try jw.objectField("include");
                try jw.beginArray();
                for (includes) |inc| try jw.write(inc);
                try jw.endArray();
            }
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
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(config.model);
        try jw.objectField("input");
        // `input` is already a serialised JSON array — splice raw.
        try jw.beginWriteRaw();
        try aw.writer.writeAll(input);
        jw.endWriteRaw();
        try jw.objectField("temperature");
        try jw.write(config.temperature);
        try jw.objectField("max_output_tokens");
        try jw.write(config.max_tokens);

        if (config.previous_response_id) |prev_id| {
            try jw.objectField("previous_response_id");
            try jw.write(prev_id);
        }
        if (config.store) |store| {
            try jw.objectField("store");
            try jw.write(store);
        }
        if (config.server_max_turns) |smt| {
            try jw.objectField("max_turns");
            try jw.write(smt);
        }
        if (config.include) |includes| {
            if (includes.len > 0) {
                try jw.objectField("include");
                try jw.beginArray();
                for (includes) |inc| try jw.write(inc);
                try jw.endArray();
            }
        }

        try jw.endObject();
        return aw.toOwnedSlice();
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
    /// Write a "user" input item (with optional multimodal content) via the
    /// supplied Stringify writer. The writer must already be inside an
    /// array context.
    fn writeUserMessage(self: *GrokClient, jw: *std.json.Stringify, prompt: []const u8, config: common.RequestConfig) !void {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("user");
        try jw.objectField("content");

        if (config.file_ids != null or config.images != null) {
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_text");
            try jw.objectField("text");
            try jw.write(prompt);
            try jw.endObject();

            if (config.file_ids) |fids| {
                for (fids) |fid| {
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("input_file");
                    try jw.objectField("file_id");
                    try jw.write(fid);
                    try jw.endObject();
                }
            }
            if (config.images) |images| {
                for (images) |img| {
                    const img_url = try img.toImageUrl(self.allocator);
                    defer self.allocator.free(img_url);
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("image_url");
                    try jw.objectField("image_url");
                    try jw.beginObject();
                    try jw.objectField("url");
                    try jw.write(img_url);
                    try jw.endObject();
                    try jw.endObject();
                }
            }
            try jw.endArray();
        } else {
            try jw.write(prompt);
        }

        try jw.endObject();
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
    /// Write a single role+content input item via the supplied Stringify
    /// writer. The writer must already be inside an array context.
    fn writeInputItem(self: *GrokClient, jw: *std.json.Stringify, msg: common.AIMessage) !void {
        _ = self;
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(msg.role.toString());
        try jw.objectField("content");
        try jw.write(msg.content);
        try jw.endObject();
    }

    /// Map an AIMessage to Responses API input item format for tool calling
    /// function_call items for tool calls, function_call_output for results
    /// Write one Responses API input item via the supplied
    /// std.json.Stringify writer. The writer must already be inside an
    /// array context — Stringify manages array commas itself.
    fn writeResponsesApiItem(
        self: *GrokClient,
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
