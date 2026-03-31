// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Model listing — `zig-ai models` and `zig-ai models --detailed`
//!
//! Prints available providers, models, defaults, pricing, and env vars
//! so that consumers (humans, Claude, Tauri apps) can discover capabilities
//! without guessing.

const std = @import("std");
const model_costs = @import("model_costs.zig");
const config = @import("config.zig");

const print = std.debug.print;

// Reusable dash strings
const D10 = "----------";
const D12 = "------------";
const D18 = "------------------";
const D20 = "--------------------";
const D24 = "------------------------";
const D34 = "----------------------------------";
const D60 = "------------------------------------------------------------";
const D90 = "------------------------------------------------------------------------------------------";

// ============================================================================
// Public entry point
// ============================================================================

pub fn run(args: []const []const u8) void {
    var detailed = false;
    var filter_provider: ?[]const u8 = null;

    var i: usize = 2; // skip program name + "models"
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--detailed") or std.mem.eql(u8, arg, "-d")) {
            detailed = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else {
            // Treat as provider filter
            filter_provider = arg;
        }
    }

    if (detailed) {
        printDetailed(filter_provider);
    } else {
        printSummary(filter_provider);
    }
}

// ============================================================================
// Page 1: Summary
// ============================================================================

fn printSummary(filter: ?[]const u8) void {
    print("\n", .{});
    print("  zig-ai models\n", .{});
    print("  ==============\n\n", .{});

    // Text providers
    printSection("Text Providers", filter, &text_providers);
    printSection("Image Providers", filter, &image_providers);
    printSection("Video Providers", filter, &video_providers);
    printSection("Music Providers", filter, &music_providers);
    printSection("Other Capabilities", filter, &other_capabilities);

    print("  Tip: run `zig-ai models --detailed` for pricing and token info\n", .{});
    print("       run `zig-ai models <provider>` to filter (e.g. `zig-ai models claude`)\n\n", .{});
}

const ProviderRow = struct {
    command: []const u8,
    provider_name: []const u8,
    default_model: []const u8,
    small_model: []const u8,
    env_var: []const u8,
    category: []const u8,
};

const text_providers = [_]ProviderRow{
    .{ .command = "claude", .provider_name = "Anthropic", .default_model = config.Defaults.anthropic_default, .small_model = config.Defaults.anthropic_small, .env_var = "ANTHROPIC_API_KEY", .category = "text" },
    .{ .command = "deepseek", .provider_name = "DeepSeek", .default_model = config.Defaults.deepseek_default, .small_model = config.Defaults.deepseek_small, .env_var = "DEEPSEEK_API_KEY", .category = "text" },
    .{ .command = "gemini", .provider_name = "Google Gemini", .default_model = config.Defaults.google_default, .small_model = config.Defaults.google_small, .env_var = "GEMINI_API_KEY", .category = "text" },
    .{ .command = "grok", .provider_name = "xAI Grok", .default_model = config.Defaults.xai_default, .small_model = config.Defaults.xai_small, .env_var = "XAI_API_KEY", .category = "text" },
    .{ .command = "openai", .provider_name = "OpenAI", .default_model = config.Defaults.openai_default, .small_model = config.Defaults.openai_small, .env_var = "OPENAI_API_KEY", .category = "text" },
    .{ .command = "vertex", .provider_name = "Google Vertex AI", .default_model = config.Defaults.vertex_default, .small_model = config.Defaults.vertex_small, .env_var = "VERTEX_PROJECT_ID", .category = "text" },
};

const image_providers = [_]ProviderRow{
    .{ .command = "dalle3", .provider_name = "OpenAI", .default_model = "dall-e-3", .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "image" },
    .{ .command = "gpt-image", .provider_name = "OpenAI", .default_model = "gpt-image-1", .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "image" },
    .{ .command = "gpt-image-15", .provider_name = "OpenAI", .default_model = "gpt-image-1.5", .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "image" },
    .{ .command = "grok-image", .provider_name = "xAI", .default_model = "grok-2-image", .small_model = "-", .env_var = "XAI_API_KEY", .category = "image" },
    .{ .command = "imagen", .provider_name = "Google GenAI", .default_model = "imagen-4.0-generate-001", .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "image" },
    .{ .command = "gemini-image", .provider_name = "Google", .default_model = config.Defaults.gemini_flash_image, .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "image" },
    .{ .command = "gemini-image-pro", .provider_name = "Google", .default_model = "gemini-3-pro-image-preview", .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "image" },
    .{ .command = "vertex-image", .provider_name = "Google Vertex", .default_model = "imagegeneration@006", .small_model = "-", .env_var = "VERTEX_PROJECT_ID", .category = "image" },
};

