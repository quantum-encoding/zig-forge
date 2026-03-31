// Model Connectivity Test Suite
// Tests all configured AI providers and logs responses
// Run with: zig build test-models -- [provider]
// Or run all: zig build test-models

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const ai = http_sentinel.ai;
const model_config = @import("config");

const TestResult = struct {
    provider: []const u8,
    model: []const u8,
    success: bool,
    response_preview: []const u8,
    input_tokens: u32,
    output_tokens: u32,
    latency_ms: u64,
    error_message: ?[]const u8,
    timestamp: i64,
};

const TestLog = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(TestResult),

    fn init(allocator: std.mem.Allocator) TestLog {
        return .{
            .allocator = allocator,
            .results = .empty,
        };
    }

    fn deinit(self: *TestLog) void {
        for (self.results.items) |r| {
            self.allocator.free(r.response_preview);
            if (r.error_message) |e| self.allocator.free(e);
        }
        self.results.deinit(self.allocator);
    }

    fn add(self: *TestLog, result: TestResult) !void {
        try self.results.append(self.allocator, result);
    }

    fn writeJson(self: *TestLog, path: []const u8) !void {
        // Use C file API for Zig 0.16 compatibility
        var path_buf: [512]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const file = std.c.fopen(path_buf[0..path.len :0], "w") orelse return error.FileOpenFailed;
        defer _ = std.c.fclose(file);

        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        const a = self.allocator;

        try json_buf.appendSlice(a, "{\n  \"test_run\": \"");

        // Add timestamp
        var time_buf: [32]u8 = undefined;
        const time_str = getTimestamp(&time_buf);
        try json_buf.appendSlice(a, time_str);

        try json_buf.appendSlice(a, "\",\n  \"results\": [\n");

        for (self.results.items, 0..) |r, i| {
            if (i > 0) try json_buf.appendSlice(a, ",\n");
            try json_buf.appendSlice(a, "    {\n");

            var fmt_buf: [256]u8 = undefined;
            var len = std.fmt.bufPrint(&fmt_buf, "      \"provider\": \"{s}\",\n", .{r.provider}) catch continue;
            try json_buf.appendSlice(a, len);
            len = std.fmt.bufPrint(&fmt_buf, "      \"model\": \"{s}\",\n", .{r.model}) catch continue;
            try json_buf.appendSlice(a, len);
            len = std.fmt.bufPrint(&fmt_buf, "      \"success\": {s},\n", .{if (r.success) "true" else "false"}) catch continue;
            try json_buf.appendSlice(a, len);
            len = std.fmt.bufPrint(&fmt_buf, "      \"latency_ms\": {d},\n", .{r.latency_ms}) catch continue;
            try json_buf.appendSlice(a, len);
            len = std.fmt.bufPrint(&fmt_buf, "      \"input_tokens\": {d},\n", .{r.input_tokens}) catch continue;
            try json_buf.appendSlice(a, len);
            len = std.fmt.bufPrint(&fmt_buf, "      \"output_tokens\": {d},\n", .{r.output_tokens}) catch continue;
            try json_buf.appendSlice(a, len);

            // Escape response preview for JSON
            try json_buf.appendSlice(a, "      \"response_preview\": \"");
            for (r.response_preview) |c| {
                switch (c) {
                    '"' => try json_buf.appendSlice(a, "\\\""),
                    '\\' => try json_buf.appendSlice(a, "\\\\"),
                    '\n' => try json_buf.appendSlice(a, "\\n"),
                    '\r' => try json_buf.appendSlice(a, "\\r"),
                    '\t' => try json_buf.appendSlice(a, "\\t"),
                    else => try json_buf.append(a, c),
                }
            }
            try json_buf.appendSlice(a, "\"");

            if (r.error_message) |e| {
                try json_buf.appendSlice(a, ",\n      \"error\": \"");
                for (e) |c| {
                    switch (c) {
                        '"' => try json_buf.appendSlice(a, "\\\""),
                        '\\' => try json_buf.appendSlice(a, "\\\\"),
                        '\n' => try json_buf.appendSlice(a, "\\n"),
                        else => try json_buf.append(a, c),
                    }
                }
                try json_buf.appendSlice(a, "\"");
            }
            try json_buf.appendSlice(a, "\n    }");
        }

        try json_buf.appendSlice(a, "\n  ]\n}\n");

        // Write to file
        _ = std.c.fwrite(json_buf.items.ptr, 1, json_buf.items.len, file);
    }
};

