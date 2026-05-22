// Copyright (c) 2026 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Cloudflare Workers AI client.
//!
//! Speaks OpenAI Chat Completions wire format against Cloudflare's
//! /accounts/{account_id}/ai/v1/chat/completions endpoint. Models live
//! at @cf/* paths (Gemma 4, Nemotron 3, Llama 3.3 — the open-source
//! frontier CF hosts that aren't on Vertex).
//!
//! Wire shape:
//!   POST {base}/accounts/{ACCOUNT_ID}/ai/v1/chat/completions
//!   Authorization: Bearer <token>
//!   {
//!     "model": "@cf/google/gemma-4-26b-a4b-it",
//!     "messages": [...],
//!     "stream": true,
//!     "stream_options": { "include_usage": true },
//!     "tools": [...],
//!     ...
//!   }
//!
//! `include_usage=true` is what makes CF emit a trailing SSE event with
//! `usage: { prompt_tokens, completion_tokens, ... }`. Without it the
//! turn ends with no token counts and cost emission silently zeros.

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const CloudflareClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    account_id: []const u8,
    base_url: []const u8,
    allocator: std.mem.Allocator,

    pub const Config = struct {
        api_key: []const u8,
        /// Cloudflare account ID (the long hex string in the dashboard URL).
        /// Required — embedded in the endpoint path.
        account_id: []const u8,
        /// Host root. Tests can override; default is the public API host.
        base_url: []const u8 = "https://api.cloudflare.com/client/v4",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !CloudflareClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = config.api_key,
            .account_id = config.account_id,
            .base_url = config.base_url,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CloudflareClient) void {
        self.http_client.deinit();
    }

    /// Stream a turn through CF Workers AI. Translates OpenAI Chat
    /// Completions SSE deltas into the existing StreamEvent variants
    /// the agent loop already consumes (text_delta, tool_use_start,
    /// tool_input_delta, block_stop, message_stop).
    pub fn sendMessageStreamingWithEvents(
        self: *CloudflareClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
        callback: common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        // Build the full request payload as JSON in a string buffer.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"model\":\"");
        try appendEscaped(self.allocator, &payload, config.model);
        try payload.appendSlice(self.allocator, "\",\"messages\":[");

        var first_msg = true;
        if (config.system_prompt) |sys| {
            if (sys.len > 0) {
                try payload.appendSlice(self.allocator, "{\"role\":\"system\",\"content\":\"");
                try appendEscaped(self.allocator, &payload, sys);
                try payload.appendSlice(self.allocator, "\"}");
                first_msg = false;
            }
        }

        for (context) |msg| {
            try appendMessages(self.allocator, &payload, msg, &first_msg);
        }

        if (prompt.len > 0) {
            if (!first_msg) try payload.append(self.allocator, ',');
            try payload.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":\"");
            try appendEscaped(self.allocator, &payload, prompt);
            try payload.appendSlice(self.allocator, "\"}");
            first_msg = false;
        }

        try payload.appendSlice(self.allocator, "],\"stream\":true,\"stream_options\":{\"include_usage\":true}");

        // Per-call overrides. CF Chat Completions uses max_completion_tokens.
        try payload.print(self.allocator, ",\"max_completion_tokens\":{d}", .{config.max_tokens});
        if (config.temperature != 0.0) {
            try payload.print(self.allocator, ",\"temperature\":{d}", .{config.temperature});
        }

        if (config.tools) |tool_defs| {
            if (tool_defs.len > 0) {
                try payload.appendSlice(self.allocator, ",\"tools\":[");
                for (tool_defs, 0..) |t, i| {
                    if (i > 0) try payload.append(self.allocator, ',');
                    try payload.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
                    try appendEscaped(self.allocator, &payload, t.name);
                    try payload.appendSlice(self.allocator, "\",\"description\":\"");
                    try appendEscaped(self.allocator, &payload, t.description);
                    try payload.appendSlice(self.allocator, "\",\"parameters\":");
                    // input_schema is already JSON — embed verbatim
                    try payload.appendSlice(self.allocator, t.input_schema);
                    try payload.appendSlice(self.allocator, "}}");
                }
                try payload.append(self.allocator, ']');
            }
        }

        try payload.append(self.allocator, '}');

        // Endpoint: {base}/accounts/{account_id}/ai/v1/chat/completions
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/accounts/{s}/ai/v1/chat/completions",
            .{ self.base_url, self.account_id },
        );
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
        };

        var ctx = EventCtx{
            .gpa = self.allocator,
            .user_callback = callback,
            .user_context = cb_context,
        };
        defer ctx.deinit();

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

        // CF Chat Completions doesn't emit per-block-stop events. After
        // the stream ends, synthesize block_stops for any tracked tool
        // blocks (so the agent loop's streamEventCb can surface their
        // final accumulated args), then a message_stop with usage.
        ctx.flushTerminal();
    }
};

