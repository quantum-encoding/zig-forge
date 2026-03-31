// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent CLI command handlers

const std = @import("std");
const config = @import("config.zig");
const executor = @import("executor.zig");
const security = @import("security/mod.zig");
const pricing = @import("pricing.zig");

const orchestrator_mod = @import("orchestrator.zig");

const http_sentinel = @import("http-sentinel");
const ai = http_sentinel.ai;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        printHelp();
        return;
    }

    // Skip program name and "agent"
    var i: usize = 2;
    var task: ?[]const u8 = null;
    var config_name: ?[]const u8 = null;
    var sandbox_root: ?[]const u8 = null;
    var interactive = false;

    // xAI server-side tools
    var server_tools_list: std.ArrayListUnmanaged(ai.common.ServerSideTool) = .empty;
    defer server_tools_list.deinit(allocator);
    var mcp_tools_list: std.ArrayListUnmanaged(ai.common.McpToolConfig) = .empty;
    defer mcp_tools_list.deinit(allocator);
    var collection_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer collection_list.deinit(allocator);
    var file_id_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_id_list.deinit(allocator);
    var tool_choice: ?ai.common.ToolChoice = null;
    var tool_choice_function: ?[]const u8 = null;
    var parallel_tool_calls: ?bool = null;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --config requires a name or path\n", .{});
                return;
            }
            config_name = args[i];
        } else if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --sandbox requires a path\n", .{});
                return;
            }
            sandbox_root = args[i];
        } else if (std.mem.eql(u8, arg, "list")) {
            try listAgents(allocator);
            return;
        } else if (std.mem.eql(u8, arg, "show")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: 'show' requires an agent name\n", .{});
                return;
            }
            try showAgent(allocator, args[i]);
            return;
        } else if (std.mem.eql(u8, arg, "init")) {
            i += 1;
            const name = if (i < args.len) args[i] else "default";
            try initAgent(allocator, name, sandbox_root orelse ".");
            return;
        } else if (std.mem.eql(u8, arg, "orchestrate")) {
            // Collect remaining args for orchestrate subcommand
            try runOrchestrate(allocator, args[i + 1 ..]);
            return;
        } else if (std.mem.eql(u8, arg, "--web-search")) {
            try server_tools_list.append(allocator, .web_search);
        } else if (std.mem.eql(u8, arg, "--x-search")) {
            try server_tools_list.append(allocator, .x_search);
        } else if (std.mem.eql(u8, arg, "--code-interpreter")) {
            try server_tools_list.append(allocator, .code_interpreter);
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mcp requires a server URL\n", .{});
                return;
            }
            try mcp_tools_list.append(allocator, .{ .server_url = args[i] });
        } else if (std.mem.eql(u8, arg, "--collection")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --collection requires a collection ID\n", .{});
                return;
            }
            try collection_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--file-id")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file-id requires a file ID\n", .{});
                return;
            }
            try file_id_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--tool-choice")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --tool-choice requires a value\n", .{});
                return;
            }
            const val = args[i];
            if (std.mem.eql(u8, val, "auto")) {
                tool_choice = .auto;
            } else if (std.mem.eql(u8, val, "required") or std.mem.eql(u8, val, "any")) {
                tool_choice = .required;
            } else if (std.mem.eql(u8, val, "none")) {
                tool_choice = .none;
            } else if (std.mem.eql(u8, val, "validated")) {
                tool_choice = .validated;
            } else {
                tool_choice = .function;
                tool_choice_function = val;
            }
        } else if (std.mem.eql(u8, arg, "--no-parallel-tools")) {
            parallel_tool_calls = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            task = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        }
    }

    // Load or create config
    var agent_config: config.AgentConfig = undefined;

    if (config_name) |name| {
        // Try loading by name or path
        if (std.mem.endsWith(u8, name, ".json")) {
            agent_config = config.AgentConfig.loadFromFile(allocator, name) catch |err| {
                std.debug.print("Error loading config from {s}: {}\n", .{ name, err });
                return;
            };
        } else {
            agent_config = config.AgentConfig.loadByName(allocator, name) catch |err| {
                std.debug.print("Error loading config '{s}': {}\n", .{ name, err });
                return;
            };
        }
    } else if (sandbox_root) |root| {
        // Create default config with given sandbox root
        agent_config = createDefaultConfig(allocator, root) catch |err| {
            std.debug.print("Error creating config: {}\n", .{err});
            return;
        };
    } else {
        std.debug.print("Error: Either --config or --sandbox is required\n", .{});
        printHelp();
        return;
    }

    // Create executor
    var agent_executor = executor.AgentExecutor.init(allocator, agent_config) catch |err| {
        std.debug.print("Error initializing agent: {}\n", .{err});
        return;
    };
    defer agent_executor.deinit();

    // Set server-side tools if any were requested
    if (server_tools_list.items.len > 0) {
        agent_executor.server_tools = server_tools_list.items;
    }
    if (mcp_tools_list.items.len > 0) {
        agent_executor.mcp_tools = mcp_tools_list.items;
    }
    if (collection_list.items.len > 0) {
        agent_executor.collection_ids = collection_list.items;
    }
    if (file_id_list.items.len > 0) {
        agent_executor.file_ids = file_id_list.items;
    }
    agent_executor.tool_choice = tool_choice;
    agent_executor.tool_choice_function = tool_choice_function;
    agent_executor.parallel_tool_calls = parallel_tool_calls;

    std.debug.print("\nAgent: {s}\n", .{agent_config.agent_name});
    std.debug.print("Sandbox: {s}\n", .{agent_executor.sandbox.getRoot()});
    std.debug.print("Provider: {s}\n", .{agent_config.provider.name});
    std.debug.print("Platform: {s}\n", .{agent_executor.sandbox.getPlatformInfo()});

    if (interactive) {
        try agent_executor.runInteractive();
    } else if (task) |t| {
        std.debug.print("\nTask: {s}\n", .{t});

        var result = agent_executor.run(t) catch |err| {
            std.debug.print("\nError running task: {}\n", .{err});
            return;
        };
        defer result.deinit();

        std.debug.print("\n══════════════════════════════════════════════════\n", .{});
        std.debug.print("Result:\n{s}\n", .{result.final_response});
        std.debug.print("══════════════════════════════════════════════════\n", .{});
        const effective_model = getEffectiveModel(agent_config.provider);
        std.debug.print("\nTurns: {d}, Tool calls: {d}, Tokens: {d}/{d}\n", .{
            result.turns_used,
            result.tool_calls_made,
            result.total_input_tokens,
            result.total_output_tokens,
        });
        if (pricing.calculateCost(effective_model, result.total_input_tokens, result.total_output_tokens)) |cost| {
            var cost_buf: [64]u8 = undefined;
            std.debug.print("Cost: {s} ({s})\n", .{ pricing.formatCost(&cost_buf, cost), effective_model });
        }
    } else {
        std.debug.print("Error: No task provided. Use --interactive or provide a task.\n", .{});
        printHelp();
    }
}