const video_providers = [_]ProviderRow{
    .{ .command = "veo", .provider_name = "Google", .default_model = config.Defaults.veo, .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "video" },
    .{ .command = "sora", .provider_name = "OpenAI", .default_model = config.Defaults.sora, .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "video" },
    .{ .command = "grok-video", .provider_name = "xAI", .default_model = "grok-imagine-video", .small_model = "-", .env_var = "XAI_API_KEY", .category = "video" },
};

const music_providers = [_]ProviderRow{
    .{ .command = "lyria", .provider_name = "Google Vertex", .default_model = config.Defaults.lyria, .small_model = "-", .env_var = "VERTEX_PROJECT_ID", .category = "music" },
    .{ .command = "lyria-realtime", .provider_name = "Google Vertex", .default_model = config.Defaults.lyria_realtime, .small_model = "-", .env_var = "VERTEX_PROJECT_ID", .category = "music" },
};

const other_capabilities = [_]ProviderRow{
    .{ .command = "tts-openai", .provider_name = "OpenAI", .default_model = "gpt-4o-mini-tts", .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "speech" },
    .{ .command = "tts-google", .provider_name = "Google", .default_model = "gemini-2.5-flash-tts", .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "speech" },
    .{ .command = "stt-openai", .provider_name = "OpenAI", .default_model = "whisper-1", .small_model = "-", .env_var = "OPENAI_API_KEY", .category = "transcription" },
    .{ .command = "research", .provider_name = "Google Gemini", .default_model = config.Defaults.google_default, .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "research" },
    .{ .command = "search", .provider_name = "xAI Grok", .default_model = config.Defaults.xai_default, .small_model = "-", .env_var = "XAI_API_KEY", .category = "web search" },
    .{ .command = "live", .provider_name = "Google Gemini", .default_model = "gemini-2.0-flash-live-001", .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "realtime" },
    .{ .command = "voice", .provider_name = "xAI Grok", .default_model = "grok-2-public", .small_model = "-", .env_var = "XAI_API_KEY", .category = "voice agent" },
    .{ .command = "agent", .provider_name = "Any", .default_model = "(per provider)", .small_model = "-", .env_var = "(per provider)", .category = "agent" },
    .{ .command = "batch-api", .provider_name = "Claude/Gemini/OpenAI/xAI", .default_model = "(per provider)", .small_model = "-", .env_var = "(per provider)", .category = "batch" },
    .{ .command = "structured", .provider_name = "Any", .default_model = "(per provider)", .small_model = "-", .env_var = "(per provider)", .category = "structured output" },
    .{ .command = "embed", .provider_name = "Google Gemini", .default_model = "text-embedding-004", .small_model = "-", .env_var = "GEMINI_API_KEY", .category = "embeddings" },
};

fn printSection(title: []const u8, filter: ?[]const u8, rows: []const ProviderRow) void {
    // Check if any rows match filter
    if (filter) |f| {
        var has_match = false;
        for (rows) |row| {
            if (matchesFilter(row, f)) {
                has_match = true;
                break;
            }
        }
        if (!has_match) return;
    }

    // Check if any row has a non-"-" small model (text providers)
    var has_tiers = false;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.small_model, "-")) {
            has_tiers = true;
            break;
        }
    }

    print("  {s}\n", .{title});
    printDashLine(title.len);
    if (has_tiers) {
        print("  {s:<14} {s:<16} {s:<30} {s:<28} {s}\n", .{ "Command", "Provider", "Main Model", "Small Model", "Env Var" });
        print("  {s:<14} {s:<16} {s:<30} {s:<28} {s}\n", .{ D12, "---------------", "----------------------------", "--------------------------", D24 });
    } else {
        print("  {s:<20} {s:<22} {s:<36} {s}\n", .{ "Command", "Provider", "Default Model", "Env Var" });
        print("  {s:<20} {s:<22} {s:<36} {s}\n", .{ D18, D20, D34, D24 });
    }

    for (rows) |row| {
        if (filter) |f| {
            if (!matchesFilter(row, f)) continue;
        }
        if (has_tiers) {
            print("  {s:<14} {s:<16} {s:<30} {s:<28} {s}\n", .{ row.command, row.provider_name, row.default_model, row.small_model, row.env_var });
        } else {
            print("  {s:<20} {s:<22} {s:<36} {s}\n", .{ row.command, row.provider_name, row.default_model, row.env_var });
        }
    }
    print("\n", .{});
}

