// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Google Gemini AI client
//! Direct access to Gemini API using API key authentication
//!
//! API Documentation: https://ai.google.dev/docs

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

pub const GeminiClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    base_url: []const u8,
    allocator: std.mem.Allocator,

    pub const DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";
    const MAX_TURNS = 100;

    pub const Config = struct {
        api_key: []const u8,
        base_url: []const u8 = DEFAULT_BASE_URL,
    };

    /// Available Gemini models
    pub const Models = struct {
        pub const PRO_2_5 = "gemini-2.5-pro";
        pub const FLASH_2_5 = "gemini-2.5-flash";
        pub const FLASH_LITE_2_5 = "gemini-2.5-flash-lite";
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GeminiClient {
        return initWithConfig(allocator, .{ .api_key = api_key });
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !GeminiClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = config.api_key,
            .base_url = config.base_url,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GeminiClient) void {
        self.http_client.deinit();
    }

    /// Send a single message
    pub fn sendMessage(
        self: *GeminiClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a streaming message — calls callback for each text chunk
    pub fn sendMessageStreaming(
        self: *GeminiClient,
        prompt: []const u8,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        context: ?*anyopaque,
    ) !void {
        // Build generateContent payload (same format, endpoint handles streaming)
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"");
        try payload.appendSlice(self.allocator, escaped);
        try payload.appendSlice(self.allocator, "\"}]}]");

        // System instruction
        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Generation config
        const gen_config = try std.fmt.allocPrint(self.allocator,
            \\,"generationConfig":{{"temperature":{d},"maxOutputTokens":{}}}
        , .{ config.temperature, config.max_tokens });
        defer self.allocator.free(gen_config);
        try payload.appendSlice(self.allocator, gen_config);

        try payload.appendSlice(self.allocator, "}");

        // Streaming endpoint: streamGenerateContent with alt=sse
        const endpoint = try std.fmt.allocPrint(self.allocator,
            "{s}/models/{s}:streamGenerateContent?key={s}&alt=sse",
            .{ self.base_url, config.model, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, payload.items);
        defer stream.deinit();

        if (@intFromEnum(stream.status) >= 400) {
            self.http_client.captureError(stream.body);
            return common.AIError.ApiRequestFailed;
        }

        // Parse SSE events — Gemini format:
        // data: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}
        while (stream.next()) |event| {
            if (event.done) break;

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                event.data,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const candidates = parsed.value.object.get("candidates") orelse continue;
            if (candidates != .array or candidates.array.items.len == 0) continue;

            const candidate = candidates.array.items[0];
            const content = candidate.object.get("content") orelse continue;
            const parts = content.object.get("parts") orelse continue;
            if (parts != .array) continue;

            for (parts.array.items) |part| {
                const text = part.object.get("text") orelse continue;
                if (text != .string) continue;

                if (!callback(text.string, context)) return;
            }
        }
    }

    /// Send a streaming message with full conversation history.
    /// Builds a `contents` array (Gemini's canonical multi-turn shape) and points at
    /// `:streamGenerateContent?alt=sse` so deltas arrive as SSE.
    pub fn sendMessageStreamingWithContext(
        self: *GeminiClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"contents\":[");

        var first = true;
        for (history) |msg| {
            if (!first) try payload.appendSlice(self.allocator, ",");
            first = false;
            try self.appendMessage(&payload, msg);
        }

        if (prompt.len > 0) {
            if (!first) try payload.appendSlice(self.allocator, ",");
            const escaped = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped);
            const user_part = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","parts":[{{"text":"{s}"}}]}}
            , .{escaped});
            defer self.allocator.free(user_part);
            try payload.appendSlice(self.allocator, user_part);
        }

        try payload.appendSlice(self.allocator, "]");

        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        const gen_config = try std.fmt.allocPrint(self.allocator,
            \\,"generationConfig":{{"temperature":{d},"maxOutputTokens":{}}}
        , .{ config.temperature, config.max_tokens });
        defer self.allocator.free(gen_config);
        try payload.appendSlice(self.allocator, gen_config);

        try payload.appendSlice(self.allocator, "}");

        const endpoint = try std.fmt.allocPrint(self.allocator,
            "{s}/models/{s}:streamGenerateContent?key={s}&alt=sse",
            .{ self.base_url, config.model, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var stream = try self.http_client.postStreaming(endpoint, &headers, payload.items);
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

            const candidates = parsed.value.object.get("candidates") orelse continue;
            if (candidates != .array or candidates.array.items.len == 0) continue;

            const candidate = candidates.array.items[0];
            const content = candidate.object.get("content") orelse continue;
            const parts = content.object.get("parts") orelse continue;
            if (parts != .array) continue;

            for (parts.array.items) |part| {
                const text = part.object.get("text") orelse continue;
                if (text != .string) continue;
                if (!callback(text.string, cb_context)) return;
            }
        }
    }

    /// Tool-aware streaming SSE handler for Gemini.
    /// Each event delivers `candidates[].content.parts[]` plus an optional
    /// `finishReason`. Text parts emit text_delta (always at index 0). Each
    /// functionCall part gets a fresh content-block index, with the args
    /// re-serialized and emitted as one tool_input_delta + block_stop.
    /// `finishReason` (or last event) → message_stop.
    const EventCtx = struct {
        gpa: std.mem.Allocator,
        user_callback: common.StreamEventCallback,
        user_context: ?*anyopaque,
        next_tool_index: u32 = 1,
    };

    fn eventStreamHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
        const ctx: *EventCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
        if (event.done) return false;

        var arena_buf: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        const a = fba.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, a, event.data, .{}) catch return true;
        defer parsed.deinit();

        const candidates = parsed.value.object.get("candidates") orelse return true;
        if (candidates != .array or candidates.array.items.len == 0) return true;

        const candidate = candidates.array.items[0];
        if (candidate.object.get("content")) |content| {
            if (content.object.get("parts")) |parts| {
                if (parts == .array) {
                    for (parts.array.items) |part| {
                        if (part.object.get("text")) |t| {
                            if (t == .string) {
                                if (!ctx.user_callback(.{ .text_delta = .{
                                    .index = 0,
                                    .text = t.string,
                                } }, ctx.user_context)) return false;
                            }
                        } else if (part.object.get("functionCall")) |fc| {
                            if (fc != .object) continue;
                            const name_v = fc.object.get("name") orelse continue;
                            if (name_v != .string) continue;
                            const args_v = fc.object.get("args") orelse continue;

                            const idx = ctx.next_tool_index;
                            ctx.next_tool_index += 1;

                            // Synthesize a stable id — Gemini doesn't return one.
                            const synth_id = std.fmt.allocPrint(ctx.gpa, "gem-{d}", .{idx}) catch continue;
                            defer ctx.gpa.free(synth_id);

                            if (!ctx.user_callback(.{ .tool_use_start = .{
                                .index = idx,
                                .id = synth_id,
                                .name = name_v.string,
                            } }, ctx.user_context)) return false;

                            // Serialize args back to a JSON string for the agent loop.
                            var args_buf: std.Io.Writer.Allocating = .init(ctx.gpa);
                            defer args_buf.deinit();
                            var stringify: std.json.Stringify = .{
                                .writer = &args_buf.writer,
                                .options = .{},
                            };
                            stringify.write(args_v) catch continue;

                            if (!ctx.user_callback(.{ .tool_input_delta = .{
                                .index = idx,
                                .partial_json = args_buf.written(),
                            } }, ctx.user_context)) return false;

                            if (!ctx.user_callback(.{ .block_stop = .{ .index = idx } }, ctx.user_context)) return false;
                        }
                    }
                }
            }
        }

        if (candidate.object.get("finishReason")) |fr| {
            if (fr == .string) {
                var in_t: u32 = 0;
                var out_t: u32 = 0;
                if (parsed.value.object.get("usageMetadata")) |um| if (um == .object) {
                    if (um.object.get("promptTokenCount")) |pt| if (pt == .integer and pt.integer >= 0) {
                        in_t = @intCast(pt.integer);
                    };
                    if (um.object.get("candidatesTokenCount")) |ct| if (ct == .integer and ct.integer >= 0) {
                        out_t = @intCast(ct.integer);
                    };
                };
                _ = ctx.user_callback(.{ .message_stop = .{
                    .stop_reason = fr.string,
                    .input_tokens = in_t,
                    .output_tokens = out_t,
                } }, ctx.user_context);
            }
        }

        return true;
    }

    /// Tool-aware streaming with full conversation history.
    /// Mirrors the Anthropic / OpenAI / Grok paths: emits structured events
    /// through a `StreamEventCallback` so callers can drive an agent loop.
    pub fn sendMessageStreamingWithEvents(
        self: *GeminiClient,
        prompt: []const u8,
        history: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"contents\":[");

        var first = true;
        for (history) |msg| {
            if (!first) try payload.appendSlice(self.allocator, ",");
            first = false;
            try self.appendMessage(&payload, msg);
        }

        if (prompt.len > 0) {
            if (!first) try payload.appendSlice(self.allocator, ",");
            const escaped = try common.escapeJsonString(self.allocator, prompt);
            defer self.allocator.free(escaped);
            const user_part = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"user","parts":[{{"text":"{s}"}}]}}
            , .{escaped});
            defer self.allocator.free(user_part);
            try payload.appendSlice(self.allocator, user_part);
        }
        try payload.appendSlice(self.allocator, "]");

        if (config.system_prompt) |system| {
            const sys_escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(sys_escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
            , .{sys_escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        if (config.tools) |tool_defs| {
            try payload.appendSlice(self.allocator, ",\"tools\":[{\"functionDeclarations\":[");
            for (tool_defs, 0..) |tool, i| {
                if (i > 0) try payload.appendSlice(self.allocator, ",");
                const escaped_name = try common.escapeJsonString(self.allocator, tool.name);
                defer self.allocator.free(escaped_name);
                const escaped_desc = try common.escapeJsonString(self.allocator, tool.description);
                defer self.allocator.free(escaped_desc);
                const tj = try std.fmt.allocPrint(self.allocator,
                    \\{{"name":"{s}","description":"{s}","parameters":{s}}}
                , .{ escaped_name, escaped_desc, tool.input_schema });
                defer self.allocator.free(tj);
                try payload.appendSlice(self.allocator, tj);
            }
            try payload.appendSlice(self.allocator, "]}]");
        }

        const gen_config = try std.fmt.allocPrint(self.allocator,
            \\,"generationConfig":{{"temperature":{d},"maxOutputTokens":{}}}
        , .{ config.temperature, config.max_tokens });
        defer self.allocator.free(gen_config);
        try payload.appendSlice(self.allocator, gen_config);

        try payload.appendSlice(self.allocator, "}");

        const endpoint = try std.fmt.allocPrint(self.allocator,
            "{s}/models/{s}:streamGenerateContent?key={s}&alt=sse",
            .{ self.base_url, config.model, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var ev_ctx = EventCtx{
            .gpa = self.allocator,
            .user_callback = callback,
            .user_context = cb_context,
        };

        const status = try self.http_client.postSseStream(
            endpoint,
            &headers,
            payload.items,
            eventStreamHandler,
            &ev_ctx,
        );

        if (@intFromEnum(status) >= 400) {
            return common.AIError.ApiRequestFailed;
        }
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *GeminiClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        var timer = Timer.start(self.http_client.io());

        // Build contents array (Gemini format)
        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(self.allocator);

        try contents.appendSlice(self.allocator, "[");

        // Add context messages
        for (context, 0..) |msg, i| {
            if (i > 0) try contents.appendSlice(self.allocator, ",");
            try self.appendMessage(&contents, msg);
        }

        // Add current prompt (with images if provided)
        if (context.len > 0) try contents.appendSlice(self.allocator, ",");

        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);

        try contents.appendSlice(self.allocator, "{\"role\":\"user\",\"parts\":[");

        // Add text part
        const text_part = try std.fmt.allocPrint(self.allocator, "{{\"text\":\"{s}\"}}", .{escaped_prompt});
        defer self.allocator.free(text_part);
        try contents.appendSlice(self.allocator, text_part);

        // Add image parts if provided
        if (config.images) |images| {
            for (images) |img| {
                if (img.isUrl()) {
                    // URL-based image: use file_data with file_uri
                    const img_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"file_data":{{"file_uri":"{s}","mime_type":"{s}"}}}}
                    , .{ img.url.?, img.media_type });
                    defer self.allocator.free(img_part);
                    try contents.appendSlice(self.allocator, img_part);
                } else {
                    // Base64-encoded image: use inline_data
                    const img_part = try std.fmt.allocPrint(self.allocator,
                        \\,{{"inline_data":{{"mime_type":"{s}","data":"{s}"}}}}
                    , .{ img.media_type, img.data });
                    defer self.allocator.free(img_part);
                    try contents.appendSlice(self.allocator, img_part);
                }
            }
        }

        try contents.appendSlice(self.allocator, "]}");

        try contents.appendSlice(self.allocator, "]");

        var turn_count: u32 = 0;
        var total_tokens: u32 = 0;

        // Agentic loop
        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(contents.items, config);
            defer self.allocator.free(payload);

            const response = try self.makeRequest(config.model, payload);
            defer self.allocator.free(response);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usageMetadata")) |usage| {
                if (usage.object.get("totalTokenCount")) |total| {
                    total_tokens = @intCast(total.integer);
                }
            }

            // Extract candidates
            const candidates = parsed.value.object.get("candidates") orelse
                return common.AIError.InvalidResponse;

            if (candidates.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const candidate = candidates.array.items[0];
            const content = candidate.object.get("content") orelse
                return common.AIError.InvalidResponse;

            const parts = content.object.get("parts") orelse
                return common.AIError.InvalidResponse;

            // Extract text content and function calls from parts
            var text_content: std.ArrayList(u8) = .empty;
            defer text_content.deinit(self.allocator);

            var tool_calls_list: std.ArrayList(common.ToolCall) = .empty;
            errdefer {
                for (tool_calls_list.items) |*tc| tc.deinit();
                tool_calls_list.deinit(self.allocator);
            }

            for (parts.array.items) |part| {
                if (part.object.get("text")) |text| {
                    if (text_content.items.len > 0) {
                        try text_content.appendSlice(self.allocator, "\n");
                    }
                    try text_content.appendSlice(self.allocator, text.string);
                } else if (part.object.get("functionCall")) |fc| {
                    const fn_name = fc.object.get("name") orelse continue;
                    const fn_args = fc.object.get("args") orelse continue;

                    // Serialize args to JSON string
                    var args_writer: std.Io.Writer.Allocating = .init(self.allocator);
                    defer args_writer.deinit();
                    var args_stream: std.json.Stringify = .{
                        .writer = &args_writer.writer,
                        .options = .{},
                    };
                    try args_stream.write(fn_args);

                    // Gemini doesn't provide tool call IDs, generate one
                    const call_id = try common.generateId(self.allocator, self.http_client.io());

                    try tool_calls_list.append(self.allocator, .{
                        .id = call_id,
                        .name = try self.allocator.dupe(u8, fn_name.string),
                        .arguments = try self.allocator.dupe(u8, args_writer.written()),
                        .allocator = self.allocator,
                    });
                }
            }

            // Determine stop reason
            const stop_reason_str = if (tool_calls_list.items.len > 0)
                try self.allocator.dupe(u8, "tool_use")
            else if (candidate.object.get("finishReason")) |reason|
                try self.allocator.dupe(u8, reason.string)
            else
                null;

            const elapsed_ns = timer.read();

            return common.AIResponse{
                .message = .{
                    .id = try common.generateId(self.allocator, self.http_client.io()),
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
                    .input_tokens = 0, // Gemini doesn't provide breakdown
                    .output_tokens = total_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "gemini"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .stop_reason = stop_reason_str,
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    fn buildRequestPayload(
        self: *GeminiClient,
        contents: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{");

        const contents_part = try std.fmt.allocPrint(self.allocator, "\"contents\":{s},", .{contents});
        defer self.allocator.free(contents_part);
        try payload.appendSlice(self.allocator, contents_part);

        // System instruction
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},
            , .{escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Tools: function declarations + server-side tools (google_search, url_context, googleMaps)
        {
            const has_functions = config.tools != null;
            var has_gemini_tools = false;
            if (config.server_tools) |st| {
                for (st) |tool| {
                    if (tool.isGeminiTool()) {
                        has_gemini_tools = true;
                        break;
                    }
                }
            }

            if (has_functions or has_gemini_tools) {
                try payload.appendSlice(self.allocator, "\"tools\":[");
                var tool_obj_count: usize = 0;

                // Function declarations as one tool object
                if (config.tools) |tool_defs| {
                    try payload.appendSlice(self.allocator, "{\"functionDeclarations\":[");
                    for (tool_defs, 0..) |tool, i| {
                        if (i > 0) try payload.appendSlice(self.allocator, ",");
                        const escaped_name = try common.escapeJsonString(self.allocator, tool.name);
                        defer self.allocator.free(escaped_name);
                        const escaped_desc = try common.escapeJsonString(self.allocator, tool.description);
                        defer self.allocator.free(escaped_desc);

                        const tool_json = try std.fmt.allocPrint(self.allocator,
                            \\{{"name":"{s}","description":"{s}","parameters":{s}}}
                        , .{ escaped_name, escaped_desc, tool.input_schema });
                        defer self.allocator.free(tool_json);
                        try payload.appendSlice(self.allocator, tool_json);
                    }
                    try payload.appendSlice(self.allocator, "]}");
                    tool_obj_count += 1;
                }

                // Server-side tools as separate objects
                if (config.server_tools) |st| {
                    for (st) |tool| {
                        if (tool.toGeminiToolJson()) |json| {
                            if (tool_obj_count > 0) try payload.appendSlice(self.allocator, ",");
                            try payload.appendSlice(self.allocator, json);
                            tool_obj_count += 1;
                        }
                    }
                }

                try payload.appendSlice(self.allocator, "],");
            }
        }

        // Tool config: functionCallingConfig + retrievalConfig
        {
            const has_fc_config = config.tool_choice != null;
            const has_retrieval_config = config.maps_latitude != null and config.maps_longitude != null;

            if (has_fc_config or has_retrieval_config) {
                try payload.appendSlice(self.allocator, "\"toolConfig\":{");
                var tc_count: usize = 0;

                // functionCallingConfig (mode + allowedFunctionNames)
                if (config.tool_choice) |tc| {
                    try payload.appendSlice(self.allocator, "\"functionCallingConfig\":{");

                    const mode_str = try std.fmt.allocPrint(self.allocator,
                        "\"mode\":\"{s}\"", .{tc.toGeminiMode()});
                    defer self.allocator.free(mode_str);
                    try payload.appendSlice(self.allocator, mode_str);

                    // allowedFunctionNames: from explicit list or single function name
                    const fn_names = config.allowed_function_names;
                    const single_fn = if (tc == .function) config.tool_choice_function else null;

                    if (fn_names != null or single_fn != null) {
                        try payload.appendSlice(self.allocator, ",\"allowedFunctionNames\":[");
                        var fn_count: usize = 0;

                        if (fn_names) |names| {
                            for (names) |name| {
                                if (fn_count > 0) try payload.appendSlice(self.allocator, ",");
                                const escaped = try common.escapeJsonString(self.allocator, name);
                                defer self.allocator.free(escaped);
                                const fn_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
                                defer self.allocator.free(fn_str);
                                try payload.appendSlice(self.allocator, fn_str);
                                fn_count += 1;
                            }
                        } else if (single_fn) |name| {
                            const escaped = try common.escapeJsonString(self.allocator, name);
                            defer self.allocator.free(escaped);
                            const fn_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
                            defer self.allocator.free(fn_str);
                            try payload.appendSlice(self.allocator, fn_str);
                        }

                        try payload.appendSlice(self.allocator, "]");
                    }

                    try payload.appendSlice(self.allocator, "}");
                    tc_count += 1;
                }

                // retrievalConfig (Google Maps location)
                if (has_retrieval_config) {
                    if (tc_count > 0) try payload.appendSlice(self.allocator, ",");
                    const rc = try std.fmt.allocPrint(self.allocator,
                        \\"retrievalConfig":{{"latLng":{{"latitude":{d},"longitude":{d}}}}}
                    , .{ config.maps_latitude.?, config.maps_longitude.? });
                    defer self.allocator.free(rc);
                    try payload.appendSlice(self.allocator, rc);
                }

                try payload.appendSlice(self.allocator, "},");
            }
        }

        // Generation config
        {
            const gen_config = try std.fmt.allocPrint(self.allocator,
                \\"generationConfig":{{"temperature":{d},"maxOutputTokens":{},"topP":{d}
            , .{ config.temperature, config.max_tokens, config.top_p });
            defer self.allocator.free(gen_config);
            try payload.appendSlice(self.allocator, gen_config);

            if (config.media_resolution) |mr| {
                const mr_str = try std.fmt.allocPrint(self.allocator,
                    \\,"mediaResolution":"{s}"
                , .{mr.toApiString()});
                defer self.allocator.free(mr_str);
                try payload.appendSlice(self.allocator, mr_str);
            }

            try payload.appendSlice(self.allocator, "}");
        }

        try payload.appendSlice(self.allocator, "}");

        return payload.toOwnedSlice(self.allocator);
    }

    fn makeRequest(self: *GeminiClient, model: []const u8, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/models/{s}:generateContent?key={s}",
            .{ self.base_url, model, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *GeminiClient,
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

    fn appendMessage(self: *GeminiClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
        if (msg.tool_calls) |tool_calls| {
            // Model message with function calls
            try writer.appendSlice(self.allocator, "{\"role\":\"model\",\"parts\":[");

            var has_part = false;

            // Add text part if present
            if (msg.content.len > 0) {
                const escaped = try common.escapeJsonString(self.allocator, msg.content);
                defer self.allocator.free(escaped);
                const text_part = try std.fmt.allocPrint(self.allocator,
                    \\{{"text":"{s}"}}
                , .{escaped});
                defer self.allocator.free(text_part);
                try writer.appendSlice(self.allocator, text_part);
                has_part = true;
            }

            // Add functionCall parts
            for (tool_calls) |call| {
                if (has_part) try writer.appendSlice(self.allocator, ",");
                const escaped_name = try common.escapeJsonString(self.allocator, call.name);
                defer self.allocator.free(escaped_name);
                // arguments is a JSON string, embed it directly as the args object
                const call_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"functionCall":{{"name":"{s}","args":{s}}}}}
                , .{ escaped_name, call.arguments });
                defer self.allocator.free(call_json);
                try writer.appendSlice(self.allocator, call_json);
                has_part = true;
            }

            try writer.appendSlice(self.allocator, "]}");
        } else if (msg.tool_results) |tool_results| {
            // User message with function responses
            try writer.appendSlice(self.allocator, "{\"role\":\"user\",\"parts\":[");

            for (tool_results, 0..) |result, i| {
                if (i > 0) try writer.appendSlice(self.allocator, ",");
                // Gemini uses function name (not ID) in responses
                const name = result.tool_name orelse result.tool_call_id;
                const escaped_name = try common.escapeJsonString(self.allocator, name);
                defer self.allocator.free(escaped_name);
                const escaped_content = try common.escapeJsonString(self.allocator, result.content);
                defer self.allocator.free(escaped_content);

                const result_json = try std.fmt.allocPrint(self.allocator,
                    \\{{"functionResponse":{{"name":"{s}","response":{{"content":"{s}"}}}}}}
                , .{ escaped_name, escaped_content });
                defer self.allocator.free(result_json);
                try writer.appendSlice(self.allocator, result_json);
            }

            try writer.appendSlice(self.allocator, "]}");
        } else {
            // Simple text message
            const role = switch (msg.role) {
                .user => "user",
                .assistant => "model",
                else => "user",
            };

            const escaped = try common.escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped);

            const msg_json = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
            , .{ role, escaped });
            defer self.allocator.free(msg_json);
            try writer.appendSlice(self.allocator, msg_json);
        }
    }

    /// Helper: Create default config for Gemini Pro
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.PRO_2_5,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    // ====================================================================
    // Files API — upload, get status, list, delete
    // ====================================================================

    const UPLOAD_BASE = "https://generativelanguage.googleapis.com/upload/v1beta/files";

    /// Upload a file via the Gemini Files API (resumable protocol).
    /// Returns the file_uri on success (caller owns the string).
    /// Supports PDFs, videos, images, audio, text — up to 2GB (free) or 20GB (paid).
    pub fn uploadFile(self: *GeminiClient, file_data: []const u8, filename: []const u8, mime_type: []const u8) ![]u8 {
        // Step 1: Start resumable upload — get upload URL from response header
        const start_url = try std.fmt.allocPrint(self.allocator, "{s}?key={s}", .{ UPLOAD_BASE, self.api_key });
        defer self.allocator.free(start_url);

        const num_bytes_str = try std.fmt.allocPrint(self.allocator, "{d}", .{file_data.len});
        defer self.allocator.free(num_bytes_str);

        const escaped_name = try common.escapeJsonString(self.allocator, filename);
        defer self.allocator.free(escaped_name);

        const metadata = try std.fmt.allocPrint(self.allocator,
            \\{{"file":{{"display_name":"{s}"}}}}
        , .{escaped_name});
        defer self.allocator.free(metadata);

        const start_headers = [_]std.http.Header{
            .{ .name = "X-Goog-Upload-Protocol", .value = "resumable" },
            .{ .name = "X-Goog-Upload-Command", .value = "start" },
            .{ .name = "X-Goog-Upload-Header-Content-Length", .value = num_bytes_str },
            .{ .name = "X-Goog-Upload-Header-Content-Type", .value = mime_type },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var start_resp = try self.http_client.postExtractHeader(
            start_url,
            &start_headers,
            metadata,
            "x-goog-upload-url",
        );
        defer start_resp.deinit();

        if (start_resp.status != .ok) {
            return common.AIError.ApiRequestFailed;
        }

        const upload_url = start_resp.header_value orelse return common.AIError.ApiRequestFailed;

        // Step 2: Upload the actual bytes
        const upload_headers = [_]std.http.Header{
            .{ .name = "Content-Length", .value = num_bytes_str },
            .{ .name = "X-Goog-Upload-Offset", .value = "0" },
            .{ .name = "X-Goog-Upload-Command", .value = "upload, finalize" },
        };

        var upload_resp = try self.http_client.postWithOptions(
            upload_url,
            &upload_headers,
            file_data,
            .{ .max_body_size = 1 * 1024 * 1024 }, // response is small JSON
        );
        defer upload_resp.deinit();

        if (upload_resp.status != .ok) {
            return common.AIError.ApiRequestFailed;
        }

        // Parse response to get file name and URI
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            upload_resp.body,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        const file_obj = parsed.value.object.get("file") orelse return common.AIError.InvalidResponse;

        // Check if file needs processing (videos take time)
        if (file_obj.object.get("state")) |state| {
            if (state == .string and std.mem.eql(u8, state.string, "PROCESSING")) {
                // Return the name so caller can poll for completion
                if (file_obj.object.get("name")) |name| {
                    if (name == .string) {
                        return try self.allocator.dupe(u8, name.string);
                    }
                }
            }
        }

        // File is ACTIVE — return the URI
        if (file_obj.object.get("uri")) |uri| {
            if (uri == .string) {
                return try self.allocator.dupe(u8, uri.string);
            }
        }

        // Fallback: return name for polling
        if (file_obj.object.get("name")) |name| {
            if (name == .string) {
                return try self.allocator.dupe(u8, name.string);
            }
        }

        return common.AIError.InvalidResponse;
    }

    /// Get file status/metadata. Returns JSON response body (caller owns).
    /// Use to poll for PROCESSING → ACTIVE state after video upload.
    pub fn getFileStatus(self: *GeminiClient, file_name: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator,
            "{s}/{s}?key={s}",
            .{ self.base_url, file_name, self.api_key },
        );
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.get(url, &headers);
        defer response.deinit();

        if (response.status != .ok) {
            return common.AIError.ApiRequestFailed;
        }

        return try self.allocator.dupe(u8, response.body);
    }

    /// Wait for a file to become ACTIVE (polls until ready or timeout).
    /// Returns the file_uri on success.
    pub fn waitForFile(self: *GeminiClient, file_name: []const u8, max_polls: u32) ![]u8 {
        var polls: u32 = 0;
        while (polls < max_polls) : (polls += 1) {
            const json = try self.getFileStatus(file_name);
            defer self.allocator.free(json);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                json,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            if (parsed.value.object.get("state")) |state| {
                if (state == .string) {
                    if (std.mem.eql(u8, state.string, "ACTIVE")) {
                        if (parsed.value.object.get("uri")) |uri| {
                            if (uri == .string) {
                                return try self.allocator.dupe(u8, uri.string);
                            }
                        }
                    } else if (std.mem.eql(u8, state.string, "FAILED")) {
                        return common.AIError.ApiRequestFailed;
                    }
                }
            }

            // Sleep 2 seconds between polls
            self.http_client.io().sleep(std.Io.Duration.fromSeconds(2), .awake) catch {};
        }

        return common.AIError.RequestTimeout;
    }

    /// List all uploaded files. Returns JSON response body (caller owns).
    pub fn listFiles(self: *GeminiClient) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator,
            "{s}/files?key={s}",
            .{ self.base_url, self.api_key },
        );
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.get(url, &headers);
        defer response.deinit();

        if (response.status != .ok) {
            return common.AIError.ApiRequestFailed;
        }

        return try self.allocator.dupe(u8, response.body);
    }

    /// Delete an uploaded file by name (e.g., "files/abc123").
    pub fn deleteFile(self: *GeminiClient, file_name: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator,
            "{s}/{s}?key={s}",
            .{ self.base_url, file_name, self.api_key },
        );
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.delete(url, &headers);
        defer response.deinit();

        if (response.status != .ok and response.status != .no_content) {
            return common.AIError.ApiRequestFailed;
        }
    }

    // ====================================================================
    // Embeddings API — text embeddings with task types
    // ====================================================================

    pub const EMBEDDING_MODEL = "gemini-embedding-001";

    /// Generate embeddings for one or more texts.
    /// Returns one EmbeddingResult per input text (caller owns all).
    pub fn embedContent(
        self: *GeminiClient,
        texts: []const []const u8,
        task_type: ?common.EmbeddingTaskType,
        output_dimensionality: ?u32,
    ) ![]common.EmbeddingResult {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"content\":{\"parts\":[");

        for (texts, 0..) |text, i| {
            if (i > 0) try payload.appendSlice(self.allocator, ",");
            const escaped = try common.escapeJsonString(self.allocator, text);
            defer self.allocator.free(escaped);
            const part = try std.fmt.allocPrint(self.allocator, "{{\"text\":\"{s}\"}}", .{escaped});
            defer self.allocator.free(part);
            try payload.appendSlice(self.allocator, part);
        }

        try payload.appendSlice(self.allocator, "]}");

        if (task_type) |tt| {
            const tt_str = try std.fmt.allocPrint(self.allocator, ",\"taskType\":\"{s}\"", .{tt.toApiString()});
            defer self.allocator.free(tt_str);
            try payload.appendSlice(self.allocator, tt_str);
        }

        if (output_dimensionality) |dim| {
            const dim_str = try std.fmt.allocPrint(self.allocator, ",\"outputDimensionality\":{d}", .{dim});
            defer self.allocator.free(dim_str);
            try payload.appendSlice(self.allocator, dim_str);
        }

        try payload.appendSlice(self.allocator, "}");

        // POST to embedContent endpoint
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/models/{s}:embedContent?key={s}",
            .{ self.base_url, EMBEDDING_MODEL, self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload.items);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        // Parse response: {"embeddings": [{"values": [0.1, 0.2, ...]}]}
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Handle both single embedding and batch responses
        // Single: {"embedding": {"values": [...]}}
        // Batch: {"embeddings": [{"values": [...]}, ...]}
        var embeddings_array: []const std.json.Value = undefined;
        var single_wrapper: [1]std.json.Value = undefined;

        if (parsed.value.object.get("embeddings")) |embs| {
            embeddings_array = embs.array.items;
        } else if (parsed.value.object.get("embedding")) |emb| {
            single_wrapper[0] = emb;
            embeddings_array = &single_wrapper;
        } else {
            return common.AIError.InvalidResponse;
        }

        var results = try self.allocator.alloc(common.EmbeddingResult, embeddings_array.len);
        errdefer {
            for (results) |*r| r.deinit();
            self.allocator.free(results);
        }

        for (embeddings_array, 0..) |emb_obj, i| {
            const values_json = emb_obj.object.get("values") orelse return common.AIError.InvalidResponse;
            const values = try self.allocator.alloc(f64, values_json.array.items.len);
            errdefer self.allocator.free(values);

            for (values_json.array.items, 0..) |v, j| {
                values[j] = switch (v) {
                    .float => v.float,
                    .integer => @floatFromInt(v.integer),
                    else => 0.0,
                };
            }

            results[i] = .{
                .values = values,
                .allocator = self.allocator,
            };
        }

        return results;
    }

    /// Helper: Create config for fast responses (Flash)
    pub fn fastConfig() common.RequestConfig {
        return .{
            .model = Models.FLASH_2_5,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for ultra-fast responses (Flash Lite)
    pub fn ultraFastConfig() common.RequestConfig {
        return .{
            .model = Models.FLASH_LITE_2_5,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }
};

test "GeminiClient initialization" {
    const allocator = std.testing.allocator;

    var client = try GeminiClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "GeminiClient config helpers" {
    const default_cfg = GeminiClient.defaultConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.PRO_2_5, default_cfg.model);

    const fast_cfg = GeminiClient.fastConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.FLASH_2_5, fast_cfg.model);

    const ultra_fast_cfg = GeminiClient.ultraFastConfig();
    try std.testing.expectEqualStrings(GeminiClient.Models.FLASH_LITE_2_5, ultra_fast_cfg.model);
}
