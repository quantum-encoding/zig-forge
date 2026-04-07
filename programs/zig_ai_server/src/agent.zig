// Agent endpoint — POST /qai/v1/agent
// Single model, single loop, three tools: bash, write_file, read_file
// Pure Zig — no libc, no C externs, no system(), no popen()
// Uses std.Io for all I/O, std.process.run for child processes

const std = @import("std");
const http = std.http;
const Io = std.Io;
const Dir = std.Io.Dir;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const models_mod = @import("models.zig");
const account_mod = @import("account.zig");
const chat_mod = @import("chat.zig");
const security = @import("security.zig");
const Response = router.Response;

// ── Request type ────────────────────────────────────────────

const AgentRequest = struct {
    goal: []const u8,
    model: []const u8 = "deepseek-chat",
    max_iterations: ?i32 = null,
    ephemeral: ?bool = null,
    enable_rag: ?bool = null,
    system_prompt: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
};

// ── Tool definitions (3 tools) ──────────────────────────────

const tool_definitions = [_]hs.ai.common.ToolDefinition{
    .{
        .name = "bash",
        .description = "Run a shell command in the workspace directory. Use for: ls, grep, git, zig build, rag search, cat, etc. The working directory is the agent workspace.",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"}},"required":["command"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Write content to a file in the workspace. Creates parent directories if needed. Use this instead of heredocs in bash.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative file path within workspace"},"content":{"type":"string","description":"Complete file content to write"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "read_file",
        .description = "Read the contents of a file in the workspace. Returns the file content as text. Max 100KB.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative file path within workspace"}},"required":["path"]}
        ,
    },
};

// ── System prompts ──────────────────────────────────────────

const SYSTEM_PROMPT =
    \\You are an expert software engineer. You have access to three tools: bash, write_file, and read_file.
    \\
    \\Guidelines:
    \\- Use bash for all shell operations: ls, grep, git, compilers, package managers, etc.
    \\- Use write_file to create/modify files (avoids heredoc quoting issues).
    \\- Use read_file to inspect existing files.
    \\- Always check your work: after writing code, compile/test it with bash.
    \\- Fix errors iteratively — read the error, fix, rebuild.
    \\- Be concise in explanations. Let the code speak.
;

const RAG_SYSTEM_PROMPT =
    \\You are an expert software engineer with access to a RAG knowledge base. You have three tools: bash, write_file, and read_file.
    \\
    \\Guidelines:
    \\- BEFORE writing code, search the RAG for relevant documentation:
    \\  bash: rag search -c "Zig" "std.http.Server listen accept"
    \\  bash: rag search -c "Zig 0.16 Example Programs" "echo server thread"
    \\- Use bash for all shell operations: ls, grep, git, compilers, etc.
    \\- Use write_file to create/modify files.
    \\- Use read_file to inspect existing files.
    \\- After compiler errors, search RAG for the correct API before guessing.
    \\- Always compile/test your code after writing it.
    \\- Fix errors iteratively. Let the code speak.
;

// ── Handler ─────────────────────────────────────────────────