fn printHelp() void {
    std.debug.print(
        \\
        \\zig-ai agent - AI Agent with Security Sandbox
        \\
        \\Usage:
        \\  zig-ai agent "task" --config <name>     Run a task
        \\  zig-ai agent "task" --sandbox <path>   Run with quick sandbox
        \\  zig-ai agent --interactive --config <name>
        \\  zig-ai agent list                      List available agents
        \\  zig-ai agent show <name>               Show agent config
        \\  zig-ai agent init <name>               Create agent config
        \\  zig-ai agent orchestrate "goal" --sandbox <path>
        \\
        \\Options:
        \\  -c, --config <name>   Agent config name or path
        \\  -s, --sandbox <path>  Sandbox root directory
        \\  -i, --interactive     Interactive mode
        \\  --web-search          Enable xAI web search (Grok only)
        \\  --x-search            Enable xAI X/Twitter search (Grok only)
        \\  --code-interpreter    Enable xAI code interpreter (Grok only)
        \\  --mcp <url>           Connect to MCP server (Grok only)
        \\  --collection <id>     Search collection documents (Grok only, repeatable)
        \\  --file-id <id>        Attach uploaded file (Grok only, repeatable)
        \\  --tool-choice <v>     Tool choice: auto/required/none/<function_name>
        \\  --no-parallel-tools   Disable parallel function calling
        \\  -h, --help            Show this help
        \\
        \\Orchestrate options:
        \\  --architect <provider>     Architect provider (default: claude)
        \\  --worker <provider>        Default worker provider (default: claude)
        \\  --architect-model <model>  Architect model override
        \\  --worker-model <model>     Worker model override
        \\  --plan <path>              Resume from saved plan
        \\  --max-cost <usd>           Cost limit before aborting
        \\  --no-save-plan             Don't persist plan
        \\  --audit-log <path>         Audit log file path
        \\
        \\Examples:
        \\  zig-ai agent "List all .zig files" --sandbox ./my-project
        \\  zig-ai agent --interactive --config code-assistant
        \\  zig-ai agent "Refactor main.zig" -c ./agent.json
        \\  zig-ai agent "Research latest Zig news" -c grok-agent --web-search --x-search
        \\  zig-ai agent orchestrate "Build an HTTP server" --sandbox ./project
        \\  zig-ai agent orchestrate --plan ./plan.json --sandbox ./project
        \\
        \\Config locations:
        \\  ~/.config/zig_ai/agents/<name>.json
        \\  ./config/agents/<name>.json
        \\
    , .{});
}