// C time functions
const time_t = i64;
const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};
extern "c" fn time(timer: ?*time_t) time_t;
extern "c" fn localtime_r(timer: *const time_t, result: *tm) ?*tm;

fn getTimestamp(buf: []u8) []const u8 {
    var t = time(null);
    var tm_result: tm = undefined;
    if (localtime_r(&t, &tm_result)) |local| {
        const year: u32 = @intCast(@as(i32, local.tm_year) + 1900);
        const month: u32 = @intCast(@as(i32, local.tm_mon) + 1);
        const day: u32 = @intCast(local.tm_mday);
        const hour: u32 = @intCast(local.tm_hour);
        const min: u32 = @intCast(local.tm_min);
        const sec: u32 = @intCast(local.tm_sec);
        const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            year, month, day, hour, min, sec,
        }) catch return "unknown";
        return result;
    }
    return "unknown";
}

fn getEnvVar(allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
    const value = std.c.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

const TEST_PROMPT = "Reply with exactly: 'API test successful' and nothing else.";

pub fn testClaude(allocator: std.mem.Allocator, log: *TestLog, cfg: *model_config.ModelConfig) !void {
    const model = cfg.getModelOr("anthropic", "default", model_config.Defaults.anthropic_default);
    std.debug.print("Testing Claude ({s})...\n", .{model});

    const start = time(null) * 1000;

    const api_key = getEnvVar(allocator, "ANTHROPIC_API_KEY") catch |e| {
        try log.add(.{
            .provider = "claude",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_message = try allocator.dupe(u8, "ANTHROPIC_API_KEY not set"),
            .timestamp = start,
        });
        return e;
    };
    defer allocator.free(api_key);

    var client = try ai.ClaudeClient.init(allocator, api_key);
    defer client.deinit();

    var req_config = ai.ClaudeClient.defaultConfig();
    req_config.model = model; // Use model from TOML config
    req_config.max_tokens = 100;

    var response = client.sendMessage(TEST_PROMPT, req_config) catch |e| {
        const latency = @as(u64, @intCast(time(null) * 1000 - start));
        try log.add(.{
            .provider = "claude",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = latency,
            .error_message = try allocator.dupe(u8, @errorName(e)),
            .timestamp = start,
        });
        return e;
    };
    defer response.deinit();

    const latency = @as(u64, @intCast(time(null) * 1000 - start));
    const preview_len = @min(response.message.content.len, 100);

    try log.add(.{
        .provider = "claude",
        .model = model,
        .success = true,
        .response_preview = try allocator.dupe(u8, response.message.content[0..preview_len]),
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = latency,
        .error_message = null,
        .timestamp = start,
    });

    std.debug.print("  ✓ {s} - {d}ms, {d}/{d} tokens\n", .{
        response.message.content[0..preview_len],
        latency,
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}

pub fn testDeepSeek(allocator: std.mem.Allocator, log: *TestLog, cfg: *model_config.ModelConfig) !void {
    const model = cfg.getModelOr("deepseek", "default", model_config.Defaults.deepseek_default);
    std.debug.print("Testing DeepSeek ({s})...\n", .{model});

    const start = time(null) * 1000;

    const api_key = getEnvVar(allocator, "DEEPSEEK_API_KEY") catch |e| {
        try log.add(.{
            .provider = "deepseek",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_message = try allocator.dupe(u8, "DEEPSEEK_API_KEY not set"),
            .timestamp = start,
        });
        return e;
    };
    defer allocator.free(api_key);

    var client = try ai.DeepSeekClient.init(allocator, api_key);
    defer client.deinit();

    var req_config = ai.DeepSeekClient.defaultConfig();
    req_config.model = model; // Use model from TOML config
    req_config.max_tokens = 100;

    var response = client.sendMessage(TEST_PROMPT, req_config) catch |e| {
        const latency = @as(u64, @intCast(time(null) * 1000 - start));
        try log.add(.{
            .provider = "deepseek",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = latency,
            .error_message = try allocator.dupe(u8, @errorName(e)),
            .timestamp = start,
        });
        return e;
    };
    defer response.deinit();

    const latency = @as(u64, @intCast(time(null) * 1000 - start));
    const preview_len = @min(response.message.content.len, 100);

    try log.add(.{
        .provider = "deepseek",
        .model = model,
        .success = true,
        .response_preview = try allocator.dupe(u8, response.message.content[0..preview_len]),
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = latency,
        .error_message = null,
        .timestamp = start,
    });

    std.debug.print("  ✓ {s} - {d}ms, {d}/{d} tokens\n", .{
        response.message.content[0..preview_len],
        latency,
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}

pub fn testGemini(allocator: std.mem.Allocator, log: *TestLog, cfg: *model_config.ModelConfig) !void {
    const model = cfg.getModelOr("google", "default", model_config.Defaults.google_default);
    std.debug.print("Testing Gemini ({s})...\n", .{model});

    const start = time(null) * 1000;

    // Try GOOGLE_GENAI_API_KEY first, then GEMINI_API_KEY as fallback
    const api_key = getEnvVar(allocator, "GOOGLE_GENAI_API_KEY") catch
        getEnvVar(allocator, "GEMINI_API_KEY") catch |e| {
        try log.add(.{
            .provider = "gemini",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_message = try allocator.dupe(u8, "GOOGLE_GENAI_API_KEY/GEMINI_API_KEY not set"),
            .timestamp = start,
        });
        return e;
    };
    defer allocator.free(api_key);

    var client = try ai.GeminiClient.init(allocator, api_key);
    defer client.deinit();

    var req_config = ai.GeminiClient.defaultConfig();
    req_config.model = model;
    req_config.max_tokens = 100;

    var response = client.sendMessage(TEST_PROMPT, req_config) catch |e| {
        const latency = @as(u64, @intCast(time(null) * 1000 - start));
        try log.add(.{
            .provider = "gemini",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = latency,
            .error_message = try allocator.dupe(u8, @errorName(e)),
            .timestamp = start,
        });
        return e;
    };
    defer response.deinit();

    const latency = @as(u64, @intCast(time(null) * 1000 - start));
    const preview_len = @min(response.message.content.len, 100);

    try log.add(.{
        .provider = "gemini",
        .model = model,
        .success = true,
        .response_preview = try allocator.dupe(u8, response.message.content[0..preview_len]),
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = latency,
        .error_message = null,
        .timestamp = start,
    });

    std.debug.print("  ✓ {s} - {d}ms, {d}/{d} tokens\n", .{
        response.message.content[0..preview_len],
        latency,
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}

pub fn testGrok(allocator: std.mem.Allocator, log: *TestLog, cfg: *model_config.ModelConfig) !void {
    const model = cfg.getModelOr("xai", "default", model_config.Defaults.xai_default);
    std.debug.print("Testing Grok ({s})...\n", .{model});

    const start = time(null) * 1000;

    const api_key = getEnvVar(allocator, "XAI_API_KEY") catch |e| {
        try log.add(.{
            .provider = "grok",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_message = try allocator.dupe(u8, "XAI_API_KEY not set"),
            .timestamp = start,
        });
        return e;
    };
    defer allocator.free(api_key);

    var client = try ai.GrokClient.init(allocator, api_key);
    defer client.deinit();

    var req_config = ai.GrokClient.defaultConfig();
    req_config.model = model; // Use model from TOML config
    req_config.max_tokens = 100;

    var response = client.sendMessage(TEST_PROMPT, req_config) catch |e| {
        const latency = @as(u64, @intCast(time(null) * 1000 - start));
        try log.add(.{
            .provider = "grok",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = latency,
            .error_message = try allocator.dupe(u8, @errorName(e)),
            .timestamp = start,
        });
        return e;
    };
    defer response.deinit();

    const latency = @as(u64, @intCast(time(null) * 1000 - start));
    const preview_len = @min(response.message.content.len, 100);

    try log.add(.{
        .provider = "grok",
        .model = model,
        .success = true,
        .response_preview = try allocator.dupe(u8, response.message.content[0..preview_len]),
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = latency,
        .error_message = null,
        .timestamp = start,
    });

    std.debug.print("  ✓ {s} - {d}ms, {d}/{d} tokens\n", .{
        response.message.content[0..preview_len],
        latency,
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}

pub fn testOpenAI(allocator: std.mem.Allocator, log: *TestLog, cfg: *model_config.ModelConfig) !void {
    const model = cfg.getModelOr("openai", "default", "gpt-5.2");
    std.debug.print("Testing OpenAI ({s})...\n", .{model});

    const start = time(null) * 1000;

    const api_key = getEnvVar(allocator, "OPENAI_API_KEY") catch |e| {
        try log.add(.{
            .provider = "openai",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = 0,
            .error_message = try allocator.dupe(u8, "OPENAI_API_KEY not set"),
            .timestamp = start,
        });
        return e;
    };
    defer allocator.free(api_key);

    var client = try ai.OpenAIClient.init(allocator, api_key);
    defer client.deinit();

    var req_config = ai.OpenAIClient.defaultConfig();
    req_config.model = model;
    req_config.max_tokens = 100;

    var response = client.sendMessage(TEST_PROMPT, req_config) catch |e| {
        const latency = @as(u64, @intCast(time(null) * 1000 - start));
        try log.add(.{
            .provider = "openai",
            .model = model,
            .success = false,
            .response_preview = try allocator.dupe(u8, ""),
            .input_tokens = 0,
            .output_tokens = 0,
            .latency_ms = latency,
            .error_message = try allocator.dupe(u8, @errorName(e)),
            .timestamp = start,
        });
        return e;
    };
    defer response.deinit();

    const latency = @as(u64, @intCast(time(null) * 1000 - start));
    const preview_len = @min(response.message.content.len, 100);

    try log.add(.{
        .provider = "openai",
        .model = model,
        .success = true,
        .response_preview = try allocator.dupe(u8, response.message.content[0..preview_len]),
        .input_tokens = response.usage.input_tokens,
        .output_tokens = response.usage.output_tokens,
        .latency_ms = latency,
        .error_message = null,
        .timestamp = start,
    });

    std.debug.print("  ✓ {s} - {d}ms, {d}/{d} tokens\n", .{
        response.message.content[0..preview_len],
        latency,
        response.usage.input_tokens,
        response.usage.output_tokens,
    });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Model Connectivity Test Suite                   ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var cfg = model_config.ModelConfig.init(allocator);
    defer cfg.deinit();

    var log = TestLog.init(allocator);
    defer log.deinit();

    // Check environment variable for specific provider to test
    // Set TEST_PROVIDER=claude,deepseek,gemini,grok,openai or leave unset for all
    var test_all = true;
    var test_claude = false;
    var test_deepseek = false;
    var test_gemini = false;
    var test_grok = false;
    var test_openai = false;

    if (std.c.getenv("TEST_PROVIDER")) |provider_ptr| {
        const providers = std.mem.span(provider_ptr);
        test_all = false;
        if (std.mem.indexOf(u8, providers, "claude") != null) test_claude = true;
        if (std.mem.indexOf(u8, providers, "deepseek") != null) test_deepseek = true;
        if (std.mem.indexOf(u8, providers, "gemini") != null) test_gemini = true;
        if (std.mem.indexOf(u8, providers, "grok") != null) test_grok = true;
        if (std.mem.indexOf(u8, providers, "openai") != null) test_openai = true;
    }

    var passed: u32 = 0;
    var failed: u32 = 0;

    if (test_all or test_claude) {
        testClaude(allocator, &log, &cfg) catch {};
        if (log.results.items.len > 0 and log.results.items[log.results.items.len - 1].success) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    if (test_all or test_deepseek) {
        testDeepSeek(allocator, &log, &cfg) catch {};
        if (log.results.items.len > 0 and log.results.items[log.results.items.len - 1].success) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    if (test_all or test_gemini) {
        testGemini(allocator, &log, &cfg) catch {};
        if (log.results.items.len > 0 and log.results.items[log.results.items.len - 1].success) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    if (test_all or test_grok) {
        testGrok(allocator, &log, &cfg) catch {};
        if (log.results.items.len > 0 and log.results.items[log.results.items.len - 1].success) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    if (test_all or test_openai) {
        testOpenAI(allocator, &log, &cfg) catch {};
        if (log.results.items.len > 0 and log.results.items[log.results.items.len - 1].success) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════\n", .{});
    std.debug.print("Results: {d} passed, {d} failed\n", .{ passed, failed });
    std.debug.print("═══════════════════════════════════════════════════\n", .{});

    // Save log
    log.writeJson("tests/results/model_test_latest.json") catch |e| {
        std.debug.print("Warning: Could not save log: {s}\n", .{@errorName(e)});
    };

    std.debug.print("\nResults saved to tests/results/model_test_latest.json\n", .{});
}
