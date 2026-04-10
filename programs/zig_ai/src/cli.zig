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

// Helper to get environment variable (replaces removed std.process.getEnvVarOwned)
fn getEnvVarOwned(allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
    const value = std.c.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

// Zig 0.16 compatible - get realtime seconds
fn getRealtimeSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
const http_sentinel = @import("http-sentinel");
pub const ai = http_sentinel.ai;
const model_costs = @import("model_costs.zig");
const model_config = @import("config.zig");

pub const CLIConfig = struct {
    provider: Provider = .deepseek,
    model: ?[]const u8 = null, // Explicit model override (null = provider default)
    interactive: bool = false,
    temperature: f32 = 1.0,
    max_tokens: u32 = 64000,
    system_prompt: ?[]const u8 = null,
    save_conversation: bool = false,
    show_usage: bool = true,
    show_cost: bool = true,
    save_code: ?[]const u8 = null, // Base filename for saving code blocks
    image_paths: ?[]const []const u8 = null, // Image files for vision
    server_tools: ?[]const ai.common.ServerSideTool = null, // xAI server-side tools
    mcp_tools: ?[]const ai.common.McpToolConfig = null, // xAI remote MCP tools
    include: ?[]const []const u8 = null, // xAI include parameter
    collection_ids: ?[]const []const u8 = null, // xAI collection IDs for file_search
    collection_max_results: u32 = 10, // Max results from collection search
    file_ids: ?[]const []const u8 = null, // xAI uploaded file IDs for attachment_search
    tool_choice: ?ai.common.ToolChoice = null, // Tool choice control (auto/required/none/function/validated)
    tool_choice_function: ?[]const u8 = null, // Force specific function tool by name
    parallel_tool_calls: ?bool = null, // Enable/disable parallel function calling
    allowed_function_names: ?[]const []const u8 = null, // Restrict to specific functions (Gemini)
    maps_latitude: ?f64 = null, // Google Maps latitude (Gemini only)
    maps_longitude: ?f64 = null, // Google Maps longitude (Gemini only)
    media_resolution: ?ai.common.MediaResolution = null, // Gemini media resolution (low/medium/high/ultra_high)
};

pub const Provider = enum {
    claude,
    deepseek,
    gemini,
    grok,
    openai,
    vertex,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        if (std.mem.eql(u8, s, "grok")) return .grok;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "gpt")) return .openai; // alias
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        return null;
    }

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .deepseek => "deepseek",
            .gemini => "gemini",
            .grok => "grok",
            .openai => "openai",
            .vertex => "vertex",
        };
    }

    pub fn displayName(self: Provider) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .deepseek => "DeepSeek",
            .gemini => "Gemini",
            .grok => "Grok",
            .openai => "GPT-5.2",
            .vertex => "Vertex AI",
        };
    }

    pub fn getEnvVar(self: Provider) [:0]const u8 {
        return switch (self) {
            .claude => "ANTHROPIC_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .grok => "XAI_API_KEY",
            .openai => "OPENAI_API_KEY",
            .vertex => "VERTEX_PROJECT_ID",
        };
    }

    pub fn getDefaultModel(self: Provider, cfg: ?*const model_config.ModelConfig) []const u8 {
        // Try to get model from config: main → default → hardcoded
        if (cfg) |c| {
            const section = self.getConfigSection();
            if (c.getMainModel(section)) |model| {
                return model;
            }
        }
        // Fall back to hardcoded defaults
        return switch (self) {
            .claude => model_config.Defaults.anthropic_default,
            .deepseek => model_config.Defaults.deepseek_default,
            .gemini => model_config.Defaults.google_default,
            .grok => model_config.Defaults.xai_default,
            .openai => model_config.Defaults.openai_default,
            .vertex => model_config.Defaults.vertex_default,
        };
    }

    /// Get the small (cheapest/fastest) model for this provider
    pub fn getSmallModel(self: Provider, cfg: ?*const model_config.ModelConfig) []const u8 {
        if (cfg) |c| {
            const section = self.getConfigSection();
            if (c.getSmallModel(section)) |model| {
                return model;
            }
        }
        return switch (self) {
            .claude => model_config.Defaults.anthropic_small,
            .deepseek => model_config.Defaults.deepseek_small,
            .gemini => model_config.Defaults.google_small,
            .grok => model_config.Defaults.xai_small,
            .openai => model_config.Defaults.openai_small,
            .vertex => model_config.Defaults.vertex_small,
        };
    }

    pub fn getConfigSection(self: Provider) []const u8 {
        return switch (self) {
            .claude => model_config.Providers.anthropic,
            .deepseek => model_config.Providers.deepseek,
            .gemini => model_config.Providers.google,
            .grok => model_config.Providers.xai,
            .openai => model_config.Providers.openai,
            .vertex => model_config.Providers.vertex,
        };
    }

    /// Get provider name for cost lookup
    pub fn getCostProviderName(self: Provider) []const u8 {
        return switch (self) {
            .claude => "anthropic",
            .deepseek => "deepseek",
            .gemini => "google",
            .grok => "xai",
            .openai => "openai",
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
    model_config: model_config.ModelConfig,

    pub fn init(allocator: std.mem.Allocator, cli_config: CLIConfig) CLI {
        return .{
            .allocator = allocator,
            .config = cli_config,
            .model_config = model_config.ModelConfig.init(allocator),
        };
    }

    pub fn deinit(self: *CLI) void {
        self.model_config.deinit();
    }

    /// Get the current model for the active provider
    pub fn getCurrentModel(self: *CLI) []const u8 {
        return self.config.provider.getDefaultModel(&self.model_config);
    }

    /// Execute a single query
    pub fn query(self: *CLI, prompt: []const u8) !void {
        std.debug.print("\n{s}\n", .{self.config.provider.displayName()});
        std.debug.print("Query: {s}\n\n", .{prompt});

        var response = try self.sendToProvider(prompt, null);
        defer response.deinit();

        std.debug.print("Response:\n{s}\n\n", .{response.message.content});

        // Display citations if present (from xAI Responses API)
        self.printCitations(response);

        if (self.config.show_usage) {
            self.printUsageStats(response);
        }

        if (self.config.show_cost) {
            self.printCost(response);
        }

        // Save code blocks if --save was specified
        if (self.config.save_code) |base_name| {
            std.debug.print("\n", .{});
            const saved = saveCodeBlocks(self.allocator, response.message.content, base_name) catch |err| {
                std.debug.print("Error saving code blocks: {}\n", .{err});
                return;
            };
            if (saved > 0) {
                std.debug.print("Total: {d} file(s) saved\n", .{saved});
            }
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

            self.printCitations(response);

            if (self.config.show_usage) {
                self.printUsageStats(response);
            }

            // Add to conversation history
            const user_msg = ai.AIMessage{
                .id = try ai.common.generateId(self.allocator, io),
                .role = .user,
                .content = try self.allocator.dupe(u8, trimmed),
                .timestamp = getRealtimeSeconds(),
                .allocator = self.allocator,
            };
            try conversation.addMessage(user_msg);
            try conversation.addMessage(response.message);
        }
    }

    pub fn sendToProvider(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
    ) !ai.AIResponse {
        // Load images if provided
        var images: ?[]ai.common.ImageInput = null;
        var loaded_images: []ai.common.ImageInput = &.{};
        defer {
            for (loaded_images) |*img| {
                img.deinit();
            }
            if (images != null) {
                self.allocator.free(loaded_images);
            }
        }

        if (self.config.image_paths) |paths| {
            loaded_images = try self.allocator.alloc(ai.common.ImageInput, paths.len);
            var count: usize = 0;
            errdefer {
                for (loaded_images[0..count]) |*img| {
                    img.deinit();
                }
                self.allocator.free(loaded_images);
            }

            // Io handle for file reads (loadImageFromFile needs it for Dir ops)
            var file_io = std.Io.Threaded.init_single_threaded;
            const fio = file_io.io();

            for (paths) |path| {
                if (ai.common.ImageInput.isHttpUrl(path)) {
                    // Direct HTTPS URL — pass through without downloading
                    loaded_images[count] = ai.common.ImageInput.fromUrl(
                        try self.allocator.dupe(u8, path),
                        self.allocator,
                    );
                } else {
                    // Local file — load and base64 encode
                    loaded_images[count] = ai.common.loadImageFromFile(self.allocator, fio, path) catch |err| {
                        std.debug.print("Error loading image '{s}': {}\n", .{ path, err });
                        return err;
                    };
                }
                count += 1;
            }
            images = loaded_images;
        }

        const config_base = ai.common.RequestConfig{
            .model = self.config.model orelse "",
            .max_tokens = self.config.max_tokens,
            .temperature = self.config.temperature,
            .system_prompt = self.config.system_prompt,
            .images = images,
            .server_tools = self.config.server_tools,
            .mcp_tools = self.config.mcp_tools,
            .include = self.config.include,
            .collection_ids = self.config.collection_ids,
            .collection_max_results = self.config.collection_max_results,
            .file_ids = self.config.file_ids,
            .tool_choice = self.config.tool_choice,
            .tool_choice_function = self.config.tool_choice_function,
            .parallel_tool_calls = self.config.parallel_tool_calls,
            .allowed_function_names = self.config.allowed_function_names,
            .maps_latitude = self.config.maps_latitude,
            .maps_longitude = self.config.maps_longitude,
            .media_resolution = self.config.media_resolution,
        };

        return switch (self.config.provider) {
            .claude => try self.callClaude(prompt, context, config_base),
            .deepseek => try self.callDeepSeek(prompt, context, config_base),
            .gemini => try self.callGemini(prompt, context, config_base),
            .grok => try self.callGrok(prompt, context, config_base),
            .openai => try self.callOpenAI(prompt, context, config_base),
            .vertex => try self.callVertex(prompt, context, config_base),
        };
    }

    fn callClaude(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = try getEnvVarOwned(self.allocator, "ANTHROPIC_API_KEY");
        defer self.allocator.free(api_key);

        var client = try ai.ClaudeClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.ClaudeClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        config.images = base_config.images;

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
        const api_key = try getEnvVarOwned(self.allocator, "DEEPSEEK_API_KEY");
        defer self.allocator.free(api_key);

        var client = try ai.DeepSeekClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.DeepSeekClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        // Note: DeepSeek doesn't support vision, images will be ignored

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
        const api_key = getEnvVarOwned(self.allocator, "GEMINI_API_KEY") catch try getEnvVarOwned(self.allocator, "GOOGLE_GENAI_API_KEY");
        defer self.allocator.free(api_key);

        var client = try ai.GeminiClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.GeminiClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        config.images = base_config.images;
        config.server_tools = base_config.server_tools;
        config.tool_choice = base_config.tool_choice;
        config.tool_choice_function = base_config.tool_choice_function;
        config.allowed_function_names = base_config.allowed_function_names;
        config.maps_latitude = base_config.maps_latitude;
        config.maps_longitude = base_config.maps_longitude;
        config.media_resolution = base_config.media_resolution;

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
        const api_key = try getEnvVarOwned(self.allocator, "XAI_API_KEY");
        defer self.allocator.free(api_key);

        var client = try ai.GrokClient.init(self.allocator, api_key);
        defer client.deinit();

        var config = ai.GrokClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        config.images = base_config.images;
        config.tools = base_config.tools;
        config.server_tools = base_config.server_tools;
        config.mcp_tools = base_config.mcp_tools;
        config.collection_ids = base_config.collection_ids;
        config.collection_max_results = base_config.collection_max_results;
        config.file_ids = base_config.file_ids;
        config.store = base_config.store;
        config.server_max_turns = base_config.server_max_turns;
        config.previous_response_id = base_config.previous_response_id;
        config.include = base_config.include;
        config.tool_choice = base_config.tool_choice;
        config.tool_choice_function = base_config.tool_choice_function;
        config.parallel_tool_calls = base_config.parallel_tool_calls;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn callOpenAI(
        self: *CLI,
        prompt: []const u8,
        context: ?[]const ai.AIMessage,
        base_config: ai.common.RequestConfig,
    ) !ai.AIResponse {
        const api_key = try getEnvVarOwned(self.allocator, "OPENAI_API_KEY");
        defer self.allocator.free(api_key);

        var client = try ai.OpenAIClient.init(self.allocator, api_key);
        defer client.deinit();

        // GPT-5.2 uses Responses API with reasoning and verbosity controls
        var config = ai.OpenAIClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        config.images = base_config.images;
        // Default: none reasoning (lowest latency), medium verbosity

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
        const project_id = try getEnvVarOwned(self.allocator, "VERTEX_PROJECT_ID");
        defer self.allocator.free(project_id);

        var client = try ai.VertexClient.init(self.allocator, .{ .project_id = project_id });
        defer client.deinit();

        var config = ai.VertexClient.defaultConfig();
        if (base_config.model.len > 0) config.model = base_config.model;
        config.max_tokens = base_config.max_tokens;
        config.temperature = base_config.temperature;
        config.system_prompt = base_config.system_prompt;
        config.images = base_config.images;

        if (context) |ctx| {
            return try client.sendMessageWithContext(prompt, ctx, config);
        } else {
            return try client.sendMessage(prompt, config);
        }
    }

    fn printCitations(_: *CLI, response: ai.AIResponse) void {
        if (response.citations) |citations| {
            std.debug.print("Sources ({d}):\n", .{citations.len});
            for (citations, 0..) |url, i| {
                std.debug.print("  [{d}] {s}\n", .{ i + 1, url });
            }
            std.debug.print("\n", .{});
        }
    }

    fn printUsageStats(self: *CLI, response: ai.AIResponse) void {
        _ = self;
        std.debug.print("Tokens: {} in, {} out\n", .{
            response.usage.input_tokens,
            response.usage.output_tokens,
        });
    }

    fn printCost(self: *CLI, response: ai.AIResponse) void {
        // Use actual model-aware pricing from model_costs database
        const model = self.config.model orelse self.getCurrentModel();
        const cost = self.config.provider.calculateCost(
            model,
            response.usage.input_tokens,
            response.usage.output_tokens,
        );
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

    std.debug.print("  5. openai    - {s}\n", .{Provider.openai.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.openai.getEnvVar()});

    std.debug.print("  6. vertex    - {s}\n", .{Provider.vertex.displayName()});
    std.debug.print("     Env var: {s}\n\n", .{Provider.vertex.getEnvVar()});
}

pub fn printUsage() void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  AI Providers CLI - Universal AI Command Line Tool          ║\n", .{});
    std.debug.print("║  Text: Claude, DeepSeek, Gemini, GPT-5.2, Grok, Vertex       ║\n", .{});
    std.debug.print("║  Images: DALL-E, Grok, Imagen, Gemini                        ║\n", .{});
    std.debug.print("║  Video: Sora, Veo, Grok  |  Music: Lyria                     ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("TEXT GENERATION:\n", .{});
    std.debug.print("  zig-ai [provider] \"prompt\"              - One-shot query\n", .{});
    std.debug.print("  zig-ai --interactive [provider]         - Interactive mode\n", .{});
    std.debug.print("  zig-ai --list                           - List text providers\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Text providers: claude, deepseek, gemini, grok, openai, vertex\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("IMAGE GENERATION:\n", .{});
    std.debug.print("  zig-ai dalle3 \"prompt\"                  - DALL-E 3 (OPENAI_API_KEY)\n", .{});
    std.debug.print("  zig-ai dalle2 \"prompt\"                  - DALL-E 2 (OPENAI_API_KEY)\n", .{});
    std.debug.print("  zig-ai gpt-image \"prompt\"               - GPT-Image (OPENAI_API_KEY)\n", .{});
    std.debug.print("  zig-ai grok-image \"prompt\"              - Grok (XAI_API_KEY)\n", .{});
    std.debug.print("  zig-ai imagen \"prompt\"                  - Imagen (GEMINI_API_KEY)\n", .{});
    std.debug.print("  zig-ai gemini-image \"prompt\"            - Gemini Flash (GEMINI_API_KEY)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Image options: -n <count>, -s <size>, -a <aspect-ratio>, -q <quality>\n", .{});
    std.debug.print("  zig-ai --list-image-providers           - List image providers\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("VIDEO GENERATION:\n", .{});
    std.debug.print("  zig-ai sora \"prompt\"                    - OpenAI Sora 2 (OPENAI_API_KEY)\n", .{});
    std.debug.print("  zig-ai veo \"prompt\"                     - Google Veo 2 (GEMINI_API_KEY)\n", .{});
    std.debug.print("  zig-ai grok-video \"prompt\"              - Grok Imagine Video (XAI_API_KEY)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Video options: -d <duration>, -r <resolution>, -a <aspect-ratio>\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("MUSIC GENERATION:\n", .{});
    std.debug.print("  zig-ai lyria \"prompt\"                   - Google Lyria 2 (gcloud auth)\n", .{});
    std.debug.print("  zig-ai lyria-realtime \"prompt\"          - Lyria instant clips (gcloud auth)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Music options: -d <duration>, --bpm <bpm>, --seed <num>\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("TEXT OPTIONS:\n", .{});
    std.debug.print("  --temperature <f32>    - Set temperature (0.0-2.0)\n", .{});
    std.debug.print("  --max-tokens <u32>     - Set max output tokens\n", .{});
    std.debug.print("  --system <text>        - Set system prompt\n", .{});
    std.debug.print("  --text-template, -T    - Use a text template (e.g., joke-code, tutor)\n", .{});
    std.debug.print("  --param, -P key=val    - Set template parameter (can use multiple times)\n", .{});
    std.debug.print("  --text-templates       - List available text templates\n", .{});
    std.debug.print("  --image <path>         - Add image for vision (can use multiple times)\n", .{});
    std.debug.print("  --doc, --pdf <path>    - Add document (PDF, CSV, etc.) for understanding\n", .{});
    std.debug.print("  --video <path>         - Upload video via Gemini Files API (Gemini only)\n", .{});
    std.debug.print("  --youtube <url>        - Add YouTube video for analysis (Gemini only)\n", .{});
    std.debug.print("  --media-resolution <v> - Media quality: low/medium/high/ultra_high (Gemini)\n", .{});
    std.debug.print("  --save <name>          - Save code blocks to files (e.g., name.zig)\n", .{});
    std.debug.print("  --no-usage             - Hide usage stats\n", .{});
    std.debug.print("  --no-cost              - Hide cost estimates\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("FUNCTION CALLING:\n", .{});
    std.debug.print("  --tool-choice <mode>   - auto/required/none/validated/<function_name>\n", .{});
    std.debug.print("  --allowed-fn <name>    - Restrict to function (repeatable, Gemini)\n", .{});
    std.debug.print("  --no-parallel-tools    - Disable parallel function calling (Grok)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("GEMINI TOOLS (Google only):\n", .{});
    std.debug.print("  --google-search        - Enable Google Search grounding\n", .{});
    std.debug.print("  --url-context          - Enable URL context retrieval\n", .{});
    std.debug.print("  --google-maps          - Enable Google Maps grounding\n", .{});
    std.debug.print("  --maps-location lat,lng- Set location for Maps grounding\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("GEMINI FILES API:\n", .{});
    std.debug.print("  zig-ai gemini-file upload <path>   - Upload file to Gemini\n", .{});
    std.debug.print("  zig-ai gemini-file status <name>   - Check processing status\n", .{});
    std.debug.print("  zig-ai gemini-file list            - List uploaded files\n", .{});
    std.debug.print("  zig-ai gemini-file delete <name>   - Delete a file\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("GEMINI LIVE (real-time WebSocket streaming):\n", .{});
    std.debug.print("  zig-ai live \"prompt\"               - One-shot live query (text mode)\n", .{});
    std.debug.print("  zig-ai live -i                     - Interactive live session\n", .{});
    std.debug.print("  zig-ai live \"prompt\" --modality audio -v puck   - Audio response\n", .{});
    std.debug.print("  zig-ai live -i --context-compression             - Unlimited session\n", .{});
    std.debug.print("  zig-ai live --help                 - Full live options\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EMBEDDINGS (Gemini):\n", .{});
    std.debug.print("  zig-ai embed \"text\"                - Generate text embeddings\n", .{});
    std.debug.print("  zig-ai embed -t similarity \"a\" \"b\" - Compare text similarity\n", .{});
    std.debug.print("  zig-ai embed -d 768 --json \"text\"  - Custom dimensions, JSON output\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("GROK SERVER-SIDE TOOLS (xAI only):\n", .{});
    std.debug.print("  --web-search           - Enable web search tool\n", .{});
    std.debug.print("  --x-search             - Enable X/Twitter search tool\n", .{});
    std.debug.print("  --code-interpreter     - Enable code interpreter tool\n", .{});
    std.debug.print("  --mcp <url>            - Connect to remote MCP server (can use multiple)\n", .{});
    std.debug.print("  --mcp-label <label>    - Label for the preceding --mcp server\n", .{});
    std.debug.print("  --mcp-auth <token>     - Authorization token for the preceding --mcp server\n", .{});
    std.debug.print("  --include <value>      - Request additional response data\n", .{});
    std.debug.print("                           e.g., inline_citations, web_search_call.action.sources\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("  zig-ai deepseek \"What is Zig?\"\n", .{});
    std.debug.print("  zig-ai openai \"Write a hello world in Zig\" --save hello\n", .{});
    std.debug.print("  zig-ai gemini \"What's in this image?\" --image photo.png\n", .{});
    std.debug.print("  zig-ai claude \"Compare these\" --image a.jpg --image b.jpg\n", .{});
    std.debug.print("  zig-ai claude -T joke-code -P language=rust \"recursion\"\n", .{});
    std.debug.print("  zig-ai gemini -T eli5 -P domain=physics \"quantum entanglement\"\n", .{});
    std.debug.print("  zig-ai grok -T roast -P intensity=savage \"my spaghetti code\"\n", .{});
    std.debug.print("  zig-ai grok \"Latest xAI news\" --web-search\n", .{});
    std.debug.print("  zig-ai grok \"What are people saying about Zig?\" --x-search\n", .{});
    std.debug.print("  zig-ai grok \"Calculate 50!\" --code-interpreter\n", .{});
    std.debug.print("  zig-ai grok \"Analyze repo\" --mcp https://mcp.deepwiki.com/mcp\n", .{});
    std.debug.print("  zig-ai gemini \"Describe this video\" --video clip.mp4\n", .{});
    std.debug.print("  zig-ai gemini \"Summarize\" --youtube https://youtube.com/watch?v=xxx\n", .{});
    std.debug.print("  zig-ai gemini \"What's in this PDF?\" --pdf report.pdf\n", .{});
    std.debug.print("  zig-ai dalle3 \"a cosmic duck in space\"\n", .{});
    std.debug.print("  zig-ai grok-image \"quantum computer\" -n 4\n", .{});
    std.debug.print("  zig-ai sora \"a cat playing piano\" -d 10\n", .{});
    std.debug.print("  zig-ai lyria \"ambient space soundscape\"\n", .{});
    std.debug.print("  zig-ai --interactive gemini\n", .{});
    std.debug.print("\n", .{});
}

// ============================================================================
// Code Block Extraction and Saving
// ============================================================================

/// A single code block extracted from AI response
pub const CodeBlock = struct {
    language: []const u8,
    content: []const u8,
};

/// Extract code blocks from markdown-formatted AI response
/// Returns array of CodeBlock structs (caller owns memory)
pub fn extractCodeBlocks(allocator: std.mem.Allocator, content: []const u8) ![]CodeBlock {
    var blocks: std.ArrayListUnmanaged(CodeBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        // Find start of code block (```)
        const block_start = std.mem.indexOfPos(u8, content, pos, "```") orelse break;

        // Find end of language identifier (newline after ```)
        const lang_end = std.mem.indexOfPos(u8, content, block_start + 3, "\n") orelse break;
        const language = std.mem.trim(u8, content[block_start + 3 .. lang_end], &std.ascii.whitespace);

        // Find end of code block
        const code_start = lang_end + 1;
        const block_end = std.mem.indexOfPos(u8, content, code_start, "```") orelse break;

        const code_content = content[code_start..block_end];

        try blocks.append(allocator, .{
            .language = if (language.len > 0) language else "txt",
            .content = code_content,
        });

        pos = block_end + 3;
    }

    return blocks.toOwnedSlice(allocator);
}

/// Get file extension for a language identifier
pub fn getExtensionForLanguage(lang: []const u8) []const u8 {
    const lang_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "zig", "zig" },
        .{ "python", "py" },
        .{ "py", "py" },
        .{ "javascript", "js" },
        .{ "js", "js" },
        .{ "typescript", "ts" },
        .{ "ts", "ts" },
        .{ "rust", "rs" },
        .{ "rs", "rs" },
        .{ "go", "go" },
        .{ "golang", "go" },
        .{ "c", "c" },
        .{ "cpp", "cpp" },
        .{ "c++", "cpp" },
        .{ "java", "java" },
        .{ "kotlin", "kt" },
        .{ "swift", "swift" },
        .{ "ruby", "rb" },
        .{ "rb", "rb" },
        .{ "php", "php" },
        .{ "sh", "sh" },
        .{ "bash", "sh" },
        .{ "shell", "sh" },
        .{ "zsh", "zsh" },
        .{ "fish", "fish" },
        .{ "sql", "sql" },
        .{ "html", "html" },
        .{ "css", "css" },
        .{ "scss", "scss" },
        .{ "json", "json" },
        .{ "yaml", "yaml" },
        .{ "yml", "yml" },
        .{ "toml", "toml" },
        .{ "xml", "xml" },
        .{ "markdown", "md" },
        .{ "md", "md" },
        .{ "lua", "lua" },
        .{ "perl", "pl" },
        .{ "r", "r" },
        .{ "scala", "scala" },
        .{ "haskell", "hs" },
        .{ "hs", "hs" },
        .{ "elixir", "ex" },
        .{ "ex", "ex" },
        .{ "erlang", "erl" },
        .{ "clojure", "clj" },
        .{ "nim", "nim" },
        .{ "odin", "odin" },
        .{ "asm", "asm" },
        .{ "assembly", "asm" },
        .{ "nasm", "asm" },
        .{ "s", "s" },
        .{ "makefile", "mk" },
        .{ "dockerfile", "dockerfile" },
        .{ "txt", "txt" },
        .{ "text", "txt" },
    });

    return lang_map.get(lang) orelse "txt";
}

/// Save code blocks to files with appropriate extensions
/// Returns the number of files saved
pub fn saveCodeBlocks(allocator: std.mem.Allocator, content: []const u8, base_name: []const u8) !u32 {
    const blocks = try extractCodeBlocks(allocator, content);
    defer allocator.free(blocks);

    if (blocks.len == 0) {
        std.debug.print("No code blocks found in response\n", .{});
        return 0;
    }

    // Track language counts for numbering multiple blocks of same type
    var lang_counts = std.StringHashMap(u32).init(allocator);
    defer lang_counts.deinit();

    var saved: u32 = 0;

    for (blocks) |block| {
        const ext = getExtensionForLanguage(block.language);

        // Get current count for this extension
        const count = lang_counts.get(ext) orelse 0;
        try lang_counts.put(ext, count + 1);

        // Build filename: base_name.ext or base_name_N.ext for duplicates
        const filename = if (count == 0)
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, ext })
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}.{s}", .{ base_name, count + 1, ext });
        defer allocator.free(filename);

        // Write file using C API (Zig 0.16 compatible)
        const filename_z = try allocator.dupeZ(u8, filename);
        defer allocator.free(filename_z);

        const file = std.c.fopen(filename_z, "wb") orelse {
            std.debug.print("Failed to create file: {s}\n", .{filename});
            continue;
        };
        defer _ = std.c.fclose(file);

        const written = std.c.fwrite(block.content.ptr, 1, block.content.len, file);
        if (written != block.content.len) {
            std.debug.print("Warning: incomplete write to {s}\n", .{filename});
            continue;
        }

        std.debug.print("Saved: {s} ({d} bytes, {s})\n", .{ filename, block.content.len, block.language });
        saved += 1;
    }

    return saved;
}