fn runOrchestrate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var goal: ?[]const u8 = null;
    var sandbox_root: ?[]const u8 = null;
    var config_name: ?[]const u8 = null;
    var architect_provider: []const u8 = "claude";
    var worker_provider: []const u8 = "claude";
    var architect_model: ?[]const u8 = null;
    var worker_model: ?[]const u8 = null;
    var resume_plan: ?[]const u8 = null;
    var max_cost: f64 = 0;
    var save_plan: bool = true;
    var audit_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --sandbox requires a path\n", .{}); return; }
            sandbox_root = args[i];
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --config requires a name\n", .{}); return; }
            config_name = args[i];
        } else if (std.mem.eql(u8, arg, "--architect")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --architect requires a provider\n", .{}); return; }
            architect_provider = args[i];
        } else if (std.mem.eql(u8, arg, "--worker")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --worker requires a provider\n", .{}); return; }
            worker_provider = args[i];
        } else if (std.mem.eql(u8, arg, "--architect-model")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --architect-model requires a model\n", .{}); return; }
            architect_model = args[i];
        } else if (std.mem.eql(u8, arg, "--worker-model")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --worker-model requires a model\n", .{}); return; }
            worker_model = args[i];
        } else if (std.mem.eql(u8, arg, "--plan")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --plan requires a path\n", .{}); return; }
            resume_plan = args[i];
        } else if (std.mem.eql(u8, arg, "--max-cost")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --max-cost requires a value\n", .{}); return; }
            // Parse float from string
            max_cost = parseFloat(args[i]);
        } else if (std.mem.eql(u8, arg, "--no-save-plan")) {
            save_plan = false;
        } else if (std.mem.eql(u8, arg, "--audit-log")) {
            i += 1;
            if (i >= args.len) { std.debug.print("Error: --audit-log requires a path\n", .{}); return; }
            audit_path = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            goal = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        }
    }

    // Validate required args
    if (goal == null and resume_plan == null) {
        std.debug.print("Error: Provide a goal or --plan to resume\n", .{});
        printHelp();
        return;
    }

    if (sandbox_root == null) {
        std.debug.print("Error: --sandbox is required for orchestrate\n", .{});
        return;
    }

    // Load or create agent config
    var agent_config: config.AgentConfig = undefined;

    if (config_name) |name| {
        if (std.mem.endsWith(u8, name, ".json")) {
            agent_config = config.AgentConfig.loadFromFile(allocator, name) catch |err| {
                std.debug.print("Error loading config from {s}: {}\n", .{ name, err });
                return;
            };
        } else {
            agent_config = config.AgentConfig.loadByName(allocator, name) catch |err| {
                std.debug.print("Error loading config '{s}': {}\n", .{ name, err });
                return;
            };
        }
    } else {
        agent_config = createDefaultConfig(allocator, sandbox_root.?) catch |err| {
            std.debug.print("Error creating config: {}\n", .{err});
            return;
        };
    }

    // Build orchestrator config
    const orch_config = config.OrchestratorConfig{
        .architect_provider = architect_provider,
        .architect_model = architect_model,
        .worker_provider = worker_provider,
        .worker_model = worker_model,
        .save_plan = save_plan,
        .audit_log = true,
        .audit_path = audit_path,
        .max_cost_usd = max_cost,
    };

    std.debug.print("\n╔══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  AI Orchestrator                                 ║\n", .{});
    std.debug.print("║  Sandbox: {s: <38}║\n", .{sandbox_root.?});
    std.debug.print("║  Architect: {s: <36}║\n", .{architect_provider});
    std.debug.print("║  Workers: {s: <38}║\n", .{worker_provider});
    std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});

    var orch = orchestrator_mod.Orchestrator.init(allocator, agent_config, orch_config);
    defer orch.deinit();

    var result: orchestrator_mod.OrchestratorResult = undefined;

    if (resume_plan) |plan_path| {
        // Resume from saved plan
        std.debug.print("\nResuming from plan: {s}\n", .{plan_path});

        // Load the session file to get the plan JSON
        var sess = @import("session.zig").Session.load(allocator, plan_path) catch |err| {
            std.debug.print("Error loading plan: {}\n", .{err});
            return;
        };
        defer sess.deinit();

        result = orch.runFromPlan(sess.plan_json) catch |err| {
            std.debug.print("Error running from plan: {}\n", .{err});
            return;
        };
    } else {
        std.debug.print("\nGoal: {s}\n", .{goal.?});
        result = orch.run(goal.?) catch |err| {
            std.debug.print("Error running orchestration: {}\n", .{err});
            return;
        };
    }
    defer result.deinit();

    // Print summary
    std.debug.print("\n══════════════════════════════════════════════════\n", .{});
    std.debug.print("Orchestration Summary:\n{s}\n", .{result.summary});
    std.debug.print("══════════════════════════════════════════════════\n", .{});

    if (result.plan_path) |pp| {
        std.debug.print("Plan saved: {s}\n", .{pp});
    }
}

