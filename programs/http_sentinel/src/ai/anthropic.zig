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

        // Add current prompt if non-empty (empty means caller manages all messages via context).
        // The prompt JSON is emitted via std.json.Stringify and then re-parsed back into a
        // std.json.Value so downstream code can keep handling messages as a uniform tree.
        if (prompt.len > 0) {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");

            if (config.images) |images| {
                try jw.beginArray();
                // Text part
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(prompt);
                try jw.endObject();
                // Image parts
                for (images) |img| {
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("image");
                    try jw.objectField("source");
                    try jw.beginObject();
                    if (img.isUrl()) {
                        try jw.objectField("type");
                        try jw.write("url");
                        try jw.objectField("url");
                        try jw.write(img.url.?);
                    } else {
                        try jw.objectField("type");
                        try jw.write("base64");
                        try jw.objectField("media_type");
                        try jw.write(img.media_type);
                        try jw.objectField("data");
                        try jw.write(img.data);
                    }
                    try jw.endObject();
                    try jw.endObject();
                }
                try jw.endArray();
            } else {
                try jw.write(prompt);
            }

            try jw.endObject();

            const prompt_json = aw.written();
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
        // Every field is written through std.json.Stringify — no
        // hand-rolled escaping, no allocPrint string interpolation.
        // The `input_schema` field of each tool is already a JSON value
        // as supplied by the caller; we emit it via beginWriteRaw so it
        // lands in the payload as an object, not as a quoted string.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(config.model);

        try jw.objectField("max_tokens");
        try jw.write(config.max_tokens);

        if (config.system_prompt) |system| {
            try jw.objectField("system");
            try jw.write(system);
        }

        try jw.objectField("temperature");
        try jw.write(config.temperature);

        if (config.tools) |tools| {
            try jw.objectField("tools");
            try jw.beginArray();
            for (tools) |tool| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("description");
                try jw.write(tool.description);
                try jw.objectField("input_schema");
                try jw.beginWriteRaw();
                try aw.writer.writeAll(tool.input_schema);
                jw.endWriteRaw();
                try jw.endObject();
            }
            try jw.endArray();
        }

        try jw.objectField("messages");
        try jw.write(messages);

        try jw.endObject();

        return aw.toOwnedSlice();
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

    /// Send a streaming message (single prompt, no history).
    /// For multi-turn conversations, use sendMessageStreamingWithContext.
    pub fn sendMessageStreaming(
        self: *AnthropicClient,
        prompt: []const u8,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        return self.sendMessageStreamingWithContext(prompt, &[_]common.AIMessage{}, config, callback, cb_context);
    }

    /// Send a streaming message with full conversation history.
    /// True incremental SSE — first token in milliseconds.
    /// Request stays on the stack (TLS pointers valid).
    pub fn sendMessageStreamingWithContext(
        self: *AnthropicClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        // Build messages array from context + prompt (reuses existing logic)
        var messages: std.ArrayList(std.json.Value) = .empty;
        defer messages.deinit(self.allocator);

        var parsed_objects: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_objects.items) |*parsed| parsed.deinit();
            parsed_objects.deinit(self.allocator);
        }

        // Add conversation history
        for (context) |msg| {
            const parsed = try self.buildMessageJson(msg);
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        // Add current prompt — emitted via std.json.Stringify, then
        // re-parsed back into std.json.Value so it joins the message
        // tree shape.
        if (prompt.len > 0) {
            const prompt_json = try std.json.Stringify.valueAlloc(self.allocator, .{
                .role = "user",
                .content = prompt,
            }, .{});
            defer self.allocator.free(prompt_json);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, prompt_json, .{});
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        // Build payload using existing method (handles model, max_tokens, system, tools, messages)
        var base_payload = try self.buildRequestPayload(messages.items, config);
        defer self.allocator.free(base_payload);

        // Inject "stream":true into the payload (before the closing })
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        // Remove trailing }
        if (base_payload.len > 0 and base_payload[base_payload.len - 1] == '}') {
            try payload.appendSlice(self.allocator, base_payload[0 .. base_payload.len - 1]);
            try payload.appendSlice(self.allocator, ",\"stream\":true}");
        } else {
            try payload.appendSlice(self.allocator, base_payload);
        }

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.base_url});
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = DEFAULT_ANTHROPIC_VERSION },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        var sse_ctx = SseCtx{
            .allocator = self.allocator,
            .user_callback = callback,
            .user_context = cb_context,
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

    /// Tool-aware streaming context — emits structured events (text deltas,
    /// tool_use start/delta/stop, message_stop) so callers can drive an
    /// agent loop without buffering the whole response.
    const EventCtx = struct {
        user_callback: common.StreamEventCallback,
        user_context: ?*anyopaque,
        /// Block kind tracked per index so `content_block_stop` can be
        /// dispatched correctly. `is_tool[i]` is true iff content block `i`
        /// was started as a `tool_use` block.
        is_tool: [64]bool = @splat(false),
    };

    fn eventStreamHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
        const ctx: *EventCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
        if (event.done) return false;

        // Use a temporary GPA for the per-event JSON parse; nothing here
        // outlives this function call so we can leak the GPA on early-return
        // — but we don't, we always deinit.
        var arena_buf: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        const a = fba.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, a, event.data, .{}) catch return true;
        defer parsed.deinit();

        const obj = parsed.value.object;
        const event_type_v = obj.get("type") orelse return true;
        if (event_type_v != .string) return true;
        const event_type = event_type_v.string;

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const idx = readIndex(obj) orelse return true;
            const block = obj.get("content_block") orelse return true;
            if (block != .object) return true;
            const block_type_v = block.object.get("type") orelse return true;
            if (block_type_v != .string) return true;

            if (std.mem.eql(u8, block_type_v.string, "tool_use")) {
                if (idx < ctx.is_tool.len) ctx.is_tool[idx] = true;
                const id_v = block.object.get("id") orelse return true;
                const name_v = block.object.get("name") orelse return true;
                if (id_v != .string or name_v != .string) return true;

                return ctx.user_callback(.{ .tool_use_start = .{
                    .index = idx,
                    .id = id_v.string,
                    .name = name_v.string,
                } }, ctx.user_context);
            }
            // text block — no event needed; deltas will arrive next.
            return true;
        }

        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const idx = readIndex(obj) orelse return true;
            const delta = obj.get("delta") orelse return true;
            if (delta != .object) return true;
            const dtype_v = delta.object.get("type") orelse return true;
            if (dtype_v != .string) return true;

            if (std.mem.eql(u8, dtype_v.string, "text_delta")) {
                const text_v = delta.object.get("text") orelse return true;
                if (text_v != .string) return true;
                return ctx.user_callback(.{ .text_delta = .{
                    .index = idx,
                    .text = text_v.string,
                } }, ctx.user_context);
            } else if (std.mem.eql(u8, dtype_v.string, "input_json_delta")) {
                const pj_v = delta.object.get("partial_json") orelse return true;
                if (pj_v != .string) return true;
                return ctx.user_callback(.{ .tool_input_delta = .{
                    .index = idx,
                    .partial_json = pj_v.string,
                } }, ctx.user_context);
            }
            return true;
        }

        if (std.mem.eql(u8, event_type, "content_block_stop")) {
            const idx = readIndex(obj) orelse return true;
            return ctx.user_callback(.{ .block_stop = .{ .index = idx } }, ctx.user_context);
        }

        if (std.mem.eql(u8, event_type, "message_delta")) {
            // Carries final stop_reason on the delta object + final usage.
            const delta = obj.get("delta") orelse return true;
            if (delta != .object) return true;
            const sr_v = delta.object.get("stop_reason") orelse return true;
            if (sr_v != .string) return true;
            const in_t = readU32Field(obj, "usage", "input_tokens") orelse 0;
            const out_t = readU32Field(obj, "usage", "output_tokens") orelse 0;
            return ctx.user_callback(.{ .message_stop = .{
                .stop_reason = sr_v.string,
                .input_tokens = in_t,
                .output_tokens = out_t,
            } }, ctx.user_context);
        }

        if (std.mem.eql(u8, event_type, "message_stop")) {
            return ctx.user_callback(.{ .message_stop = .{ .stop_reason = null } }, ctx.user_context);
        }

        return true;
    }

    fn readIndex(obj: std.json.ObjectMap) ?u32 {
        const v = obj.get("index") orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            else => null,
        };
    }

    fn readU32Field(obj: std.json.ObjectMap, parent_key: []const u8, child_key: []const u8) ?u32 {
        const parent = obj.get(parent_key) orelse return null;
        if (parent != .object) return null;
        const v = parent.object.get(child_key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            else => null,
        };
    }

    /// Tool-aware streaming with full conversation history.
    /// The richer `StreamEventCallback` lets callers drive an agent loop:
    /// text deltas, tool_use start, tool argument JSON deltas, block stops,
    /// and message stop arrive as structured events. Slices inside events
    /// are transient — dupe to keep them.
    pub fn sendMessageStreamingWithEvents(
        self: *AnthropicClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var messages: std.ArrayList(std.json.Value) = .empty;
        defer messages.deinit(self.allocator);

        var parsed_objects: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        defer {
            for (parsed_objects.items) |*p| p.deinit();
            parsed_objects.deinit(self.allocator);
        }

        for (context) |msg| {
            const parsed = try self.buildMessageJson(msg);
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        if (prompt.len > 0) {
            const prompt_json = try std.json.Stringify.valueAlloc(self.allocator, .{
                .role = "user",
                .content = prompt,
            }, .{});
            defer self.allocator.free(prompt_json);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, prompt_json, .{});
            try parsed_objects.append(self.allocator, parsed);
            try messages.append(self.allocator, parsed.value);
        }

        var base_payload = try self.buildRequestPayload(messages.items, config);
        defer self.allocator.free(base_payload);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        if (base_payload.len > 0 and base_payload[base_payload.len - 1] == '}') {
            try payload.appendSlice(self.allocator, base_payload[0 .. base_payload.len - 1]);
            try payload.appendSlice(self.allocator, ",\"stream\":true}");
        } else {
            try payload.appendSlice(self.allocator, base_payload);
        }

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.base_url});
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = DEFAULT_ANTHROPIC_VERSION },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        var ctx = EventCtx{
            .user_callback = callback,
            .user_context = cb_context,
        };

        const status = try self.http_client.postSseStream(
            endpoint,
            &headers,
            payload.items,
            eventStreamHandler,
            &ctx,
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
        // Emit the message via std.json.Stringify, then re-parse so the
        // caller gets a uniform std.json.Value back. tool_use `input`
        // is already a JSON object string; we splice it via
        // beginWriteRaw to avoid double-encoding.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        if (msg.tool_calls) |tool_calls| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("content");
            try jw.beginArray();

            if (msg.content.len > 0) {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(msg.content);
                try jw.endObject();
            }

            for (tool_calls) |call| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("tool_use");
                try jw.objectField("id");
                try jw.write(call.id);
                try jw.objectField("name");
                try jw.write(call.name);
                try jw.objectField("input");
                try jw.beginWriteRaw();
                try aw.writer.writeAll(call.arguments);
                jw.endWriteRaw();
                try jw.endObject();
            }

            try jw.endArray();
            try jw.endObject();
        } else if (msg.tool_results) |tool_results| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();

            for (tool_results) |result| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("tool_result");
                try jw.objectField("tool_use_id");
                try jw.write(result.tool_call_id);
                try jw.objectField("content");
                try jw.write(result.content);
                try jw.endObject();
            }

            try jw.endArray();
            try jw.endObject();
        } else {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(msg.role.toString());
            try jw.objectField("content");
            try jw.write(msg.content);
            try jw.endObject();
        }

        return try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            aw.written(),
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

