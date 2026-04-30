//! qai chat — pure-Zig terminal chat client.
//!
//! Streams from a configurable provider/base_url. By default talks directly
//! to upstream (Claude/OpenAI/Gemini/Grok/DeepSeek). Point base_url at your
//! own backend in qai.toml and the same client routes through there.
//!
//! Usage:
//!   qai                     # interactive REPL
//!   qai "single prompt"     # one-shot, prints reply, exits
//!   qai --config=path.toml  # use custom config file
//!   qai --provider=openai   # override provider for this run
//!   qai --model=...         # override model

const std = @import("std");
const hs = @import("http-sentinel");
const cfg_mod = @import("config.zig");
const agent = @import("agent.zig");

const Provider = cfg_mod.Provider;

const StreamCtx = struct {
    /// Accumulates the assistant's full reply for history persistence.
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    /// stdout writer's interface — token deltas go straight here for live display.
    out: *std.Io.Writer,
};

fn streamCallback(text: []const u8, ctx: ?*anyopaque) bool {
    const c: *StreamCtx = @alignCast(@ptrCast(ctx orelse return false));
    c.buf.appendSlice(c.allocator, text) catch return false;
    c.out.writeAll(text) catch return false;
    c.out.flush() catch return false;
    return true;
}

const Args = struct {
    config_path: ?[]const u8 = null,
    provider_override: ?Provider = null,
    model_override: ?[]const u8 = null,
    max_tokens_override: ?u32 = null,
    reasoning_override: ?[]const u8 = null,
    one_shot: ?[]const u8 = null,
    tools_enabled: bool = false,
    auto_approve: bool = false,
};

const ParseArgsError = error{
    HelpRequested,
    InvalidProvider,
} || std.process.Args.Iterator.InitError;