/// Simple float parser for CLI args (no std.fmt.parseFloat in Zig 0.16)
fn parseFloat(s: []const u8) f64 {
    var result: f64 = 0;
    var decimal_place: f64 = 0;
    var after_dot = false;

    for (s) |c| {
        if (c == '.') {
            after_dot = true;
            decimal_place = 0.1;
        } else if (c >= '0' and c <= '9') {
            if (after_dot) {
                result += @as(f64, @floatFromInt(c - '0')) * decimal_place;
                decimal_place *= 0.1;
            } else {
                result = result * 10 + @as(f64, @floatFromInt(c - '0'));
            }
        }
    }
    return result;
}

fn listAgents(allocator: std.mem.Allocator) !void {
    std.debug.print("\nAvailable agent configs:\n\n", .{});

    const dirs = try config.getConfigDirs(allocator);
    defer {
        for (dirs) |dir| {
            allocator.free(dir);
        }
        allocator.free(dirs);
    }

    for (dirs) |dir| {
        std.debug.print("  {s}\n", .{dir});

        // List JSON files
        const dir_z = try allocator.allocSentinel(u8, dir.len, 0);
        defer allocator.free(dir_z);
        @memcpy(dir_z, dir);

        const d = std.c.opendir(dir_z.ptr);
        if (d == null) continue;
        defer _ = std.c.closedir(d.?);

        while (std.c.readdir(d.?)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            if (std.mem.endsWith(u8, name, ".json")) {
                std.debug.print("    - {s}\n", .{name});
            }
        }
    }

    std.debug.print("\n", .{});
}

fn showAgent(allocator: std.mem.Allocator, name: []const u8) !void {
    var agent_config = config.AgentConfig.loadByName(allocator, name) catch |err| {
        std.debug.print("Error loading config '{s}': {}\n", .{ name, err });
        return;
    };
    defer agent_config.deinit();

    std.debug.print("\nAgent: {s}\n", .{agent_config.agent_name});
    if (agent_config.description) |desc| {
        std.debug.print("Description: {s}\n", .{desc});
    }
    std.debug.print("\nProvider:\n", .{});
    std.debug.print("  name: {s}\n", .{agent_config.provider.name});
    if (agent_config.provider.model) |m| {
        std.debug.print("  model: {s}\n", .{m});
    }
    std.debug.print("  max_tokens: {d}\n", .{agent_config.provider.max_tokens});
    std.debug.print("  max_turns: {d}\n", .{agent_config.provider.max_turns});

    std.debug.print("\nSandbox:\n", .{});
    std.debug.print("  root: {s}\n", .{agent_config.sandbox.root});
    std.debug.print("  allow_network: {}\n", .{agent_config.sandbox.allow_network});

    std.debug.print("\nEnabled tools:\n", .{});
    for (agent_config.tools.enabled) |tool| {
        std.debug.print("  - {s}\n", .{tool});
    }

    std.debug.print("\n", .{});
}

