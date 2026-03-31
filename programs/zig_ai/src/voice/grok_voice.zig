// Grok Voice Agent — Core session logic
// Real-time WebSocket voice agent for xAI's Realtime API
// Text input -> audio + text response via wss://api.x.ai/v1/realtime

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ws_client = @import("ws_client.zig");

const Voice = types.Voice;
const AudioEncoding = types.AudioEncoding;
const AudioFormat = types.AudioFormat;
const SessionConfig = types.SessionConfig;
const SessionState = types.SessionState;
const ToolCall = types.ToolCall;
const VoiceResponse = types.VoiceResponse;

/// Grok Voice Agent session
pub const GrokVoiceSession = struct {
    allocator: Allocator,
    ws: ws_client.XaiWsClient,
    state: SessionState = .disconnected,
    config: SessionConfig = .{},

    // Accumulation buffers
    transcript_buf: std.ArrayListUnmanaged(u8),
    audio_buf: std.ArrayListUnmanaged(u8),
    tool_calls_buf: std.ArrayListUnmanaged(ToolCall),

    const Self = @This();

    /// Initialize a new voice session
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .ws = try ws_client.XaiWsClient.init(allocator),
            .transcript_buf = .empty,
            .audio_buf = .empty,
            .tool_calls_buf = .empty,
        };
        return self;
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        self.close();
        self.transcript_buf.deinit(self.allocator);
        self.audio_buf.deinit(self.allocator);
        for (self.tool_calls_buf.items) |*tc| tc.deinit();
        self.tool_calls_buf.deinit(self.allocator);
        self.ws.deinit();
        self.allocator.destroy(self);
    }

    /// Connect to xAI Realtime and configure session
    pub fn connect(self: *Self, api_key: []const u8, config: SessionConfig) !void {
        if (self.state != .disconnected) return error.AlreadyConnected;

        self.state = .connecting;
        self.config = config;
        errdefer self.state = .failed;

        try self.ws.connect(api_key);

        self.state = .configuring;

        // Send session.update
        try self.sendSessionUpdate();

        // Wait for session.updated and conversation.created
        var got_session_updated = false;
        var got_conversation = false;

        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            const msg = try self.ws.receive() orelse return error.SetupFailed;
            defer self.allocator.free(msg);

            if (std.mem.indexOf(u8, msg, "\"session.updated\"") != null) {
                got_session_updated = true;
            }
            if (std.mem.indexOf(u8, msg, "\"conversation.created\"") != null) {
                got_conversation = true;
            }

            if (got_session_updated and got_conversation) {
                self.state = .ready;
                return;
            }
        }

        return error.SetupFailed;
    }

    /// Send text input and wait for complete response
    pub fn sendTextAndWait(self: *Self, text: []const u8) !VoiceResponse {
        if (self.state != .ready) return error.NotConnected;

        const start_ts = getTimestamp();

        // Clear accumulation buffers
        self.transcript_buf.clearRetainingCapacity();
        self.audio_buf.clearRetainingCapacity();
        for (self.tool_calls_buf.items) |*tc| tc.deinit();
        self.tool_calls_buf.clearRetainingCapacity();

        // Send conversation.item.create with input_text
        try self.sendConversationItem(text);

        // Send response.create
        try self.sendResponseCreate();

        self.state = .responding;

        // Collect all deltas until response.done
        try self.collectResponse();

        self.state = .ready;

        const elapsed = getTimestamp() - start_ts;

        // Build response
        const transcript = if (self.transcript_buf.items.len > 0)
            try self.allocator.dupe(u8, self.transcript_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const audio = if (self.audio_buf.items.len > 0)
            try self.allocator.dupe(u8, self.audio_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const tool_calls = if (self.tool_calls_buf.items.len > 0)
            try self.allocator.dupe(ToolCall, self.tool_calls_buf.items)
        else
            try self.allocator.alloc(ToolCall, 0);

        // Don't free tool_calls_buf items since ownership transferred
        self.tool_calls_buf.clearRetainingCapacity();

        return VoiceResponse{
            .transcript = transcript,
            .audio_data = audio,
            .tool_calls = tool_calls,
            .processing_time_ms = elapsed,
            .allocator = self.allocator,
        };
    }

    /// Send a tool result and trigger another response
    pub fn sendToolResult(self: *Self, call_id: []const u8, output: []const u8) !void {
        if (self.state != .ready and self.state != .tool_calling) return error.NotConnected;

        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"type\":\"conversation.item.create\",\"item\":{\"type\":\"function_call_output\",\"call_id\":\"");
        try json.appendSlice(self.allocator, call_id);
        try json.appendSlice(self.allocator, "\",\"output\":\"");
        try appendJsonEscaped(&json, self.allocator, output);
        try json.appendSlice(self.allocator, "\"}}");

        try self.ws.sendText(json.items);
        try self.sendResponseCreate();
    }

    /// Collect response after sending tool result
    pub fn collectToolResponse(self: *Self) !VoiceResponse {
        const start_ts = getTimestamp();

        self.transcript_buf.clearRetainingCapacity();
        self.audio_buf.clearRetainingCapacity();
        for (self.tool_calls_buf.items) |*tc| tc.deinit();
        self.tool_calls_buf.clearRetainingCapacity();

        self.state = .responding;
        try self.collectResponse();
        self.state = .ready;

        const elapsed = getTimestamp() - start_ts;

        const transcript = if (self.transcript_buf.items.len > 0)
            try self.allocator.dupe(u8, self.transcript_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const audio = if (self.audio_buf.items.len > 0)
            try self.allocator.dupe(u8, self.audio_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const tool_calls = if (self.tool_calls_buf.items.len > 0)
            try self.allocator.dupe(ToolCall, self.tool_calls_buf.items)
        else
            try self.allocator.alloc(ToolCall, 0);

        self.tool_calls_buf.clearRetainingCapacity();

        return VoiceResponse{
            .transcript = transcript,
            .audio_data = audio,
            .tool_calls = tool_calls,
            .processing_time_ms = elapsed,
            .allocator = self.allocator,
        };
    }

    pub fn isConnected(self: *const Self) bool {
        return self.state != .disconnected and self.state != .failed;
    }

    pub fn getState(self: *const Self) SessionState {
        return self.state;
    }

    pub fn close(self: *Self) void {
        if (self.state == .disconnected) return;
        self.ws.close();
        self.state = .disconnected;
    }

    // ========================================================================
    // Private Methods
    // ========================================================================

    fn sendSessionUpdate(self: *Self) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator,
            \\{"type":"session.update","session":{"voice":"
        );
        try json.appendSlice(self.allocator, self.config.voice.toString());
        try json.appendSlice(self.allocator, "\"");

        // Instructions
        if (self.config.instructions) |instr| {
            try json.appendSlice(self.allocator, ",\"instructions\":\"");
            try appendJsonEscaped(&json, self.allocator, instr);
            try json.appendSlice(self.allocator, "\"");
        }

        // Turn detection disabled for text input
        try json.appendSlice(self.allocator, ",\"turn_detection\":{\"type\":null}");

        // Audio format
        try json.appendSlice(self.allocator, ",\"audio\":{\"input\":{\"format\":{\"type\":\"");
        try json.appendSlice(self.allocator, self.config.output_format.encoding.toApiString());
        try json.appendSlice(self.allocator, "\",\"rate\":");
        var rate_buf: [16]u8 = undefined;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d}", .{self.config.output_format.sample_rate}) catch "24000";
        try json.appendSlice(self.allocator, rate_str);
        try json.appendSlice(self.allocator, "}},\"output\":{\"format\":{\"type\":\"");
        try json.appendSlice(self.allocator, self.config.output_format.encoding.toApiString());
        try json.appendSlice(self.allocator, "\",\"rate\":");
        try json.appendSlice(self.allocator, rate_str);
        try json.appendSlice(self.allocator, "}}}");

        // Tools
        if (self.config.tools.len > 0) {
            try json.appendSlice(self.allocator, ",\"tools\":[");
            for (self.config.tools, 0..) |tool, i| {
                if (i > 0) try json.append(self.allocator, ',');
                try json.appendSlice(self.allocator, "{\"type\":\"function\",\"name\":\"");
                try json.appendSlice(self.allocator, tool.name);
                try json.appendSlice(self.allocator, "\",\"description\":\"");
                try appendJsonEscaped(&json, self.allocator, tool.description);
                try json.appendSlice(self.allocator, "\",\"parameters\":");
                try json.appendSlice(self.allocator, tool.parameters_json);
                try json.appendSlice(self.allocator, "}");
            }
            try json.appendSlice(self.allocator, "]");
        }

        try json.appendSlice(self.allocator, "}}");
        try self.ws.sendText(json.items);
    }

    fn sendConversationItem(self: *Self, text: []const u8) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator,
            \\{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"
        );
        try appendJsonEscaped(&json, self.allocator, text);
        try json.appendSlice(self.allocator, "\"}]}}");

        try self.ws.sendText(json.items);
    }

    fn sendResponseCreate(self: *Self) !void {
        try self.ws.sendText("{\"type\":\"response.create\",\"response\":{\"modalities\":[\"text\",\"audio\"]}}");
    }

    fn collectResponse(self: *Self) !void {
        var attempts: u32 = 0;
        while (attempts < 5000) : (attempts += 1) {
            const msg = try self.ws.receive() orelse return error.ConnectionClosed;
            defer self.allocator.free(msg);

            // Transcript delta
            if (std.mem.indexOf(u8, msg, "\"response.output_audio_transcript.delta\"") != null) {
                if (extractJsonField(msg, "delta")) |delta| {
                    try self.transcript_buf.appendSlice(self.allocator, delta);
                }
                continue;
            }

            // Audio delta (base64-encoded PCM)
            if (std.mem.indexOf(u8, msg, "\"response.output_audio.delta\"") != null) {
                if (extractJsonField(msg, "delta")) |b64_data| {
                    const decoded = decodeBase64(self.allocator, b64_data) catch continue;
                    defer self.allocator.free(decoded);
                    try self.audio_buf.appendSlice(self.allocator, decoded);
                }
                continue;
            }

            // Tool call complete
            if (std.mem.indexOf(u8, msg, "\"response.function_call_arguments.done\"") != null) {
                self.state = .tool_calling;
                const call_id = extractJsonField(msg, "call_id") orelse continue;
                const name = extractJsonField(msg, "name") orelse continue;
                const arguments = extractJsonField(msg, "arguments") orelse continue;

                try self.tool_calls_buf.append(self.allocator, .{
                    .call_id = try self.allocator.dupe(u8, call_id),
                    .name = try self.allocator.dupe(u8, name),
                    .arguments = try self.allocator.dupe(u8, arguments),
                    .allocator = self.allocator,
                });
                continue;
            }

            // Response done — break collection loop
            if (std.mem.indexOf(u8, msg, "\"response.done\"") != null) {
                return;
            }
        }
    }
};

