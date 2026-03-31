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
    // Anthropic
    .{ .provider = "anthropic", .model = "claude-sonnet-4-5-20250929", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },
    .{ .provider = "anthropic", .model = "claude-sonnet-4-20250514", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },
    .{ .provider = "anthropic", .model = "claude-opus-4-1-20250805", .input_cost_per_1m = 15.0, .output_cost_per_1m = 75.0, .cache_write_cost_per_1m = 18.75, .cache_read_cost_per_1m = 1.5 },
    .{ .provider = "anthropic", .model = "claude-3-7-sonnet-20250219", .input_cost_per_1m = 3.0, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 3.75, .cache_read_cost_per_1m = 0.3 },

    // DeepSeek
    .{ .provider = "deepseek", .model = "deepseek-chat", .input_cost_per_1m = 0.28, .output_cost_per_1m = 0.42, .cache_write_cost_per_1m = 0.028, .cache_read_cost_per_1m = 0.014 },
    .{ .provider = "deepseek", .model = "deepseek-reasoner", .input_cost_per_1m = 0.28, .output_cost_per_1m = 0.42, .cache_write_cost_per_1m = 0.028, .cache_read_cost_per_1m = 0.014 },

    // Google (Gemini)
    .{ .provider = "google", .model = "gemini-2.5-pro", .input_cost_per_1m = 2.5, .output_cost_per_1m = 15.0, .cache_write_cost_per_1m = 0.3125, .cache_read_cost_per_1m = 0.025 },
    .{ .provider = "google", .model = "gemini-2.5-flash", .input_cost_per_1m = 0.3, .output_cost_per_1m = 2.5, .cache_write_cost_per_1m = 0.01875, .cache_read_cost_per_1m = 0.0015 },
    .{ .provider = "google", .model = "gemini-2.5-flash-lite", .input_cost_per_1m = 0.1, .output_cost_per_1m = 0.4, .cache_write_cost_per_1m = 0.009375, .cache_read_cost_per_1m = 0.00075 },

    // XAI (Grok)
    .{ .provider = "xai", .model = "grok-code-fast-1", .input_cost_per_1m = 0.2, .output_cost_per_1m = 1.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-fast-non-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-4-fast-reasoning", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
    .{ .provider = "xai", .model = "grok-2-latest", .input_cost_per_1m = 0.2, .output_cost_per_1m = 0.5, .cache_write_cost_per_1m = 0.0, .cache_read_cost_per_1m = 0.05 },
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

test "calculateCost claude" {
    // Claude: 1M input tokens, 1M output tokens
    // (1M/1M * 3.0) + (1M/1M * 15.0) = 3.0 + 15.0 = 18.0
    const cost = calculateCost("anthropic", "claude-sonnet-4-5-20250929", 1_000_000, 1_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 18.0), cost, 0.01);
}