// External anchor: Anthropic Messages API request schema.
//   https://docs.anthropic.com/en/api/messages
// The documented request body is a top-level object with REQUIRED `model`
// (string), `max_tokens` (integer), and `messages` (array of {role, content})
// fields, plus optional `system` and `temperature`. Neither the field names
// nor the shape below come from this codebase — they are Anthropic's published
// contract, so this is an external-anchored test, not a roundtrip. It pins
// buildRequestPayload's emitted JSON against that contract and proves the
// Stringify path is injection-safe for an adversarial model identifier.
test "buildRequestPayload matches documented Anthropic Messages API schema" {
    const allocator = std.testing.allocator;

    var client = try AnthropicClient.init(allocator, .{ .api_key = "k" });
    defer client.deinit();

    // A single user turn, shaped as the API's messages[] element.
    const user_msg = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"role\":\"user\",\"content\":\"hello\"}",
        .{},
    );
    defer user_msg.deinit();

    const payload = try client.buildRequestPayload(
        &[_]std.json.Value{user_msg.value},
        .{ .model = "claude-sonnet-4", .max_tokens = 1024, .temperature = 0.5 },
    );
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Required top-level fields, exact names and JSON types per the schema.
    try std.testing.expectEqualStrings("claude-sonnet-4", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1024), root.get("max_tokens").?.integer);
    const messages = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", messages.items[0].object.get("content").?.string);
}

// Injection-safety anchor for the same builder: a model identifier containing
// a `"` and a `\` (the exact bytes that broke the old allocPrint/hand-rolled
// JSON shapes — CLAUDE.md anti-pattern #1) must survive as data, never as
// JSON structure. If the payload still parses AND the model field decodes
// byte-for-byte, the Stringify escaping is doing its job.
test "buildRequestPayload escapes an adversarial model identifier" {
    const allocator = std.testing.allocator;

    var client = try AnthropicClient.init(allocator, .{ .api_key = "k" });
    defer client.deinit();

    const user_msg = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"role\":\"user\",\"content\":\"hi\"}",
        .{},
    );
    defer user_msg.deinit();

    const hostile_model = "evil\",\"max_tokens\":999999,\"x\":\"\\";
    const payload = try client.buildRequestPayload(
        &[_]std.json.Value{user_msg.value},
        .{ .model = hostile_model, .max_tokens = 8 },
    );
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // The `"` did not open a new field: max_tokens is still the real 8, and
    // the model decodes to the exact adversarial bytes we passed in.
    try std.testing.expectEqualStrings(hostile_model, root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 8), root.get("max_tokens").?.integer);
}
