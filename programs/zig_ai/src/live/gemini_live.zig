// Gemini Live Session — Core session logic
// Real-time WebSocket streaming for Gemini Live API
// Text/audio input -> text/audio response via wss://generativelanguage.googleapis.com

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ws_client = @import("ws_client.zig");

const LiveConfig = types.LiveConfig;
const SessionState = types.SessionState;
const FunctionCall = types.FunctionCall;
const LiveResponse = types.LiveResponse;
const Modality = types.Modality;

/// Gemini Live session
pub const GeminiLiveSession = struct {
    allocator: Allocator,
    ws: ws_client.GeminiWsClient,
    state: SessionState = .disconnected,
    config: LiveConfig = .{},

    // Accumulation buffers
    text_buf: std.ArrayListUnmanaged(u8),
    audio_buf: std.ArrayListUnmanaged(u8),
    output_transcript_buf: std.ArrayListUnmanaged(u8),
    input_transcript_buf: std.ArrayListUnmanaged(u8),
    function_calls_buf: std.ArrayListUnmanaged(FunctionCall),
    total_tokens: u32 = 0,

    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .ws = try ws_client.GeminiWsClient.init(allocator),
            .text_buf = .empty,
            .audio_buf = .empty,
            .output_transcript_buf = .empty,
            .input_transcript_buf = .empty,
            .function_calls_buf = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.text_buf.deinit(self.allocator);
        self.audio_buf.deinit(self.allocator);
        self.output_transcript_buf.deinit(self.allocator);
        self.input_transcript_buf.deinit(self.allocator);
        for (self.function_calls_buf.items) |*fc| fc.deinit();
        self.function_calls_buf.deinit(self.allocator);
        self.ws.deinit();
        self.allocator.destroy(self);
    }

    /// Connect to Gemini Live API and send setup config
    pub fn connect(self: *Self, api_key: []const u8, config: LiveConfig) !void {
        if (self.state != .disconnected) return error.AlreadyConnected;

        self.state = .connecting;
        self.config = config;
        errdefer self.state = .failed;

        try self.ws.connect(api_key);

        self.state = .setup_sent;

        // Send setup message
        try self.sendSetup();

        // Wait for setupComplete
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            const msg = try self.ws.receive() orelse return error.SetupFailed;
            defer self.allocator.free(msg);

            if (std.mem.indexOf(u8, msg, "\"setupComplete\"") != null) {
                self.state = .ready;
                return;
            }
        }

        return error.SetupFailed;
    }

    /// Send text and wait for complete response (turn)
    pub fn sendTextAndWait(self: *Self, text: []const u8) !LiveResponse {
        if (self.state != .ready) return error.NotConnected;

        const start_ts = getTimestamp();

        // Clear buffers
        self.clearBuffers();

        // Send clientContent with text
        try self.sendClientContent(text);

        self.state = .responding;

        // Collect until turnComplete
        try self.collectResponse();

        self.state = .ready;

        return self.buildResponse(start_ts);
    }

    /// Send tool responses and wait for model to continue
    pub fn sendToolResponseAndWait(self: *Self, responses: []const ToolResponse) !LiveResponse {
        if (self.state != .ready and self.state != .tool_calling) return error.NotConnected;

        const start_ts = getTimestamp();
        self.clearBuffers();

        // Build toolResponse message
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"toolResponse\":{\"functionResponses\":[");

        for (responses, 0..) |resp, i| {
            if (i > 0) try json.append(self.allocator, ',');
            try json.appendSlice(self.allocator, "{\"id\":\"");
            try json.appendSlice(self.allocator, resp.id);
            try json.appendSlice(self.allocator, "\",\"name\":\"");
            try json.appendSlice(self.allocator, resp.name);
            try json.appendSlice(self.allocator, "\",\"response\":{\"result\":\"");
            try appendJsonEscaped(&json, self.allocator, resp.output);
            try json.appendSlice(self.allocator, "\"}}");
        }

        try json.appendSlice(self.allocator, "]}}");
        try self.ws.sendText(json.items);

        self.state = .responding;
        try self.collectResponse();
        self.state = .ready;

        return self.buildResponse(start_ts);
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

    fn sendSetup(self: *Self) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"setup\":{\"model\":\"models/");
        try json.appendSlice(self.allocator, self.config.model);
        try json.appendSlice(self.allocator, "\"");

        // generationConfig
        try json.appendSlice(self.allocator, ",\"generationConfig\":{\"responseModalities\":[\"");
        try json.appendSlice(self.allocator, self.config.modality.toApiString());
        try json.appendSlice(self.allocator, "\"]");

        // Temperature
        var temp_buf: [32]u8 = undefined;
        const temp_str = std.fmt.bufPrint(&temp_buf, ",\"temperature\":{d}", .{self.config.temperature}) catch "";
        try json.appendSlice(self.allocator, temp_str);

        // Voice (for audio modality)
        if (self.config.voice) |voice| {
            try json.appendSlice(self.allocator, ",\"speechConfig\":{\"voiceConfig\":{\"prebuiltVoiceConfig\":{\"voiceName\":\"");
            try json.appendSlice(self.allocator, voice.toString());
            try json.appendSlice(self.allocator, "\"}}}");
        }

        try json.appendSlice(self.allocator, "}"); // close generationConfig

        // System instruction
        if (self.config.system_instruction) |sys| {
            try json.appendSlice(self.allocator, ",\"systemInstruction\":{\"parts\":[{\"text\":\"");
            try appendJsonEscaped(&json, self.allocator, sys);
            try json.appendSlice(self.allocator, "\"}]}");
        }

        // Transcription options
        if (self.config.output_transcription) {
            try json.appendSlice(self.allocator, ",\"outputAudioTranscription\":{}");
        }
        if (self.config.input_transcription) {
            try json.appendSlice(self.allocator, ",\"inputAudioTranscription\":{}");
        }

        // Context window compression
        if (self.config.context_compression) {
            try json.appendSlice(self.allocator, ",\"contextWindowCompression\":{\"slidingWindow\":{}}");
        }

        // Affective dialog
        if (self.config.affective_dialog) {
            try json.appendSlice(self.allocator, ",\"enableAffectiveDialog\":true");
        }

        // Proactive audio
        if (self.config.proactive_audio) {
            try json.appendSlice(self.allocator, ",\"proactivity\":{\"proactiveAudio\":true}");
        }

        // Thinking
        if (self.config.thinking_budget) |budget| {
            var budget_buf: [64]u8 = undefined;
            const budget_str = std.fmt.bufPrint(&budget_buf, ",\"thinkingConfig\":{{\"thinkingBudget\":{d}}}", .{budget}) catch "";
            try json.appendSlice(self.allocator, budget_str);
        }

        // Tools
        if (self.config.google_search) {
            try json.appendSlice(self.allocator, ",\"tools\":[{\"googleSearch\":{}}]");
        }

        // VAD configuration
        if (!self.config.vad.disabled) {
            try json.appendSlice(self.allocator, ",\"realtimeInputConfig\":{\"automaticActivityDetection\":{");
            try json.appendSlice(self.allocator, "\"startOfSpeechSensitivity\":\"");
            try json.appendSlice(self.allocator, self.config.vad.start_sensitivity.toApiString());
            try json.appendSlice(self.allocator, "\",\"endOfSpeechSensitivity\":\"");
            try json.appendSlice(self.allocator, self.config.vad.end_sensitivity.toApiString());
            try json.appendSlice(self.allocator, "\"}}");
        } else {
            try json.appendSlice(self.allocator, ",\"realtimeInputConfig\":{\"automaticActivityDetection\":{\"disabled\":true}}");
        }

        try json.appendSlice(self.allocator, "}}"); // close setup
        try self.ws.sendText(json.items);
    }

    fn sendClientContent(self: *Self, text: []const u8) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"clientContent\":{\"turns\":[{\"role\":\"user\",\"parts\":[{\"text\":\"");
        try appendJsonEscaped(&json, self.allocator, text);
        try json.appendSlice(self.allocator, "\"}]}],\"turnComplete\":true}}");

        try self.ws.sendText(json.items);
    }

    fn collectResponse(self: *Self) !void {
        var attempts: u32 = 0;
        while (attempts < 5000) : (attempts += 1) {
            const msg = try self.ws.receive() orelse return error.ConnectionClosed;
            defer self.allocator.free(msg);

            // Server content with model turn
            if (std.mem.indexOf(u8, msg, "\"serverContent\"") != null) {
                // Check for turnComplete
                if (std.mem.indexOf(u8, msg, "\"turnComplete\":true") != null) {
                    // Extract any text parts before returning
                    self.extractTextParts(msg);
                    return;
                }

                // Extract text parts from modelTurn
                self.extractTextParts(msg);

                // Extract audio data (base64 inlineData)
                if (std.mem.indexOf(u8, msg, "\"inlineData\"") != null) {
                    if (extractJsonField(msg, "data")) |b64| {
                        const decoded = decodeBase64(self.allocator, b64) catch continue;
                        defer self.allocator.free(decoded);
                        self.audio_buf.appendSlice(self.allocator, decoded) catch {};
                    }
                }

                // Output transcription
                if (std.mem.indexOf(u8, msg, "\"outputTranscription\"") != null) {
                    if (extractNestedTextField(msg, "outputTranscription")) |t| {
                        self.output_transcript_buf.appendSlice(self.allocator, t) catch {};
                    }
                }

                // Input transcription
                if (std.mem.indexOf(u8, msg, "\"inputTranscription\"") != null) {
                    if (extractNestedTextField(msg, "inputTranscription")) |t| {
                        self.input_transcript_buf.appendSlice(self.allocator, t) catch {};
                    }
                }

                // Interrupted
                if (std.mem.indexOf(u8, msg, "\"interrupted\":true") != null) {
                    self.audio_buf.clearRetainingCapacity();
                }

                continue;
            }

            // Tool call
            if (std.mem.indexOf(u8, msg, "\"toolCall\"") != null) {
                self.state = .tool_calling;
                self.extractFunctionCalls(msg);
                return;
            }

            // Usage metadata
            if (std.mem.indexOf(u8, msg, "\"usageMetadata\"") != null) {
                if (extractJsonField(msg, "totalTokenCount")) |tc| {
                    self.total_tokens = std.fmt.parseInt(u32, tc, 10) catch 0;
                }
                continue;
            }

            // GoAway message
            if (std.mem.indexOf(u8, msg, "\"goAway\"") != null) {
                continue;
            }
        }
    }

    fn extractTextParts(self: *Self, msg: []const u8) void {
        // Find "text":"..." within modelTurn parts
        // Simple extraction: look for "text":"<content>"
        var pos: usize = 0;
        while (pos < msg.len) {
            const needle = "\"text\":\"";
            const start = std.mem.indexOfPos(u8, msg, pos, needle) orelse break;
            const value_start = start + needle.len;
            if (value_start >= msg.len) break;

            // Skip if this is part of a setup/config key
            if (start > 0 and msg[start - 1] != ',' and msg[start - 1] != '{') {
                pos = value_start;
                continue;
            }

            // Find end of string value
            var end = value_start;
            while (end < msg.len) : (end += 1) {
                if (msg[end] == '"' and (end == value_start or msg[end - 1] != '\\')) break;
            }

            if (end > value_start and end < msg.len) {
                const text = msg[value_start..end];
                // Don't append the text parts that are role/modality identifiers
                if (!std.mem.eql(u8, text, "user") and
                    !std.mem.eql(u8, text, "model") and
                    !std.mem.eql(u8, text, "TEXT") and
                    !std.mem.eql(u8, text, "AUDIO"))
                {
                    if (self.text_buf.items.len > 0) {
                        self.text_buf.appendSlice(self.allocator, "") catch {};
                    }
                    self.text_buf.appendSlice(self.allocator, text) catch {};
                }
            }

            pos = end + 1;
        }
    }

    fn extractFunctionCalls(self: *Self, msg: []const u8) void {
        // Look for functionCalls array entries: {"id":"...","name":"...","args":{...}}
        var pos: usize = 0;
        while (pos < msg.len) {
            const fc_start = std.mem.indexOfPos(u8, msg, pos, "\"functionCalls\"") orelse break;
            pos = fc_start + 14;

            // Extract individual function calls
            while (pos < msg.len) {
                const id = extractJsonFieldFrom(msg, pos, "id") orelse break;
                const name = extractJsonFieldFrom(msg, pos, "name") orelse break;

                // For args, find "args":{...}
                const args_needle = "\"args\":";
                const args_start = std.mem.indexOfPos(u8, msg, pos, args_needle) orelse break;
                const args_obj_start = args_start + args_needle.len;

                // Find matching closing brace
                var depth: i32 = 0;
                var args_end = args_obj_start;
                while (args_end < msg.len) : (args_end += 1) {
                    if (msg[args_end] == '{') depth += 1;
                    if (msg[args_end] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            args_end += 1;
                            break;
                        }
                    }
                }

                const args = if (args_end > args_obj_start) msg[args_obj_start..args_end] else "{}";

                self.function_calls_buf.append(self.allocator, .{
                    .id = self.allocator.dupe(u8, id) catch break,
                    .name = self.allocator.dupe(u8, name) catch break,
                    .args = self.allocator.dupe(u8, args) catch break,
                    .allocator = self.allocator,
                }) catch break;

                pos = args_end;
            }
            break;
        }
    }

    fn clearBuffers(self: *Self) void {
        self.text_buf.clearRetainingCapacity();
        self.audio_buf.clearRetainingCapacity();
        self.output_transcript_buf.clearRetainingCapacity();
        self.input_transcript_buf.clearRetainingCapacity();
        for (self.function_calls_buf.items) |*fc| fc.deinit();
        self.function_calls_buf.clearRetainingCapacity();
        self.total_tokens = 0;
    }

    fn buildResponse(self: *Self, start_ts: u64) !LiveResponse {
        const elapsed = getTimestamp() - start_ts;

        const text = if (self.text_buf.items.len > 0)
            try self.allocator.dupe(u8, self.text_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const audio = if (self.audio_buf.items.len > 0)
            try self.allocator.dupe(u8, self.audio_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const out_transcript = if (self.output_transcript_buf.items.len > 0)
            try self.allocator.dupe(u8, self.output_transcript_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const in_transcript = if (self.input_transcript_buf.items.len > 0)
            try self.allocator.dupe(u8, self.input_transcript_buf.items)
        else
            try self.allocator.alloc(u8, 0);

        const function_calls = if (self.function_calls_buf.items.len > 0)
            try self.allocator.dupe(FunctionCall, self.function_calls_buf.items)
        else
            try self.allocator.alloc(FunctionCall, 0);

        // Ownership transferred
        self.function_calls_buf.clearRetainingCapacity();

        return LiveResponse{
            .text = text,
            .audio_data = audio,
            .output_transcript = out_transcript,
            .input_transcript = in_transcript,
            .function_calls = function_calls,
            .processing_time_ms = elapsed,
            .total_tokens = self.total_tokens,
            .allocator = self.allocator,
        };
    }
};

/// Tool response to send back to the model
pub const ToolResponse = struct {
    id: []const u8,
    name: []const u8,
    output: []const u8,
};

/// Write a WAV file header + PCM data (24kHz, 16-bit, mono)
pub fn writeWav(allocator: Allocator, pcm_data: []const u8) ![]u8 {
    const data_size: u32 = @intCast(pcm_data.len);
    const sample_rate: u32 = 24000;
    const bits_per_sample: u16 = 16;
    const channels: u16 = 1;
    const byte_rate: u32 = sample_rate * @as(u32, channels) * @as(u32, bits_per_sample) / 8;
    const block_align: u16 = channels * bits_per_sample / 8;
    const file_size: u32 = 36 + data_size;

    var buf = try allocator.alloc(u8, 44 + pcm_data.len);

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], file_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], byte_rate, .little);
    std.mem.writeInt(u16, buf[32..34], block_align, .little);
    std.mem.writeInt(u16, buf[34..36], bits_per_sample, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    @memcpy(buf[44..], pcm_data);

    return buf;
}

// ============================================================================
// Utilities
// ============================================================================

fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    return extractJsonFieldFrom(json, 0, field);
}

fn extractJsonFieldFrom(json: []const u8, from: usize, field: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;

    const start = (std.mem.indexOfPos(u8, json, from, needle) orelse return null) + needle.len;
    if (start >= json.len) return null;

    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '"' and (end == start or json[end - 1] != '\\')) break;
    }
    if (end <= start or end > json.len) return null;

    return json[start..end];
}

fn extractNestedTextField(json: []const u8, section: []const u8) ?[]const u8 {
    // Find "section":{"text":"..."}
    const section_start = std.mem.indexOf(u8, json, section) orelse return null;
    return extractJsonFieldFrom(json, section_start, "text");
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

test "extractJsonField" {
    const json = "{\"type\":\"serverContent\",\"text\":\"hello\"}";
    const text = extractJsonField(json, "text");
    try std.testing.expect(text != null);
    try std.testing.expectEqualSlices(u8, "hello", text.?);
}
