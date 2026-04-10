// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent Executor - Main agentic loop
//! Handles tool calling, conversation management, and provider integration

const std = @import("std");
const config = @import("config.zig");
const security = @import("security/mod.zig");
const tools = @import("tools/mod.zig");
const pricing = @import("pricing.zig");
const Timer = @import("../timer.zig").Timer;

// Zig 0.16 compatible - get realtime seconds
fn getRealtimeSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Count trailing assistant + tool messages at the end of a conversation.
/// Used to extract only the new items when chaining via previous_response_id
/// (the server already has the earlier conversation from its stored state).
fn countRecentToolMessages(messages: []const ai.AIMessage) usize {
    var count: usize = 0;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .assistant or messages[i].role == .tool) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

// HTTP sentinel imports (AI providers)
const http_sentinel = @import("http-sentinel");
const ai = http_sentinel.ai;

pub const ExecutorError = error{
    ConfigNotFound,
    SandboxInitFailed,
    ProviderNotSupported,
    ApiKeyMissing,
    MaxTurnsReached,
    ToolExecutionFailed,
    OutOfMemory,
};

pub const AgentResult = struct {
    final_response: []const u8,
    turns_used: u32,
    tool_calls_made: u32,
    total_input_tokens: u32,
    total_output_tokens: u32,
    success: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentResult) void {
        self.allocator.free(self.final_response);
    }
};

/// Real-time tool execution events
pub const ToolEvent = union(enum) {
    turn_start: struct { turn: u32 },
    tool_start: struct { name: []const u8, reason: ?[]const u8 },
    tool_complete: struct { name: []const u8, success: bool, duration_ms: u64 },
    turn_complete: struct { turn: u32, has_tool_calls: bool },
};

pub const EventCallback = ?*const fn (ToolEvent) void;

/// Default event handler - prints formatted output to stderr
fn defaultEventHandler(event: ToolEvent) void {
    switch (event) {
        .turn_start => |e| std.debug.print("\n[Turn {d}] Sending to provider...\n", .{e.turn}),
        .tool_start => |e| {
            std.debug.print("[agent] {s}", .{e.name});
            if (e.reason) |r| std.debug.print(" - {s}", .{r});
            std.debug.print("\n", .{});
        },
        .tool_complete => |e| {
            const symbol: []const u8 = if (e.success) "✓" else "✗";
            std.debug.print("[agent] {s} {s} ({d}ms)\n", .{ symbol, e.name, e.duration_ms });
        },
        .turn_complete => |e| {
            if (!e.has_tool_calls) {
                std.debug.print("[Turn {d}] Final response received\n", .{e.turn});
            }
        },
    }
}