fn parseArgs(args_in: std.process.Args) ParseArgsError!Args {
    var out = Args{};
    var it = std.process.Args.Iterator.init(args_in);
    _ = it.next(); // exe name

    while (it.next()) |raw| {
        if (std.mem.startsWith(u8, raw, "--config=")) {
            out.config_path = raw["--config=".len..];
        } else if (std.mem.startsWith(u8, raw, "--provider=")) {
            out.provider_override = Provider.parse(raw["--provider=".len..]) orelse return error.InvalidProvider;
        } else if (std.mem.startsWith(u8, raw, "--model=")) {
            out.model_override = raw["--model=".len..];
        } else if (std.mem.startsWith(u8, raw, "--max-tokens=")) {
            out.max_tokens_override = std.fmt.parseInt(u32, raw["--max-tokens=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, raw, "--reasoning=")) {
            out.reasoning_override = raw["--reasoning=".len..];
        } else if (std.mem.eql(u8, raw, "--tools")) {
            out.tools_enabled = true;
        } else if (std.mem.eql(u8, raw, "--yes") or std.mem.eql(u8, raw, "-y")) {
            out.auto_approve = true;
        } else if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
            return error.HelpRequested;
        } else if (out.one_shot == null) {
            out.one_shot = raw;
        }
    }
    return out;
}

fn writeAllSafe(out: *std.Io.Writer, bytes: []const u8) void {
    out.writeAll(bytes) catch {};
    out.flush() catch {};
}

const HELP =
    \\qai — pure-Zig terminal chat client.
    \\
    \\Usage:
    \\  qai [flags] [prompt]
    \\
    \\Flags:
    \\  --config=PATH       Path to qai.toml (default: ./qai.toml, then ~/.config/qai/config.toml)
    \\  --provider=NAME     Override provider: anthropic|openai|gemini|grok|deepseek
    \\  --model=ID          Override model id
    \\  --max-tokens=N      Override max output tokens (default 4096)
    \\  --reasoning=LEVEL   Override OpenAI/Grok reasoning effort: minimal|low|medium|high|xhigh
    \\  --tools             Enable tool calling. Read-only tools (read_file, ls,
    \\                      grep) run unprompted. Writable tools (write_file,
    \\                      edit_file, bash) prompt y/n before each call.
    \\                      Streams live for Anthropic, OpenAI, and Grok.
    \\  -y, --yes           Auto-approve all writable tool calls (DANGEROUS).
    \\                      Use only for trusted scripted runs.
    \\  -h, --help          Show this help
    \\
    \\If a prompt is supplied, qai runs once and exits. Otherwise it drops into
    \\an interactive REPL — type a line, see streamed reply, repeat. /quit to
    \\exit, /clear to reset history.
    \\
    \\API keys are read from the env var named in qai.toml's per-provider section
    \\(default: ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.). To route through your
    \\own backend, set base_url to your server URL in qai.toml and switch the
    \\api_key_env to a per-user token (e.g. QAI_TOKEN).
    \\
;

/// Resolve which config file to load. Caller owns the returned slice.
fn resolveConfigPath(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    override: ?[]const u8,
) !?[]const u8 {
    if (override) |p| return try gpa.dupe(u8, p);

    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, "qai.toml", .{})) {
        return try gpa.dupe(u8, "qai.toml");
    } else |_| {}

    if (environ_map.get("HOME")) |home| {
        const path = try std.fmt.allocPrint(gpa, "{s}/.config/qai/config.toml", .{home});
        if (cwd.access(io, path, .{})) {
            return path;
        } else |_| gpa.free(path);
    }

    return null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = parseArgs(init.minimal.args) catch |e| switch (e) {
        error.HelpRequested => {
            writeAllSafe(err, HELP);
            return;
        },
        error.InvalidProvider => {
            writeAllSafe(err, "error: --provider must be one of anthropic|openai|gemini|grok|deepseek\n");
            std.process.exit(2);
        },
    };

    const path = try resolveConfigPath(io, gpa, env, args.config_path);
    defer if (path) |p| gpa.free(p);

    var cfg = if (path) |p|
        try cfg_mod.loadFile(io, gpa, p)
    else
        try cfg_mod.defaults(gpa);
    defer cfg.deinit();

    if (args.provider_override) |p| {
        cfg.provider = p;
        // If user picked a new provider without specifying --model, swap the
        // model to that provider's default. Otherwise the previous provider's
        // default leaks through and the upstream rejects it.
        if (args.model_override == null) {
            cfg.model = try cfg.arena.allocator().dupe(u8, p.defaultModel());
        }
    }
    if (args.model_override) |m| cfg.model = try cfg.arena.allocator().dupe(u8, m);
    if (args.max_tokens_override) |t| cfg.max_tokens = t;
    if (args.reasoning_override) |r| cfg.reasoning_effort = try cfg.arena.allocator().dupe(u8, r);

    // Verify the active provider's key is set right now — failing here is
    // friendlier than waiting for the first turn. Crucially, we DO NOT cache
    // the value: the API key is re-resolved every dispatchTurn so /provider
    // switches mid-session pick up the right key for the new provider.
    {
        const settings = cfg.active();
        if (env.get(settings.api_key_env) == null) {
            try err.print(
                "error: env var {s} is not set. (provider={s}, base_url={s})\n" ++
                    "       set it, or edit qai.toml to point at a different api_key_env.\n",
                .{ settings.api_key_env, cfg.provider.name(), settings.base_url },
            );
            try err.flush();
            std.process.exit(1);
        }

        try err.print(
            "qai · provider={s} · model={s} · base_url={s}\n",
            .{ cfg.provider.name(), cfg.model, settings.base_url },
        );
        try err.flush();
    }

    var history: std.ArrayList(hs.ai.common.AIMessage) = .empty;
    defer {
        for (history.items) |*m| m.deinit();
        history.deinit(gpa);
    }

    var approvals = agent.Approvals.init(gpa);
    defer approvals.deinit();
    // Per-project approvals file. Loaded silently if it exists; appended
    // to (atomically) every time the user picks "always" at a confirm prompt.
    approvals.attachDisk(io, ".qai/approvals") catch |e| {
        try err.print("[approvals] failed to load .qai/approvals: {s}\n", .{@errorName(e)});
        try err.flush();
    };

    // Stdin reader is shared between the REPL line-input and the
    // tool-confirmation prompt — set it up once.
    const stdin_file = std.Io.File.stdin();
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = stdin_file.reader(io, &stdin_buf);
    const in = &stdin_reader.interface;

    if (args.one_shot) |prompt| {
        try dispatchTurn(gpa, io, &cfg, env, &history, prompt, out, err, in, &approvals, args);
        try out.writeAll("\n");
        try out.flush();
        return;
    }

    // REPL.
    while (true) {
        try out.writeAll("\nyou> ");
        try out.flush();

        const raw = in.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed, error.StreamTooLong => return e,
        } orelse {
            try out.writeAll("\n");
            try out.flush();
            return;
        };
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;

        // Slash commands: handled locally, no LLM round-trip.
        if (line.len > 0 and line[0] == '/') {
            if (try handleSlashCommand(gpa, io, line, &cfg, &history, &approvals, out, err)) continue;
            // handleSlashCommand returned false → /quit signal: exit.
            return;
        }

        try out.writeAll("\n");
        try out.flush();
        dispatchTurn(gpa, io, &cfg, env, &history, line, out, err, in, &approvals, args) catch |e| {
            try err.print("\n[error: {s}]\n", .{@errorName(e)});
            try err.flush();
        };
    }
}

