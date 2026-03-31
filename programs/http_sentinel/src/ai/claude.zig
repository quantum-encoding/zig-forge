// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Claude (Anthropic) AI client
//! High-level wrapper around the Anthropic API client

const std = @import("std");
const anthropic = @import("anthropic.zig");
const common = @import("common.zig");

pub const ClaudeClient = struct {
    client: anthropic.AnthropicClient,

    const CLAUDE_API_BASE = "https://api.anthropic.com";

    /// Available Claude models
    pub const Models = struct {
        pub const SONNET_4_5 = "claude-sonnet-4-5-20250929";
        pub const SONNET_4 = "claude-sonnet-4-20250514";
        pub const OPUS_4_1 = "claude-opus-4-1-20250805";
        pub const HAIKU = "claude-3-haiku-20240307";
        pub const SONNET_3_5 = "claude-3-5-sonnet-20240620";
    };

    /// Initialize Claude client with API key
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !ClaudeClient {
        return .{
            .client = try anthropic.AnthropicClient.init(allocator, .{
                .api_key = api_key,
                .base_url = CLAUDE_API_BASE,
                .provider_name = "claude",
            }),
        };
    }

    pub fn deinit(self: *ClaudeClient) void {
        self.client.deinit();
    }

    /// Send a single message to Claude
    pub fn sendMessage(
        self: *ClaudeClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.client.sendMessage(prompt, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *ClaudeClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.client.sendMessageWithContext(prompt, context, config);
    }

    /// Helper: Create default config for Claude Sonnet 4.5
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.SONNET_4_5,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for fast responses (Haiku)
    pub fn fastConfig() common.RequestConfig {
        return .{
            .model = Models.HAIKU,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for deep thinking (Opus)
    pub fn deepConfig() common.RequestConfig {
        return .{
            .model = Models.OPUS_4_1,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }
};

test "ClaudeClient initialization" {
    const allocator = std.testing.allocator;

    var client = try ClaudeClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("claude", client.client.provider_name);
}

test "ClaudeClient config helpers" {
    const default_cfg = ClaudeClient.defaultConfig();
    try std.testing.expectEqualStrings(ClaudeClient.Models.SONNET_4_5, default_cfg.model);
    try std.testing.expectEqual(@as(u32, 8000), default_cfg.max_tokens);

    const fast_cfg = ClaudeClient.fastConfig();
    try std.testing.expectEqualStrings(ClaudeClient.Models.HAIKU, fast_cfg.model);

    const deep_cfg = ClaudeClient.deepConfig();
    try std.testing.expectEqualStrings(ClaudeClient.Models.OPUS_4_1, deep_cfg.model);
    try std.testing.expectEqual(@as(u32, 16000), deep_cfg.max_tokens);
}