/// Agent executor - runs agentic loops with tool calling
pub const AgentExecutor = struct {
    allocator: std.mem.Allocator,
    agent_config: config.AgentConfig,
    sandbox: security.Sandbox,
    tool_registry: tools.ToolRegistry,
    io_threaded: *std.Io.Threaded, // For generateId's io.random()
    on_event: EventCallback = &defaultEventHandler,

    /// xAI server-side tools (web_search, x_search, code_interpreter)
    /// Set before calling run() to enable server-side tools alongside client-side agent tools
    server_tools: ?[]const ai.common.ServerSideTool = null,

    /// Remote MCP tools — xAI connects to external MCP servers
    mcp_tools: ?[]const ai.common.McpToolConfig = null,

    /// Collection IDs for file_search tool (xAI only)
    collection_ids: ?[]const []const u8 = null,

    /// Uploaded file IDs for attachment_search (xAI only)
    file_ids: ?[]const []const u8 = null,

    /// Context injection — prepended to system prompt for worker agents
    /// Used by the orchestrator to pass upstream task results to workers
    context_injection: ?[]const u8 = null,

    /// Tool choice control (auto/required/none/function/validated)
    tool_choice: ?ai.common.ToolChoice = null,
    tool_choice_function: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    allowed_function_names: ?[]const []const u8 = null,

    pub fn init(allocator: std.mem.Allocator, agent_config: config.AgentConfig) !AgentExecutor {
        // Initialize sandbox
        const sandbox_config = security.SandboxConfig{
            .root = agent_config.sandbox.root,
            .writable_paths = agent_config.sandbox.writable_paths,
            .readonly_paths = agent_config.sandbox.readonly_paths,
            .allow_network = agent_config.sandbox.allow_network,
            .allowed_commands = agent_config.tools.execute_command.allowed_commands,
            .banned_patterns = agent_config.tools.execute_command.banned_patterns,
        };

        var sandbox = security.Sandbox.init(allocator, sandbox_config) catch {
            return ExecutorError.SandboxInitFailed;
        };
        errdefer sandbox.deinit();

        // Create output directory if it doesn't exist
        const output_dir = std.fmt.allocPrint(allocator, "{s}/output", .{agent_config.sandbox.root}) catch null;
        if (output_dir) |dir| {
            defer allocator.free(dir);
            const dir_z = allocator.allocSentinel(u8, dir.len, 0) catch null;
            if (dir_z) |dz| {
                defer allocator.free(dz);
                @memcpy(dz, dir);
                _ = std.c.mkdir(dz.ptr, 0o755);
            }
        }

        const tool_registry = tools.ToolRegistry.init(allocator, &agent_config);

        const io_t = try allocator.create(std.Io.Threaded);
        io_t.* = std.Io.Threaded.init(allocator, .{});

        return AgentExecutor{
            .allocator = allocator,
            .agent_config = agent_config,
            .sandbox = sandbox,
            .tool_registry = tool_registry,
            .io_threaded = io_t,
        };
    }

    pub fn deinit(self: *AgentExecutor) void {
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
        self.tool_registry.deinit();
        self.sandbox.deinit();
        self.agent_config.deinit();
    }

    /// Run agent with a task
    pub fn run(self: *AgentExecutor, task: []const u8) !AgentResult {
        const provider_name = self.agent_config.provider.name;

        // Get API key
        const env_var = getEnvVarForProvider(provider_name);
        const api_key_ptr = std.c.getenv(env_var) orelse {
            std.debug.print("Error: {s} environment variable not set\n", .{env_var});
            return ExecutorError.ApiKeyMissing;
        };
        const api_key = std.mem.span(api_key_ptr);

        // Build system prompt with tool instructions
        var system_prompt: std.ArrayListUnmanaged(u8) = .empty;
        defer system_prompt.deinit(self.allocator);

        // Inject upstream task context (from orchestrator) before system prompt
        if (self.context_injection) |ctx| {
            try system_prompt.appendSlice(self.allocator, ctx);
            try system_prompt.appendSlice(self.allocator, "\n\n");
        }

        if (self.agent_config.system_prompt) |sp| {
            try system_prompt.appendSlice(self.allocator, sp);
            try system_prompt.appendSlice(self.allocator, "\n\n");
        }

        try system_prompt.appendSlice(self.allocator,
            \\You are an AI agent with access to tools for file operations and command execution.
            \\You are working within a sandbox rooted at:
        );
        try system_prompt.appendSlice(self.allocator, self.sandbox.getRoot());
        try system_prompt.appendSlice(self.allocator,
            \\
            \\
            \\Use the tools available to accomplish the task. When the task is complete, provide a final summary.
        );

        // Dispatch to generic agentic loop with provider-specific client
        if (std.mem.eql(u8, provider_name, "claude")) {
            var client = try ai.ClaudeClient.init(self.allocator, api_key);
            defer client.deinit();
            var req_config = ai.ClaudeClient.defaultConfig();
            req_config.max_tokens = self.agent_config.provider.max_tokens;
            req_config.temperature = self.agent_config.provider.temperature;
            req_config.system_prompt = system_prompt.items;
            return self.runAgenticLoop(ai.ClaudeClient, &client, task, req_config);
        } else if (std.mem.eql(u8, provider_name, "gemini")) {
            var client = try ai.GeminiClient.init(self.allocator, api_key);
            defer client.deinit();
            var req_config = ai.GeminiClient.defaultConfig();
            req_config.max_tokens = self.agent_config.provider.max_tokens;
            req_config.temperature = self.agent_config.provider.temperature;
            req_config.system_prompt = system_prompt.items;
            return self.runAgenticLoop(ai.GeminiClient, &client, task, req_config);
        } else if (std.mem.eql(u8, provider_name, "openai") or std.mem.eql(u8, provider_name, "gpt")) {
            var client = try ai.OpenAIClient.init(self.allocator, api_key);
            defer client.deinit();
            var req_config = ai.OpenAIClient.defaultConfig();
            req_config.max_tokens = self.agent_config.provider.max_tokens;
            req_config.temperature = self.agent_config.provider.temperature;
            req_config.system_prompt = system_prompt.items;
            return self.runAgenticLoop(ai.OpenAIClient, &client, task, req_config);
        } else if (std.mem.eql(u8, provider_name, "grok")) {
            var client = try ai.GrokClient.init(self.allocator, api_key);
            defer client.deinit();
            var req_config = ai.GrokClient.defaultConfig();
            req_config.max_tokens = self.agent_config.provider.max_tokens;
            req_config.temperature = self.agent_config.provider.temperature;
            req_config.system_prompt = system_prompt.items;
            req_config.server_tools = self.server_tools;
            req_config.mcp_tools = self.mcp_tools;
            req_config.collection_ids = self.collection_ids;
            req_config.file_ids = self.file_ids;
            req_config.tool_choice = self.tool_choice;
            req_config.tool_choice_function = self.tool_choice_function;
            req_config.parallel_tool_calls = self.parallel_tool_calls;
            req_config.allowed_function_names = self.allowed_function_names;
            return self.runAgenticLoop(ai.GrokClient, &client, task, req_config);
        } else {
            std.debug.print("Provider '{s}' not supported for agent mode\n", .{provider_name});
            return ExecutorError.ProviderNotSupported;
        }
    }

    /// Generic agentic loop that works with any provider client
    fn runAgenticLoop(
        self: *AgentExecutor,
        comptime ClientType: type,
        client: *ClientType,
        task: []const u8,
        req_config: ai.common.RequestConfig,
    ) !AgentResult {
        // Build tool definitions for the API
        var tool_defs: std.ArrayListUnmanaged(ai.common.ToolDefinition) = .empty;
        defer tool_defs.deinit(self.allocator);

        for (self.agent_config.tools.enabled) |tool_name| {
            if (tools.getToolDef(tool_name)) |def| {
                try tool_defs.append(self.allocator, .{
                    .name = def.name,
                    .description = def.description,
                    .input_schema = def.input_schema,
                });
            }
        }

        var turns: u32 = 0;
        var tool_calls_made: u32 = 0;
        var total_input: u32 = 0;
        var total_output: u32 = 0;

        // Runaway detection: track consecutive identical tool calls
        var last_tool_name: ?[]const u8 = null;
        defer if (last_tool_name) |n| self.allocator.free(n);
        var consecutive_same_tool: u32 = 0;
        const max_consecutive_same: u32 = 3;

        // Build messages array - the executor owns the full conversation
        var messages_list: std.ArrayListUnmanaged(ai.AIMessage) = .empty;
        defer {
            for (messages_list.items) |*msg| {
                msg.deinit();
            }
            messages_list.deinit(self.allocator);
        }

        // Add initial user message to context
        const user_msg = ai.AIMessage{
            .id = try ai.common.generateId(self.allocator, self.io_threaded.io()),
            .role = .user,
            .content = try self.allocator.dupe(u8, task),
            .timestamp = getRealtimeSeconds(),
            .allocator = self.allocator,
        };
        try messages_list.append(self.allocator, user_msg);

        // Build config with tools
        var loop_config = req_config;
        loop_config.tools = tool_defs.items;

        // For Responses API providers (Grok, OpenAI): enable store + previous_response_id
        // to preserve server-side tool state (web_search results, etc.) across turns
        const uses_responses_api = loop_config.server_tools != null or loop_config.mcp_tools != null or loop_config.collection_ids != null or loop_config.file_ids != null;
        if (uses_responses_api) {
            loop_config.store = true;
        }

        // Track the response ID for conversation chaining
        var prev_response_id: ?[]u8 = null;
        defer if (prev_response_id) |id| self.allocator.free(id);

        // Agentic loop
        while (turns < self.agent_config.provider.max_turns) {
            turns += 1;

            if (self.on_event) |emit| {
                emit(.{ .turn_start = .{ .turn = turns } });
            }

            // When chaining via previous_response_id, only send new items (tool outputs)
            // instead of the full conversation history — the server has the rest
            loop_config.previous_response_id = prev_response_id;
            const context = if (prev_response_id != null and uses_responses_api)
                messages_list.items[messages_list.items.len -| countRecentToolMessages(messages_list.items) ..]
            else
                messages_list.items;

            // Pass empty prompt - the task is already in messages_list as the first user message
            var response = client.sendMessageWithContext("", context, loop_config) catch |err| {
                std.debug.print("API Error: {}\n", .{err});
                return ExecutorError.ToolExecutionFailed;
            };
            defer response.deinit();

            total_input += response.usage.input_tokens;
            total_output += response.usage.output_tokens;

            // Capture response ID for conversation chaining (Responses API)
            if (uses_responses_api) {
                if (prev_response_id) |old_id| self.allocator.free(old_id);
                prev_response_id = self.allocator.dupe(u8, response.message.id) catch null;
            }

            // Check for tool calls
            if (response.message.tool_calls) |api_tool_calls| {
                if (self.on_event) |emit| {
                    emit(.{ .turn_complete = .{ .turn = turns, .has_tool_calls = true } });
                }

                // Runaway detection: if the same single tool keeps being called, force completion
                if (api_tool_calls.len == 1) {
                    const call_name = api_tool_calls[0].name;
                    if (last_tool_name) |prev| {
                        if (std.mem.eql(u8, prev, call_name)) {
                            consecutive_same_tool += 1;
                        } else {
                            consecutive_same_tool = 1;
                        }
                        self.allocator.free(prev);
                    } else {
                        consecutive_same_tool = 1;
                    }
                    last_tool_name = try self.allocator.dupe(u8, call_name);

                    if (consecutive_same_tool > max_consecutive_same) {
                        std.debug.print("[Turn {d}] Runaway detected: {s} called {d} times consecutively, forcing completion\n", .{ turns, call_name, consecutive_same_tool });
                        return AgentResult{
                            .final_response = try self.allocator.dupe(u8, response.message.content),
                            .turns_used = turns,
                            .tool_calls_made = tool_calls_made,
                            .total_input_tokens = total_input,
                            .total_output_tokens = total_output,
                            .success = true,
                            .allocator = self.allocator,
                        };
                    }
                } else {
                    consecutive_same_tool = 0;
                    if (last_tool_name) |prev| {
                        self.allocator.free(prev);
                    }
                    last_tool_name = null;
                }

                // Add assistant message with tool calls to context (deep copy to avoid double-free)
                var copied_tool_calls = try self.allocator.alloc(ai.common.ToolCall, api_tool_calls.len);
                for (api_tool_calls, 0..) |call, i| {
                    copied_tool_calls[i] = .{
                        .id = try self.allocator.dupe(u8, call.id),
                        .name = try self.allocator.dupe(u8, call.name),
                        .arguments = try self.allocator.dupe(u8, call.arguments),
                        .allocator = self.allocator,
                    };
                }

                const assistant_msg = ai.AIMessage{
                    .id = try ai.common.generateId(self.allocator, self.io_threaded.io()),
                    .role = .assistant,
                    .content = try self.allocator.dupe(u8, response.message.content),
                    .timestamp = getRealtimeSeconds(),
                    .tool_calls = copied_tool_calls,
                    .allocator = self.allocator,
                };
                try messages_list.append(self.allocator, assistant_msg);

                // Execute each tool and add results
                for (api_tool_calls) |call| {
                    if (self.on_event) |emit| {
                        emit(.{ .tool_start = .{ .name = call.name, .reason = null } });
                    }

                    var tool_timer = Timer.start() catch unreachable;
                    tool_calls_made += 1;

                    // Execute tool
                    var tool_output = try self.tool_registry.executeTool(&self.sandbox, call.name, call.arguments);
                    defer tool_output.deinit();

                    const tool_elapsed_ns = tool_timer.read();

                    const result_text = if (tool_output.success)
                        tool_output.content
                    else
                        tool_output.error_message orelse "Tool execution failed";

                    if (self.on_event) |emit| {
                        emit(.{ .tool_complete = .{
                            .name = call.name,
                            .success = tool_output.success,
                            .duration_ms = tool_elapsed_ns / std.time.ns_per_ms,
                        } });
                    }

                    // Add tool result message
                    var tool_results = try self.allocator.alloc(ai.common.ToolResult, 1);
                    tool_results[0] = .{
                        .tool_call_id = try self.allocator.dupe(u8, call.id),
                        .content = try self.allocator.dupe(u8, result_text),
                        .is_error = !tool_output.success,
                        .tool_name = try self.allocator.dupe(u8, call.name),
                        .allocator = self.allocator,
                    };

                    const result_msg = ai.AIMessage{
                        .id = try ai.common.generateId(self.allocator, self.io_threaded.io()),
                        .role = .tool,
                        .content = try self.allocator.dupe(u8, result_text),
                        .timestamp = getRealtimeSeconds(),
                        .tool_results = tool_results,
                        .allocator = self.allocator,
                    };
                    try messages_list.append(self.allocator, result_msg);
                }
            } else {
                // No tool calls - check stop reason
                const stop_reason = if (response.metadata.stop_reason) |sr|
                    ai.common.StopReason.fromString(sr)
                else
                    ai.common.StopReason.end_turn;

                if (self.on_event) |emit| {
                    emit(.{ .turn_complete = .{ .turn = turns, .has_tool_calls = false } });
                }

                if (stop_reason == .tool_use) {
                    // Model wants to use tools but none were returned - continue
                    continue;
                }

                // Final response
                return AgentResult{
                    .final_response = try self.allocator.dupe(u8, response.message.content),
                    .turns_used = turns,
                    .tool_calls_made = tool_calls_made,
                    .total_input_tokens = total_input,
                    .total_output_tokens = total_output,
                    .success = true,
                    .allocator = self.allocator,
                };
            }
        }

        return ExecutorError.MaxTurnsReached;
    }

    /// Interactive mode - REPL
    pub fn runInteractive(self: *AgentExecutor) !void {
        std.debug.print("\n╔══════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  AI Agent - Interactive Mode                     ║\n", .{});
        std.debug.print("║  Sandbox: {s: <38}║\n", .{self.sandbox.getRoot()});
        std.debug.print("║  Provider: {s: <37}║\n", .{self.agent_config.provider.name});
        std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\nCommands: /quit, /help, /tools\n\n", .{});

        var buf: [4096]u8 = undefined;

        while (true) {
            std.debug.print("agent> ", .{});

            // Read line from stdin (fd 0) using C read
            var line_len: usize = 0;
            while (line_len < buf.len - 1) {
                const read_count = std.c.read(0, buf[line_len..].ptr, 1);
                if (read_count <= 0) return; // EOF or error
                if (buf[line_len] == '\n') break;
                line_len += 1;
            }

            const input = std.mem.trim(u8, buf[0..line_len], &[_]u8{ '\n', '\r', ' ' });

            if (input.len == 0) continue;

            if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/exit")) {
                std.debug.print("Goodbye!\n", .{});
                break;
            }

            if (std.mem.eql(u8, input, "/help")) {
                std.debug.print("\nCommands:\n", .{});
                std.debug.print("  /quit   - Exit interactive mode\n", .{});
                std.debug.print("  /tools  - List enabled tools\n", .{});
                std.debug.print("  /help   - Show this help\n", .{});
                std.debug.print("\nEnter any other text to send it as a task to the agent.\n\n", .{});
                continue;
            }

            if (std.mem.eql(u8, input, "/tools")) {
                std.debug.print("\nEnabled tools:\n", .{});
                for (self.agent_config.tools.enabled) |tool| {
                    std.debug.print("  - {s}\n", .{tool});
                }
                std.debug.print("\n", .{});
                continue;
            }

            // Run task
            var result = self.run(input) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                continue;
            };
            defer result.deinit();

            std.debug.print("\n{s}\n\n", .{result.final_response});
            const effective_model = self.agent_config.provider.model orelse getDefaultModel(self.agent_config.provider.name);
            if (pricing.calculateCost(effective_model, result.total_input_tokens, result.total_output_tokens)) |cost| {
                var cost_buf: [64]u8 = undefined;
                std.debug.print("[{d} turns, {d} tool calls, {d}/{d} tokens, {s}]\n\n", .{
                    result.turns_used,
                    result.tool_calls_made,
                    result.total_input_tokens,
                    result.total_output_tokens,
                    pricing.formatCost(&cost_buf, cost),
                });
            } else {
                std.debug.print("[{d} turns, {d} tool calls, {d}/{d} tokens]\n\n", .{
                    result.turns_used,
                    result.tool_calls_made,
                    result.total_input_tokens,
                    result.total_output_tokens,
                });
            }
        }
    }
};

/// Get environment variable name for provider
fn getEnvVarForProvider(provider: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, provider, "claude")) return "ANTHROPIC_API_KEY";
    if (std.mem.eql(u8, provider, "gemini")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "gpt")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "grok")) return "XAI_API_KEY";
    if (std.mem.eql(u8, provider, "deepseek")) return "DEEPSEEK_API_KEY";
    return "API_KEY";
}

/// Get default model name for a provider (matches defaultConfig() in each client)
fn getDefaultModel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "claude")) return "claude-sonnet-4-5-20250929";
    if (std.mem.eql(u8, provider, "gemini")) return "gemini-2.5-pro";
    if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "gpt")) return "gpt-5.2";
    if (std.mem.eql(u8, provider, "grok")) return "grok-4-1-fast-non-reasoning";
    if (std.mem.eql(u8, provider, "deepseek")) return "deepseek-chat";
    return "unknown";
}
