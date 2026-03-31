// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! OpenAI Text-to-Speech client
//! Supports gpt-4o-mini-tts, tts-1, and tts-1-hd models
//!
//! API Documentation: https://platform.openai.com/docs/guides/text-to-speech

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const types = @import("types.zig");

pub const OpenAITTSClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const OPENAI_API_BASE = "https://api.openai.com/v1";
    const MAX_TEXT_LENGTH = 4096; // OpenAI limit

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenAITTSClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAITTSClient) void {
        self.http_client.deinit();
    }

    /// Generate speech from text
    pub fn speak(self: *OpenAITTSClient, request: types.TTSRequest) !types.TTSResponse {
        if (request.text.len > MAX_TEXT_LENGTH) {
            return types.TTSError.TextTooLong;
        }

        const payload = try self.buildRequestPayload(request);
        defer self.allocator.free(payload);

        const audio_data = try self.makeRequest(payload);

        return types.TTSResponse{
            .audio_data = audio_data,
            .format = request.format,
            .allocator = self.allocator,
        };
    }

    /// Generate speech with default settings (coral voice, mp3 format)
    pub fn speakSimple(self: *OpenAITTSClient, text: []const u8) !types.TTSResponse {
        return self.speak(.{ .text = text });
    }

    /// Generate speech with a specific voice
    pub fn speakWithVoice(
        self: *OpenAITTSClient,
        text: []const u8,
        voice: types.Voice,
    ) !types.TTSResponse {
        return self.speak(.{ .text = text, .voice = voice });
    }

    /// Generate speech with instructions (gpt-4o-mini-tts only)
    pub fn speakWithInstructions(
        self: *OpenAITTSClient,
        text: []const u8,
        voice: types.Voice,
        instructions: []const u8,
    ) !types.TTSResponse {
        return self.speak(.{
            .text = text,
            .voice = voice,
            .model = .gpt_4o_mini_tts,
            .instructions = instructions,
        });
    }

    fn buildRequestPayload(self: *OpenAITTSClient, request: types.TTSRequest) ![]u8 {
        // Escape text for JSON
        var escaped_text: std.ArrayList(u8) = .empty;
        defer escaped_text.deinit(self.allocator);

        for (request.text) |c| {
            switch (c) {
                '"' => try escaped_text.appendSlice(self.allocator, "\\\""),
                '\\' => try escaped_text.appendSlice(self.allocator, "\\\\"),
                '\n' => try escaped_text.appendSlice(self.allocator, "\\n"),
                '\r' => try escaped_text.appendSlice(self.allocator, "\\r"),
                '\t' => try escaped_text.appendSlice(self.allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try escaped_text.appendSlice(self.allocator, hex);
                    } else {
                        try escaped_text.append(self.allocator, c);
                    }
                },
            }
        }

        // Build optional parts
        var optional_parts: std.ArrayList(u8) = .empty;
        defer optional_parts.deinit(self.allocator);

        // Add instructions if provided and model supports it
        if (request.instructions) |instructions| {
            if (request.model.supportsInstructions()) {
                // Escape instructions
                var escaped_instructions: std.ArrayList(u8) = .empty;
                defer escaped_instructions.deinit(self.allocator);

                for (instructions) |c| {
                    switch (c) {
                        '"' => try escaped_instructions.appendSlice(self.allocator, "\\\""),
                        '\\' => try escaped_instructions.appendSlice(self.allocator, "\\\\"),
                        '\n' => try escaped_instructions.appendSlice(self.allocator, "\\n"),
                        else => try escaped_instructions.append(self.allocator, c),
                    }
                }

                const instr_part = try std.fmt.allocPrint(self.allocator,
                    \\,"instructions":"{s}"
                , .{escaped_instructions.items});
                defer self.allocator.free(instr_part);
                try optional_parts.appendSlice(self.allocator, instr_part);
            }
        }

        // Add speed if not default
        if (request.speed != 1.0) {
            const speed_part = try std.fmt.allocPrint(self.allocator,
                \\,"speed":{d:.2}
            , .{request.speed});
            defer self.allocator.free(speed_part);
            try optional_parts.appendSlice(self.allocator, speed_part);
        }

        return std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","input":"{s}","voice":"{s}","response_format":"{s}"{s}}}
        , .{
            request.model.toString(),
            escaped_text.items,
            request.voice.toString(),
            request.format.toString(),
            optional_parts.items,
        });
    }

    fn makeRequest(self: *OpenAITTSClient, payload: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/audio/speech",
            .{OPENAI_API_BASE},
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
            return self.handleErrorResponse(response.status);
        }

        // Response body is raw audio data
        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(self: *OpenAITTSClient, status: std.http.Status) types.TTSError {
        _ = self;
        return switch (status) {
            .unauthorized, .forbidden => types.TTSError.InvalidApiKey,
            .too_many_requests => types.TTSError.RateLimitExceeded,
            .bad_request => types.TTSError.InvalidRequest,
            else => types.TTSError.ServerError,
        };
    }

    // ============================================================
    // Helper configurations
    // ============================================================

    /// Default TTS request (coral voice, mp3, gpt-4o-mini-tts)
    pub fn defaultRequest(text: []const u8) types.TTSRequest {
        return .{ .text = text };
    }

    /// High quality TTS request (tts-1-hd model)
    pub fn hdRequest(text: []const u8, voice: types.Voice) types.TTSRequest {
        return .{
            .text = text,
            .voice = voice,
            .model = .tts_1_hd,
        };
    }

    /// Low latency TTS request (tts-1 model, wav format)
    pub fn lowLatencyRequest(text: []const u8, voice: types.Voice) types.TTSRequest {
        return .{
            .text = text,
            .voice = voice,
            .model = .tts_1,
            .format = .wav,
        };
    }
};

test "OpenAITTSClient initialization" {
    const allocator = std.testing.allocator;

    var client = try OpenAITTSClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "TTSRequest defaults" {
    const req = OpenAITTSClient.defaultRequest("Hello");
    try std.testing.expectEqualStrings("Hello", req.text);
    try std.testing.expectEqual(types.Voice.coral, req.voice);
    try std.testing.expectEqual(types.TTSModel.gpt_4o_mini_tts, req.model);
    try std.testing.expectEqual(types.AudioFormat.mp3, req.format);
}
