// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! High-Performance AI Provider Clients for Zig
//!
//! Unified interface for multiple AI providers:
//! - Claude (Anthropic)
//! - DeepSeek (Anthropic-compatible, ultra-affordable)
//! - Gemini (Google)
//! - Grok (X.AI)
//! - OpenAI (GPT-5.x)
//! - Vertex AI (Google Cloud — Gemini + Model Garden MaaS)
//! - ElevenLabs (voice synthesis, TTS, cloning, dubbing)
//! - Meshy (3D generation — text/image to 3D, remesh, retexture, rig, animate)
//! - HeyGen (video synthesis — digital humans, avatars)
//!
//! Features:
//! - Production-grade HTTP client (zig-http-sentinel)
//! - Thread-safe response management
//! - Conversation context tracking
//! - Token usage and cost estimation
//! - Agentic loops with tool calling support (coming soon)
//! - Export conversations to JSON/Markdown

const std = @import("std");

// Core types and utilities
pub const common = @import("ai/common.zig");
pub const ResponseManager = @import("ai/response_manager.zig").ResponseManager;

// Provider clients — text generation
pub const ClaudeClient = @import("ai/claude.zig").ClaudeClient;
pub const DeepSeekClient = @import("ai/deepseek.zig").DeepSeekClient;
pub const GeminiClient = @import("ai/gemini.zig").GeminiClient;
pub const GrokClient = @import("ai/grok.zig").GrokClient;
pub const OpenAIClient = @import("ai/openai.zig").OpenAIClient;
pub const VertexClient = @import("ai/vertex.zig").VertexClient;

// Specialized media providers
pub const ElevenLabsClient = @import("ai/elevenlabs.zig").ElevenLabsClient;
pub const MeshyClient = @import("ai/meshy.zig").MeshyClient;
pub const HeyGenClient = @import("ai/heygen.zig").HeyGenClient;

// Re-export commonly used types
pub const AIError = common.AIError;
pub const AIMessage = common.AIMessage;
pub const AIResponse = common.AIResponse;
pub const RequestConfig = common.RequestConfig;
pub const ConversationContext = common.ConversationContext;
pub const UsageStats = common.UsageStats;

/// Provider identifier
pub const Provider = enum {
    claude,
    deepseek,
    gemini,
    grok,
    openai,
    vertex,

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .deepseek => "deepseek",
            .gemini => "gemini",
            .grok => "grok",
            .openai => "openai",
            .vertex => "vertex",
        };
    }
};

/// Unified AI client that can work with any provider
pub const AIClient = struct {
    provider: Provider,
    claude: ?ClaudeClient = null,
    deepseek: ?DeepSeekClient = null,
    gemini: ?GeminiClient = null,
    grok: ?GrokClient = null,
    openai: ?OpenAIClient = null,
    vertex: ?VertexClient = null,
    allocator: std.mem.Allocator,

    /// Initialize client for a specific provider
    pub fn init(allocator: std.mem.Allocator, provider: Provider, config: ProviderConfig) !AIClient {
        var client = AIClient{
            .provider = provider,
            .allocator = allocator,
        };

        switch (provider) {
            .claude => {
                client.claude = try ClaudeClient.init(allocator, config.api_key.?);
            },
            .deepseek => {
                client.deepseek = try DeepSeekClient.init(allocator, config.api_key.?);
            },
            .gemini => {
                client.gemini = try GeminiClient.init(allocator, config.api_key.?);
            },
            .grok => {
                client.grok = try GrokClient.init(allocator, config.api_key.?);
            },
            .openai => {
                client.openai = try OpenAIClient.init(allocator, config.api_key.?);
            },
            .vertex => {
                client.vertex = try VertexClient.init(allocator, .{
                    .project_id = config.project_id.?,
                    .location = config.location orelse "us-central1",
                });
            },
        }

        return client;
    }

    pub fn deinit(self: *AIClient) void {
        switch (self.provider) {
            .claude => if (self.claude) |*c| c.deinit(),
            .deepseek => if (self.deepseek) |*c| c.deinit(),
            .gemini => if (self.gemini) |*c| c.deinit(),
            .grok => if (self.grok) |*c| c.deinit(),
            .openai => if (self.openai) |*c| c.deinit(),
            .vertex => if (self.vertex) |*c| c.deinit(),
        }
    }

    /// Send a message to the AI provider
    pub fn sendMessage(
        self: *AIClient,
        prompt: []const u8,
        config: RequestConfig,
    ) !AIResponse {
        return switch (self.provider) {
            .claude => self.claude.?.sendMessage(prompt, config),
            .deepseek => self.deepseek.?.sendMessage(prompt, config),
            .gemini => self.gemini.?.sendMessage(prompt, config),
            .grok => self.grok.?.sendMessage(prompt, config),
            .openai => self.openai.?.sendMessage(prompt, config),
            .vertex => self.vertex.?.sendMessage(prompt, config),
        };
    }

    /// Stream a message — calls callback per token chunk
    pub fn sendMessageStreaming(
        self: *AIClient,
        prompt: []const u8,
        config: RequestConfig,
        callback: common.StreamCallback,
        context: ?*anyopaque,
    ) !void {
        return switch (self.provider) {
            .claude => self.claude.?.client.sendMessageStreaming(prompt, config, callback, context),
            .deepseek => self.deepseek.?.client.sendMessageStreaming(prompt, config, callback, context),
            .gemini => self.gemini.?.sendMessageStreaming(prompt, config, callback, context),
            .grok => self.grok.?.sendMessageStreaming(prompt, config, callback, context),
            .openai => self.openai.?.sendMessageStreaming(prompt, config, callback, context),
            .vertex => return error.ProviderUnavailable, // Vertex streaming TBD
        };
    }

    /// Stream a message with full conversation history — calls callback per token chunk
    pub fn sendMessageStreamingWithContext(
        self: *AIClient,
        prompt: []const u8,
        chat_context: []const AIMessage,
        config: RequestConfig,
        callback: common.StreamCallback,
        cb_context: ?*anyopaque,
    ) !void {
        return switch (self.provider) {
            .claude => self.claude.?.client.sendMessageStreamingWithContext(prompt, chat_context, config, callback, cb_context),
            // Other providers: fall back to single-prompt streaming for now
            .deepseek => self.deepseek.?.client.sendMessageStreaming(prompt, config, callback, cb_context),
            .gemini => self.gemini.?.sendMessageStreaming(prompt, config, callback, cb_context),
            .grok => self.grok.?.sendMessageStreaming(prompt, config, callback, cb_context),
            .openai => self.openai.?.sendMessageStreaming(prompt, config, callback, cb_context),
            .vertex => return error.ProviderUnavailable,
        };
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *AIClient,
        prompt: []const u8,
        context: []const AIMessage,
        config: RequestConfig,
    ) !AIResponse {
        return switch (self.provider) {
            .claude => self.claude.?.sendMessageWithContext(prompt, context, config),
            .deepseek => self.deepseek.?.sendMessageWithContext(prompt, context, config),
            .gemini => self.gemini.?.sendMessageWithContext(prompt, context, config),
            .grok => self.grok.?.sendMessageWithContext(prompt, context, config),
            .openai => self.openai.?.sendMessageWithContext(prompt, context, config),
            .vertex => self.vertex.?.sendMessageWithContext(prompt, context, config),
        };
    }
};