// ---- message JSON building ----

/// Emit one or more JSON-encoded Chat Completions messages for a single
/// AIMessage. Tool_results in Anthropic-shape (one user message carrying
/// N results) expand into N separate {role:"tool", ...} entries because
/// that's what Chat Completions expects.
fn appendMessages(
    gpa: std.mem.Allocator,
    payload: *std.ArrayList(u8),
    msg: common.AIMessage,
    first_msg: *bool,
) !void {
    if (msg.tool_results) |results| {
        for (results) |r| {
            if (!first_msg.*) try payload.append(gpa, ',');
            try payload.appendSlice(gpa, "{\"role\":\"tool\",\"tool_call_id\":\"");
            try appendEscaped(gpa, payload, r.tool_call_id);
            try payload.appendSlice(gpa, "\",\"content\":\"");
            try appendEscaped(gpa, payload, r.content);
            try payload.appendSlice(gpa, "\"}");
            first_msg.* = false;
        }
        return;
    }

    if (!first_msg.*) try payload.append(gpa, ',');

    const role = switch (msg.role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };

    try payload.appendSlice(gpa, "{\"role\":\"");
    try payload.appendSlice(gpa, role);
    try payload.appendSlice(gpa, "\"");

    // Assistant with tool_calls — content may be empty (model only called tools)
    // but the field is required for the assistant role.
    if (msg.tool_calls) |calls| {
        try payload.appendSlice(gpa, ",\"content\":\"");
        try appendEscaped(gpa, payload, msg.content);
        try payload.appendSlice(gpa, "\",\"tool_calls\":[");
        for (calls, 0..) |c, i| {
            if (i > 0) try payload.append(gpa, ',');
            try payload.appendSlice(gpa, "{\"id\":\"");
            try appendEscaped(gpa, payload, c.id);
            try payload.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"");
            try appendEscaped(gpa, payload, c.name);
            // c.arguments is already a JSON string (e.g. {"path":"src"})
            // but Chat Completions expects it as an *escaped string* (not
            // an embedded object), so re-escape.
            try payload.appendSlice(gpa, "\",\"arguments\":\"");
            try appendEscaped(gpa, payload, c.arguments);
            try payload.appendSlice(gpa, "\"}}");
        }
        try payload.append(gpa, ']');
    } else {
        try payload.appendSlice(gpa, ",\"content\":\"");
        try appendEscaped(gpa, payload, msg.content);
        try payload.append(gpa, '"');
    }

    try payload.append(gpa, '}');
    first_msg.* = false;
}

fn appendEscaped(gpa: std.mem.Allocator, payload: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try payload.appendSlice(gpa, "\\\""),
        '\\' => try payload.appendSlice(gpa, "\\\\"),
        '\n' => try payload.appendSlice(gpa, "\\n"),
        '\r' => try payload.appendSlice(gpa, "\\r"),
        '\t' => try payload.appendSlice(gpa, "\\t"),
        0x08 => try payload.appendSlice(gpa, "\\b"),
        0x0C => try payload.appendSlice(gpa, "\\f"),
        else => {
            if (c < 0x20) {
                try payload.print(gpa, "\\u{x:0>4}", .{c});
            } else {
                try payload.append(gpa, c);
            }
        },
    };
}

