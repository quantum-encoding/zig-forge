// Tool Calling Smoke Test Suite
// Tests tool calling wire formats across all providers
// Run with: zig build test-tools -- [provider]
// Or run all: zig build test-tools

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const ai = http_sentinel.ai;
const model_config = @import("config");

// Zig 0.16 compatible Timer
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

// C time
const time_t = i64;
extern "c" fn time(timer: ?*time_t) time_t;

fn getEnvVar(allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
    const value = std.c.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

const ProviderResult = struct {
    provider: []const u8,
    model: []const u8,
    success: bool,
    tool_calls_received: u32,
    text_content_len: usize,
    input_tokens: u32,
    output_tokens: u32,
    latency_ms: u64,
    error_msg: ?[]const u8,
};

/// Single tool definition: a simple "echo" tool the model can call
const test_tools = [_]ai.common.ToolDefinition{
    .{
        .name = "get_current_time",
        .description = "Returns the current date and time. Call this tool to find out what time it is.",
        .input_schema =
        \\{"type":"object","properties":{"timezone":{"type":"string","description":"Optional timezone (e.g. UTC, EST)"}},"required":[]}
        ,
    },
};

const TOOL_PROMPT = "What time is it right now? Use the get_current_time tool to find out.";

fn testProviderToolCalling(
    comptime ClientType: type,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    provider_name: []const u8,
) ProviderResult {
    var timer = Timer.start() catch unreachable;

    var client = ClientType.init(allocator, api_key) catch {
        return .{
            .provider = provider_name,
            .model = model,
            .success = false,
            .tool_calls_received = 0,
            .text_content_len = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_msg = "Client init failed",
        };
    };
    defer client.deinit();

    var req_config = ClientType.defaultConfig();
    req_config.model = model;
    req_config.max_tokens = 1024;
    req_config.tools = &test_tools;
    req_config.system_prompt = "You are a helpful assistant. When asked about the time, ALWAYS use the get_current_time tool.";

    // First turn: send prompt, expect tool call back
    var response = client.sendMessage(TOOL_PROMPT, req_config) catch |err| {
        const elapsed = timer.read() / std.time.ns_per_ms;
        return .{
            .provider = provider_name,
            .model = model,
            .success = false,
            .tool_calls_received = 0,
            .text_content_len = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = elapsed,
            .error_msg = @errorName(err),
        };
    };
    defer response.deinit();

    const elapsed = timer.read() / std.time.ns_per_ms;

    const tc_count: u32 = if (response.message.tool_calls) |tc| @intCast(tc.len) else 0;

    // Verify: did we get tool calls?
    var all_good = tc_count > 0;

    // Verify: tool name matches
    if (response.message.tool_calls) |tc| {
        for (tc) |call| {
            if (!std.mem.eql(u8, call.name, "get_current_time")) {
                all_good = false;
            }
        }
    }

    return .{
        .provider = provider_name,
        .model = model,
        .success = all_good,
        .tool_calls_received = tc_count,
        .text_content_len = response.message.content.len,
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = elapsed,
        .error_msg = if (!all_good and tc_count == 0) "No tool calls returned" else null,
    };
}

fn printResult(r: ProviderResult) void {
    const symbol: []const u8 = if (r.success) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m";
    std.debug.print("  {s} {s} ({s})\n", .{ symbol, r.provider, r.model });
    std.debug.print("    tool_calls: {d}, text: {d} chars, tokens: {d}/{d}, latency: {d}ms\n", .{
        r.tool_calls_received,
        r.text_content_len,
        r.input_tokens,
        r.output_tokens,
        r.latency_ms,
    });
    if (r.error_msg) |e| {
        std.debug.print("    \x1b[31merror: {s}\x1b[0m\n", .{e});
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Tool Calling Smoke Test                         ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Test: Send prompt requiring tool use, verify tool_calls returned\n", .{});
    std.debug.print("Tool: get_current_time (simple, all models can handle it)\n\n", .{});

    var cfg = model_config.ModelConfig.init(allocator);
    defer cfg.deinit();

    // Check which providers to test
    var test_all = true;
    var test_claude = false;
    var test_gemini = false;
    var test_grok = false;
    var test_openai = false;

    if (std.c.getenv("TEST_PROVIDER")) |provider_ptr| {
        const providers = std.mem.span(provider_ptr);
        test_all = false;
        if (std.mem.indexOf(u8, providers, "claude") != null) test_claude = true;
        if (std.mem.indexOf(u8, providers, "gemini") != null) test_gemini = true;
        if (std.mem.indexOf(u8, providers, "grok") != null) test_grok = true;
        if (std.mem.indexOf(u8, providers, "openai") != null) test_openai = true;
    }

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    // Claude
    if (test_all or test_claude) {
        const model = cfg.getModelOr("anthropic", "default", model_config.Defaults.anthropic_default);
        if (getEnvVar(allocator, "ANTHROPIC_API_KEY")) |key| {
            defer allocator.free(key);
            const r = testProviderToolCalling(ai.ClaudeClient, allocator, key, model, "claude");
            printResult(r);
            if (r.success) passed += 1 else failed += 1;
        } else |_| {
            std.debug.print("  - claude: SKIPPED (no ANTHROPIC_API_KEY)\n", .{});
            skipped += 1;
        }
    }

    // Grok
    if (test_all or test_grok) {
        const model = cfg.getModelOr("xai", "default", model_config.Defaults.xai_default);
        if (getEnvVar(allocator, "XAI_API_KEY")) |key| {
            defer allocator.free(key);
            const r = testProviderToolCalling(ai.GrokClient, allocator, key, model, "grok");
            printResult(r);
            if (r.success) passed += 1 else failed += 1;
        } else |_| {
            std.debug.print("  - grok: SKIPPED (no XAI_API_KEY)\n", .{});
            skipped += 1;
        }
    }

    // Gemini
    if (test_all or test_gemini) {
        const model = cfg.getModelOr("google", "default", model_config.Defaults.google_default);
        const key = getEnvVar(allocator, "GOOGLE_GENAI_API_KEY") catch
            getEnvVar(allocator, "GEMINI_API_KEY") catch null;
        if (key) |k| {
            defer allocator.free(k);
            const r = testProviderToolCalling(ai.GeminiClient, allocator, k, model, "gemini");
            printResult(r);
            if (r.success) passed += 1 else failed += 1;
        } else {
            std.debug.print("  - gemini: SKIPPED (no GOOGLE_GENAI_API_KEY)\n", .{});
            skipped += 1;
        }
    }

    // OpenAI (Chat Completions path with tools)
    if (test_all or test_openai) {
        const model = cfg.getModelOr("openai", "default", "gpt-5.2");
        if (getEnvVar(allocator, "OPENAI_API_KEY")) |key| {
            defer allocator.free(key);
            const r = testProviderToolCalling(ai.OpenAIClient, allocator, key, model, "openai");
            printResult(r);
            if (r.success) passed += 1 else failed += 1;
        } else |_| {
            std.debug.print("  - openai: SKIPPED (no OPENAI_API_KEY)\n", .{});
            skipped += 1;
        }
    }

    // Summary
    std.debug.print("\n═══════════════════════════════════════════════════\n", .{});
    std.debug.print("Results: {d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    std.debug.print("═══════════════════════════════════════════════════\n\n", .{});
}
