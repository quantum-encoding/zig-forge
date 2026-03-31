// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");

// Core HTTP client
pub const HttpClient = @import("http_client.zig").HttpClient;

// Connection pooling (legacy - has issues with Zig 0.16.0)
pub const pool = @import("pool/pool.zig");

// Client pooling (recommended - client-per-worker pattern)
pub const client_pool = @import("pool/client_pool.zig");

// Retry engine
pub const retry = @import("retry/retry.zig");

// Error definitions
pub const errors = @import("errors.zig");

// Encoding utilities (Base64)
pub const encoding = struct {
    pub const base64 = @import("encoding/base64.zig");
};

// AI provider clients (Claude, DeepSeek, Gemini, Grok, Vertex)
pub const ai = @import("ai.zig");

// Audio/TTS clients (OpenAI, Google)
pub const audio = @import("audio/mod.zig");

// Batch processing (CSV batch/parallel prompts)
pub const batch = @import("batch.zig");

// Re-export main types for convenience
pub const ConnectionPool = pool.ConnectionPool;
pub const ClientPool = client_pool.ClientPool;
pub const HttpWorker = client_pool.HttpWorker;
pub const RetryEngine = retry.RetryEngine;
pub const HttpError = errors.HttpError;

// AI exports
pub const AIClient = ai.AIClient;
pub const ClaudeClient = ai.ClaudeClient;
pub const DeepSeekClient = ai.DeepSeekClient;
pub const GeminiClient = ai.GeminiClient;
pub const GrokClient = ai.GrokClient;
pub const OpenAIClient = ai.OpenAIClient;
pub const VertexClient = ai.VertexClient;
pub const ResponseManager = ai.ResponseManager;

// Audio/TTS/STT exports
pub const OpenAITTSClient = audio.OpenAITTSClient;
pub const OpenAISTTClient = audio.OpenAISTTClient;
pub const GoogleTTSClient = audio.GoogleTTSClient;

test {
    std.testing.refAllDecls(@This());
}