// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Model pricing data and cost estimation
//! Prices in USD per million tokens (MTok) — updated Feb 2026

const std = @import("std");

pub const ModelPricing = struct {
    input_per_mtok: f64,
    output_per_mtok: f64,
};

/// Get pricing for a model. Returns null for unknown models.
pub fn getModelPricing(model: []const u8) ?ModelPricing {
    // Claude (Anthropic) — prices updated 2026-02
    // Active models: opus-4-6 ($5/$25), sonnet-4-5 ($3/$15), haiku-4-5 ($1/$5)
    if (std.mem.startsWith(u8, model, "claude-opus-4-6")) return .{ .input_per_mtok = 5.0, .output_per_mtok = 25.0 };
    if (std.mem.startsWith(u8, model, "claude-opus-4-5")) return .{ .input_per_mtok = 5.0, .output_per_mtok = 25.0 };
    if (std.mem.startsWith(u8, model, "claude-haiku-4-5")) return .{ .input_per_mtok = 1.0, .output_per_mtok = 5.0 };
    if (std.mem.startsWith(u8, model, "claude-sonnet-4-5")) return .{ .input_per_mtok = 3.0, .output_per_mtok = 15.0 };
    // Legacy fallbacks (still matched for backwards compat)
    if (std.mem.startsWith(u8, model, "claude-opus-4")) return .{ .input_per_mtok = 15.0, .output_per_mtok = 75.0 };
    if (std.mem.startsWith(u8, model, "claude-sonnet-4")) return .{ .input_per_mtok = 3.0, .output_per_mtok = 15.0 };
    if (std.mem.startsWith(u8, model, "claude-3-haiku")) return .{ .input_per_mtok = 0.25, .output_per_mtok = 1.25 };

    // Gemini (Google) — free tier exists but these are pay-as-you-go
    if (std.mem.startsWith(u8, model, "gemini-3-flash")) return .{ .input_per_mtok = 0.10, .output_per_mtok = 0.40 };
    if (std.mem.startsWith(u8, model, "gemini-3-pro")) return .{ .input_per_mtok = 1.25, .output_per_mtok = 10.0 };
    if (std.mem.startsWith(u8, model, "gemini-2.5-flash-lite")) return .{ .input_per_mtok = 0.0375, .output_per_mtok = 0.15 };
    if (std.mem.startsWith(u8, model, "gemini-2.5-flash")) return .{ .input_per_mtok = 0.075, .output_per_mtok = 0.30 };
    if (std.mem.startsWith(u8, model, "gemini-2.5-pro")) return .{ .input_per_mtok = 1.25, .output_per_mtok = 10.0 };

    // Grok (xAI) — prices from docs.x.ai/developers/models Feb 2026
    if (std.mem.startsWith(u8, model, "grok-4-1-fast")) return .{ .input_per_mtok = 0.20, .output_per_mtok = 0.50 };
    if (std.mem.startsWith(u8, model, "grok-4-fast")) return .{ .input_per_mtok = 0.20, .output_per_mtok = 0.50 };
    if (std.mem.startsWith(u8, model, "grok-code")) return .{ .input_per_mtok = 0.20, .output_per_mtok = 1.50 };
    if (std.mem.startsWith(u8, model, "grok-4-0709") or std.mem.eql(u8, model, "grok-4")) return .{ .input_per_mtok = 3.0, .output_per_mtok = 15.0 };

    // OpenAI GPT-5
    if (std.mem.startsWith(u8, model, "gpt-5.2-pro")) return .{ .input_per_mtok = 15.0, .output_per_mtok = 60.0 };
    if (std.mem.startsWith(u8, model, "gpt-5.2-codex")) return .{ .input_per_mtok = 6.0, .output_per_mtok = 24.0 };
    if (std.mem.startsWith(u8, model, "gpt-5.2")) return .{ .input_per_mtok = 2.0, .output_per_mtok = 8.0 };
    if (std.mem.startsWith(u8, model, "gpt-5.1")) return .{ .input_per_mtok = 2.0, .output_per_mtok = 8.0 };
    if (std.mem.startsWith(u8, model, "gpt-5-mini")) return .{ .input_per_mtok = 0.30, .output_per_mtok = 1.20 };
    if (std.mem.startsWith(u8, model, "gpt-5-nano")) return .{ .input_per_mtok = 0.10, .output_per_mtok = 0.40 };
    if (std.mem.startsWith(u8, model, "gpt-5")) return .{ .input_per_mtok = 2.0, .output_per_mtok = 8.0 };
    if (std.mem.startsWith(u8, model, "o3-pro")) return .{ .input_per_mtok = 20.0, .output_per_mtok = 80.0 };
    if (std.mem.startsWith(u8, model, "o3-mini")) return .{ .input_per_mtok = 1.10, .output_per_mtok = 4.40 };
    if (std.mem.startsWith(u8, model, "o3")) return .{ .input_per_mtok = 10.0, .output_per_mtok = 40.0 };
    if (std.mem.startsWith(u8, model, "o4-mini")) return .{ .input_per_mtok = 1.10, .output_per_mtok = 4.40 };

    // DeepSeek
    if (std.mem.startsWith(u8, model, "deepseek-chat")) return .{ .input_per_mtok = 0.14, .output_per_mtok = 0.28 };
    if (std.mem.startsWith(u8, model, "deepseek-reasoner")) return .{ .input_per_mtok = 0.55, .output_per_mtok = 2.19 };

    return null;
}

/// Calculate session cost from token counts
pub fn calculateCost(model: []const u8, input_tokens: u32, output_tokens: u32) ?f64 {
    const pricing = getModelPricing(model) orelse return null;
    const input_cost = (@as(f64, @floatFromInt(input_tokens)) / 1_000_000.0) * pricing.input_per_mtok;
    const output_cost = (@as(f64, @floatFromInt(output_tokens)) / 1_000_000.0) * pricing.output_per_mtok;
    return input_cost + output_cost;
}

/// Format cost as a human-readable string into a buffer
/// Returns the formatted slice
pub fn formatCost(buf: []u8, cost: f64) []const u8 {
    if (cost < 0.01) {
        // Sub-cent: show as fraction of a cent
        const cents = cost * 100.0;
        return std.fmt.bufPrint(buf, "${d:.6} ({d:.4}¢)", .{ cost, cents }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "${d:.4}", .{cost}) catch "?";
    }
}

test "claude sonnet pricing" {
    const pricing = getModelPricing("claude-sonnet-4-5-20250929").?;
    try std.testing.expectEqual(@as(f64, 3.0), pricing.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 15.0), pricing.output_per_mtok);
}

test "claude opus 4.6 pricing" {
    const pricing = getModelPricing("claude-opus-4-6").?;
    try std.testing.expectEqual(@as(f64, 5.0), pricing.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 25.0), pricing.output_per_mtok);
}

test "claude haiku pricing" {
    const pricing = getModelPricing("claude-haiku-4-5-20251001").?;
    try std.testing.expectEqual(@as(f64, 1.0), pricing.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 5.0), pricing.output_per_mtok);
}

test "gemini pricing" {
    const pricing = getModelPricing("gemini-2.5-flash").?;
    try std.testing.expectEqual(@as(f64, 0.075), pricing.input_per_mtok);
}

test "calculateCost" {
    // 1M input + 500K output on Claude Sonnet = $3 + $7.50 = $10.50
    const cost = calculateCost("claude-sonnet-4-5-20250929", 1_000_000, 500_000).?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), cost, 0.01);
}

test "unknown model returns null" {
    try std.testing.expect(getModelPricing("unknown-model-xyz") == null);
}
