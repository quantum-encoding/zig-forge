// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! AI Providers CLI Tool
//! Universal command-line interface for Claude, DeepSeek, Gemini, Grok, and Vertex AI
//!
//! Usage:
//!   zig-ai [provider] [options] "prompt"
//!   zig-ai --interactive [provider]
//!   zig-ai --list-providers
//!
//! Examples:
//!   zig-ai deepseek "What is Zig?"
//!   zig-ai claude --interactive
//!   zig-ai gemini --temp 0.5 "Explain async/await"

const std = @import("std");

/// Get current Unix timestamp in seconds (pure Zig via Io)
fn getCurrentTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
const ai = @import("ai.zig");
const model_costs = @import("model_costs.zig");

/// Get environment variable value (borrowed slice from environ map)
fn getEnvVar(environ_map: *const std.process.Environ.Map, key: []const u8) ![]const u8 {
    return environ_map.get(key) orelse error.EnvironmentVariableNotFound;
}

pub const CLIConfig = struct {
    provider: Provider = .deepseek,
    interactive: bool = false,
    temperature: f32 = 1.0,
    max_tokens: u32 = 4096,
    system_prompt: ?[]const u8 = null,
    save_conversation: bool = false,
    show_usage: bool = true,
    show_cost: bool = true,
};

pub const Provider = enum {
    claude,
    deepseek,
    gemini,
    grok,
    vertex,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        if (std.mem.eql(u8, s, "grok")) return .grok;
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        return null;
    }

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .deepseek => "deepseek",
            .gemini => "gemini",
            .grok => "grok",
            .vertex => "vertex",
        };
    }

    pub fn displayName(self: Provider) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .deepseek => "DeepSeek",
            .gemini => "Gemini",
            .grok => "Grok",
            .vertex => "Vertex AI",
        };
    }

    pub fn getEnvVar(self: Provider) []const u8 {
        return switch (self) {
            .claude => "ANTHROPIC_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .grok => "XAI_API_KEY",
            .vertex => "VERTEX_PROJECT_ID",
        };
    }

    pub fn getDefaultModel(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude-3-7-sonnet-20250219",
            .deepseek => "deepseek-chat",
            .gemini => "gemini-2.5-flash",
            .grok => "grok-2-latest",
            .vertex => "gemini-2.5-pro",
        };
    }

    /// Get provider name for cost lookup
    pub fn getCostProviderName(self: Provider) []const u8 {
        return switch (self) {
            .claude => "anthropic",
            .deepseek => "deepseek",
            .gemini => "google",
            .grok => "xai",
            .vertex => "google",
        };
    }

    /// Calculate cost using actual model pricing from model_costs.csv
    pub fn calculateCost(self: Provider, model: []const u8, input_tokens: u32, output_tokens: u32) f64 {
        const provider_name = self.getCostProviderName();
        return model_costs.calculateCost(provider_name, model, input_tokens, output_tokens);
    }
};