// ---- SSE event handling ----

/// Per-tool-call accumulator. Cloudflare/OpenAI Chat Completions stream
/// `tool_calls[i]` deltas where `i` is the tool slot inside the assistant
/// message; we map slot 0 → StreamEvent.index 1 (text occupies index 0).
const ToolAccum = struct {
    /// Whether tool_use_start has been emitted for this slot.
    started: bool = false,
    /// Buffered name/id so we can emit tool_use_start once both are seen.
    /// Some servers send id+name on the first delta with empty arguments;
    /// others split across deltas. We only emit start once we have a name.
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
};

const EventCtx = struct {
    gpa: std.mem.Allocator,
    user_callback: common.StreamEventCallback,
    user_context: ?*anyopaque,

    /// Has any text_delta been emitted? Used to decide whether to emit a
    /// block_stop for index 0 at end-of-stream.
    saw_text: bool = false,

    /// One slot per OpenAI tool_calls index, up to MAX_TOOL_SLOTS.
    tools: [MAX_TOOL_SLOTS]ToolAccum = @splat(.{}),
    tool_count: u32 = 0,

    /// Captured from the trailing event when stream_options.include_usage=true.
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    /// Captured from any choice's finish_reason. Mapped to the StreamEvent's
    /// stop_reason string at flushTerminal time.
    finish_reason: std.ArrayList(u8) = .empty,

    /// Set if a callback returned false (abort). flushTerminal becomes a
    /// no-op so we don't keep dispatching after the agent loop bailed.
    aborted: bool = false,

    const MAX_TOOL_SLOTS = 16;

    fn deinit(self: *EventCtx) void {
        for (&self.tools) |*t| {
            t.id.deinit(self.gpa);
            t.name.deinit(self.gpa);
        }
        self.finish_reason.deinit(self.gpa);
    }

    /// Map an OpenAI tool_calls slot index (0-based) to the StreamEvent
    /// content-block index. Text always occupies index 0, so tool 0 → 1.
    fn toolBlockIndex(slot: u32) u32 {
        return slot + 1;
    }

    /// Called once at end-of-stream to emit synthetic block_stops for any
    /// open blocks and the final message_stop with stop_reason + usage.
    fn flushTerminal(self: *EventCtx) void {
        if (self.aborted) return;

        // Synthetic block_stop for text (index 0) if any text deltas fired.
        if (self.saw_text) {
            if (!self.user_callback(.{ .block_stop = .{ .index = 0 } }, self.user_context)) {
                self.aborted = true;
                return;
            }
        }

        // Synthetic block_stop for each emitted tool block.
        for (self.tools[0..self.tool_count], 0..) |t, slot| {
            if (!t.started) continue;
            if (!self.user_callback(.{ .block_stop = .{ .index = toolBlockIndex(@intCast(slot)) } }, self.user_context)) {
                self.aborted = true;
                return;
            }
        }

        // Map CF finish_reason to Anthropic-style stop_reason. The agent
        // loop only checks for emptiness vs presence; we still map known
        // values so debugging is less surprising.
        const sr: ?[]const u8 = if (self.finish_reason.items.len == 0)
            null
        else if (std.mem.eql(u8, self.finish_reason.items, "stop"))
            "end_turn"
        else if (std.mem.eql(u8, self.finish_reason.items, "tool_calls"))
            "tool_use"
        else if (std.mem.eql(u8, self.finish_reason.items, "length"))
            "max_tokens"
        else
            self.finish_reason.items;

        _ = self.user_callback(.{ .message_stop = .{
            .stop_reason = sr,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
        } }, self.user_context);
    }
};

