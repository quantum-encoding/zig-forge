// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Google Gemini Text-to-Speech client
//! Supports gemini-2.5-flash-preview-tts and gemini-2.5-pro-preview-tts
//!
//! API Documentation: https://ai.google.dev/gemini-api/docs/speech-generation
//!
//! Key differences from OpenAI TTS:
//! - Uses generateContent API with AUDIO response modality
//! - Output is base64-encoded PCM (24kHz, 16-bit LE, mono)
//! - 30 prebuilt voices with different styles
//! - Supports multi-speaker TTS (up to 2 speakers)
//! - Controllable via natural language prompts (style, accent, pace)

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const types = @import("types.zig");

pub const GoogleTTSClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const GOOGLE_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
    const MAX_CONTEXT_TOKENS = 32000; // 32k token context window limit

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GoogleTTSClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GoogleTTSClient) void {
        self.http_client.deinit();
    }

    /// Generate speech from text (single speaker)
    pub fn speak(self: *GoogleTTSClient, request: types.GoogleTTSRequest) !types.GoogleTTSResponse {
        const payload = if (request.speakers) |speakers|
            try self.buildMultiSpeakerPayload(request, speakers)
        else
            try self.buildSingleSpeakerPayload(request);
        defer self.allocator.free(payload);

        const audio_data = try self.makeRequest(request.model, payload);

        return types.GoogleTTSResponse{
            .audio_data = audio_data,
            .allocator = self.allocator,
        };
    }

    /// Generate speech with default settings (Kore voice, Flash model)
    pub fn speakSimple(self: *GoogleTTSClient, text: []const u8) !types.GoogleTTSResponse {
        return self.speak(.{ .text = text });
    }

    /// Generate speech with a specific voice
    pub fn speakWithVoice(
        self: *GoogleTTSClient,
        text: []const u8,
        voice: types.GoogleVoice,
    ) !types.GoogleTTSResponse {
        return self.speak(.{ .text = text, .voice = voice });
    }

    /// Generate multi-speaker conversation
    pub fn speakMultiSpeaker(
        self: *GoogleTTSClient,
        text: []const u8,
        speakers: []const types.SpeakerConfig,
    ) !types.GoogleTTSResponse {
        return self.speak(.{
            .text = text,
            .speakers = speakers,
        });
    }

    fn buildSingleSpeakerPayload(self: *GoogleTTSClient, request: types.GoogleTTSRequest) ![]u8 {
        // Escape text for JSON
        const escaped_text = try self.escapeJson(request.text);
        defer self.allocator.free(escaped_text);

        return std.fmt.allocPrint(self.allocator,
            \\{{"contents":[{{"parts":[{{"text":"{s}"}}]}}],"generationConfig":{{"responseModalities":["AUDIO"],"speechConfig":{{"voiceConfig":{{"prebuiltVoiceConfig":{{"voiceName":"{s}"}}}}}}}}}}
        , .{
            escaped_text,
            request.voice.toString(),
        });
    }

    fn buildMultiSpeakerPayload(
        self: *GoogleTTSClient,
        request: types.GoogleTTSRequest,
        speakers: []const types.SpeakerConfig,
    ) ![]u8 {
        // Escape text for JSON
        const escaped_text = try self.escapeJson(request.text);
        defer self.allocator.free(escaped_text);

        // Build speaker configs array
        var speaker_configs: std.ArrayList(u8) = .empty;
        defer speaker_configs.deinit(self.allocator);

        for (speakers, 0..) |speaker, i| {
            if (i > 0) {
                try speaker_configs.append(self.allocator, ',');
            }
            const config = try std.fmt.allocPrint(self.allocator,
                \\{{"speaker":"{s}","voiceConfig":{{"prebuiltVoiceConfig":{{"voiceName":"{s}"}}}}}}
            , .{ speaker.name, speaker.voice.toString() });
            defer self.allocator.free(config);
            try speaker_configs.appendSlice(self.allocator, config);
        }

        return std.fmt.allocPrint(self.allocator,
            \\{{"contents":[{{"parts":[{{"text":"{s}"}}]}}],"generationConfig":{{"responseModalities":["AUDIO"],"speechConfig":{{"multiSpeakerVoiceConfig":{{"speakerVoiceConfigs":[{s}]}}}}}}}}
        , .{
            escaped_text,
            speaker_configs.items,
        });
    }

    fn escapeJson(self: *GoogleTTSClient, text: []const u8) ![]u8 {
        var escaped: std.ArrayList(u8) = .empty;
        errdefer escaped.deinit(self.allocator);

        for (text) |c| {
            switch (c) {
                '"' => try escaped.appendSlice(self.allocator, "\\\""),
                '\\' => try escaped.appendSlice(self.allocator, "\\\\"),
                '\n' => try escaped.appendSlice(self.allocator, "\\n"),
                '\r' => try escaped.appendSlice(self.allocator, "\\r"),
                '\t' => try escaped.appendSlice(self.allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try escaped.appendSlice(self.allocator, hex);
                    } else {
                        try escaped.append(self.allocator, c);
                    }
                },
            }
        }

        return try escaped.toOwnedSlice(self.allocator);
    }

    fn makeRequest(self: *GoogleTTSClient, model: types.GoogleTTSModel, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}:generateContent?key={s}",
            .{ GOOGLE_API_BASE, model.toString(), self.api_key },
        );
        defer self.allocator.free(endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        // Parse response and extract base64 audio data
        return self.parseResponse(response.body);
    }

    fn parseResponse(self: *GoogleTTSClient, response_body: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always },
        ) catch {
            return types.GoogleTTSError.InvalidResponse;
        };
        defer parsed.deinit();

        // Navigate: candidates[0].content.parts[0].inlineData.data
        const candidates = parsed.value.object.get("candidates") orelse
            return types.GoogleTTSError.InvalidResponse;
        if (candidates.array.items.len == 0)
            return types.GoogleTTSError.InvalidResponse;

        const content = candidates.array.items[0].object.get("content") orelse
            return types.GoogleTTSError.InvalidResponse;
        const parts = content.object.get("parts") orelse
            return types.GoogleTTSError.InvalidResponse;
        if (parts.array.items.len == 0)
            return types.GoogleTTSError.InvalidResponse;

        const inline_data = parts.array.items[0].object.get("inlineData") orelse
            return types.GoogleTTSError.InvalidResponse;
        const data = inline_data.object.get("data") orelse
            return types.GoogleTTSError.InvalidResponse;

        // Decode base64 audio data
        const base64_data = data.string;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64_data) catch
            return types.GoogleTTSError.Base64DecodeError;
        const audio_data = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(audio_data);

        std.base64.standard.Decoder.decode(audio_data, base64_data) catch
            return types.GoogleTTSError.Base64DecodeError;

        return audio_data;
    }

    fn handleErrorResponse(self: *GoogleTTSClient, status: std.http.Status) types.GoogleTTSError {
        _ = self;
        return switch (status) {
            .unauthorized, .forbidden => types.GoogleTTSError.InvalidApiKey,
            .too_many_requests => types.GoogleTTSError.RateLimitExceeded,
            .bad_request => types.GoogleTTSError.InvalidRequest,
            else => types.GoogleTTSError.ServerError,
        };
    }

    // ============================================================
    // Helper configurations
    // ============================================================

    /// Default TTS request (Kore voice, Flash model)
    pub fn defaultRequest(text: []const u8) types.GoogleTTSRequest {
        return .{ .text = text };
    }

    /// Pro quality TTS request
    pub fn proRequest(text: []const u8, voice: types.GoogleVoice) types.GoogleTTSRequest {
        return .{
            .text = text,
            .voice = voice,
            .model = .gemini_2_5_pro_tts,
        };
    }

    /// Create a conversation between two speakers
    pub fn conversationRequest(
        text: []const u8,
        speaker1_name: []const u8,
        speaker1_voice: types.GoogleVoice,
        speaker2_name: []const u8,
        speaker2_voice: types.GoogleVoice,
    ) types.GoogleTTSRequest {
        const speakers = &[_]types.SpeakerConfig{
            .{ .name = speaker1_name, .voice = speaker1_voice },
            .{ .name = speaker2_name, .voice = speaker2_voice },
        };
        return .{
            .text = text,
            .speakers = speakers,
        };
    }
};

test "GoogleTTSClient initialization" {
    const allocator = std.testing.allocator;

    var client = try GoogleTTSClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "GoogleTTSRequest defaults" {
    const req = GoogleTTSClient.defaultRequest("Hello");
    try std.testing.expectEqualStrings("Hello", req.text);
    try std.testing.expectEqual(types.GoogleVoice.kore, req.voice);
    try std.testing.expectEqual(types.GoogleTTSModel.gemini_2_5_flash_tts, req.model);
}