/// Handle a /-prefixed command. Returns true to continue the REPL, false to
/// quit. Unknown commands print a hint and continue.
fn handleSlashCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    line: []const u8,
    cfg: *cfg_mod.Config,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    approvals: *agent.Approvals,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !bool {
    _ = out;
    // Split into command + tail args.
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (sp) |i| line[0..i] else line;
    const tail = if (sp) |i| std.mem.trim(u8, line[i + 1 ..], " \t") else "";

    if (std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/exit")) return false;

    if (std.mem.eql(u8, cmd, "/help")) {
        try err.writeAll(
            \\Slash commands:
            \\  /help                Show this help
            \\  /quit, /exit         Exit qai
            \\  /clear, /reset       Clear conversation history
            \\  /history             Show turn count + last few message previews
            \\  /tools               List available tools
            \\  /model [ID]          Show current model, or switch to ID
            \\  /provider [NAME]     Show current provider, or switch (anthropic|openai|gemini|grok|deepseek)
            \\  /approvals           List session approvals
            \\  /forget              Clear all approvals (in-memory + on-disk)
            \\  /save PATH           Save the conversation as markdown to PATH
            \\
        );
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/clear") or std.mem.eql(u8, cmd, "/reset")) {
        for (history.items) |*m| m.deinit();
        history.clearRetainingCapacity();
        try err.writeAll("[history cleared]\n");
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/history")) {
        try err.print("[history] {d} messages\n", .{history.items.len});
        const start = if (history.items.len > 6) history.items.len - 6 else 0;
        for (history.items[start..], start..) |m, i| {
            const preview_len = @min(m.content.len, 80);
            const role = m.role.toString();
            try err.print("  {d}. {s}: {s}", .{ i, role, m.content[0..preview_len] });
            if (m.content.len > preview_len) try err.writeAll("…");
            if (m.tool_calls) |tc| try err.print(" [+{d} tool_calls]", .{tc.len});
            if (m.tool_results) |tr| try err.print(" [+{d} tool_results]", .{tr.len});
            try err.writeAll("\n");
        }
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/tools")) {
        const tools = @import("tools.zig");
        for (tools.all_tools) |t| {
            const tag = if (t.is_writable) "[writable]" else "[read-only]";
            try err.print("  {s:<11} {s} — {s}\n", .{ tag, t.name, t.description });
        }
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/model")) {
        if (tail.len == 0) {
            try err.print("[model] current: {s}\n", .{cfg.model});
        } else {
            const a = cfg.arena.allocator();
            cfg.model = try a.dupe(u8, tail);
            try err.print("[model] switched to {s}\n", .{cfg.model});
        }
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/provider")) {
        if (tail.len == 0) {
            try err.print("[provider] current: {s} (model {s})\n", .{ cfg.provider.name(), cfg.model });
        } else {
            const new_p = cfg_mod.Provider.parse(tail) orelse {
                try err.print("[provider] unknown: {s}. Use anthropic|openai|gemini|grok|deepseek.\n", .{tail});
                try err.flush();
                return true;
            };
            cfg.provider = new_p;
            const a = cfg.arena.allocator();
            cfg.model = try a.dupe(u8, new_p.defaultModel());
            try err.print("[provider] switched to {s} (model {s})\n", .{ cfg.provider.name(), cfg.model });
        }
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/approvals")) {
        try err.print("[approvals] {d} paths, {d} bash commands, {d} bash rules\n", .{
            approvals.paths.items.len,
            approvals.commands.items.len,
            approvals.bash_rules.items.len,
        });
        for (approvals.paths.items) |p| try err.print("  path: {s}\n", .{p});
        for (approvals.commands.items) |c| try err.print("  bash: {s}\n", .{c});
        for (approvals.bash_rules.items) |r| try err.print("  rule: {s} *\n", .{r});
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/forget")) {
        approvals.clear();
        try err.writeAll("[approvals] cleared (in-memory + on-disk)\n");
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/save")) {
        if (tail.len == 0) {
            try err.writeAll("[save] usage: /save <path>\n");
            try err.flush();
            return true;
        }
        saveConversationMarkdown(gpa, io, tail, cfg, history) catch |e| {
            try err.print("[save] failed: {s}\n", .{@errorName(e)});
            try err.flush();
            return true;
        };
        try err.print("[save] wrote {d} messages to {s}\n", .{ history.items.len, tail });
        try err.flush();
        return true;
    }

    try err.print("[?] unknown command: {s} (try /help)\n", .{cmd});
    try err.flush();
    return true;
}

/// Render the current conversation as markdown. One section per turn,
/// `## role`, plus an inline rendering of any tool_calls and tool_results
/// so the transcript reads like Claude Code's logs.
fn saveConversationMarkdown(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    cfg: *cfg_mod.Config,
    history: *std.ArrayList(hs.ai.common.AIMessage),
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    try buf.print(gpa,
        \\# qai conversation
        \\
        \\- provider: `{s}`
        \\- model: `{s}`
        \\- base_url: `{s}`
        \\- saved (epoch): `{d}`
        \\- messages: {d}
        \\
        \\---
        \\
    , .{ cfg.provider.name(), cfg.model, cfg.active().base_url, ts, history.items.len });

    for (history.items, 0..) |m, i| {
        try buf.print(gpa, "## [{d}] {s}\n\n", .{ i, m.role.toString() });
        if (m.content.len > 0) {
            try buf.appendSlice(gpa, m.content);
            if (m.content[m.content.len - 1] != '\n') try buf.appendSlice(gpa, "\n");
            try buf.appendSlice(gpa, "\n");
        }
        if (m.tool_calls) |calls| {
            try buf.appendSlice(gpa, "**tool calls:**\n\n");
            for (calls) |c| {
                try buf.print(gpa, "- `{s}({s})`\n", .{ c.name, c.arguments });
            }
            try buf.appendSlice(gpa, "\n");
        }
        if (m.tool_results) |results| {
            try buf.appendSlice(gpa, "**tool results:**\n\n");
            for (results) |r| {
                try buf.print(gpa, "<details><summary><code>{s}</code></summary>\n\n```\n", .{r.tool_call_id});
                try buf.appendSlice(gpa, r.content);
                if (r.content.len > 0 and r.content[r.content.len - 1] != '\n') try buf.appendSlice(gpa, "\n");
                try buf.appendSlice(gpa, "```\n\n</details>\n\n");
            }
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

fn dispatchTurn(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *cfg_mod.Config,
    env: *const std.process.Environ.Map,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    prompt: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    stdin: *std.Io.Reader,
    approvals: *agent.Approvals,
    args: Args,
) !void {
    const settings = cfg.active();
    // Re-resolve the API key per-turn so /provider switches mid-session pick
    // up the right key for the new provider.
    const api_key = env.get(settings.api_key_env) orelse {
        try err.print(
            "[error] env var {s} not set for provider={s}.\n",
            .{ settings.api_key_env, cfg.provider.name() },
        );
        try err.flush();
        return;
    };

    if (args.tools_enabled) {
        return agent.run(.{
            .gpa = gpa,
            .io = io,
            .provider = cfg.provider,
            .api_key = api_key,
            .base_url = settings.base_url,
            .provider_name = cfg.provider.name(),
            .model = cfg.model,
            .max_tokens = cfg.max_tokens,
            .temperature = cfg.temperature,
            .reasoning_effort = cfg.reasoning_effort,
            .system_prompt = cfg.system_prompt,
            .history = history,
            .out = out,
            .err = err,
            .stdin = stdin,
            .auto_approve = args.auto_approve,
            .approvals = approvals,
            .user_prompt = prompt,
        });
    }
    return runTurn(gpa, io, cfg, api_key, history, prompt, out, err);
}

fn runTurn(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *cfg_mod.Config,
    api_key: []const u8,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    prompt: []const u8,
    out: *std.Io.Writer,
    err_writer: *std.Io.Writer,
) !void {
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(gpa);

    var ctx = StreamCtx{ .buf = &reply, .allocator = gpa, .out = out };

    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = cfg.model,
        .max_tokens = cfg.max_tokens,
        .temperature = cfg.temperature,
        .system_prompt = cfg.system_prompt,
    };

    const settings = cfg.active();

    switch (cfg.provider) {
        .anthropic, .deepseek => {
            var client = try hs.ai.AnthropicClient.init(gpa, .{
                .api_key = api_key,
                .base_url = settings.base_url,
                .provider_name = cfg.provider.name(),
            });
            defer client.deinit();
            client.sendMessageStreamingWithContext(prompt, history.items, req_cfg, streamCallback, &ctx) catch |e| {
                try agent.surfaceApiError(err_writer, &client.http_client, e);
                return e;
            };
        },
        .openai => {
            var client = try hs.ai.OpenAIClient.initWithConfig(gpa, .{
                .api_key = api_key,
                .base_url = settings.base_url,
            });
            defer client.deinit();
            client.sendMessageStreamingWithContext(prompt, history.items, req_cfg, streamCallback, &ctx) catch |e| {
                try agent.surfaceApiError(err_writer, &client.http_client, e);
                return e;
            };
        },
        .grok => {
            var client = try hs.ai.GrokClient.initWithConfig(gpa, .{
                .api_key = api_key,
                .base_url = settings.base_url,
            });
            defer client.deinit();
            client.sendMessageStreamingWithContext(prompt, history.items, req_cfg, streamCallback, &ctx) catch |e| {
                try agent.surfaceApiError(err_writer, &client.http_client, e);
                return e;
            };
        },
        .gemini => {
            var client = try hs.ai.GeminiClient.initWithConfig(gpa, .{
                .api_key = api_key,
                .base_url = settings.base_url,
            });
            defer client.deinit();
            client.sendMessageStreamingWithContext(prompt, history.items, req_cfg, streamCallback, &ctx) catch |e| {
                try agent.surfaceApiError(err_writer, &client.http_client, e);
                return e;
            };
        },
    }

    try appendMsg(gpa, io, history, .user, prompt);
    try appendMsg(gpa, io, history, .assistant, reply.items);
}

fn appendMsg(
    gpa: std.mem.Allocator,
    io: std.Io,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    role: hs.ai.common.MessageRole,
    content: []const u8,
) !void {
    const id = try std.fmt.allocPrint(gpa, "msg-{d}", .{history.items.len});
    const owned = try gpa.dupe(u8, content);
    try history.append(gpa, .{
        .id = id,
        .role = role,
        .content = owned,
        .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
        .allocator = gpa,
    });
}