pub fn handle(request: *http.Server.Request, allocator: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) Response {
    // Parse with 256KB limit for agent requests
    const body = json_util.readBody(request, allocator, security.Limits.max_agent_body) catch |err| {
        return errorResp(err);
    };
    defer allocator.free(body);

    if (body.len == 0) return errorResp(error.EmptyBody);

    const parsed = std.json.parseFromSlice(AgentRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errorResp(error.OutOfMemory);
    };
    defer parsed.deinit();
    const req = parsed.value;

    const provider_info = chat_mod.resolveProvider(req.model) orelse {
        return .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_model","message":"Unknown model. Use claude-*, deepseek-*, gemini-*, grok-*, gpt-*"}
            ,
        };
    };

    const api_key = hs.ai.getApiKeyFromEnv(environ_map, provider_info.env_var) catch {
        return .{
            .status = .internal_server_error,
            .body =
            \\{"error":"config_error","message":"Missing provider API key"}
            ,
        };
    };
    // api_key is borrowed from environ_map — no free needed

    var client = hs.ai.AIClient.init(allocator, provider_info.provider, .{
        .api_key = api_key,
    }) catch {
        return .{
            .status = .internal_server_error,
            .body =
            \\{"error":"provider_error","message":"Failed to init AI client"}
            ,
        };
    };
    defer client.deinit();

    // Sanitize workspace ID — alphanumeric, hyphen, underscore only
    const raw_ws_id = req.workspace_id orelse "agent-session";
    const workspace_id = security.sanitizeId(raw_ws_id) orelse {
        return .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"workspace_id must be alphanumeric, hyphens, underscores only (max 128 chars)"}
            ,
        };
    };
    const is_ephemeral = req.ephemeral orelse true;
    const workspace_path = createWorkspace(allocator, io, workspace_id, is_ephemeral) catch {
        return .{
            .status = .internal_server_error,
            .body =
            \\{"error":"workspace_error","message":"Failed to create workspace"}
            ,
        };
    };
    defer allocator.free(workspace_path);

    const max_iters: u32 = if (req.max_iterations) |mi|
        @intCast(@min(@max(mi, 1), @as(i32, @intCast(security.Limits.max_agent_iterations))))
    else
        25;
    const enable_rag = req.enable_rag orelse false;

    const result = runAgentLoop(
        allocator,
        io,
        &client,
        req.goal,
        req.model,
        workspace_path,
        max_iters,
        enable_rag,
        req.system_prompt,
    ) catch |err| {
        const msg = std.fmt.allocPrint(allocator,
            \\{{"error":"agent_error","message":"Agent loop failed: {s}"}}
        , .{@errorName(err)}) catch
            \\{"error":"agent_error","message":"Agent loop failed"}
        ;
        return .{ .status = .internal_server_error, .body = msg };
    };

    return .{ .body = result };
}

// ── Agent Loop ──────────────────────────────────────────────

fn runAgentLoop(
    allocator: std.mem.Allocator,
    io: Io,
    client: *hs.ai.AIClient,
    goal: []const u8,
    model: []const u8,
    workspace: []const u8,
    max_iters: u32,
    enable_rag: bool,
    custom_system: ?[]const u8,
) ![]u8 {
    var config = hs.ai.RequestConfig{
        .model = model,
        .max_tokens = 16384,
        .temperature = 0.7,
        .tools = &tool_definitions,
        .tool_choice = .auto,
        .system_prompt = custom_system orelse (if (enable_rag) RAG_SYSTEM_PROMPT else SYSTEM_PROMPT),
    };
    _ = &config;

    var messages: std.ArrayListUnmanaged(hs.ai.AIMessage) = .empty;
    defer {
        for (messages.items) |*msg| msg.deinit();
        messages.deinit(allocator);
    }

    var total_input_tokens: u32 = 0;
    var total_output_tokens: u32 = 0;
    var iterations_used: u32 = 0;
    var files_written: u32 = 0;
    var tool_calls_total: u32 = 0;
    var final_text: []const u8 = "";
    var final_text_alloc: ?[]u8 = null;
    defer if (final_text_alloc) |ft| allocator.free(ft);

    var iter: u32 = 0;
    while (iter < max_iters) : (iter += 1) {
        iterations_used = iter + 1;

        const prompt = if (iter == 0) goal else "";
        var response = if (messages.items.len > 0)
            try client.sendMessageWithContext(prompt, messages.items, config)
        else
            try client.sendMessage(prompt, config);

        total_input_tokens += response.usage.input_tokens;
        total_output_tokens += response.usage.output_tokens;

        if (response.message.tool_calls) |tool_calls| {
            try messages.append(allocator, response.message);

            var results: std.ArrayListUnmanaged(hs.ai.common.ToolResult) = .empty;
            defer {
                for (results.items) |*r| r.deinit();
                results.deinit(allocator);
            }

            for (tool_calls) |call| {
                tool_calls_total += 1;
                const result = executeTool(allocator, io, call, workspace) catch |err| {
                    const err_content = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch
                        allocator.dupe(u8, "Error: tool execution failed") catch continue;
                    try results.append(allocator, .{
                        .tool_call_id = try allocator.dupe(u8, call.id),
                        .content = err_content,
                        .is_error = true,
                        .allocator = allocator,
                    });
                    continue;
                };

                if (std.mem.eql(u8, call.name, "write_file")) {
                    files_written += 1;
                }

                try results.append(allocator, result);
            }

            const results_owned = try allocator.dupe(hs.ai.common.ToolResult, results.items);
            results.items.len = 0;

            try messages.append(allocator, .{
                .id = try hs.ai.common.generateId(allocator, io),
                .role = .user,
                .content = try allocator.dupe(u8, ""),
                .timestamp = 0,
                .tool_results = results_owned,
                .allocator = allocator,
            });
        } else {
            final_text_alloc = try allocator.dupe(u8, response.message.content);
            final_text = final_text_alloc.?;
            response.deinit();
            break;
        }
    }

    // Record cost — integer arithmetic, no floats in billing
    const pricing = models_mod.getPricing(model);
    const input_millidollars: i64 = @intFromFloat(pricing.input * 1000.0);
    const output_millidollars: i64 = @intFromFloat(pricing.output * 1000.0);
    const cost_ticks = @divFloor(input_millidollars * @as(i64, total_input_tokens) * 10_000_000, 1_000_000) +
        @divFloor(output_millidollars * @as(i64, total_output_tokens) * 10_000_000, 1_000_000);
    account_mod.recordTicks(cost_ticks);

    const escaped = try chat_mod.jsonEscape(allocator, final_text);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator,
        \\{{"status":"completed","model":"{s}","iterations":{d},"tool_calls":{d},"files_written":{d},"usage":{{"input_tokens":{d},"output_tokens":{d},"cost_ticks":{d}}},"response":"{s}"}}
    , .{ model, iterations_used, tool_calls_total, files_written, total_input_tokens, total_output_tokens, cost_ticks, escaped });
}

