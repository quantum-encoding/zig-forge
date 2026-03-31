// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! OpenAI Speech-to-Text client
//! Supports whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe
//!
//! API Documentation: https://platform.openai.com/docs/guides/speech-to-text

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const types = @import("types.zig");

pub const OpenAISTTClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const OPENAI_API_BASE = "https://api.openai.com/v1";
    const MAX_FILE_SIZE = 25 * 1024 * 1024; // 25 MB limit

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenAISTTClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAISTTClient) void {
        self.http_client.deinit();
    }

    /// Transcribe audio to text
    pub fn transcribe(self: *OpenAISTTClient, request: types.STTRequest) !types.STTResponse {
        if (request.audio_data.len > MAX_FILE_SIZE) {
            return types.STTError.FileTooLarge;
        }

        const response_body = try self.makeMultipartRequest(
            "/audio/transcriptions",
            request,
        );
        defer self.allocator.free(response_body);

        return self.parseResponse(response_body, request.response_format);
    }

    /// Transcribe audio file with default settings
    pub fn transcribeSimple(self: *OpenAISTTClient, audio_data: []const u8) !types.STTResponse {
        return self.transcribe(.{ .audio_data = audio_data });
    }

    /// Transcribe with a specific model
    pub fn transcribeWithModel(
        self: *OpenAISTTClient,
        audio_data: []const u8,
        model: types.STTModel,
    ) !types.STTResponse {
        return self.transcribe(.{
            .audio_data = audio_data,
            .model = model,
        });
    }

    /// Translate audio to English (whisper-1 only)
    pub fn translate(self: *OpenAISTTClient, audio_data: []const u8) !types.STTResponse {
        if (audio_data.len > MAX_FILE_SIZE) {
            return types.STTError.FileTooLarge;
        }

        const request = types.STTRequest{
            .audio_data = audio_data,
            .model = .whisper_1, // Translation only supports whisper-1
        };

        const response_body = try self.makeMultipartRequest(
            "/audio/translations",
            request,
        );
        defer self.allocator.free(response_body);

        return self.parseResponse(response_body, request.response_format);
    }

    fn makeMultipartRequest(
        self: *OpenAISTTClient,
        endpoint_path: []const u8,
        request: types.STTRequest,
    ) ![]u8 {
        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ OPENAI_API_BASE, endpoint_path },
        );
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        );
        defer self.allocator.free(auth_header);

        // Build multipart form data
        const boundary = "----ZigAudioBoundary7MA4YWxkTrZu0gW";
        const content_type = try std.fmt.allocPrint(
            self.allocator,
            "multipart/form-data; boundary={s}",
            .{boundary},
        );
        defer self.allocator.free(content_type);

        const body = try self.buildMultipartBody(boundary, request);
        defer self.allocator.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.post(endpoint, &headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn buildMultipartBody(
        self: *OpenAISTTClient,
        boundary: []const u8,
        request: types.STTRequest,
    ) ![]u8 {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        // File field
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "\r\n");
        const file_header = try std.fmt.allocPrint(self.allocator,
            "Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n",
            .{request.filename},
        );
        defer self.allocator.free(file_header);
        try body.appendSlice(self.allocator, file_header);
        try body.appendSlice(self.allocator, request.audio_data);
        try body.appendSlice(self.allocator, "\r\n");

        // Model field
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "\r\n");
        try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"model\"\r\n\r\n");
        try body.appendSlice(self.allocator, request.model.toString());
        try body.appendSlice(self.allocator, "\r\n");

        // Response format field
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "\r\n");
        try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n");
        try body.appendSlice(self.allocator, request.response_format.toString());
        try body.appendSlice(self.allocator, "\r\n");

        // Language field (optional)
        if (request.language) |lang| {
            try body.appendSlice(self.allocator, "--");
            try body.appendSlice(self.allocator, boundary);
            try body.appendSlice(self.allocator, "\r\n");
            try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"language\"\r\n\r\n");
            try body.appendSlice(self.allocator, lang);
            try body.appendSlice(self.allocator, "\r\n");
        }

        // Prompt field (optional)
        if (request.prompt) |prompt| {
            if (request.model.supportsPrompt()) {
                try body.appendSlice(self.allocator, "--");
                try body.appendSlice(self.allocator, boundary);
                try body.appendSlice(self.allocator, "\r\n");
                try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n");
                try body.appendSlice(self.allocator, prompt);
                try body.appendSlice(self.allocator, "\r\n");
            }
        }

        // Temperature field (if not default)
        if (request.temperature != 0.0) {
            try body.appendSlice(self.allocator, "--");
            try body.appendSlice(self.allocator, boundary);
            try body.appendSlice(self.allocator, "\r\n");
            try body.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"temperature\"\r\n\r\n");
            const temp_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{request.temperature});
            defer self.allocator.free(temp_str);
            try body.appendSlice(self.allocator, temp_str);
            try body.appendSlice(self.allocator, "\r\n");
        }

        // End boundary
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "--\r\n");

        return try body.toOwnedSlice(self.allocator);
    }

    fn parseResponse(
        self: *OpenAISTTClient,
        response_body: []const u8,
        format: types.STTResponseFormat,
    ) !types.STTResponse {
        switch (format) {
            .text, .srt, .vtt => {
                // Plain text response
                return types.STTResponse{
                    .text = try self.allocator.dupe(u8, response_body),
                    .allocator = self.allocator,
                };
            },
            .json, .verbose_json, .diarized_json => {
                // JSON response - extract text field
                const parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    response_body,
                    .{ .allocate = .alloc_always },
                );
                defer parsed.deinit();

                const text = if (parsed.value.object.get("text")) |t|
                    try self.allocator.dupe(u8, t.string)
                else
                    return types.STTError.InvalidResponse;

                var language: ?[]u8 = null;
                if (parsed.value.object.get("language")) |lang| {
                    language = try self.allocator.dupe(u8, lang.string);
                }

                var duration: ?f64 = null;
                if (parsed.value.object.get("duration")) |dur| {
                    duration = dur.float;
                }

                return types.STTResponse{
                    .text = text,
                    .language = language,
                    .duration = duration,
                    .allocator = self.allocator,
                };
            },
        }
    }

    fn handleErrorResponse(self: *OpenAISTTClient, status: std.http.Status) types.STTError {
        _ = self;
        return switch (status) {
            .unauthorized, .forbidden => types.STTError.InvalidApiKey,
            .too_many_requests => types.STTError.RateLimitExceeded,
            .bad_request => types.STTError.InvalidRequest,
            .payload_too_large => types.STTError.FileTooLarge,
            else => types.STTError.ServerError,
        };
    }

    // ============================================================
    // Helper configurations
    // ============================================================

    /// Default STT request (gpt-4o-mini-transcribe, text format)
    pub fn defaultRequest(audio_data: []const u8) types.STTRequest {
        return .{ .audio_data = audio_data };
    }

    /// High quality STT request (gpt-4o-transcribe)
    pub fn hqRequest(audio_data: []const u8) types.STTRequest {
        return .{
            .audio_data = audio_data,
            .model = .gpt_4o_transcribe,
        };
    }

    /// Whisper request with timestamps
    pub fn whisperRequest(audio_data: []const u8) types.STTRequest {
        return .{
            .audio_data = audio_data,
            .model = .whisper_1,
            .response_format = .verbose_json,
        };
    }
};

test "OpenAISTTClient initialization" {
    const allocator = std.testing.allocator;

    var client = try OpenAISTTClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
}

test "STTRequest defaults" {
    const req = OpenAISTTClient.defaultRequest("test");
    try std.testing.expectEqual(types.STTModel.gpt_4o_mini_transcribe, req.model);
    try std.testing.expectEqual(types.STTResponseFormat.text, req.response_format);
}