/// Configuration for initializing a provider client
pub const ProviderConfig = struct {
    /// API key (required for Claude, DeepSeek, Gemini, Grok)
    api_key: ?[]const u8 = null,

    /// Project ID (required for Vertex AI)
    project_id: ?[]const u8 = null,

    /// Location (optional, for Vertex AI, defaults to us-central1)
    location: ?[]const u8 = null,
};

/// Get API key from environment variable (pure Zig — no libc)
pub fn getApiKeyFromEnv(environ_map: *const std.process.Environ.Map, var_name: []const u8) ![]const u8 {
    return environ_map.get(var_name) orelse {
        std.debug.print("Error: Environment variable '{s}' not set\n", .{var_name});
        return error.EnvironmentVariableNotFound;
    };
}

/// Pricing information for all providers (as of 2026-03)
pub const Pricing = struct {
    /// Claude Sonnet 4.6 pricing (per 1M tokens)
    pub const CLAUDE_SONNET_INPUT = 3.0;
    pub const CLAUDE_SONNET_OUTPUT = 15.0;

    /// Claude Opus 4.6 pricing (per 1M tokens)
    pub const CLAUDE_OPUS_INPUT = 5.0;
    pub const CLAUDE_OPUS_OUTPUT = 25.0;

    /// Claude Haiku pricing (per 1M tokens)
    pub const CLAUDE_HAIKU_INPUT = 0.25;
    pub const CLAUDE_HAIKU_OUTPUT = 1.25;

    /// DeepSeek pricing (per 1M tokens) - Ultra affordable!
    pub const DEEPSEEK_INPUT = 0.14;
    pub const DEEPSEEK_OUTPUT = 0.28;

    /// Gemini pricing varies by region and model
    /// These are approximate US prices (per 1M tokens)
    pub const GEMINI_PRO_INPUT = 1.25;
    pub const GEMINI_PRO_OUTPUT = 5.0;
    pub const GEMINI_FLASH_INPUT = 0.075;
    pub const GEMINI_FLASH_OUTPUT = 0.30;

    /// Grok pricing (per 1M tokens)
    pub const GROK_INPUT = 5.0;
    pub const GROK_OUTPUT = 15.0;

    // Note: Vertex AI uses same Gemini pricing but with enterprise support
};

test "AIClient initialization" {
    const allocator = std.testing.allocator;

    var client = try AIClient.init(allocator, .deepseek, .{
        .api_key = "test-key",
    });
    defer client.deinit();

    try std.testing.expectEqual(Provider.deepseek, client.provider);
}

test {
    std.testing.refAllDecls(@This());
}
