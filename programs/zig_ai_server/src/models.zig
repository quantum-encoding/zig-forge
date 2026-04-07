// Models endpoint — GET /qai/v1/models, GET /qai/v1/models/pricing
// Serves the model registry with pricing data from http_sentinel

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

/// Model registry — all available models with pricing
/// Matches quantum-sdk ModelInfo shape
const Model = struct {
    id: []const u8,
    provider: []const u8,
    display_name: []const u8,
    category: []const u8,
    input_per_million: f64,
    output_per_million: f64,
};

const MODELS = [_]Model{
    // Anthropic
    .{ .id = "claude-sonnet-4-6", .provider = "anthropic", .display_name = "Claude Sonnet 4.6", .category = "Text", .input_per_million = 3.0, .output_per_million = 15.0 },
    .{ .id = "claude-sonnet-4-5-20250929", .provider = "anthropic", .display_name = "Claude Sonnet 4.5", .category = "Text", .input_per_million = 3.0, .output_per_million = 15.0 },
    .{ .id = "claude-opus-4-6", .provider = "anthropic", .display_name = "Claude Opus 4.6", .category = "Text", .input_per_million = 15.0, .output_per_million = 75.0 },
    .{ .id = "claude-haiku-4-5-20251001", .provider = "anthropic", .display_name = "Claude Haiku 4.5", .category = "Text", .input_per_million = 0.80, .output_per_million = 4.0 },

    // DeepSeek
    .{ .id = "deepseek-chat", .provider = "deepseek", .display_name = "DeepSeek Chat V3", .category = "Text", .input_per_million = 0.28, .output_per_million = 0.42 },
    .{ .id = "deepseek-reasoner", .provider = "deepseek", .display_name = "DeepSeek Reasoner R1", .category = "Text", .input_per_million = 0.55, .output_per_million = 2.19 },

    // Google Gemini
    .{ .id = "gemini-2.5-pro", .provider = "google", .display_name = "Gemini 2.5 Pro", .category = "Text", .input_per_million = 2.50, .output_per_million = 15.0 },
    .{ .id = "gemini-2.5-flash", .provider = "google", .display_name = "Gemini 2.5 Flash", .category = "Text", .input_per_million = 0.15, .output_per_million = 0.60 },
    .{ .id = "gemini-2.5-flash-lite", .provider = "google", .display_name = "Gemini 2.5 Flash Lite", .category = "Text", .input_per_million = 0.075, .output_per_million = 0.30 },

    // xAI Grok
    .{ .id = "grok-3-mini", .provider = "xai", .display_name = "Grok 3 Mini", .category = "Text", .input_per_million = 0.30, .output_per_million = 0.50 },
    .{ .id = "grok-3", .provider = "xai", .display_name = "Grok 3", .category = "Text", .input_per_million = 3.0, .output_per_million = 15.0 },
    .{ .id = "grok-2-latest", .provider = "xai", .display_name = "Grok 2", .category = "Text", .input_per_million = 2.0, .output_per_million = 10.0 },

    // OpenAI
    .{ .id = "gpt-4.1-mini", .provider = "openai", .display_name = "GPT-4.1 Mini", .category = "Text", .input_per_million = 0.40, .output_per_million = 1.60 },
    .{ .id = "gpt-4.1", .provider = "openai", .display_name = "GPT-4.1", .category = "Text", .input_per_million = 2.0, .output_per_million = 8.0 },
    .{ .id = "gpt-4o", .provider = "openai", .display_name = "GPT-4o", .category = "Text", .input_per_million = 2.50, .output_per_million = 10.0 },
    .{ .id = "o4-mini", .provider = "openai", .display_name = "o4-mini", .category = "Text", .input_per_million = 1.10, .output_per_million = 4.40 },
};

/// GET /qai/v1/models — returns full model list
pub fn handleModels(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const json = buildModelsJson(allocator) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build models list"}
        };
    };
    return .{ .body = json };
}

/// GET /qai/v1/models/pricing — returns pricing table
pub fn handlePricing(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const json = buildPricingJson(allocator) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build pricing list"}
        };
    };
    return .{ .body = json };
}

fn buildModelsJson(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"models\":[");

    for (MODELS, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, ',');
        const entry = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","input_per_million":{d:.2},"output_per_million":{d:.2}}}
        , .{ m.id, m.provider, m.display_name, m.category, m.input_per_million, m.output_per_million });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn buildPricingJson(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"pricing\":[");

    for (MODELS, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, ',');
        const entry = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","provider":"{s}","display_name":"{s}","input_per_million":{d:.2},"output_per_million":{d:.2}}}
        , .{ m.id, m.provider, m.display_name, m.input_per_million, m.output_per_million });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Lookup pricing for a model by ID. Returns (input_per_million, output_per_million).
pub fn getPricing(model_id: []const u8) struct { input: f64, output: f64 } {
    for (MODELS) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            return .{ .input = m.input_per_million, .output = m.output_per_million };
        }
    }
    // Fuzzy match: check if model starts with a known prefix
    for (MODELS) |m| {
        if (std.mem.startsWith(u8, model_id, m.id)) {
            return .{ .input = m.input_per_million, .output = m.output_per_million };
        }
    }
    // Default fallback
    return .{ .input = 3.0, .output = 15.0 };
}