// ── Tool Execution ──────────────────────────────────────────

fn executeTool(
    allocator: std.mem.Allocator,
    io: Io,
    call: hs.ai.common.ToolCall,
    workspace: []const u8,
) !hs.ai.common.ToolResult {
    const args = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch {
        return .{
            .tool_call_id = try allocator.dupe(u8, call.id),
            .content = try allocator.dupe(u8, "Error: invalid JSON arguments"),
            .is_error = true,
            .allocator = allocator,
        };
    };
    defer args.deinit();

    if (std.mem.eql(u8, call.name, "bash")) {
        return execBash(allocator, io, call.id, args.value, workspace);
    } else if (std.mem.eql(u8, call.name, "write_file")) {
        return execWriteFile(allocator, io, call.id, args.value, workspace);
    } else if (std.mem.eql(u8, call.name, "read_file")) {
        return execReadFile(allocator, io, call.id, args.value, workspace);
    }

    return .{
        .tool_call_id = try allocator.dupe(u8, call.id),
        .content = try allocator.dupe(u8, "Error: unknown tool"),
        .is_error = true,
        .allocator = allocator,
    };
}

// ── bash tool: std.process.run ──────────────────────────────

fn execBash(
    allocator: std.mem.Allocator,
    io: Io,
    call_id: []const u8,
    args: std.json.Value,
    workspace: []const u8,
) !hs.ai.common.ToolResult {
    const command = getStr(args, "command") orelse {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: missing 'command' argument"),
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Validate command against blocklist
    if (security.validateCommand(command) == null) {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: command blocked by security policy"),
            .is_error = true,
            .allocator = allocator,
        };
    }

    // Use std.process.run — pure Zig, captures stdout+stderr
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bash", "-c", command },
        .cwd = .{ .path = workspace },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error spawning process: {s}", .{@errorName(err)});
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = msg,
            .is_error = true,
            .allocator = allocator,
        };
    };
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    // Combine stdout + stderr
    const content = if (exit_code != 0 and result.stderr.len > 0) blk: {
        defer allocator.free(result.stdout);
        break :blk try std.fmt.allocPrint(allocator, "Exit code: {d}\n{s}\n{s}", .{ exit_code, result.stdout, result.stderr });
    } else if (result.stderr.len > 0) blk: {
        defer allocator.free(result.stdout);
        break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ result.stdout, result.stderr });
    } else if (result.stdout.len == 0) blk: {
        allocator.free(result.stdout);
        break :blk try allocator.dupe(u8, "(no output)");
    } else result.stdout;

    return .{
        .tool_call_id = try allocator.dupe(u8, call_id),
        .content = content,
        .is_error = exit_code != 0,
        .allocator = allocator,
    };
}

// ── write_file tool: std.Io.Dir ─────────────────────────────