pub const CLI = struct {
    allocator: std.mem.Allocator,
    config: CLIConfig,
    environ_map: *const std.process.Environ.Map,

    pub fn init(allocator: std.mem.Allocator, config: CLIConfig, environ_map: *const std.process.Environ.Map) CLI {
        return .{
            .allocator = allocator,
            .config = config,
            .environ_map = environ_map,
        };
    }

    /// Execute a single query
    pub fn query(self: *CLI, prompt: []const u8) !void {
        std.debug.print("\n{s}\n", .{self.config.provider.displayName()});
        std.debug.print("Query: {s}\n\n", .{prompt});

        var response = try self.sendToProvider(prompt, null);
        defer response.deinit();

        std.debug.print("Response:\n{s}\n\n", .{response.message.content});

        if (self.config.show_usage) {
            self.printUsage(response);
        }

        if (self.config.show_cost) {
            self.printCost(response);
        }
    }

    /// Start interactive conversation mode
    pub fn interactive(self: *CLI) !void {
        std.debug.print("\n╔══════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  AI Providers CLI - Interactive Mode            ║\n", .{});
        std.debug.print("║  Provider: {s: <37}║\n", .{self.config.provider.displayName()});
        std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\nCommands:\n", .{});
        std.debug.print("  /help     - Show this help\n", .{});
        std.debug.print("  /clear    - Clear conversation history\n", .{});
        std.debug.print("  /switch   - Switch provider\n", .{});
        std.debug.print("  /quit     - Exit\n", .{});
        std.debug.print("\n", .{});

        var io_threaded = std.Io.Threaded.init_single_threaded;
        const io = io_threaded.io();

        var conversation = try ai.ConversationContext.init(self.allocator, io);
        defer conversation.deinit();

        const stdin_file = std.Io.File.stdin();
        var stdin_buffer: [256]u8 = undefined;
        var stdin_reader = stdin_file.reader(io, &stdin_buffer);

        const stdout_file = std.Io.File.stdout();
        var stdout_buffer: [256]u8 = undefined;
        var stdout_writer = stdout_file.writer(io, &stdout_buffer);

        while (true) {
            try stdout_writer.interface.writeAll("\n👤 You: ");
            try stdout_writer.interface.flush();

            const input = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed, error.StreamTooLong => return err,
            } orelse break;
            const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

            if (trimmed.len == 0) continue;

            // Handle commands
            if (std.mem.startsWith(u8, trimmed, "/")) {
                if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) {
                    std.debug.print("\n👋 Goodbye!\n\n", .{});
                    break;
                } else if (std.mem.eql(u8, trimmed, "/clear")) {
                    conversation.deinit();
                    conversation = try ai.ConversationContext.init(self.allocator, io);
                    std.debug.print("🗑️  Conversation cleared\n", .{});
                    continue;
                } else if (std.mem.eql(u8, trimmed, "/help")) {
                    std.debug.print("\nCommands:\n", .{});
                    std.debug.print("  /help     - Show this help\n", .{});
                    std.debug.print("  /clear    - Clear conversation history\n", .{});
                    std.debug.print("  /switch   - Switch provider\n", .{});
                    std.debug.print("  /quit     - Exit\n", .{});
                    continue;
                } else if (std.mem.eql(u8, trimmed, "/switch")) {
                    std.debug.print("\nAvailable providers:\n", .{});
                    std.debug.print("  1. claude\n", .{});
                    std.debug.print("  2. deepseek\n", .{});
                    std.debug.print("  3. gemini\n", .{});
                    std.debug.print("  4. grok\n", .{});
                    std.debug.print("  5. vertex\n", .{});
                    try stdout_writer.interface.writeAll("\nEnter provider name: ");
                    try stdout_writer.interface.flush();

                    const provider_input = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                        error.ReadFailed, error.StreamTooLong => return err,
                    } orelse continue;
                    const provider_trimmed = std.mem.trim(u8, provider_input, &std.ascii.whitespace);

                    if (Provider.fromString(provider_trimmed)) |new_provider| {
                        self.config.provider = new_provider;
                        conversation.deinit();
                        conversation = try ai.ConversationContext.init(self.allocator, io);
                        std.debug.print("Switched to {s}\n", .{new_provider.displayName()});
                    } else {
                        std.debug.print("Unknown provider\n", .{});
                    }
                    continue;
                } else {
                    std.debug.print("Unknown command. Type /help for available commands.\n", .{});
                    continue;
                }
            }

            // Send to AI
            const context_slice = conversation.messages.items;
            var response = try self.sendToProvider(trimmed, context_slice);
            defer response.deinit();

            try stdout_writer.interface.print("\n{s}:\n{s}\n", .{ self.config.provider.displayName(), response.message.content });
            try stdout_writer.interface.flush();

            if (self.config.show_usage) {
                self.printUsage(response);
            }

            // Add to conversation history
            const user_msg = ai.AIMessage{
                .id = try ai.common.generateId(self.allocator, io),
                .role = .user,
                .content = try self.allocator.dupe(u8, trimmed),
                .timestamp = getCurrentTimestamp(io),
                .allocator = self.allocator,
            };
            try conversation.addMessage(user_msg);
            try conversation.addMessage(response.message);
        }
    }

    fn sendToProvider(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
    ) !ai.AIResponse {
        const config_base = ai.common.RequestConfig{
            .model = "",
            .max_tokens = self.config.max_tokens,
            .temperature = self.config.temperature,
            .system_prompt = self.config.system_prompt,
        };

        return switch (self.config.provider) {
            .claude => try self.callClaude(prompt, context, config_base),
            .deepseek => try self.callDeepSeek(prompt, context, config_base),
            .gemini => try self.callGemini(prompt, context, config_base),
            .grok => try self.callGrok(prompt, context, config_base),
            .vertex => try self.callVertex(prompt, context, config_base),
        };
    }

    fn callClaude(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = try getEnvVar(self.environ_map, "ANTHROPIC_API_KEY");

        var client = try ai.ClaudeClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.ClaudeClient.defaultConfig();
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn callDeepSeek(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = try getEnvVar(self.environ_map, "DEEPSEEK_API_KEY");

        var client = try ai.DeepSeekClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.DeepSeekClient.defaultConfig();
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn callGemini(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = getEnvVar(self.environ_map, "GEMINI_API_KEY") catch try getEnvVar(self.environ_map, "GOOGLE_GENAI_API_KEY");

        var client = try ai.GeminiClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.GeminiClient.defaultConfig();
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn callGrok(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = try getEnvVar(self.environ_map, "XAI_API_KEY");

        var client = try ai.GrokClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.GrokClient.defaultConfig();
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn callVertex(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const project_id = try getEnvVar(self.environ_map, "VERTEX_PROJECT_ID");

        var client = try ai.VertexClient.init(self.allocator, .{ .project_id = project_id });
        defer client.deinit();

        var config = ai.VertexClient.defaultConfig();
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn printUsage(self: *CLI, response: ai.AIResponse) void {
        _ = self;
        std.debug.print("Tokens: {} in, {} out\n", .{
            response.usage.input_tokens,
            response.usage.output_tokens,
        });
    }

    fn printCost(self: *CLI, response: ai.AIResponse) void {
        const cost = switch (self.config.provider) {
            .deepseek => response.usage.estimateCost(0.14, 0.28),
            .claude => response.usage.estimateCost(3.0, 15.0),
            .gemini => response.usage.estimateCost(0.075, 0.30),
            .grok => response.usage.estimateCost(2.0, 10.0),
            .vertex => response.usage.estimateCost(1.25, 5.0),
        };

        std.debug.print("Estimated cost: ${d:.6}\n", .{cost});
    }
};

pub fn listProviders() void {
    std.debug.print("\nAvailable AI Providers:\n\n", .{});
    std.debug.print("  1. claude    - {s}\n", .{Provider.claude.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.claude.getEnvVar()});

    std.debug.print("  2. deepseek  - {s}\n", .{Provider.deepseek.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.deepseek.getEnvVar()});

    std.debug.print("  3. gemini    - {s}\n", .{Provider.gemini.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.gemini.getEnvVar()});

    std.debug.print("  4. grok      - {s}\n", .{Provider.grok.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.grok.getEnvVar()});

    std.debug.print("  5. vertex    - {s}\n", .{Provider.vertex.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.vertex.getEnvVar()});
}

pub fn printUsage() void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  AI Providers CLI - Universal AI Command Line Tool          ║\n", .{});
    std.debug.print("║  Supports: Claude, DeepSeek, Gemini, Grok, Vertex AI        ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("  zig-ai [provider] \"prompt\"              - One-shot query\n", .{});
    std.debug.print("  zig-ai --interactive [provider]         - Interactive mode\n", .{});
    std.debug.print("  zig-ai --list                           - List providers\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("PROVIDERS:\n", .{});
    std.debug.print("  claude, deepseek, gemini, grok, vertex\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("OPTIONS:\n", .{});
    std.debug.print("  --temperature <f32>    - Set temperature (0.0-2.0)\n", .{});
    std.debug.print("  --max-tokens <u32>     - Set max output tokens\n", .{});
    std.debug.print("  --system <text>        - Set system prompt\n", .{});
    std.debug.print("  --no-usage             - Hide usage stats\n", .{});
    std.debug.print("  --no-cost              - Hide cost estimates\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("  zig-ai deepseek \"What is Zig?\"\n", .{});
    std.debug.print("  zig-ai claude --temperature 0.5 \"Explain async\"\n", .{});
    std.debug.print("  zig-ai --interactive gemini\n", .{});
    std.debug.print("  zig-ai grok --system \"You are a helpful assistant\" \"Hi\"\n", .{});
    std.debug.print("\n", .{});
}
