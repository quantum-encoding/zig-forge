// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! DeepSeek AI client
//! Uses Anthropic API compatibility layer
//!
//! DeepSeek supports Anthropic's API format at:
//! https://api.deepseek.com/anthropic
//!
//! Reference: https://api-docs.deepseek.com/guides/anthropic_api

const std = @import("std");
const anthropic = @import("anthropic.zig");
const common = @import("common.zig");

pub const DeepSeekClient = struct {
    client: anthropic.AnthropicClient,

    const DEEPSEEK_ANTHROPIC_BASE = "https://api.deepseek.com/anthropic";

    /// Available DeepSeek models
    pub const Models = struct {
        pub const CHAT = "deepseek-chat";
        pub const REASONER = "deepseek-reasoner";
    };

    /// Initialize DeepSeek client with API key
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !DeepSeekClient {
        return .{
            .client = try anthropic.AnthropicClient.init(allocator, .{
                .api_key = api_key,
                .base_url = DEEPSEEK_ANTHROPIC_BASE,
                .provider_name = "deepseek",
            }),
        };
    }

    pub fn deinit(self: *DeepSeekClient) void {
        self.client.deinit();
    }

    /// Send a single message to DeepSeek
    pub fn sendMessage(
        self: *DeepSeekClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.client.sendMessage(prompt, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *DeepSeekClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.client.sendMessageWithContext(prompt, context, config);
    }

    /// Helper: Create default config for DeepSeek Chat
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.CHAT,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    /// Helper: Create config for reasoning tasks
    pub fn reasoningConfig() common.RequestConfig {
        return .{
            .model = Models.REASONER,
            .max_tokens = 65536,
            .temperature = 1.0,
        };
    }

    /// Pricing information for cost estimation
    pub const Pricing = struct {
        // DeepSeek is extremely affordable
        pub const INPUT_PRICE_PER_MTOK = 0.14; // $0.14 per 1M input tokens
        pub const OUTPUT_PRICE_PER_MTOK = 0.28; // $0.28 per 1M output tokens

        /// Calculate cost for a response
        pub fn calculateCost(usage: common.UsageStats) f64 {
            return usage.estimateCost(INPUT_PRICE_PER_MTOK, OUTPUT_PRICE_PER_MTOK);
        }
    };
};

test "DeepSeekClient initialization" {
    const allocator = std.testing.allocator;

    var client = try DeepSeekClient.init(allocator, "test-key");
    defer client.deinit();

    try std.testing.expectEqualStrings("deepseek", client.client.provider_name);
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/anthropic",
        client.client.base_url,
    );
}

test "DeepSeekClient config helpers" {
    const default_cfg = DeepSeekClient.defaultConfig();
    try std.testing.expectEqualStrings(DeepSeekClient.Models.CHAT, default_cfg.model);

    const reasoning_cfg = DeepSeekClient.reasoningConfig();
    try std.testing.expectEqualStrings(DeepSeekClient.Models.REASONER, reasoning_cfg.model);
}

test "DeepSeekClient pricing" {
    const usage = common.UsageStats{
        .input_tokens = 1_000_000,
        .output_tokens = 500_000,
    };

    const cost = DeepSeekClient.Pricing.calculateCost(usage);

    // $0.14 * 1 (input) + $0.28 * 0.5 (output) = $0.28
    try std.testing.expectApproxEqAbs(@as(f64, 0.28), cost, 0.01);
}