fn matchesFilter(row: ProviderRow, filter: []const u8) bool {
    if (containsIgnoreCase(row.command, filter)) return true;
    if (containsIgnoreCase(row.provider_name, filter)) return true;
    if (containsIgnoreCase(row.category, filter)) return true;
    if (containsIgnoreCase(row.env_var, filter)) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ============================================================================
// Page 2: Detailed pricing
// ============================================================================

fn printDetailed(filter: ?[]const u8) void {
    print("\n", .{});
    print("  zig-ai models --detailed\n", .{});
    print("  ========================\n\n", .{});

    // Group costs by provider
    const providers_order = [_][]const u8{ "anthropic", "deepseek", "google", "xai", "openai" };
    const provider_labels = [_][]const u8{ "Anthropic (Claude)", "DeepSeek", "Google (Gemini)", "xAI (Grok)", "OpenAI (GPT)" };
    const provider_envs = [_][]const u8{ "ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY", "OPENAI_API_KEY" };

    for (providers_order, 0..) |prov, idx| {
        if (filter) |f| {
            if (!containsIgnoreCase(prov, f) and !containsIgnoreCase(provider_labels[idx], f)) continue;
        }

        print("  {s}  (env: {s})\n", .{ provider_labels[idx], provider_envs[idx] });
        print("  {s}\n", .{D90});
        print("  {s:<36} {s:>12} {s:>12} {s:>14} {s:>14}\n", .{ "Model", "Input/MTok", "Output/MTok", "Cache Wr/MTok", "Cache Rd/MTok" });
        print("  {s:<36} {s:>12} {s:>12} {s:>14} {s:>14}\n", .{ D34, D10, D10, D12, D12 });

        var count: usize = 0;
        for (model_costs.MODEL_COSTS) |cost| {
            if (!std.mem.eql(u8, cost.provider, prov)) continue;
            if (filter) |f| {
                if (!containsIgnoreCase(prov, f) and !containsIgnoreCase(provider_labels[idx], f) and !containsIgnoreCase(cost.model, f)) continue;
            }
            printCostRow(cost);
            count += 1;
        }
        if (count > 0) {
            print("\n", .{});
        }
    }

    // Per-unit pricing (non-token models)
    if (filter == null or matchesAny(filter.?, &.{ "image", "video", "grok", "xai", "openai" })) {
        print("  Per-Unit Pricing (non-token)\n", .{});
        print("  {s}\n", .{D60});
        print("  {s:<36} {s}\n", .{ "Model", "Price" });
        print("  {s:<36} {s}\n", .{ D34, D24 });
        print("  {s:<36} {s}\n", .{ "grok-imagine-image-pro", "$0.07/image" });
        print("  {s:<36} {s}\n", .{ "grok-imagine-image", "$0.02/image" });
        print("  {s:<36} {s}\n", .{ "grok-imagine-video", "$0.05/second" });
        print("  {s:<36} {s}\n", .{ "dall-e-3 (1024x1024)", "$0.04/image" });
        print("  {s:<36} {s}\n", .{ "dall-e-3 (1792x1024)", "$0.08/image" });
        print("  {s:<36} {s}\n", .{ "gpt-image-1 (1024x1024)", "$0.04/image" });
        print("  {s:<36} {s}\n", .{ "gpt-image-1.5 (1024x1024, low)", "$0.02/image" });
        print("  {s:<36} {s}\n", .{ "gpt-image-1.5 (1024x1024, high)", "$0.07/image" });
        print("\n", .{});
    }

    // Context windows
    if (filter == null or matchesAny(filter.?, &.{ "context", "token", "limit", "window", "anthropic", "claude", "gemini", "google", "openai", "gpt", "grok", "xai", "deepseek" })) {
        print("  Context Windows (max input tokens)\n", .{});
        print("  {s}\n", .{D60});
        print("  {s:<36} {s}\n", .{ "Provider / Model", "Context Window" });
        print("  {s:<36} {s}\n", .{ D34, D24 });
        print("  {s:<36} {s}\n", .{ "Claude Opus 4.6 / Sonnet 4.6", "200K (1M available)" });
        print("  {s:<36} {s}\n", .{ "DeepSeek Chat/Reasoner", "64K tokens" });
        print("  {s:<36} {s}\n", .{ "Gemini 2.5 Pro", "1M tokens" });
        print("  {s:<36} {s}\n", .{ "Gemini 2.5 Flash", "1M tokens" });
        print("  {s:<36} {s}\n", .{ "Gemini 3 Pro/Flash Preview", "1M tokens" });
        print("  {s:<36} {s}\n", .{ "Grok 4.1 Fast", "131K tokens" });
        print("  {s:<36} {s}\n", .{ "GPT-5.2 / GPT-5.1 / GPT-5", "128K tokens" });
        print("  {s:<36} {s}\n", .{ "GPT-4.1", "1M tokens" });
        print("  {s:<36} {s}\n", .{ "o3 / o3-pro / o4-mini", "200K tokens" });
        print("\n", .{});
    }

    // Default max output tokens
    if (filter == null or matchesAny(filter.?, &.{ "output", "token", "limit", "max" })) {
        print("  Default Max Output Tokens\n", .{});
        print("  {s}\n", .{D60});
        print("  {s:<36} {s}\n", .{ "Provider / Model", "Max Output" });
        print("  {s:<36} {s}\n", .{ D34, D24 });
        print("  {s:<36} {s}\n", .{ "Claude Opus/Sonnet/Haiku", "8,192 (up to 128K)" });
        print("  {s:<36} {s}\n", .{ "DeepSeek Chat", "8,192" });
        print("  {s:<36} {s}\n", .{ "Gemini 2.5 Flash", "65,536" });
        print("  {s:<36} {s}\n", .{ "Gemini 2.5 Pro", "65,536" });
        print("  {s:<36} {s}\n", .{ "Grok 4.1 Fast", "131,072" });
        print("  {s:<36} {s}\n", .{ "GPT-5.2", "32,768" });
        print("  {s:<36} {s}\n", .{ "o3 / o4-mini", "100,000" });
        print("\n", .{});
    }
}

fn printCostRow(cost: model_costs.ModelCost) void {
    var input_buf: [16]u8 = undefined;
    var output_buf: [16]u8 = undefined;
    var cw_buf: [16]u8 = undefined;
    var cr_buf: [16]u8 = undefined;

    const input_str = formatPrice(&input_buf, cost.input_cost_per_1m);
    const output_str = formatPrice(&output_buf, cost.output_cost_per_1m);
    const cw_str = formatPrice(&cw_buf, cost.cache_write_cost_per_1m);
    const cr_str = formatPrice(&cr_buf, cost.cache_read_cost_per_1m);

    print("  {s:<36} {s:>12} {s:>12} {s:>14} {s:>14}\n", .{ cost.model, input_str, output_str, cw_str, cr_str });
}

fn formatPrice(buf: *[16]u8, value: f64) []const u8 {
    if (value == 0.0) {
        buf[0] = '-';
        return buf[0..1];
    }
    if (value >= 1.0) {
        return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "?";
    } else if (value >= 0.01) {
        return std.fmt.bufPrint(buf, "${d:.3}", .{value}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "${d:.4}", .{value}) catch "?";
    }
}

fn matchesAny(filter: []const u8, keywords: []const []const u8) bool {
    for (keywords) |kw| {
        if (containsIgnoreCase(filter, kw)) return true;
    }
    return false;
}

// ============================================================================
// Help
// ============================================================================

fn printHelp() void {
    print(
        \\
        \\  zig-ai models [OPTIONS] [FILTER]
        \\
        \\  List available providers, models, pricing, and capabilities.
        \\
        \\  Options:
        \\    -d, --detailed    Show pricing, context windows, and token limits
        \\    -h, --help        Show this help
        \\
        \\  Filter:
        \\    Optionally pass a provider name to filter results:
        \\      zig-ai models claude       Show only Anthropic/Claude models
        \\      zig-ai models openai       Show only OpenAI models
        \\      zig-ai models image        Show only image providers
        \\      zig-ai models grok -d      Show Grok pricing details
        \\
        \\  Examples:
        \\    zig-ai models               Quick overview of all providers
        \\    zig-ai models --detailed     Full pricing and token limits
        \\    zig-ai models gemini -d      Gemini pricing only
        \\
    , .{});
}

// ============================================================================
// String helpers
// ============================================================================

fn printDashLine(len: usize) void {
    print("  ", .{});
    var i: usize = 0;
    while (i < len) : (i += 1) {
        print("-", .{});
    }
    print("\n", .{});
}
