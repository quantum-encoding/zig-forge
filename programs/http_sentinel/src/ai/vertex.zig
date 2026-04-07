// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Google Vertex AI client
//! Uses gcloud OAuth2 authentication for enterprise-grade AI
//!
//! Prerequisites: gcloud CLI installed and authenticated
//! - gcloud auth login
//! - gcloud auth application-default login

const std = @import("std");

/// Pure Zig timer using Io.Timestamp (no libc)
const Timer = struct {
    start_ts: std.Io.Timestamp,
    io: std.Io,

    pub fn start(io: std.Io) Timer {
        return .{ .start_ts = std.Io.Timestamp.now(io, .awake), .io = io };
    }

    pub fn read(self: *const Timer) u64 {
        const elapsed = self.start_ts.untilNow(self.io, .awake);
        const ns = elapsed.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// Get current Unix timestamp in seconds (pure Zig via Io)
fn getCurrentTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

pub const VertexClient = struct {
    http_client: HttpClient,
    project_id: []const u8,
    location: []const u8,
    allocator: std.mem.Allocator,
    access_token: ?[]u8 = null,

    const VERTEX_API_BASE = "https://us-central1-aiplatform.googleapis.com/v1";
    const DEFAULT_LOCATION = "us-central1";
    const MAX_TURNS = 100;

    /// Available Vertex AI models
    pub const Models = struct {
        // Gemini (native Vertex generateContent)
        pub const GEMINI_PRO_2_5 = "gemini-2.5-pro";
        pub const GEMINI_FLASH_2_5 = "gemini-2.5-flash";
        pub const GEMINI_FLASH_LITE_2_5 = "gemini-2.5-flash-lite";
        pub const GEMINI_PRO_3 = "gemini-3-pro-preview";
        pub const GEMINI_FLASH_3 = "gemini-3-flash-preview";

        // MaaS — OpenAI chat/completions format (global endpoint)
        pub const DEEPSEEK_V3_2 = "deepseek-ai/deepseek-v3.2-maas";
        pub const DEEPSEEK_OCR = "deepseek-ai/deepseek-ocr-maas";
        pub const GLM_5 = "zai-org/glm-5-maas";

        // MaaS — Mistral rawPredict (europe-west4)
        pub const CODESTRAL_2 = "codestral-2";
        pub const MISTRAL_MEDIUM_3 = "mistral-medium-3";
        pub const MISTRAL_SMALL = "mistral-small-2503";
    };

    /// Model routing: determines which endpoint pattern to use.
    const ModelRoute = enum { gemini, maas_openai, maas_mistral };

    fn routeModel(model: []const u8) ModelRoute {
        // MaaS OpenAI-compatible (global endpoint)
        if (std.mem.startsWith(u8, model, "deepseek-ai/")) return .maas_openai;
        if (std.mem.startsWith(u8, model, "zai-org/")) return .maas_openai;
        // MaaS Mistral (rawPredict, europe-west4)
        if (std.mem.startsWith(u8, model, "codestral")) return .maas_mistral;
        if (std.mem.startsWith(u8, model, "mistral-")) return .maas_mistral;
        // Default: Gemini generateContent
        return .gemini;
    }

    pub const Config = struct {
        project_id: []const u8,
        location: []const u8 = DEFAULT_LOCATION,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !VertexClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .project_id = config.project_id,
            .location = config.location,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VertexClient) void {
        if (self.access_token) |token| {
            self.allocator.free(token);
        }
        self.http_client.deinit();
    }

    /// Get OAuth2 access token. Tries in order:
    /// 1. Cached token (from previous call)
    /// 2. GCLOUD_ACCESS_TOKEN or GOOGLE_CLOUD_ACCESS_TOKEN env var
    /// 3. Auto-refresh via gcp-token-refresh subprocess
    /// 4. Auto-refresh via gcloud auth print-access-token
    fn getAccessToken(self: *VertexClient) ![]const u8 {
        if (self.access_token) |token| return token;

        // Check env vars using process.run to echo them (pure Zig — no libc getenv)
        // Note: On a Zig OS, env vars would come from the process init environ_map
        // For now, try the token commands directly since env access requires libc on POSIX
        {}

        // Try gcp-token-refresh (fast, no interactive auth)
        if (self.runTokenCommand("gcp-token-refresh")) |token| {
            self.access_token = token;
            return token;
        }

        // Fall back to gcloud CLI
        if (self.runTokenCommand("gcloud auth print-access-token")) |token| {
            self.access_token = token;
            return token;
        }

        std.debug.print("Error: Cannot get GCP access token\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  1. export GCLOUD_ACCESS_TOKEN=$(gcp-token-refresh)\n", .{});
        std.debug.print("  2. export GCLOUD_ACCESS_TOKEN=$(gcloud auth print-access-token)\n", .{});
        std.debug.print("  3. Install gcp-token-refresh: go install github.com/quantum-encoding/gcp-token-refresh@latest\n\n", .{});
        return common.AIError.AuthenticationFailed;
    }

    /// Run a shell command and capture stdout as the token (trimmed).
    /// Pure Zig — uses std.process.run instead of popen.
    fn runTokenCommand(self: *VertexClient, cmd: []const u8) ?[]u8 {
        var io_threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer io_threaded.deinit();
        const io = io_threaded.io();

        const result = std.process.run(self.allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return null;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited) return null;

        // Trim whitespace/newlines
        const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        return self.allocator.dupe(u8, trimmed) catch null;
    }

    /// Send a single message
    pub fn sendMessage(
        self: *VertexClient,
        prompt: []const u8,
        config: common.RequestConfig,
    ) !common.AIResponse {
        return self.sendMessageWithContext(prompt, &[_]common.AIMessage{}, config);
    }

    /// Send a message with conversation context
    pub fn sendMessageWithContext(
        self: *VertexClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
    ) !common.AIResponse {
        const route = routeModel(config.model);

        // MaaS models use OpenAI or Mistral format
        if (route == .maas_openai or route == .maas_mistral) {
            return self.sendMaasMessage(prompt, context, config, route);
        }

        // Gemini native format below
        var timer = Timer.start(self.http_client.io());
        const token = try self.getAccessToken();

        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(self.allocator);

        try contents.appendSlice(self.allocator, "[");

        for (context, 0..) |msg, i| {
            if (i > 0) try contents.appendSlice(self.allocator, ",");
            try self.appendMessage(&contents, msg);
        }

        if (context.len > 0) try contents.appendSlice(self.allocator, ",");
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);
        const prompt_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","parts":[{{"text":"{s}"}}]}}
        , .{escaped_prompt});
        defer self.allocator.free(prompt_json);
        try contents.appendSlice(self.allocator, prompt_json);

        try contents.appendSlice(self.allocator, "]");

        var turn_count: u32 = 0;
        var total_tokens: u32 = 0;

        while (turn_count < config.max_turns) : (turn_count += 1) {
            const payload = try self.buildRequestPayload(contents.items, config);
            defer self.allocator.free(payload);

            const response = try self.makeRequest(config.model, token, payload);
            defer self.allocator.free(response);

            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                response,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            // Extract usage
            if (parsed.value.object.get("usageMetadata")) |usage| {
                if (usage.object.get("totalTokenCount")) |total| {
                    total_tokens = @intCast(total.integer);
                }
            }

            // Extract candidates
            const candidates = parsed.value.object.get("candidates") orelse
                return common.AIError.InvalidResponse;

            if (candidates.array.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const candidate = candidates.array.items[0];
            const content = candidate.object.get("content") orelse
                return common.AIError.InvalidResponse;

            const parts = content.object.get("parts") orelse
                return common.AIError.InvalidResponse;

            // Check for function calls
            var has_function_call = false;
            for (parts.array.items) |part| {
                if (part.object.get("functionCall")) |_| {
                    has_function_call = true;
                    break;
                }
            }

            if (has_function_call) {
                // Extract function call details from response
                var func_result: std.ArrayList(u8) = .empty;
                defer func_result.deinit(self.allocator);

                for (parts.array.items) |part| {
                    if (part.object.get("functionCall")) |fc| {
                        const func_name = if (fc.object.get("name")) |n| n.string else "unknown";
                        // Build a text representation of the function call for the response
                        // In production, this would dispatch to actual tool implementations
                        if (func_result.items.len > 0) {
                            try func_result.appendSlice(self.allocator, "\n");
                        }
                        try func_result.appendSlice(self.allocator, "[Function call: ");
                        try func_result.appendSlice(self.allocator, func_name);

                        // Include arguments if available
                        if (fc.object.get("args")) |args| {
                            try func_result.appendSlice(self.allocator, "(");
                            // Serialize args object keys as parameter hints
                            var args_iter = args.object.iterator();
                            var first = true;
                            while (args_iter.next()) |entry| {
                                if (!first) try func_result.appendSlice(self.allocator, ", ");
                                first = false;
                                try func_result.appendSlice(self.allocator, entry.key_ptr.*);
                                try func_result.appendSlice(self.allocator, "=...");
                            }
                            try func_result.appendSlice(self.allocator, ")");
                        }

                        try func_result.appendSlice(self.allocator, "]");
                    }
                }

                // If we only have function calls with no text, return the function call description
                if (func_result.items.len > 0) {
                    const elapsed_ns = timer.read();
                    return common.AIResponse{
                        .message = .{
                            .id = try common.generateId(self.allocator),
                            .role = .assistant,
                            .content = try func_result.toOwnedSlice(self.allocator),
                            .timestamp = getCurrentTimestamp(self.http_client.io()),
                            .allocator = self.allocator,
                        },
                        .usage = .{
                            .input_tokens = 0,
                            .output_tokens = total_tokens,
                        },
                        .metadata = .{
                            .model = try self.allocator.dupe(u8, config.model),
                            .provider = try self.allocator.dupe(u8, "vertex"),
                            .turns_used = turn_count + 1,
                            .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                            .allocator = self.allocator,
                        },
                    };
                }
            }

            // Extract text response
            var text_content: std.ArrayList(u8) = .empty;
            defer text_content.deinit(self.allocator);

            for (parts.array.items) |part| {
                if (part.object.get("text")) |text| {
                    if (text_content.items.len > 0) {
                        try text_content.appendSlice(self.allocator, "\n");
                    }
                    try text_content.appendSlice(self.allocator, text.string);
                }
            }

            if (text_content.items.len == 0) {
                return common.AIError.InvalidResponse;
            }

            const elapsed_ns = timer.read();

            return common.AIResponse{
                .message = .{
                    .id = try common.generateId(self.allocator),
                    .role = .assistant,
                    .content = try text_content.toOwnedSlice(self.allocator),
                    .timestamp = getCurrentTimestamp(self.http_client.io()),
                    .allocator = self.allocator,
                },
                .usage = .{
                    .input_tokens = 0, // Vertex doesn't provide breakdown
                    .output_tokens = total_tokens,
                },
                .metadata = .{
                    .model = try self.allocator.dupe(u8, config.model),
                    .provider = try self.allocator.dupe(u8, "vertex"),
                    .turns_used = turn_count + 1,
                    .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                    .allocator = self.allocator,
                },
            };
        }

        return common.AIError.MaxTurnsReached;
    }

    /// Send message via MaaS (OpenAI chat/completions or Mistral rawPredict format)
    fn sendMaasMessage(
        self: *VertexClient,
        prompt: []const u8,
        context: []const common.AIMessage,
        config: common.RequestConfig,
        route: ModelRoute,
    ) !common.AIResponse {
        var timer = Timer.start(self.http_client.io());
        const token = try self.getAccessToken();

        // Build OpenAI-style messages array
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"model\":\"");
        try payload.appendSlice(self.allocator, config.model);
        try payload.appendSlice(self.allocator, "\",\"messages\":[");

        // System prompt
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_msg = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"system","content":"{s}"}},
            , .{escaped});
            defer self.allocator.free(sys_msg);
            try payload.appendSlice(self.allocator, sys_msg);
        }

        // Context messages
        for (context) |msg| {
            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
                .tool => "tool",
            };
            const escaped = try common.escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped);
            const msg_json = try std.fmt.allocPrint(self.allocator,
                \\{{"role":"{s}","content":"{s}"}},
            , .{ role_str, escaped });
            defer self.allocator.free(msg_json);
            try payload.appendSlice(self.allocator, msg_json);
        }

        // Current prompt
        const escaped_prompt = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped_prompt);
        const user_msg = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"user","content":"{s}"}}
        , .{escaped_prompt});
        defer self.allocator.free(user_msg);
        try payload.appendSlice(self.allocator, user_msg);

        // Close messages, add params
        const params = try std.fmt.allocPrint(self.allocator,
            \\],"max_tokens":{},"temperature":{d}}}
        , .{ config.max_tokens, config.temperature });
        defer self.allocator.free(params);
        try payload.appendSlice(self.allocator, params);

        _ = route; // Both maas_openai and maas_mistral use this format
        const response = try self.makeRequest(config.model, token, payload.items);
        defer self.allocator.free(response);

        // Parse OpenAI-style response
        const parsed = try std.json.parseFromSlice(
            std.json.Value, self.allocator, response, .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Extract content from choices[0].message.content
        const choices = parsed.value.object.get("choices") orelse return common.AIError.InvalidResponse;
        if (choices.array.items.len == 0) return common.AIError.InvalidResponse;
        const message = choices.array.items[0].object.get("message") orelse return common.AIError.InvalidResponse;
        const content_val = message.object.get("content") orelse return common.AIError.InvalidResponse;
        const text = content_val.string;

        // Extract usage
        var input_tokens: u32 = 0;
        var output_tokens: u32 = 0;
        if (parsed.value.object.get("usage")) |usage| {
            if (usage.object.get("prompt_tokens")) |pt| input_tokens = @intCast(pt.integer);
            if (usage.object.get("completion_tokens")) |ct| output_tokens = @intCast(ct.integer);
        }

        const elapsed_ns = timer.read();

        return common.AIResponse{
            .message = .{
                .id = try common.generateId(self.allocator),
                .role = .assistant,
                .content = try self.allocator.dupe(u8, text),
                .timestamp = getCurrentTimestamp(self.http_client.io()),
                .allocator = self.allocator,
            },
            .usage = .{
                .input_tokens = input_tokens,
                .output_tokens = output_tokens,
            },
            .metadata = .{
                .model = try self.allocator.dupe(u8, config.model),
                .provider = try self.allocator.dupe(u8, "vertex-maas"),
                .turns_used = 1,
                .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
                .allocator = self.allocator,
            },
        };
    }

    fn buildRequestPayload(
        self: *VertexClient,
        contents: []const u8,
        config: common.RequestConfig,
    ) ![]u8 {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{");

        const contents_part = try std.fmt.allocPrint(self.allocator, "\"contents\":{s},", .{contents});
        defer self.allocator.free(contents_part);
        try payload.appendSlice(self.allocator, contents_part);

        // System instruction
        if (config.system_prompt) |system| {
            const escaped = try common.escapeJsonString(self.allocator, system);
            defer self.allocator.free(escaped);
            const sys_part = try std.fmt.allocPrint(self.allocator,
                \\"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},
            , .{escaped});
            defer self.allocator.free(sys_part);
            try payload.appendSlice(self.allocator, sys_part);
        }

        // Generation config
        const gen_config = try std.fmt.allocPrint(self.allocator,
            \\"generationConfig":{{"temperature":{d},"maxOutputTokens":{},"topP":{d}}}
        , .{ config.temperature, config.max_tokens, config.top_p });
        defer self.allocator.free(gen_config);
        try payload.appendSlice(self.allocator, gen_config);

        try payload.appendSlice(self.allocator, "}");

        return payload.toOwnedSlice(self.allocator);
    }

    fn makeRequest(
        self: *VertexClient,
        model: []const u8,
        access_token: []const u8,
        payload: []const u8,
    ) ![]u8 {
        const route = routeModel(model);
        const endpoint = switch (route) {
            .gemini => try std.fmt.allocPrint(
                self.allocator,
                "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:generateContent",
                .{ self.location, self.project_id, self.location, model },
            ),
            .maas_openai => try std.fmt.allocPrint(
                self.allocator,
                "https://aiplatform.googleapis.com/v1beta1/projects/{s}/locations/global/endpoints/openapi/chat/completions",
                .{self.project_id},
            ),
            .maas_mistral => try std.fmt.allocPrint(
                self.allocator,
                "https://europe-west4-aiplatform.googleapis.com/v1/projects/{s}/locations/europe-west4/publishers/mistralai/models/{s}:rawPredict",
                .{ self.project_id, model },
            ),
        };
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{access_token},
        );
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status, response.body);
        }

        return try self.allocator.dupe(u8, response.body);
    }

    fn handleErrorResponse(
        self: *VertexClient,
        status: std.http.Status,
        body: []const u8,
    ) common.AIError {
        _ = self;

        return switch (status) {
            .unauthorized, .forbidden => common.AIError.AuthenticationFailed,
            .too_many_requests => common.AIError.RateLimitExceeded,
            .bad_request => common.parseApiError(body),
            else => common.AIError.ApiRequestFailed,
        };
    }

    fn appendMessage(self: *VertexClient, writer: *std.ArrayList(u8), msg: common.AIMessage) !void {
        const role = switch (msg.role) {
            .user => "user",
            .assistant => "model",
            else => "user",
        };

        const escaped = try common.escapeJsonString(self.allocator, msg.content);
        defer self.allocator.free(escaped);

        const msg_json = try std.fmt.allocPrint(self.allocator,
            \\{{"role":"{s}","parts":[{{"text":"{s}"}}]}}
        , .{ role, escaped });
        defer self.allocator.free(msg_json);
        try writer.appendSlice(self.allocator, msg_json);
    }

    /// Helper: Create default config for Gemini Pro on Vertex
    pub fn defaultConfig() common.RequestConfig {
        return .{
            .model = Models.GEMINI_PRO_2_5,
            .max_tokens = 65536,
            .temperature = 0.7,
        };
    }

    /// Helper: Create config for fast responses
    pub fn fastConfig() common.RequestConfig {
        return .{
            .model = Models.GEMINI_FLASH_2_5,
            .max_tokens = 65536,
            .temperature = 0.7,
        };
    }
};

test "VertexClient initialization" {
    const allocator = std.testing.allocator;

    var client = try VertexClient.init(allocator, .{
        .project_id = "test-project",
        .location = "us-central1",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("test-project", client.project_id);
    try std.testing.expectEqualStrings("us-central1", client.location);
}

test "VertexClient config helpers" {
    const default_cfg = VertexClient.defaultConfig();
    try std.testing.expectEqualStrings(VertexClient.Models.GEMINI_PRO_2_5, default_cfg.model);

    const fast_cfg = VertexClient.fastConfig();
    try std.testing.expectEqualStrings(VertexClient.Models.GEMINI_FLASH_2_5, fast_cfg.model);
}