/// Write a WAV file header + PCM data
pub fn writeWav(allocator: Allocator, pcm_data: []const u8, sample_rate: u32, bits_per_sample: u16, channels: u16) ![]u8 {
    const data_size: u32 = @intCast(pcm_data.len);
    const byte_rate: u32 = sample_rate * @as(u32, channels) * @as(u32, bits_per_sample) / 8;
    const block_align: u16 = channels * bits_per_sample / 8;
    const file_size: u32 = 36 + data_size;

    var buf = try allocator.alloc(u8, 44 + pcm_data.len);

    // RIFF header
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], file_size, .little);
    @memcpy(buf[8..12], "WAVE");

    // fmt chunk
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little); // chunk size
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM format
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], byte_rate, .little);
    std.mem.writeInt(u16, buf[32..34], block_align, .little);
    std.mem.writeInt(u16, buf[34..36], bits_per_sample, .little);

    // data chunk
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    @memcpy(buf[44..], pcm_data);

    return buf;
}

// ============================================================================
// Utilities
// ============================================================================

/// Extract a simple JSON string field value (no nested escaping)
fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    // Search for "field":"value"
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;

    const start = (std.mem.indexOf(u8, json, needle) orelse return null) + needle.len;
    if (start >= json.len) return null;

    // Find closing quote (handle escaped quotes)
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '"' and (end == start or json[end - 1] != '\\')) break;
    }
    if (end <= start or end > json.len) return null;

    return json[start..end];
}

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buffer = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buffer);
    decoder.Decoder.decode(buffer, encoded) catch return error.InvalidBase64;
    return buffer;
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try list.appendSlice(alloc, &buf);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
}

fn getTimestamp() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(@as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
}

// ============================================================================
// Tests
// ============================================================================

test "writeWav" {
    const allocator = std.testing.allocator;
    const pcm = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const wav = try writeWav(allocator, &pcm, 24000, 16, 1);
    defer allocator.free(wav);
    try std.testing.expect(wav.len == 44 + 8);
    try std.testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
}

test "extractJsonField" {
    const json = "{\"type\":\"response.done\",\"delta\":\"hello world\"}";
    const delta = extractJsonField(json, "delta");
    try std.testing.expect(delta != null);
    try std.testing.expectEqualSlices(u8, "hello world", delta.?);

    const missing = extractJsonField(json, "nonexistent");
    try std.testing.expect(missing == null);
}
