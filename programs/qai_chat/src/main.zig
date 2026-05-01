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

const Subcommand = enum { usage };

const Args = struct {
    config_path: ?[]const u8 = null,
    provider_override: ?Provider = null,
    model_override: ?[]const u8 = null,
    max_tokens_override: ?u32 = null,
    reasoning_override: ?[]const u8 = null,
    one_shot: ?[]const u8 = null,
    tools_enabled: bool = false,
    auto_approve: bool = false,
    /// Top-level subcommand. When set, qai runs that subcommand and exits
    /// without entering chat mode.
    subcommand: ?Subcommand = null,
    /// `qai usage --project=PATH` filter — accepts either an absolute path
    /// (sanitized via the same rules as projectKey) or the raw sanitized key.
    project_filter: ?[]const u8 = null,
    /// `qai usage --since=YYYYMMDD` — only rows with ts >= this prefix.
    since_filter: ?[]const u8 = null,
    /// `qai usage --by-provider` — group rows by (provider, model) instead
    /// of by project file. Useful for "where am I spending across all repos
    /// per model".
    by_provider: bool = false,
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
        } else if (std.mem.startsWith(u8, raw, "--project=")) {
            out.project_filter = raw["--project=".len..];
        } else if (std.mem.startsWith(u8, raw, "--since=")) {
            out.since_filter = raw["--since=".len..];
        } else if (std.mem.eql(u8, raw, "--by-provider")) {
            out.by_provider = true;
        } else if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
            return error.HelpRequested;
        } else if (out.subcommand == null and std.mem.eql(u8, raw, "usage")) {
            out.subcommand = .usage;
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
    \\Subcommands:
    \\  qai usage [--project=PATH] [--since=YYYYMMDD] [--by-provider]
    \\                      Summarise ~/.qai/usage/*.csv into a cost table.
    \\                      Default groups by project; --by-provider transposes
    \\                      to group by (provider, model) across all projects.
    \\                      Skips chat mode entirely.
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
        // Subcommands don't talk to providers; skip the env-var pre-flight
        // check so `qai usage` works without any keys configured.
        if (args.subcommand == null and env.get(settings.api_key_env) == null) {
            try err.print(
                "error: env var {s} is not set. (provider={s}, base_url={s})\n" ++
                    "       set it, or edit qai.toml to point at a different api_key_env.\n",
                .{ settings.api_key_env, cfg.provider.name(), settings.base_url },
            );
            try err.flush();
            std.process.exit(1);
        }

        // Suppress the banner when we're about to run a subcommand — the
        // user just wants the summary, not chat-mode chrome.
        if (args.subcommand == null) {
            try err.print(
                "qai · provider={s} · model={s} · base_url={s}\n",
                .{ cfg.provider.name(), cfg.model, settings.base_url },
            );
            try err.flush();
        }
    }

    if (args.subcommand) |sub| switch (sub) {
        .usage => {
            try runUsageSummary(gpa, io, env, out, err, args.project_filter, args.since_filter, args.by_provider);
            return;
        },
    };

    var history: std.ArrayList(hs.ai.common.AIMessage) = .empty;
    defer {
        for (history.items) |*m| m.deinit();
        history.deinit(gpa);
    }

    var approvals = agent.Approvals.init(gpa);
    defer approvals.deinit();

    var usage_total = agent.UsageStats.init(gpa);
    defer usage_total.deinit();
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
        try dispatchTurn(gpa, io, &cfg, env, &history, prompt, out, err, in, &approvals, &usage_total, args);
        try out.writeAll("\n");
        try out.flush();
        return;
    }

    // Auto-save the REPL transcript on clean exit, but only if any turn
    // actually happened. Skip if the user immediately /quit on an empty
    // session.
    defer autoSaveOnExit(gpa, io, env, &cfg, &history, &usage_total, err) catch {};

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
            if (try handleSlashCommand(gpa, io, env, line, &cfg, &history, &approvals, &usage_total, out, err)) continue;
            // handleSlashCommand returned false → /quit signal: exit.
            return;
        }

        try out.writeAll("\n");
        try out.flush();
        dispatchTurn(gpa, io, &cfg, env, &history, line, out, err, in, &approvals, &usage_total, args) catch |e| {
            try err.print("\n[error: {s}]\n", .{@errorName(e)});
            try err.flush();
        };
    }
}

/// On clean REPL exit:
///   - dump the conversation as markdown to `~/.qai/projects/<key>/<ts>-<provider>.md`
///   - append one CSV row to `~/.qai/usage/<key>.csv` with session totals
///   - print a one-line summary
/// All best-effort — failures are reported but don't propagate.
fn autoSaveOnExit(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: *cfg_mod.Config,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    usage_total: *agent.UsageStats,
    err: *std.Io.Writer,
) !void {
    if (history.items.len == 0) return;

    const path = try sessionPath(gpa, io, env, cfg.provider.name());
    defer gpa.free(path);
    saveConversationMarkdown(gpa, io, path, cfg, history) catch |e| {
        try err.print("[autosave] save failed: {s}\n", .{@errorName(e)});
        try err.flush();
        return;
    };

    // Best-effort usage log — don't block on it.
    appendUsageRow(gpa, io, env, usage_total) catch |e| {
        try err.print("[autosave] usage log failed: {s}\n", .{@errorName(e)});
        try err.flush();
    };

    const agg = usage_total.aggregate();
    try err.print(
        "[autosave] {s} · {d} turns · {d} in / {d} out · ${d:.4}\n",
        .{ path, agg.turns, agg.input_tokens, agg.output_tokens, agg.cost_usd },
    );
    try err.flush();
}

/// Build a session-named path under `~/.qai/projects/<sanitized-cwd>/`.
/// Filename format: YYYYMMDD-HHMMSS-<provider>.md (UTC). Caller owns.
///
/// Mirrors `~/.claude/projects/` — conversations live in $HOME, grouped by
/// the cwd they started in. Falls back to a project-local path if HOME is
/// missing or cwd resolution fails.
fn sessionPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    provider_name: []const u8,
) ![]u8 {
    const ts_part = try timestampSlug(gpa, io);
    defer gpa.free(ts_part);

    if (try projectDir(gpa, io, env)) |dir| {
        defer gpa.free(dir);
        return std.fmt.allocPrint(gpa, "{s}/{s}-{s}.md", .{ dir, ts_part, provider_name });
    }
    // Fallback: project-local. Better than failing the save outright.
    return std.fmt.allocPrint(gpa, ".qai/sessions/{s}-{s}.md", .{ ts_part, provider_name });
}

/// `~/.qai/projects/<sanitized-cwd>` — caller owns. Returns null if HOME or
/// cwd can't be resolved.
fn projectDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !?[]u8 {
    const home = env.get("HOME") orelse return null;
    const key = try projectKey(gpa, io) orelse return null;
    defer gpa.free(key);
    return try std.fmt.allocPrint(gpa, "{s}/.qai/projects/{s}", .{ home, key });
}

/// `~/.qai/usage/<sanitized-cwd>.csv` — caller owns. Returns null if HOME
/// or cwd can't be resolved.
fn usageLogPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !?[]u8 {
    const home = env.get("HOME") orelse return null;
    const key = try projectKey(gpa, io) orelse return null;
    defer gpa.free(key);
    return try std.fmt.allocPrint(gpa, "{s}/.qai/usage/{s}.csv", .{ home, key });
}

/// Sanitize the current working directory into a flat directory name.
/// `/Users/director/work/poly-repo/zig-forge` → `-Users-director-work-poly-repo-zig-forge`.
/// On macOS, strips the `/private` prefix so /tmp/foo lands at `-tmp-foo`,
/// matching how users say the path. Caller owns.
fn projectKey(gpa: std.mem.Allocator, io: std.Io) !?[]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return null;
    var cwd: []const u8 = buf[0..n];

    // macOS resolves /tmp → /private/tmp, /var → /private/var via realpath.
    // For our project keys we want the user-facing form.
    if (std.mem.startsWith(u8, cwd, "/private/")) {
        cwd = cwd["/private".len..];
    }

    const out = try gpa.alloc(u8, cwd.len);
    for (cwd, 0..) |c, i| {
        out[i] = if (c == '/') '-' else c;
    }
    return out;
}

/// Expand `~/...` to `$HOME/...`. Returns the input slice unchanged when
/// no expansion happens. When expansion is needed allocates and stores the
/// new path in `out_owned` (caller frees iff non-null).
fn expandTilde(
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    path: []const u8,
    out_owned: *?[]u8,
) ![]const u8 {
    out_owned.* = null;
    if (path.len < 2 or path[0] != '~' or path[1] != '/') return path;
    const home = env.get("HOME") orelse return path;
    const expanded = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, path[2..] });
    out_owned.* = expanded;
    return expanded;
}

/// UTC YYYYMMDD-HHMMSS slug. Caller owns.
fn timestampSlug(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        gpa,
        "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

/// Parse a markdown transcript written by saveConversationMarkdown back
/// into AIMessage entries, replacing whatever was in `history`. The format
/// is line-oriented:
///
///   ## [N] role
///   <free-form content>
///   **tool calls:**
///   ```json
///   [{"id":..., "name":..., "arguments":{...}}, ...]
///   ```
///   **tool results:**
///   ```json
///   [{"tool_call_id":..., "content":"..."}, ...]
///   ```
///
/// The parser is a small line state machine. It tolerates extra blank lines
/// around the fences and ignores anything before the first `## [` header.
fn loadConversationMarkdown(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    history: *std.ArrayList(hs.ai.common.AIMessage),
) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(data);

    // Wipe whatever's in history — /load is "resume this transcript".
    for (history.items) |*m| m.deinit();
    history.clearRetainingCapacity();

    const State = enum { content, tool_calls_pre, tool_calls_json, tool_results_pre, tool_results_json };
    var state: State = .content;

    var p: Pending = .{};
    defer {
        p.content.deinit(gpa);
        p.json_buf.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        // Section header — finalize previous, start new.
        if (std.mem.startsWith(u8, raw_line, "## [")) {
            try flushPending(gpa, io, history, &p);
            const role = parseRoleFromHeader(raw_line) orelse .user;
            p = .{ .role = role, .active = true };
            state = .content;
            continue;
        }

        if (!p.active) continue;

        switch (state) {
            .content => {
                if (std.mem.eql(u8, raw_line, "**tool calls:**")) {
                    state = .tool_calls_pre;
                    continue;
                }
                if (std.mem.eql(u8, raw_line, "**tool results:**")) {
                    state = .tool_results_pre;
                    continue;
                }
                try p.content.appendSlice(gpa, raw_line);
                try p.content.append(gpa, '\n');
            },
            .tool_calls_pre => {
                // Skip blanks then expect a ``` fence (with optional language).
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    p.json_buf.clearRetainingCapacity();
                    state = .tool_calls_json;
                    continue;
                }
                // Malformed — bail back to content.
                state = .content;
            },
            .tool_calls_json => {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.eql(u8, trimmed, "```")) {
                    p.calls = try parseToolCallsJson(gpa, p.json_buf.items);
                    state = .content;
                    continue;
                }
                try p.json_buf.appendSlice(gpa, raw_line);
                try p.json_buf.append(gpa, '\n');
            },
            .tool_results_pre => {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    p.json_buf.clearRetainingCapacity();
                    state = .tool_results_json;
                    continue;
                }
                state = .content;
            },
            .tool_results_json => {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.eql(u8, trimmed, "```")) {
                    p.results = try parseToolResultsJson(gpa, p.json_buf.items);
                    state = .content;
                    continue;
                }
                try p.json_buf.appendSlice(gpa, raw_line);
                try p.json_buf.append(gpa, '\n');
            },
        }
    }

    try flushPending(gpa, io, history, &p);
}

fn parseRoleFromHeader(line: []const u8) ?hs.ai.common.MessageRole {
    // "## [N] role" — find "] " then read the rest up to a possible "(".
    const close = std.mem.indexOf(u8, line, "] ") orelse return null;
    const rest = std.mem.trim(u8, line[close + 2 ..], " \t\r");
    if (std.mem.eql(u8, rest, "user")) return .user;
    if (std.mem.eql(u8, rest, "assistant")) return .assistant;
    if (std.mem.eql(u8, rest, "system")) return .system;
    if (std.mem.eql(u8, rest, "tool")) return .tool;
    return null;
}

fn parseToolCallsJson(gpa: std.mem.Allocator, json_text: []const u8) ![]hs.ai.common.ToolCall {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return &[_]hs.ai.common.ToolCall{};

    const items = parsed.value.array.items;
    const out = try gpa.alloc(hs.ai.common.ToolCall, items.len);
    var ok: usize = 0;
    errdefer {
        for (out[0..ok]) |*c| c.deinit();
        gpa.free(out);
    }

    for (items, 0..) |v, i| {
        if (v != .object) return error.InvalidFormat;
        const id_v = v.object.get("id") orelse return error.InvalidFormat;
        const name_v = v.object.get("name") orelse return error.InvalidFormat;
        const args_v = v.object.get("arguments") orelse return error.InvalidFormat;
        if (id_v != .string or name_v != .string) return error.InvalidFormat;

        // Re-serialize arguments back to a JSON string for ToolCall.arguments.
        var arg_buf: std.Io.Writer.Allocating = .init(gpa);
        errdefer arg_buf.deinit();
        var stringify: std.json.Stringify = .{ .writer = &arg_buf.writer, .options = .{} };
        try stringify.write(args_v);

        out[i] = .{
            .id = try gpa.dupe(u8, id_v.string),
            .name = try gpa.dupe(u8, name_v.string),
            .arguments = try arg_buf.toOwnedSlice(),
            .allocator = gpa,
        };
        ok = i + 1;
    }
    return out;
}

fn parseToolResultsJson(gpa: std.mem.Allocator, json_text: []const u8) ![]hs.ai.common.ToolResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return &[_]hs.ai.common.ToolResult{};

    const items = parsed.value.array.items;
    const out = try gpa.alloc(hs.ai.common.ToolResult, items.len);
    var ok: usize = 0;
    errdefer {
        for (out[0..ok]) |*r| r.deinit();
        gpa.free(out);
    }

    for (items, 0..) |v, i| {
        if (v != .object) return error.InvalidFormat;
        const id_v = v.object.get("tool_call_id") orelse return error.InvalidFormat;
        const content_v = v.object.get("content") orelse return error.InvalidFormat;
        if (id_v != .string or content_v != .string) return error.InvalidFormat;

        out[i] = .{
            .tool_call_id = try gpa.dupe(u8, id_v.string),
            .content = try gpa.dupe(u8, content_v.string),
            .allocator = gpa,
        };
        ok = i + 1;
    }
    return out;
}

const Pending = struct {
    role: hs.ai.common.MessageRole = .user,
    content: std.ArrayList(u8) = .empty,
    json_buf: std.ArrayList(u8) = .empty,
    calls: ?[]hs.ai.common.ToolCall = null,
    results: ?[]hs.ai.common.ToolResult = null,
    active: bool = false,
};

fn flushPending(
    gpa: std.mem.Allocator,
    io: std.Io,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    p: *Pending,
) !void {
    if (!p.active) return;

    // Strip trailing blank lines from the content buffer.
    var len = p.content.items.len;
    while (len > 0 and (p.content.items[len - 1] == '\n' or p.content.items[len - 1] == ' ' or p.content.items[len - 1] == '\r')) {
        len -= 1;
    }
    const content = try gpa.dupe(u8, p.content.items[0..len]);

    try history.append(gpa, .{
        .id = try std.fmt.allocPrint(gpa, "loaded-{d}", .{history.items.len}),
        .role = p.role,
        .content = content,
        .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
        .tool_calls = p.calls,
        .tool_results = p.results,
        .allocator = gpa,
    });

    p.calls = null;
    p.results = null;
    p.content.clearRetainingCapacity();
    p.json_buf.clearRetainingCapacity();
    p.active = false;
}

/// JSON-string-escape `s`. Caller owns. Used to embed user-supplied
/// names/contents into the markdown JSON tool blocks.
fn escapeJsonInline(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len + 8);
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...0x07, 0x0b, 0x0c, 0x0e...0x1f => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

/// `/sessions` — list past conversations under ~/.qai/projects/<cwd>/.
/// Filename already encodes timestamp + provider (e.g. 20260501-090508-anthropic.md),
/// so we don't open each file — the listing is cheap and accurate.
fn listSessions(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    err: *std.Io.Writer,
) !void {
    const dir_path = (try projectDir(gpa, io, env)) orelse {
        try err.writeAll("[sessions] HOME or cwd unresolved — no project dir.\n");
        try err.flush();
        return;
    };
    defer gpa.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("[sessions] no transcripts yet at {s}\n", .{dir_path});
            try err.flush();
            return;
        },
        else => return e,
    };
    defer dir.close(io);

    // Collect names so we can sort newest-first (timestamp prefix sorts as dates).
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var sizes: std.ArrayList(u64) = .empty;
    defer sizes.deinit(gpa);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
        const stat = dir.statFile(io, entry.name, .{}) catch null;
        try sizes.append(gpa, if (stat) |s| s.size else 0);
    }

    if (names.items.len == 0) {
        try err.print("[sessions] no transcripts yet at {s}\n", .{dir_path});
        try err.flush();
        return;
    }

    // Pair-sort names + sizes together, newest first.
    const Entry = struct { name: []u8, size: u64 };
    var paired = try gpa.alloc(Entry, names.items.len);
    defer gpa.free(paired);
    for (names.items, 0..) |n, i| paired[i] = .{ .name = n, .size = sizes.items[i] };
    std.mem.sort(Entry, paired, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, b.name, a.name);
        }
    }.lt);

    try err.print("[sessions] {s}/  ({d} entries)\n", .{ dir_path, paired.len });
    for (paired, 0..) |e, idx| {
        // Filename layout: <YYYYMMDD>-<HHMMSS>-<provider>.md
        const stem = e.name[0 .. e.name.len - ".md".len];
        var parts = std.mem.splitScalar(u8, stem, '-');
        const date = parts.next() orelse stem;
        const time = parts.next() orelse "";
        const provider = parts.rest();

        try err.print(
            "  {d:>2}. {s} {s}  {s:<10}  ({d} B)\n",
            .{ idx + 1, date, time, provider, e.size },
        );
    }
    try err.flush();
}

/// `qai usage [--project] [--since] [--by-provider]` — aggregate
/// ~/.qai/usage/*.csv into a single table. Default groups by project;
/// --by-provider groups by (provider, model) across projects.
fn runUsageSummary(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    project_filter: ?[]const u8,
    since_filter: ?[]const u8,
    by_provider: bool,
) !void {
    const home = env.get("HOME") orelse {
        try err.writeAll("[usage] HOME is not set — can't locate ~/.qai/usage/.\n");
        try err.flush();
        return;
    };
    const usage_dir = try std.fmt.allocPrint(gpa, "{s}/.qai/usage", .{home});
    defer gpa.free(usage_dir);

    var dir = std.Io.Dir.cwd().openDir(io, usage_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            try out.writeAll("(no usage logs yet — run a session first)\n");
            try out.flush();
            return;
        },
        else => return e,
    };
    defer dir.close(io);

    // Normalize the project filter: if it starts with '/' assume it's a
    // path and sanitize. Otherwise treat as already-sanitized key.
    var owned_filter: ?[]u8 = null;
    defer if (owned_filter) |f| gpa.free(f);
    const wanted_key: ?[]const u8 = if (project_filter) |p| blk: {
        if (p.len == 0) break :blk null;
        if (p[0] == '/') {
            const buf = try gpa.alloc(u8, p.len);
            for (p, 0..) |c, i| buf[i] = if (c == '/') '-' else c;
            owned_filter = buf;
            break :blk buf;
        }
        break :blk p;
    } else null;

    const Row = struct {
        // `key` is the bucket label printed in the leftmost column.
        // For project view: project name. For provider view: "provider/model".
        key: []const u8,
        turns: u64,
        input_tokens: u64,
        output_tokens: u64,
        cost: f64,
    };
    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| gpa.free(r.key);
        rows.deinit(gpa);
    }

    var grand: Row = .{ .key = "", .turns = 0, .input_tokens = 0, .output_tokens = 0, .cost = 0.0 };

    // Helper: find or insert a Row by key, returning a pointer.
    const upsert = struct {
        fn run(g: std.mem.Allocator, list: *std.ArrayList(Row), key: []const u8) !*Row {
            for (list.items) |*existing| {
                if (std.mem.eql(u8, existing.key, key)) return existing;
            }
            try list.append(g, .{
                .key = try g.dupe(u8, key),
                .turns = 0,
                .input_tokens = 0,
                .output_tokens = 0,
                .cost = 0.0,
            });
            return &list.items[list.items.len - 1];
        }
    }.run;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".csv")) continue;
        const project_name = entry.name[0 .. entry.name.len - ".csv".len];

        if (wanted_key) |k| if (!std.mem.eql(u8, project_name, k)) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ usage_dir, entry.name });
        defer gpa.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch continue;
        defer gpa.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw_line| {
            line_no += 1;
            if (line_no == 1) continue; // header
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            var fields = std.mem.splitScalar(u8, line, ',');
            const ts = fields.next() orelse continue;
            const provider = fields.next() orelse continue;
            const model = fields.next() orelse continue;
            const turns_s = fields.next() orelse continue;
            const in_s = fields.next() orelse continue;
            const out_s = fields.next() orelse continue;
            const cost_s = fields.next() orelse continue;

            if (since_filter) |since| {
                if (std.mem.lessThan(u8, ts, since)) continue;
            }

            const turns = std.fmt.parseInt(u64, turns_s, 10) catch 0;
            const in_t = std.fmt.parseInt(u64, in_s, 10) catch 0;
            const out_t = std.fmt.parseInt(u64, out_s, 10) catch 0;
            const cost = std.fmt.parseFloat(f64, cost_s) catch 0.0;

            // Build the row key for whichever grouping the caller asked for.
            var key_owned: ?[]u8 = null;
            const key: []const u8 = if (by_provider) blk: {
                const k = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ provider, model });
                key_owned = k;
                break :blk k;
            } else project_name;
            defer if (key_owned) |k| gpa.free(k);

            const row = try upsert(gpa, &rows, key);
            row.turns += turns;
            row.input_tokens += in_t;
            row.output_tokens += out_t;
            row.cost += cost;

            grand.turns += turns;
            grand.input_tokens += in_t;
            grand.output_tokens += out_t;
            grand.cost += cost;
        }
    }

    if (rows.items.len == 0) {
        try out.writeAll("(no rows matched)\n");
        try out.flush();
        return;
    }

    // Sort by cost desc — most-expensive bucket first, where the eye lands.
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.cost > b.cost;
        }
    }.lt);

    const header_label: []const u8 = if (by_provider) "PROVIDER/MODEL" else "PROJECT";
    var name_w: usize = header_label.len;
    for (rows.items) |r| if (r.key.len > name_w) {
        name_w = r.key.len;
    };

    try out.print("{s}", .{padRight(header_label, name_w)});
    try out.writeAll("  TURNS   IN_TOKENS  OUT_TOKENS         COST\n");
    try writeRule(out, name_w);

    for (rows.items) |r| {
        try out.print(
            "{s}  {d:>5}  {d:>10}  {d:>10}   ${d:>9.4}\n",
            .{ padRight(r.key, name_w), r.turns, r.input_tokens, r.output_tokens, r.cost },
        );
    }

    try writeRule(out, name_w);
    try out.print(
        "{s}  {d:>5}  {d:>10}  {d:>10}   ${d:>9.4}\n",
        .{ padRight("TOTAL", name_w), grand.turns, grand.input_tokens, grand.output_tokens, grand.cost },
    );
    try out.flush();
}

/// Right-pad `s` to width `w` using spaces. Returned slice is valid only
/// until the next call (uses a thread-local buffer).
fn padRight(s: []const u8, w: usize) []const u8 {
    const Local = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    const len = @min(@max(s.len, w), Local.buf.len);
    @memcpy(Local.buf[0..s.len], s);
    if (s.len < w) {
        const pad_to = @min(w, Local.buf.len);
        for (Local.buf[s.len..pad_to]) |*c| c.* = ' ';
    }
    return Local.buf[0..len];
}

fn writeRule(out: *std.Io.Writer, name_w: usize) !void {
    var i: usize = 0;
    while (i < name_w) : (i += 1) try out.writeAll("─");
    try out.writeAll("  ─────  ──────────  ──────────   ──────────\n");
}

/// Append one row PER (provider, model) bucket to
/// `~/.qai/usage/<sanitized-cwd>.csv`, writing the header on first use.
/// Best-effort — silently no-ops if HOME is missing or the session had no
/// usage to log.
fn appendUsageRow(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    usage_total: *agent.UsageStats,
) !void {
    if (usage_total.buckets.items.len == 0) return;

    const path = (try usageLogPath(gpa, io, env)) orelse return;
    defer gpa.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    // Header presence: if the file doesn't exist or is empty, prepend a header.
    const need_header = blk: {
        std.Io.Dir.cwd().access(io, path, .{}) catch break :blk true;
        break :blk false;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (need_header) {
        try buf.appendSlice(gpa, "ts,provider,model,turns,input_tokens,output_tokens,cost_usd\n");
    }

    const ts_part = try timestampSlug(gpa, io);
    defer gpa.free(ts_part);

    // One row per bucket — cleanly attributes spend even when the user
    // /provider-switched mid-session.
    for (usage_total.buckets.items) |b| {
        try buf.print(gpa, "{s},{s},{s},{d},{d},{d},{d:.6}\n", .{
            ts_part,
            b.provider,
            b.model,
            b.turns,
            b.input_tokens,
            b.output_tokens,
            b.cost_usd,
        });
    }

    if (need_header) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
        return;
    }

    // Append: read existing + concat. Atomic via .tmp + rename so the file
    // can never be corrupted by a partial write.
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch &[_]u8{};
    defer if (existing.len > 0) gpa.free(existing);

    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(gpa);
    try combined.appendSlice(gpa, existing);
    try combined.appendSlice(gpa, buf.items);

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = combined.items });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp, cwd, path, io);
}

/// Handle a /-prefixed command. Returns true to continue the REPL, false to
/// quit. Unknown commands print a hint and continue.
fn handleSlashCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    line: []const u8,
    cfg: *cfg_mod.Config,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    approvals: *agent.Approvals,
    usage_total: *agent.UsageStats,
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
            \\  /clear, /reset       Start a new conversation (reset history + usage)
            \\  /history             Show turn count + last few message previews
            \\  /tools               List available tools
            \\  /model [ID]          Show current model, or switch to ID
            \\  /provider [NAME]     Show current provider, or switch (anthropic|openai|gemini|grok|deepseek)
            \\  /approvals           List session approvals
            \\  /forget              Clear all approvals (in-memory + on-disk)
            \\  /save [PATH]         Save the conversation as markdown to PATH
            \\                       (default: ~/.qai/projects/<cwd>/<ts>-<provider>.md)
            \\  /usage               Show running token + cost totals for this session
            \\  /sessions            List past conversations saved for this project
            \\  /load PATH           Replace history with the transcript at PATH
            \\
        );
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/clear") or std.mem.eql(u8, cmd, "/reset")) {
        for (history.items) |*m| m.deinit();
        history.clearRetainingCapacity();
        usage_total.reset();
        try err.writeAll("[clear] history + usage reset (use /forget for approvals)\n");
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
        // /save with no path → session-named file under ~/.qai/projects/<cwd>/.
        // /save PATH → exact path the user typed (relative, absolute, or ~/...).
        var path: []const u8 = tail;
        var owned_default: ?[]u8 = null;
        defer if (owned_default) |p| gpa.free(p);
        var owned_expanded: ?[]u8 = null;
        defer if (owned_expanded) |p| gpa.free(p);

        if (path.len == 0) {
            owned_default = try sessionPath(gpa, io, env, cfg.provider.name());
            path = owned_default.?;
        } else {
            path = try expandTilde(gpa, env, path, &owned_expanded);
        }

        saveConversationMarkdown(gpa, io, path, cfg, history) catch |e| {
            try err.print("[save] failed: {s}\n", .{@errorName(e)});
            try err.flush();
            return true;
        };
        try err.print("[save] wrote {d} messages to {s}\n", .{ history.items.len, path });
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/usage")) {
        const agg = usage_total.aggregate();
        try err.print(
            "[usage] {d} turns · {d} in / {d} out · ${d:.4}\n",
            .{ agg.turns, agg.input_tokens, agg.output_tokens, agg.cost_usd },
        );
        // Per-provider breakdown if more than one bucket exists.
        if (usage_total.buckets.items.len > 1) {
            for (usage_total.buckets.items) |b| {
                try err.print(
                    "         · {s}/{s}: {d} turns, {d} in / {d} out, ${d:.4}\n",
                    .{ b.provider, b.model, b.turns, b.input_tokens, b.output_tokens, b.cost_usd },
                );
            }
        }
        try err.flush();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/sessions")) {
        try listSessions(gpa, io, env, err);
        return true;
    }

    if (std.mem.eql(u8, cmd, "/load")) {
        if (tail.len == 0) {
            try err.writeAll("[load] usage: /load <path>  (use /sessions to see candidates)\n");
            try err.flush();
            return true;
        }
        var owned: ?[]u8 = null;
        defer if (owned) |p| gpa.free(p);
        const path = try expandTilde(gpa, env, tail, &owned);
        loadConversationMarkdown(gpa, io, path, history) catch |e| {
            try err.print("[load] failed: {s}\n", .{@errorName(e)});
            try err.flush();
            return true;
        };
        try err.print("[load] history replaced with {d} messages from {s}\n", .{ history.items.len, path });
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
        // Tool blocks emit as JSON in fenced code blocks so /load can round-trip
        // them via std.json. Preserves IDs (lost in the previous human-pretty
        // format) which is essential for assistant.tool_use ↔ user.tool_result
        // matching when the conversation is resumed.
        if (m.tool_calls) |calls| {
            try buf.appendSlice(gpa, "**tool calls:**\n\n```json\n[");
            for (calls, 0..) |c, k| {
                if (k > 0) try buf.appendSlice(gpa, ",");
                const escaped_name = try escapeJsonInline(gpa, c.name);
                defer gpa.free(escaped_name);
                const escaped_id = try escapeJsonInline(gpa, c.id);
                defer gpa.free(escaped_id);
                try buf.print(
                    gpa,
                    "\n  {{\"id\":\"{s}\",\"name\":\"{s}\",\"arguments\":{s}}}",
                    .{ escaped_id, escaped_name, c.arguments },
                );
            }
            try buf.appendSlice(gpa, "\n]\n```\n\n");
        }
        if (m.tool_results) |results| {
            try buf.appendSlice(gpa, "**tool results:**\n\n```json\n[");
            for (results, 0..) |r, k| {
                if (k > 0) try buf.appendSlice(gpa, ",");
                const escaped_id = try escapeJsonInline(gpa, r.tool_call_id);
                defer gpa.free(escaped_id);
                const escaped_content = try escapeJsonInline(gpa, r.content);
                defer gpa.free(escaped_content);
                try buf.print(
                    gpa,
                    "\n  {{\"tool_call_id\":\"{s}\",\"content\":\"{s}\"}}",
                    .{ escaped_id, escaped_content },
                );
            }
            try buf.appendSlice(gpa, "\n]\n```\n\n");
        }
    }

    // Make sure the parent directory exists (mkdir -p) so paths like
    // `.qai/sessions/<ts>.md` work without manual setup.
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
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
    usage_total: *agent.UsageStats,
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
            .system_prompt = cfg.effectiveSystemPrompt(),
            .history = history,
            .out = out,
            .err = err,
            .stdin = stdin,
            .auto_approve = args.auto_approve,
            .approvals = approvals,
            .usage = usage_total,
            .user_prompt = prompt,
        });
    }
    return runTurn(gpa, io, cfg, api_key, history, prompt, out, err, usage_total);
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
    usage_total: *agent.UsageStats,
) !void {
    // Plain-chat now uses the same StreamEvent surface as agent mode so
    // token usage, message_stop, and any future shared signals all flow
    // through one path. Tools never fire in this configuration (we don't
    // pass any), so state.tools / state.saw_tool_use stay empty.
    var state = agent.TurnState{
        .gpa = gpa,
        .out = out,
        .err = err_writer,
    };
    defer state.deinit();

    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = cfg.model,
        .max_tokens = cfg.max_tokens,
        .temperature = cfg.temperature,
        .system_prompt = cfg.effectiveSystemPrompt(),
        .stream = true,
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
            client.sendMessageStreamingWithEvents(prompt, history.items, req_cfg, agent.streamEventCb, &state) catch |e| {
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
            client.sendMessageStreamingWithEvents(prompt, history.items, req_cfg, agent.streamEventCb, &state) catch |e| {
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
            client.sendMessageStreamingWithEvents(prompt, history.items, req_cfg, agent.streamEventCb, &state) catch |e| {
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
            client.sendMessageStreamingWithEvents(prompt, history.items, req_cfg, agent.streamEventCb, &state) catch |e| {
                try agent.surfaceApiError(err_writer, &client.http_client, e);
                return e;
            };
        },
    }

    if (state.text.items.len > 0 and state.text.items[state.text.items.len - 1] != '\n') {
        try out.writeAll("\n");
        try out.flush();
    }

    try agent.emitUsage(gpa, err_writer, cfg.provider.name(), cfg.model, state.input_tokens, state.output_tokens, 0, usage_total);

    try appendMsg(gpa, io, history, .user, prompt);
    try appendMsg(gpa, io, history, .assistant, state.text.items);
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