fn eventStreamHandler(event: HttpClient.SseEvent, raw_ctx: ?*anyopaque) bool {
    const ctx: *EventCtx = @alignCast(@ptrCast(raw_ctx orelse return false));
    if (event.done) return true;
    if (ctx.aborted) return false;

    // OpenAI streams a sentinel "[DONE]" event we should stop on without
    // trying to parse as JSON.
    const trimmed = std.mem.trim(u8, event.data, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "[DONE]")) return true;

    // Per-event scratch arena. Stays under 16 KB for normal events; one
    // alloc, dropped at function exit. Same pattern as anthropic.zig.
    var arena_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, event.data, .{}) catch return true;
    defer parsed.deinit();

    if (parsed.value != .object) return true;
    const obj = parsed.value.object;

    // Usage may arrive on its own trailing event (CF's pattern with
    // include_usage=true) or alongside a final choice. Either way we
    // cache it and flushTerminal emits message_stop after the stream ends.
    if (obj.get("usage")) |usage_v| {
        if (usage_v == .object) {
            if (readU32(usage_v.object, "prompt_tokens")) |t| ctx.input_tokens = t;
            if (readU32(usage_v.object, "completion_tokens")) |t| ctx.output_tokens = t;
        }
    }

    const choices_v = obj.get("choices") orelse return true;
    if (choices_v != .array) return true;
    if (choices_v.array.items.len == 0) return true;

    const choice = choices_v.array.items[0];
    if (choice != .object) return true;

    if (choice.object.get("finish_reason")) |fr_v| {
        if (fr_v == .string and fr_v.string.len > 0) {
            ctx.finish_reason.clearRetainingCapacity();
            ctx.finish_reason.appendSlice(ctx.gpa, fr_v.string) catch return false;
        }
    }

    const delta_v = choice.object.get("delta") orelse return true;
    if (delta_v != .object) return true;
    const delta = delta_v.object;

    if (delta.get("content")) |content_v| {
        if (content_v == .string and content_v.string.len > 0) {
            ctx.saw_text = true;
            if (!ctx.user_callback(.{ .text_delta = .{
                .index = 0,
                .text = content_v.string,
            } }, ctx.user_context)) {
                ctx.aborted = true;
                return false;
            }
        }
    }

    if (delta.get("tool_calls")) |tcalls_v| {
        if (tcalls_v == .array) {
            for (tcalls_v.array.items) |tc| {
                if (tc != .object) continue;
                const slot = readU32(tc.object, "index") orelse continue;
                if (slot >= EventCtx.MAX_TOOL_SLOTS) continue;
                if (slot >= ctx.tool_count) ctx.tool_count = slot + 1;
                const accum = &ctx.tools[slot];

                if (tc.object.get("id")) |id_v| {
                    if (id_v == .string) accum.id.appendSlice(ctx.gpa, id_v.string) catch return false;
                }

                const fn_v = tc.object.get("function") orelse continue;
                if (fn_v != .object) continue;

                if (fn_v.object.get("name")) |name_v| {
                    if (name_v == .string and name_v.string.len > 0) {
                        accum.name.appendSlice(ctx.gpa, name_v.string) catch return false;
                    }
                }

                // Emit tool_use_start the first time we have a non-empty
                // name. The id may still be empty for some providers — pass
                // through whatever we have.
                if (!accum.started and accum.name.items.len > 0) {
                    accum.started = true;
                    if (!ctx.user_callback(.{ .tool_use_start = .{
                        .index = EventCtx.toolBlockIndex(slot),
                        .id = accum.id.items,
                        .name = accum.name.items,
                    } }, ctx.user_context)) {
                        ctx.aborted = true;
                        return false;
                    }
                }

                if (fn_v.object.get("arguments")) |args_v| {
                    if (args_v == .string and args_v.string.len > 0 and accum.started) {
                        if (!ctx.user_callback(.{ .tool_input_delta = .{
                            .index = EventCtx.toolBlockIndex(slot),
                            .partial_json = args_v.string,
                        } }, ctx.user_context)) {
                            ctx.aborted = true;
                            return false;
                        }
                    }
                }
            }
        }
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

test "CloudflareClient initialization" {
    const allocator = std.testing.allocator;
    var client = try CloudflareClient.init(allocator, .{
        .api_key = "test-token",
        .account_id = "test-account",
    });
    defer client.deinit();
    try std.testing.expectEqualStrings("test-token", client.api_key);
    try std.testing.expectEqualStrings("test-account", client.account_id);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4", client.base_url);
}