fn execWriteFile(
    allocator: std.mem.Allocator,
    io: Io,
    call_id: []const u8,
    args: std.json.Value,
    workspace: []const u8,
) !hs.ai.common.ToolResult {
    const path = getStr(args, "path") orelse {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
            .is_error = true,
            .allocator = allocator,
        };
    };
    const content = getStr(args, "content") orelse {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: missing 'content' argument"),
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Strict path validation — no traversal, no absolute, no symlink tricks
    const safe_path = security.validatePath(path) orelse {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: invalid path — must be relative, no '..' or absolute paths"),
            .is_error = true,
            .allocator = allocator,
        };
    };
    _ = safe_path; // validated, use original `path` which is now known safe

    // Open workspace directory
    const ws_dir = Dir.openDirAbsolute(io, workspace, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error opening workspace: {s}", .{@errorName(err)});
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = msg,
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Create parent directories if needed
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        ws_dir.createDirPath(io, path[0..last_slash]) catch {};
    }

    // Write the file — pure Zig I/O
    ws_dir.writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = msg,
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Git auto-commit via std.process.run
    gitAutoCommit(allocator, io, workspace, path);

    const msg = try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ content.len, path });
    return .{
        .tool_call_id = try allocator.dupe(u8, call_id),
        .content = msg,
        .allocator = allocator,
    };
}

// ── read_file tool: Dir.readFileAlloc ───────────────────────

fn execReadFile(
    allocator: std.mem.Allocator,
    io: Io,
    call_id: []const u8,
    args: std.json.Value,
    workspace: []const u8,
) !hs.ai.common.ToolResult {
    const path = getStr(args, "path") orelse {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
            .is_error = true,
            .allocator = allocator,
        };
    };

    if (security.validatePath(path) == null) {
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = try allocator.dupe(u8, "Error: invalid path — must be relative, no '..' or absolute paths"),
            .is_error = true,
            .allocator = allocator,
        };
    }

    const ws_dir = Dir.openDirAbsolute(io, workspace, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error opening workspace: {s}", .{@errorName(err)});
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = msg,
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Read file — pure Zig, 100KB cap
    const content = ws_dir.readFileAlloc(io, path, allocator, .limited(100 * 1024)) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
        return .{
            .tool_call_id = try allocator.dupe(u8, call_id),
            .content = msg,
            .is_error = true,
            .allocator = allocator,
        };
    };

    return .{
        .tool_call_id = try allocator.dupe(u8, call_id),
        .content = content,
        .allocator = allocator,
    };
}

// ── Workspace Management (pure Zig) ─────────────────────────

fn createWorkspace(allocator: std.mem.Allocator, io: Io, id: []const u8, ephemeral: bool) ![]u8 {
    const path = if (ephemeral)
        try std.fmt.allocPrint(allocator, "/tmp/qai-agent-{s}", .{id})
    else
        try std.fmt.allocPrint(allocator, "/tmp/qai-workspace-{s}", .{id});

    // Create workspace directory via Zig std.Io.Dir
    Dir.cwd().createDirPath(io, path) catch {};

    // Git init via std.process.run
    _ = std.process.run(allocator, io, .{
        .argv = &.{ "git", "init", "-q" },
        .cwd = .{ .path = path },
    }) catch {};

    return path;
}

fn gitAutoCommit(allocator: std.mem.Allocator, io: Io, workspace: []const u8, file_path: []const u8) void {
    // git add <file>
    _ = std.process.run(allocator, io, .{
        .argv = &.{ "git", "add", file_path },
        .cwd = .{ .path = workspace },
    }) catch return;

    // git commit
    const msg = std.fmt.allocPrint(allocator, "agent: write {s}", .{file_path}) catch return;
    defer allocator.free(msg);

    _ = std.process.run(allocator, io, .{
        .argv = &.{ "git", "commit", "-q", "-m", msg },
        .cwd = .{ .path = workspace },
    }) catch return;
}

// ── Helpers ─────────────────────────────────────────────────

fn getStr(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v == .string) return v.string;
    return null;
}

fn errorResp(err: anyerror) Response {
    return switch (err) {
        error.PayloadTooLarge => .{
            .status = .payload_too_large,
            .body =
            \\{"error":"payload_too_large","message":"Request body exceeds limit"}
            ,
        },
        error.EmptyBody => .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_request","message":"Request body is empty. Send JSON with goal and model."}
            ,
        },
        else => .{
            .status = .bad_request,
            .body =
            \\{"error":"invalid_json","message":"Failed to parse request body"}
            ,
        },
    };
}
