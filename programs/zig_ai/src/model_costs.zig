// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Model costs database - Parsed from model_costs.csv

const std = @import("std");

pub const ModelCost = struct {
    provider: []const u8,
    model: []const u8,
    input_cost_per_1m: f64,
    output_cost_per_1m: f64,
    cache_write_cost_per_1m: f64,
    cache_read_cost_per_1m: f64,
};

/// Model costs embedded at compile time from model_costs.csv
pub const MODEL_COSTS = [_]ModelCost{
    // Anthropic — prices updated 2026-03 from official pricing page
    // Active models: Opus 4.6, Sonnet 4.6, Haiku 4.5
    .{ .provider = "anthropic", .model = "claude-opus-4-6", .input_cost_per_1m = 5.0, .output_cost_per_1m = 25.0, .cache_write_cost_per_1m = 6.25, .cache_read_cost_per_1m = 0.5 },
    .{ .provider = "anthropic", .model = "claude-sonnet-4-6", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },
    .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001", .input_cost_per_1m = 1.0, .output_cost_per_1m = 5.0, .cache_write_cost_per_1m = 1.25, .cache_read_cost_per_1m = 0.1 },
    // Legacy Sonnet
    .{ .provider = "anthropic", .model = "claude-sonnet-4-5-20250929", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },
    // Legacy models (commented out — use Opus 4.6 / Sonnet 4.5 / Haiku 4.5 instead)
    // .{ .provider = "anthropic", .model = "claude-opus-4-5-20251101", .input_cost_per_1m = 5.0, .output_cost_per_1m = 25.0, .cache_write_cost_per_1m = 6.25, .cache_read_cost_per_1m = 0.5 },
    // .{ .provider = "anthropic", .model = "claude-sonnet-4-20250514", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },
    // .{ .provider = "anthropic", .model = "claude-opus-4-1-20250805", .input_cost_per_1m = 15.0, .output_cost_per_1m = 75.0, .cache_write_cost_per_1m = 18.75, .cache_read_cost_per_1m = 1.5 },
    // .{ .provider = "anthropic", .model = "claude-3-7-sonnet-20250219", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },

    // DeepSeek
    .{ .provider = "deepseek", .model = "deepseek-chat", .input_cost_per_1m = 0.28, .output_cost_per_1m = 0.42, .cache_write_cost_per_1m = 0.028, .cache_read_cost_per_1m = 0.014 },
    .{ .provider = "deepseek", .model = "deepseek-reasoner", .input_cost_per_1m = 0.28, .output_cost_per_1m = 0.42, .cache_write_cost_per_1m = 0.028, .cache_read_cost_per_1m = 0.014 },

    // Google (Gemini)
    .{ .provider = "google", .model = "gemini-3-pro-preview", .input_cost_per_1m = 2.5, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 0.3125, .cache_read_cost_per_1m = 0.025 },
    .{ .provider = "google", .model = "gemini-3-flash-preview", .input_cost_per_1m = 0.3, .output_cost_per_1m = 2.5, .cache_write_cost_per_1m = 0.01875, .cache_read_cost_per_1m = 0.0015 },
    .{ .provider = "google", .model = "gemini-2.5-pro", .input_cost_per_1m = 2.5, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 0.3125, .cache_read_cost_per_1m = 0.025 },
    .{ .provider = "google", .model = "gemini-2.5-flash", .input_cost_per_1m = 0.3, .output_cost_per_1m = 2.5, .cache_write_cost_per_1m = 0.01875, .cache_read_cost_per_1m = 0.0015 },
    .{ .provider = "google", .model = "gemini-2.5-flash-lite", .input_cost_per_1m = 0.1, .output_cost_per_1m = 0.4, .cache_write_cost_per_1m = 0.009375, .cache_read_cost_per_1m = 0.00075 },

    // XAI (Grok) — prices from docs.x.ai/developers/models Feb 2026
    .{ .provider = "xai", .model = "grok-4-1-fast-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-1-fast-non-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-code-fast-1", .input_cost_per_1m = 0.2, .output_cost_per_1m = 1.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-fast-non-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-fast-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-0709", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.75 },
    // XAI Image generation — per-image pricing (not per-token)
    // grok-imagine-image-pro: $0.07/image output, $0.002/image input
    // grok-imagine-image: $0.02/image output
    // XAI Video generation — per-second pricing
    // grok-imagine-video: $0.05/second

    // OpenAI GPT-5 series
    .{ .provider = "openai", .model = "gpt-5.2", .input_cost_per_1m = 1.75, .output_cost_per_1m = 14.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.175 },
    .{ .provider = "openai", .model = "gpt-5.1", .input_cost_per_1m = 1.25, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.125 },
    .{ .provider = "openai", .model = "gpt-5", .input_cost_per_1m = 1.25, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.125 },
    .{ .provider = "openai", .model = "gpt-5-mini", .input_cost_per_1m = 0.25, .output_cost_per_1m = 2.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.025 },
    .{ .provider = "openai", .model = "gpt-5-nano", .input_cost_per_1m = 0.05, .output_cost_per_1m = 0.4, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.005 },
    // OpenAI GPT-5 Pro
    .{ .provider = "openai", .model = "gpt-5.2-pro", .input_cost_per_1m = 21.0, .output_cost_per_1m = 168.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.0 },
    .{ .provider = "openai", .model = "gpt-5-pro", .input_cost_per_1m = 15.0, .output_cost_per_1m = 120.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.0 },
    // OpenAI Codex series
    .{ .provider = "openai", .model = "gpt-5.2-codex", .input_cost_per_1m = 1.75, .output_cost_per_1m = 14.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.175 },
    .{ .provider = "openai", .model = "gpt-5.1-codex-max", .input_cost_per_1m = 1.25, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.125 },
    .{ .provider = "openai", .model = "gpt-5.1-codex", .input_cost_per_1m = 1.25, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.125 },
    .{ .provider = "openai", .model = "gpt-5.1-codex-mini", .input_cost_per_1m = 0.25, .output_cost_per_1m = 2.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.025 },
    .{ .provider = "openai", .model = "gpt-5-codex", .input_cost_per_1m = 1.25, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.125 },
    .{ .provider = "openai", .model = "codex-mini-latest", .input_cost_per_1m = 1.5, .output_cost_per_1m = 6.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.375 },
    // OpenAI o-series (reasoning)
    .{ .provider = "openai", .model = "o3", .input_cost_per_1m = 2.0, .output_cost_per_1m = 8.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.5 },
    .{ .provider = "openai", .model = "o3-pro", .input_cost_per_1m = 20.0, .output_cost_per_1m = 80.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.0 },
    .{ .provider = "openai", .model = "o3-mini", .input_cost_per_1m = 1.1, .output_cost_per_1m = 4.4, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.55 },
    .{ .provider = "openai", .model = "o3-deep-research", .input_cost_per_1m = 10.0, .output_cost_per_1m = 40.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 2.5 },
    .{ .provider = "openai", .model = "o4-mini", .input_cost_per_1m = 1.1, .output_cost_per_1m = 4.4, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.275 },
    .{ .provider = "openai", .model = "o4-mini-deep-research", .input_cost_per_1m = 2.0, .output_cost_per_1m = 8.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.5 },
    .{ .provider = "openai", .model = "o1", .input_cost_per_1m = 15.0, .output_cost_per_1m = 60.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 7.5 },
    .{ .provider = "openai", .model = "o1-pro", .input_cost_per_1m = 150.0, .output_cost_per_1m = 600.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.0 },
    .{ .provider = "openai", .model = "o1-mini", .input_cost_per_1m = 1.1, .output_cost_per_1m = 4.4, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.55 },
    // OpenAI GPT-4.1 series
    .{ .provider = "openai", .model = "gpt-4.1", .input_cost_per_1m = 2.0, .output_cost_per_1m = 8.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.5 },
    .{ .provider = "openai", .model = "gpt-4.1-mini", .input_cost_per_1m = 0.4, .output_cost_per_1m = 1.6, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.1 },
    .{ .provider = "openai", .model = "gpt-4.1-nano", .input_cost_per_1m = 0.1, .output_cost_per_1m = 0.4, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.025 },
    // OpenAI GPT-4o series
    .{ .provider = "openai", .model = "gpt-4o", .input_cost_per_1m = 2.5, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 1.25 },
    .{ .provider = "openai", .model = "gpt-4o-mini", .input_cost_per_1m = 0.15, .output_cost_per_1m = 0.6, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.075 },
    // OpenAI Image models
    .{ .provider = "openai", .model = "gpt-image-1.5", .input_cost_per_1m = 5.0, .output_cost_per_1m = 10.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 1.25 },
    .{ .provider = "openai", .model = "gpt-image-1", .input_cost_per_1m = 5.0, .output_cost_per_1m = 0.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 1.25 },
    .{ .provider = "openai", .model = "gpt-image-1-mini", .input_cost_per_1m = 2.0, .output_cost_per_1m = 0.0, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.2 },
};

/// Find cost for a specific model
pub fn getCostForModel(provider: []const u8, model: []const u8) ?ModelCost {
    for (MODEL_COSTS) |cost| {
        if (std.mem.eql(u8, cost.provider, provider) and std.mem.eql(u8, cost.model, model)) {
            return cost;
        }
    }
    return null;
}

/// Calculate cost for token usage
pub fn calculateCost(provider: []const u8, model: []const u8, input_tokens: u32, output_tokens: u32) f64 {
    const cost_info = getCostForModel(provider, model) orelse {
        // Fallback to basic estimation if model not found
        return 0.0;
    };

    const input_cost = @as(f64, @floatFromInt(input_tokens)) / 1_000_000.0 * cost_info.input_cost_per_1m;
    const output_cost = @as(f64, @floatFromInt(output_tokens)) / 1_000_000.0 * cost_info.output_cost_per_1m;

    return input_cost + output_cost;
}

test "getCostForModel" {
    const cost = getCostForModel("deepseek", "deepseek-chat");
    try std.testing.expect(cost != null);
    try std.testing.expectEqual(@as(f64, 0.28), cost.?.input_cost_per_1m);
    try std.testing.expectEqual(@as(f64, 0.42), cost.?.output_cost_per_1m);
}

test "calculateCost" {
    // DeepSeek: 1000 input tokens, 1000 output tokens
    // (1000/1M * 0.28) + (1000/1M * 0.42) = 0.00028 + 0.00042 = 0.0007
    const cost = calculateCost("deepseek", "deepseek-chat", 1000, 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0007), cost, 0.000001);
}

test "calculateCost claude sonnet" {
    // Claude Sonnet 4.5: 1M input tokens, 1M output tokens
    // (1M/1M * 3.0) + (1M/1M * 15.0) = 3.0 + 15.0 = 18.0
    const cost = calculateCost("anthropic", "claude-sonnet-4-5-20250929", 1_000_000, 1_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 18.0), cost, 0.01);
}

test "calculateCost claude opus 4.6" {
    // Claude Opus 4.6: 1M input, 1M output = $5 + $25 = $30
    const cost = calculateCost("anthropic", "claude-opus-4-6", 1_000_000, 1_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), cost, 0.01);
}

test "calculateCost claude haiku" {
    // Claude Haiku 4.5: 1M input, 1M output = $1 + $5 = $6
    const cost = calculateCost("anthropic", "claude-haiku-4-5-20251001", 1_000_000, 1_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), cost, 0.01);
}