fn initAgent(allocator: std.mem.Allocator, name: []const u8, sandbox_root: []const u8) !void {
    const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.config/zig_ai/agents", .{home});
    defer allocator.free(dir_path);

    // Create directory
    const dir_z = try allocator.allocSentinel(u8, dir_path.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, dir_path);
    _ = std.c.mkdir(dir_z.ptr, 0o755);

    // Create config file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir_path, name });
    defer allocator.free(file_path);

    const canonical_root = security.canonicalizePath(allocator, sandbox_root) catch sandbox_root;
    defer if (canonical_root.ptr != sandbox_root.ptr) allocator.free(canonical_root);

    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "agent_name": "{s}",
        \\  "description": "AI coding assistant",
        \\
        \\  "provider": {{
        \\    "name": "claude",
        \\    "max_tokens": 32768,
        \\    "max_turns": 50
        \\  }},
        \\
        \\  "sandbox": {{
        \\    "root": "{s}",
        \\    "writable_paths": ["{s}", "{s}/output"],
        \\    "allow_network": false
        \\  }},
        \\
        \\  "tools": {{
        \\    "enabled": ["read_file", "write_file", "list_files", "search_files", "execute_command"],
        \\    "execute_command": {{
        \\      "allowed_commands": ["ls", "cat", "head", "tail", "grep", "find", "wc", "diff"],
        \\      "banned_patterns": ["rm -rf /", "rm -rf ~", "sudo *"],
        \\      "timeout_ms": 30000
        \\    }}
        \\  }},
        \\
        \\  "limits": {{
        \\    "max_file_size_bytes": 1048576,
        \\    "max_files_per_operation": 100
        \\  }},
        \\
        \\  "system_prompt": "You are a helpful coding assistant. Write generated files to the output/ directory."
        \\}}
    , .{ name, canonical_root, canonical_root, canonical_root });
    defer allocator.free(content);

    const file_z = try allocator.allocSentinel(u8, file_path.len, 0);
    defer allocator.free(file_z);
    @memcpy(file_z, file_path);

    const file = std.c.fopen(file_z.ptr, "wb") orelse {
        std.debug.print("Error: Failed to create config file\n", .{});
        return;
    };
    defer _ = std.c.fclose(file);

    _ = std.c.fwrite(content.ptr, 1, content.len, file);

    std.debug.print("Created agent config: {s}\n", .{file_path});
}

fn createDefaultConfig(allocator: std.mem.Allocator, sandbox_root: []const u8) !config.AgentConfig {
    const canonical_root = try security.canonicalizePath(allocator, sandbox_root);

    var cfg = config.AgentConfig{
        .agent_name = "quick-agent",
        .sandbox = .{
            .root = canonical_root,
            .writable_paths = &.{},
        },
        .allocator = allocator,
    };

    // Track the allocated root
    try cfg._allocated_strings.append(allocator, canonical_root);

    return cfg;
}

fn getEffectiveModel(provider: config.ProviderConfig) []const u8 {
    if (provider.model) |m| return m;
    if (std.mem.eql(u8, provider.name, "claude")) return "claude-sonnet-4-5-20250929";
    if (std.mem.eql(u8, provider.name, "gemini")) return "gemini-2.5-pro";
    if (std.mem.eql(u8, provider.name, "openai") or std.mem.eql(u8, provider.name, "gpt")) return "gpt-5.2";
    if (std.mem.eql(u8, provider.name, "grok")) return "grok-4-1-fast-non-reasoning";
    if (std.mem.eql(u8, provider.name, "deepseek")) return "deepseek-chat";
    return "unknown";
}
