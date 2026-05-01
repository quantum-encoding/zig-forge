//! Tool-calling agent loop, Anthropic-direct, streaming.
//!
//! Per user prompt: stream events from Claude. Print text deltas to stdout
//! as they arrive (so the user sees the model narrate). Track tool_use
//! blocks by index and accumulate their JSON args from input_delta events.
//! When the message stops:
//!   - if no tool_use blocks → done.
//!   - else: persist the assistant turn (text + tool_uses) to history,
//!     execute each tool locally, append a user turn with tool_results,
//!     loop with empty prompt (history carries everything).

const std = @import("std");
const hs = @import("http-sentinel");
const tools = @import("tools.zig");
const cfg_mod = @import("config.zig");
const pricing = @import("pricing.zig");

const MAX_AGENT_TURNS: u32 = 12;
const MAX_TOOL_BLOCKS: usize = 16;

/// Default system prompt for agent mode. Picked to even out cross-provider
/// behavior: keeps narration brief, encourages parallel tool calls, points
/// at the available toolset. The user can override via qai.toml's
/// `system_prompt = "..."` (or by /provider during a REPL session).
const DEFAULT_AGENT_SYSTEM_PROMPT =
    \\You are a precise terminal assistant with access to local tools:
    \\
    \\- read_file(path), ls(path), grep(pattern, path, glob): read-only inspection.
    \\- write_file(path, content), edit_file(path, old, new), bash(command): writable
    \\  side effects — the user must approve each one before it runs.
    \\
    \\Guidelines:
    \\1. Use tools when they answer the question better than guessing. Don't
    \\   pre-narrate plans you can just execute.
    \\2. When you need multiple independent observations, call those tools in
    \\   parallel in a single turn — don't serialize unnecessarily.
    \\3. For edits, prefer edit_file over rewriting the whole file. Include
    \\   enough surrounding context in old_string to make it unique.
    \\4. Treat tool errors literally; surface them to the user and adapt.
    \\5. After your last tool call, give a concise final answer — don't repeat
    \\   tool output verbatim if you can summarise.
;

/// Sessionwide allowlist for writable tools, optionally persisted to a
/// per-project file at `.qai/approvals` so the user doesn't re-approve
/// the same paths/commands every run.
///
/// Wire-format is one record per line:
///   write_path <path>
///   edit_path  <path>
///   bash       <command>
///   bash_rule  <prefix>     # whole-token prefix; e.g. "git" matches "git status"
/// Comments begin with `#`. Blank lines ignored.
pub const Approvals = struct {
    gpa: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    commands: std.ArrayList([]const u8) = .empty,
    /// Whole-token prefix rules for bash commands. A rule "git" matches
    /// any command equal to "git" or starting with "git " (note the space).
    bash_rules: std.ArrayList([]const u8) = .empty,
    /// File the in-memory state mirrors. null → in-memory only.
    disk_path: ?[]const u8 = null,
    io: ?std.Io = null,

    pub fn init(gpa: std.mem.Allocator) Approvals {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Approvals) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.deinit(self.gpa);
        for (self.commands.items) |c| self.gpa.free(c);
        self.commands.deinit(self.gpa);
        for (self.bash_rules.items) |r| self.gpa.free(r);
        self.bash_rules.deinit(self.gpa);
        if (self.disk_path) |p| self.gpa.free(p);
    }

    /// Hook the in-memory store to a disk file. Loads any existing entries
    /// silently (missing file is not an error). After this call, every
    /// `rememberPath` / `rememberCommand` will atomically rewrite the file.
    pub fn attachDisk(self: *Approvals, io: std.Io, path: []const u8) !void {
        self.io = io;
        self.disk_path = try self.gpa.dupe(u8, path);
        self.loadFromDisk() catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    pub fn hasPath(self: *const Approvals, path: []const u8) bool {
        for (self.paths.items) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    pub fn hasCommand(self: *const Approvals, cmd: []const u8) bool {
        for (self.commands.items) |c| if (std.mem.eql(u8, c, cmd)) return true;
        // Whole-token prefix match: rule "git" matches "git" or "git status",
        // but NOT "github" or "gitlab".
        for (self.bash_rules.items) |rule| {
            if (cmd.len < rule.len) continue;
            if (!std.mem.startsWith(u8, cmd, rule)) continue;
            if (cmd.len == rule.len or cmd[rule.len] == ' ') return true;
        }
        return false;
    }

    pub fn hasBashRule(self: *const Approvals, rule: []const u8) bool {
        for (self.bash_rules.items) |r| if (std.mem.eql(u8, r, rule)) return true;
        return false;
    }

    pub fn rememberPath(self: *Approvals, path: []const u8) !void {
        if (self.hasPath(path)) return;
        try self.paths.append(self.gpa, try self.gpa.dupe(u8, path));
        self.saveToDisk() catch {};
    }

    pub fn rememberCommand(self: *Approvals, cmd: []const u8) !void {
        if (self.hasCommand(cmd)) return;
        try self.commands.append(self.gpa, try self.gpa.dupe(u8, cmd));
        self.saveToDisk() catch {};
    }

    pub fn rememberBashRule(self: *Approvals, rule: []const u8) !void {
        if (self.hasBashRule(rule)) return;
        try self.bash_rules.append(self.gpa, try self.gpa.dupe(u8, rule));
        self.saveToDisk() catch {};
    }

    pub fn clear(self: *Approvals) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.clearRetainingCapacity();
        for (self.commands.items) |c| self.gpa.free(c);
        self.commands.clearRetainingCapacity();
        for (self.bash_rules.items) |r| self.gpa.free(r);
        self.bash_rules.clearRetainingCapacity();
        self.saveToDisk() catch {};
    }

    fn loadFromDisk(self: *Approvals) !void {
        const io = self.io orelse return;
        const path = self.disk_path orelse return;

        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(256 * 1024));
        defer self.gpa.free(data);

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const kind = line[0..sp];
            const value = std.mem.trim(u8, line[sp + 1 ..], " \t");
            if (value.len == 0) continue;

            // Use direct list append (no save-back) — we're loading.
            if (std.mem.eql(u8, kind, "write_path") or std.mem.eql(u8, kind, "edit_path")) {
                if (!self.hasPath(value)) try self.paths.append(self.gpa, try self.gpa.dupe(u8, value));
            } else if (std.mem.eql(u8, kind, "bash")) {
                if (!self.hasCommand(value)) try self.commands.append(self.gpa, try self.gpa.dupe(u8, value));
            } else if (std.mem.eql(u8, kind, "bash_rule")) {
                if (!self.hasBashRule(value)) try self.bash_rules.append(self.gpa, try self.gpa.dupe(u8, value));
            }
        }
    }

    /// Atomically rewrite the disk file to match the in-memory state.
    /// Writes to `<path>.tmp`, then renames. Best-effort — silently no-ops
    /// if no disk_path is attached.
    fn saveToDisk(self: *Approvals) !void {
        const io = self.io orelse return;
        const path = self.disk_path orelse return;

        // Ensure the parent directory exists (mkdir -p semantics).
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        try buf.appendSlice(self.gpa,
            \\# qai approvals — auto-generated, edit at your own risk.
            \\# Format: <kind> <value>; kind is write_path | edit_path | bash.
            \\
        );

        for (self.paths.items) |p| {
            try buf.print(self.gpa, "write_path {s}\n", .{p});
        }
        for (self.commands.items) |c| {
            try buf.print(self.gpa, "bash {s}\n", .{c});
        }
        for (self.bash_rules.items) |r| {
            try buf.print(self.gpa, "bash_rule {s}\n", .{r});
        }

        const tmp = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{path});
        defer self.gpa.free(tmp);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = buf.items });
        // POSIX rename is atomic — on success the new file replaces the old.
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(tmp, cwd, path, io);
    }
};

pub const RunArgs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    provider: cfg_mod.Provider,
    api_key: []const u8,
    base_url: []const u8,
    provider_name: []const u8,
    model: []const u8,
    max_tokens: u32,
    temperature: f32,
    /// Reasoning effort for OpenAI/Grok (ignored elsewhere). Parsed at the
    /// call site against hs.ai.common.ReasoningEffort.
    reasoning_effort: []const u8 = "low",
    system_prompt: ?[]const u8,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Used to read the y/a/N confirmation when a writable tool is about to run.
    /// May be null if no terminal is attached — in that case writable tools
    /// auto-deny unless `auto_approve` is true.
    stdin: ?*std.Io.Reader,
    /// Bypass confirmation prompts (`--yes`). Read-only tools never prompt;
    /// this flag only matters for writable tools.
    auto_approve: bool,
    /// Sessionwide approvals — populated by the user picking "always" at a
    /// previous prompt. Lifetime: spans the whole REPL session.
    approvals: *Approvals,
    /// Session-wide running totals. Each completed turn adds its tokens
    /// and cost so /usage and the auto-saved transcript footer can show
    /// where the bill went.
    usage: *UsageStats,
    user_prompt: []const u8,
};

pub const Error = error{
    ToolsNotSupported,
} || anyerror;

/// One bucket of usage attributed to a single provider+model. The session
/// keeps one entry per (provider, model) pair so the CSV log can show
/// where the bill went even when the user /provider-switched mid-session.
pub const ProviderUsage = struct {
    provider: []const u8,
    model: []const u8,
    turns: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cost_usd: f64 = 0.0,
};

/// Session-wide token + cost accumulator, broken down by (provider, model).
/// Read by /usage (aggregate) and the auto-save CSV writer (per-provider rows).
pub const UsageStats = struct {
    gpa: std.mem.Allocator,
    buckets: std.ArrayList(ProviderUsage) = .empty,

    pub fn init(gpa: std.mem.Allocator) UsageStats {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *UsageStats) void {
        for (self.buckets.items) |b| {
            self.gpa.free(b.provider);
            self.gpa.free(b.model);
        }
        self.buckets.deinit(self.gpa);
    }

    pub fn reset(self: *UsageStats) void {
        for (self.buckets.items) |b| {
            self.gpa.free(b.provider);
            self.gpa.free(b.model);
        }
        self.buckets.clearRetainingCapacity();
    }

    pub fn add(
        self: *UsageStats,
        provider: []const u8,
        model: []const u8,
        input: u32,
        output: u32,
        cost: f64,
    ) !void {
        for (self.buckets.items) |*b| {
            if (std.mem.eql(u8, b.provider, provider) and std.mem.eql(u8, b.model, model)) {
                b.turns += 1;
                b.input_tokens += input;
                b.output_tokens += output;
                b.cost_usd += cost;
                return;
            }
        }
        try self.buckets.append(self.gpa, .{
            .provider = try self.gpa.dupe(u8, provider),
            .model = try self.gpa.dupe(u8, model),
            .turns = 1,
            .input_tokens = input,
            .output_tokens = output,
            .cost_usd = cost,
        });
    }

    /// Aggregate across all buckets — used by /usage and the autosave footer.
    pub fn aggregate(self: *const UsageStats) ProviderUsage {
        var total: ProviderUsage = .{ .provider = "", .model = "" };
        for (self.buckets.items) |b| {
            total.turns += b.turns;
            total.input_tokens += b.input_tokens;
            total.output_tokens += b.output_tokens;
            total.cost_usd += b.cost_usd;
        }
        return total;
    }
};

const ToolBlock = struct {
    /// Content-block index from the API.
    index: u32,
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    /// Raw JSON arguments accumulated from input_delta events.
    /// May be empty (model elected to call with `{}`) — fall back to "{}".
    args: std.ArrayList(u8),

    fn init() ToolBlock {
        return .{
            .index = 0,
            .id = .empty,
            .name = .empty,
            .args = .empty,
        };
    }

    fn deinit(self: *ToolBlock, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.args.deinit(gpa);
    }
};

pub const TurnState = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// All assistant text accumulated this turn — printed live and stored
    /// alongside any tool_uses on the assistant history entry.
    text: std.ArrayList(u8) = .empty,
    /// One entry per tool_use content block, in arrival order.
    tools: std.ArrayList(ToolBlock) = .empty,
    /// Stop reason from message_delta or message_stop.
    stop_reason: std.ArrayList(u8) = .empty,
    /// Token usage reported on message_stop. 0 if the provider didn't
    /// surface usage on this turn.
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    /// True once message_stop has fired.
    done: bool = false,
    /// True if any tool_use opened in this turn (cheap shortcut).
    saw_tool_use: bool = false,

    pub fn deinit(self: *TurnState) void {
        self.text.deinit(self.gpa);
        for (self.tools.items) |*t| t.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        self.stop_reason.deinit(self.gpa);
    }

    fn currentToolByIndex(self: *TurnState, idx: u32) ?*ToolBlock {
        for (self.tools.items) |*t| {
            if (t.index == idx) return t;
        }
        return null;
    }
};

pub fn streamEventCb(event: hs.ai.common.StreamEvent, ctx_ptr: ?*anyopaque) bool {
    const s: *TurnState = @alignCast(@ptrCast(ctx_ptr orelse return false));

    switch (event) {
        .text_delta => |td| {
            s.text.appendSlice(s.gpa, td.text) catch return false;
            s.out.writeAll(td.text) catch return false;
            s.out.flush() catch return false;
        },
        .tool_use_start => |t| {
            if (s.tools.items.len >= MAX_TOOL_BLOCKS) return true;
            s.saw_tool_use = true;
            var tb = ToolBlock.init();
            tb.index = t.index;
            tb.id.appendSlice(s.gpa, t.id) catch {
                tb.deinit(s.gpa);
                return false;
            };
            tb.name.appendSlice(s.gpa, t.name) catch {
                tb.deinit(s.gpa);
                return false;
            };
            s.tools.append(s.gpa, tb) catch {
                tb.deinit(s.gpa);
                return false;
            };
            // Visual cue that the model is about to invoke a tool. Args
            // arrive on the next deltas; we surface them on block_stop.
            s.err.print("\n[tool] {s} ", .{t.name}) catch return false;
            s.err.flush() catch return false;
        },
        .tool_input_delta => |d| {
            const tb = s.currentToolByIndex(d.index) orelse return true;
            tb.args.appendSlice(s.gpa, d.partial_json) catch return false;
        },
        .block_stop => |b| {
            // For tool_use blocks, surface the now-complete JSON args.
            if (s.currentToolByIndex(b.index)) |tb| {
                const args = if (tb.args.items.len == 0) "{}" else tb.args.items;
                s.err.print("{s}\n", .{args}) catch return false;
                s.err.flush() catch return false;
            }
        },
        .message_stop => |m| {
            if (m.stop_reason) |sr| {
                s.stop_reason.appendSlice(s.gpa, sr) catch return false;
            }
            // Take the larger of the running counter and the new value —
            // some providers fire message_stop twice (e.g. Anthropic emits
            // both message_delta with usage and a separate message_stop).
            if (m.input_tokens > s.input_tokens) s.input_tokens = m.input_tokens;
            if (m.output_tokens > s.output_tokens) s.output_tokens = m.output_tokens;
            s.done = true;
        },
    }
    return true;
}

pub fn run(args: RunArgs) !void {
    return switch (args.provider) {
        .anthropic, .deepseek => runAnthropicStream(args),
        .openai => runResponsesApiStream(args, .openai),
        .grok => runResponsesApiStream(args, .grok),
        .gemini => runGeminiStream(args),
    };
}

fn buildToolDefs() [tools.all_tools.len]hs.ai.common.ToolDefinition {
    var tool_defs: [tools.all_tools.len]hs.ai.common.ToolDefinition = undefined;
    for (tools.all_tools, 0..) |t, i| {
        tool_defs[i] = .{
            .name = t.name,
            .description = t.description,
            .input_schema = t.input_schema,
        };
    }
    return tool_defs;
}

fn runAnthropicStream(args: RunArgs) !void {
    var client = try hs.ai.AnthropicClient.init(args.gpa, .{
        .api_key = args.api_key,
        .base_url = args.base_url,
        .provider_name = args.provider_name,
    });
    defer client.deinit();

    var tool_defs = buildToolDefs();

    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = args.model,
        .max_tokens = args.max_tokens,
        .temperature = args.temperature,
        .system_prompt = args.system_prompt orelse DEFAULT_AGENT_SYSTEM_PROMPT,
        .tools = &tool_defs,
        .stream = true,
    };

    // First turn: send user_prompt; subsequent turns send empty prompt
    // because the user turn lives in history.
    var pending_prompt: []const u8 = args.user_prompt;
    var first_turn = true;

    var turn: u32 = 0;
    while (turn < MAX_AGENT_TURNS) : (turn += 1) {
        var state = TurnState{
            .gpa = args.gpa,
            .out = args.out,
            .err = args.err,
        };
        defer state.deinit();

        client.sendMessageStreamingWithEvents(
            pending_prompt,
            args.history.items,
            req_cfg,
            streamEventCb,
            &state,
        ) catch |e| {
            try surfaceApiError(args.err, &client.http_client, e);
            return e;
        };

        // Persist the user turn the moment we have its first stream back —
        // safer than tracking "did any data arrive" ourselves.
        if (first_turn) {
            try appendUser(args.gpa, args.io, args.history, args.user_prompt);
            first_turn = false;
        }
        pending_prompt = "";

        // End each turn's printed text with a newline so the next prompt
        // or [tool] line lands on a clean column.
        if (state.text.items.len > 0 and state.text.items[state.text.items.len - 1] != '\n') {
            try args.out.writeAll("\n");
            try args.out.flush();
        }

        try printTurnUsage(args, &state, turn);

        // Build the assistant history entry. Tool calls (if any) are moved
        // into the entry; text is duplicated since state.text owns it.
        const text_owned = try args.gpa.dupe(u8, state.text.items);
        var assistant_calls: ?[]hs.ai.common.ToolCall = null;
        if (state.saw_tool_use and state.tools.items.len > 0) {
            const calls = try args.gpa.alloc(hs.ai.common.ToolCall, state.tools.items.len);
            errdefer args.gpa.free(calls);
            for (state.tools.items, 0..) |*tb, i| {
                const args_json = if (tb.args.items.len == 0) "{}" else tb.args.items;
                calls[i] = .{
                    .id = try args.gpa.dupe(u8, tb.id.items),
                    .name = try args.gpa.dupe(u8, tb.name.items),
                    .arguments = try args.gpa.dupe(u8, args_json),
                    .allocator = args.gpa,
                };
            }
            assistant_calls = calls;
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .assistant,
            .content = text_owned,
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_calls = assistant_calls,
            .allocator = args.gpa,
        });

        if (assistant_calls == null) return; // nothing to execute — turn is the final answer.

        // Execute every tool call from this turn, then feed all results
        // back as one user turn.
        const calls = args.history.items[args.history.items.len - 1].tool_calls.?;
        var results = try args.gpa.alloc(hs.ai.common.ToolResult, calls.len);

        for (calls, 0..) |call, i| {
            const out_text = try executeToolWithConfirm(args, call);
            results[i] = .{
                .tool_call_id = try args.gpa.dupe(u8, call.id),
                .content = out_text,
                .allocator = args.gpa,
            };
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .user,
            .content = try args.gpa.dupe(u8, ""),
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_results = results,
            .allocator = args.gpa,
        });

        // Loop — model needs the tool results to continue.
    }

    try args.err.print("[agent] reached MAX_AGENT_TURNS ({d}) — stopping\n", .{MAX_AGENT_TURNS});
    try args.err.flush();
}

/// Run one tool call, gating writable tools behind a confirmation prompt
/// or a session-wide approval. Always returns an owned string suitable as
/// a tool_result content.
fn executeToolWithConfirm(args: RunArgs, call: hs.ai.common.ToolCall) ![]u8 {
    const spec_opt = tools.specByName(call.name);
    const writable = if (spec_opt) |s| s.is_writable else false;

    if (writable) {
        if (args.auto_approve) {
            try args.err.print("[auto-approve] {s} {s}\n", .{ call.name, call.arguments });
            try args.err.flush();
        } else if (preApproved(args.approvals, call)) {
            try args.err.print("[approved] {s} {s}\n", .{ call.name, call.arguments });
            try args.err.flush();
        } else {
            const decision = try promptConfirm(args, call);
            switch (decision) {
                .deny => return std.fmt.allocPrint(
                    args.gpa,
                    "error: user declined to run {s}. Tell the user why you wanted to run it; do not retry.",
                    .{call.name},
                ),
                .once => {},
                .always => try recordApproval(args.approvals, call),
                .always_rule => try recordRuleApproval(args.approvals, call),
            }
        }
    }

    return tools.execute(args.io, args.gpa, call.name, call.arguments) catch |e| blk: {
        break :blk try std.fmt.allocPrint(args.gpa, "error: tool failed: {s}", .{@errorName(e)});
    };
}

const Decision = enum { once, always, always_rule, deny };

/// Check whether this exact tool invocation has already been approved with
/// "always" earlier in the session.
fn preApproved(approvals: *Approvals, call: hs.ai.common.ToolCall) bool {
    if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
        const path = extractStringArg(call.arguments, "path") orelse return false;
        return approvals.hasPath(path);
    } else if (std.mem.eql(u8, call.name, "bash")) {
        const cmd = extractStringArg(call.arguments, "command") orelse return false;
        return approvals.hasCommand(cmd);
    }
    return false;
}

fn recordApproval(approvals: *Approvals, call: hs.ai.common.ToolCall) !void {
    if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) {
        if (extractStringArg(call.arguments, "path")) |p| try approvals.rememberPath(p);
    } else if (std.mem.eql(u8, call.name, "bash")) {
        if (extractStringArg(call.arguments, "command")) |c| try approvals.rememberCommand(c);
    }
}

/// Record a coarser approval — only meaningful for bash. Adds the first
/// whole token of the command as a rule, e.g. "git status -s" → rule "git".
fn recordRuleApproval(approvals: *Approvals, call: hs.ai.common.ToolCall) !void {
    if (!std.mem.eql(u8, call.name, "bash")) return; // only bash has rules
    const cmd = extractStringArg(call.arguments, "command") orelse return;
    const rule = firstToken(cmd);
    if (rule.len == 0) return;
    try approvals.rememberBashRule(rule);
}

/// First whitespace-separated token. "git status -s" → "git".
fn firstToken(s: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    const sp = std.mem.indexOfAny(u8, trimmed, " \t") orelse return trimmed;
    return trimmed[0..sp];
}

/// Cheap one-shot extraction from a JSON object. The parsed tree is freed
/// before return, so we re-locate the value's verbatim bytes inside the
/// caller's `arguments` buffer to return a slice with stable lifetime.
/// Works as long as the JSON string didn't require unescaping; for our keys
/// (paths, commands) that's true in practice.
fn extractStringArg(arguments: []const u8, key: []const u8) ?[]const u8 {
    var arena_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), arguments, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(key) orelse return null;
    if (v != .string) return null;
    const needle = v.string;
    const start = std.mem.indexOf(u8, arguments, needle) orelse return null;
    return arguments[start .. start + needle.len];
}

/// Print a per-tool-kind preview to stderr and read y/a/r/N from stdin.
/// `r` is bash-only and approves the first whole token as a prefix rule.
/// Default-deny on EOF or unrecognised input.
fn promptConfirm(args: RunArgs, call: hs.ai.common.ToolCall) !Decision {
    try args.err.writeAll("\n");
    try printToolPreview(args, call);

    if (args.stdin == null) {
        try args.err.writeAll("[auto-deny] no stdin attached — pass --yes to bypass.\n");
        try args.err.flush();
        return .deny;
    }
    const stdin = args.stdin.?;

    const is_bash = std.mem.eql(u8, call.name, "bash");
    if (is_bash) {
        // Show the rule that 'r' would install so the user can pick consciously.
        const rule = if (extractStringArg(call.arguments, "command")) |cmd| firstToken(cmd) else "";
        try args.err.print(
            "Proceed? [y]es / [a]lways exact / [r]ule \"{s} *\" / [N]o: ",
            .{if (rule.len > 0) rule else "?"},
        );
    } else {
        try args.err.writeAll("Proceed? [y]es / [a]lways for this session / [N]o: ");
    }
    try args.err.flush();

    const raw = stdin.takeDelimiter('\n') catch |e| switch (e) {
        error.ReadFailed, error.StreamTooLong => return .deny,
    } orelse return .deny;
    const ans = std.mem.trim(u8, raw, " \t\r\n");
    if (is_bash and (std.ascii.eqlIgnoreCase(ans, "r") or std.ascii.eqlIgnoreCase(ans, "rule"))) return .always_rule;
    if (std.ascii.eqlIgnoreCase(ans, "a") or std.ascii.eqlIgnoreCase(ans, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes")) return .once;
    return .deny;
}

/// Render a human-friendly preview of a tool call. Each writable tool gets
/// a kind-specific summary so the user understands what's about to happen.
fn printToolPreview(args: RunArgs, call: hs.ai.common.ToolCall) !void {
    if (std.mem.eql(u8, call.name, "write_file")) {
        try previewWriteFile(args, call.arguments);
    } else if (std.mem.eql(u8, call.name, "edit_file")) {
        try previewEditFile(args, call.arguments);
    } else if (std.mem.eql(u8, call.name, "bash")) {
        try previewBash(args, call.arguments);
    } else {
        try args.err.print("[tool] {s} {s}\n", .{ call.name, call.arguments });
    }
    try args.err.flush();
}

fn previewWriteFile(args: RunArgs, arguments: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, args.gpa, arguments, .{}) catch {
        try args.err.print("[write_file] (unparseable args) {s}\n", .{arguments});
        return;
    };
    defer parsed.deinit();
    const path = jsonString(parsed.value, "path") orelse "?";
    const content = jsonString(parsed.value, "content") orelse "";

    try args.err.print("[write_file] {s} ({d} bytes)\n", .{ path, content.len });
    const head = if (content.len > 480) content[0..480] else content;
    try args.err.writeAll("--- preview ---\n");
    try args.err.writeAll(head);
    if (content.len > head.len) try args.err.print("\n[…+{d} bytes elided]\n", .{content.len - head.len}) else if (head.len > 0 and head[head.len - 1] != '\n') try args.err.writeAll("\n");
    try args.err.writeAll("---\n");
}

fn previewEditFile(args: RunArgs, arguments: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, args.gpa, arguments, .{}) catch {
        try args.err.print("[edit_file] (unparseable args) {s}\n", .{arguments});
        return;
    };
    defer parsed.deinit();
    const path = jsonString(parsed.value, "path") orelse "?";
    const old_s = jsonString(parsed.value, "old_string") orelse "";
    const new_s = jsonString(parsed.value, "new_string") orelse "";

    try args.err.print("[edit_file] {s}\n", .{path});
    try args.err.writeAll("--- removing ---\n");
    try previewSnippet(args, old_s);
    try args.err.writeAll("--- adding ---\n");
    try previewSnippet(args, new_s);
    try args.err.writeAll("---\n");
}

fn previewBash(args: RunArgs, arguments: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, args.gpa, arguments, .{}) catch {
        try args.err.print("[bash] (unparseable args) {s}\n", .{arguments});
        return;
    };
    defer parsed.deinit();
    const cmd = jsonString(parsed.value, "command") orelse "";

    // Resolve cwd via Io and surface it so the user knows where the side
    // effect will happen — especially relevant when running qai across repos.
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_n = std.process.currentPath(args.io, &cwd_buf) catch null;
    if (cwd_n) |n| {
        try args.err.print("[bash] $ {s}    (cwd: {s})\n", .{ cmd, cwd_buf[0..n] });
    } else {
        try args.err.print("[bash] $ {s}\n", .{cmd});
    }

    if (dangerReason(cmd)) |reason| {
        try args.err.print("[!DANGER] {s}\n", .{reason});
    }
}

/// Pattern-match common foot-guns. Returns a short reason string the user
/// can read before approving. Substring-based — false positives are fine
/// (they make the user pause), false negatives are not — so when in doubt,
/// flag.
fn dangerReason(cmd: []const u8) ?[]const u8 {
    if (containsAnyOf(cmd, &.{ "rm -rf", "rm -fr", "rm --recursive --force", "rm --force --recursive" })) return "recursive force-delete";
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, cmd, " \t"), "sudo ")) return "sudo escalation";
    if (containsAnyOf(cmd, &.{ "| sh", "| bash", "|sh", "|bash" })) return "pipe-to-shell — script execution from another command";
    if (containsAnyOf(cmd, &.{ "git push --force", "git push -f", "git push --force-with-lease" })) return "force-push — overwrites remote history";
    if (containsAnyOf(cmd, &.{ "git reset --hard", "git clean -fd", "git clean -fx" })) return "destructive git operation";
    if (containsAnyOf(cmd, &.{ "chmod -R", "chmod 777", "chown -R" })) return "broad permission change";
    if (containsAnyOf(cmd, &.{ "dd if=", "mkfs", "/dev/sda", "/dev/disk", "/dev/nvme" })) return "raw block-device operation";
    if (containsAnyOf(cmd, &.{ "kill -9 ", "killall ", "pkill " })) return "killing processes";
    if (containsAnyOf(cmd, &.{ ":(){:|:&};:", "fork bomb" })) return "fork bomb";
    return null;
}

fn containsAnyOf(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, haystack, n) != null) return true;
    return false;
}

test "dangerReason flags common foot-guns" {
    try std.testing.expect(dangerReason("rm -rf /tmp/foo") != null);
    try std.testing.expect(dangerReason("rm -fr ~/Downloads") != null);
    try std.testing.expect(dangerReason("sudo apt update") != null);
    try std.testing.expect(dangerReason("curl https://x | sh") != null);
    try std.testing.expect(dangerReason("git push --force origin main") != null);
    try std.testing.expect(dangerReason("git reset --hard HEAD~1") != null);
    try std.testing.expect(dangerReason("chmod -R 777 .") != null);
    try std.testing.expect(dangerReason("dd if=/dev/zero of=/dev/sda") != null);
    try std.testing.expect(dangerReason("kill -9 1234") != null);

    // safe commands
    try std.testing.expect(dangerReason("git status") == null);
    try std.testing.expect(dangerReason("ls -la") == null);
    try std.testing.expect(dangerReason("zig build") == null);
    try std.testing.expect(dangerReason("cargo test") == null);
}

test "firstToken extracts whole-token prefix" {
    try std.testing.expectEqualStrings("git", firstToken("git status -s"));
    try std.testing.expectEqualStrings("npm", firstToken("npm test"));
    try std.testing.expectEqualStrings("ls", firstToken("ls"));
    try std.testing.expectEqualStrings("cargo", firstToken("  cargo build --release"));
    try std.testing.expectEqualStrings("", firstToken(""));
}

fn previewSnippet(args: RunArgs, s: []const u8) !void {
    const cap: usize = 320;
    const slice = if (s.len > cap) s[0..cap] else s;
    try args.err.writeAll(slice);
    if (s.len > slice.len) try args.err.print("\n[…+{d} bytes elided]\n", .{s.len - slice.len}) else if (slice.len > 0 and slice[slice.len - 1] != '\n') try args.err.writeAll("\n");
}

fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    if (child != .string) return null;
    return child.string;
}

fn printTurnUsage(args: RunArgs, state: *const TurnState, turn: u32) !void {
    try emitUsage(
        args.gpa,
        args.err,
        args.provider_name,
        args.model,
        state.input_tokens,
        state.output_tokens,
        turn,
        args.usage,
    );
}

/// Print "[turn N: in/out · $cost]" to err and accumulate into the session
/// totals (bucketed by provider+model). Caller is anyone that owns a
/// TurnState — both agent.zig and plain-chat in main.zig.
pub fn emitUsage(
    gpa: std.mem.Allocator,
    err_writer: *std.Io.Writer,
    provider: []const u8,
    model: []const u8,
    input_tokens: u32,
    output_tokens: u32,
    turn: u32,
    usage_total: *UsageStats,
) !void {
    if (input_tokens == 0 and output_tokens == 0) return;
    if (pricing.lookup(gpa, model)) |p| {
        const cost = pricing.estimate(p, input_tokens, output_tokens);
        try usage_total.add(provider, model, input_tokens, output_tokens, cost);
        try err_writer.print(
            "[turn {d}: {d} in / {d} out · ${d:.4}]\n",
            .{ turn + 1, input_tokens, output_tokens, cost },
        );
    } else {
        try usage_total.add(provider, model, input_tokens, output_tokens, 0.0);
        try err_writer.print(
            "[turn {d}: {d} in / {d} out]\n",
            .{ turn + 1, input_tokens, output_tokens },
        );
    }
    try err_writer.flush();
}

/// Print the captured upstream error body (if any) to stderr so the user
/// sees the real reason behind a failed streaming call. Pure side-effect
/// helper — does not consume or rethrow the error.
pub fn surfaceApiError(err_writer: *std.Io.Writer, http_client: *hs.HttpClient, e: anyerror) !void {
    if (http_client.last_sse_error_body) |body| {
        try err_writer.print("\n[api error: {s}]\n{s}\n", .{ @errorName(e), body });
    } else {
        try err_writer.print("\n[api error: {s}] (no body captured)\n", .{@errorName(e)});
    }
    try err_writer.flush();
}

fn appendUser(
    gpa: std.mem.Allocator,
    io: std.Io,
    history: *std.ArrayList(hs.ai.common.AIMessage),
    content: []const u8,
) !void {
    try history.append(gpa, .{
        .id = try std.fmt.allocPrint(gpa, "msg-{d}", .{history.items.len}),
        .role = .user,
        .content = try gpa.dupe(u8, content),
        .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
        .allocator = gpa,
    });
}

/// Gemini streaming agent loop. Mirrors runResponsesApiStream — same
/// TurnState/streamEventCb plumbing — but uses GeminiClient and Gemini's
/// :streamGenerateContent SSE shape.
fn runGeminiStream(args: RunArgs) !void {
    var tool_defs = buildToolDefs();

    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = args.model,
        .max_tokens = args.max_tokens,
        .temperature = args.temperature,
        .system_prompt = args.system_prompt orelse DEFAULT_AGENT_SYSTEM_PROMPT,
        .tools = &tool_defs,
        .stream = true,
    };

    var pending_prompt: []const u8 = args.user_prompt;
    var first_turn = true;

    var turn: u32 = 0;
    while (turn < MAX_AGENT_TURNS) : (turn += 1) {
        var state = TurnState{
            .gpa = args.gpa,
            .out = args.out,
            .err = args.err,
        };
        defer state.deinit();

        var client = try hs.ai.GeminiClient.initWithConfig(args.gpa, .{
            .api_key = args.api_key,
            .base_url = args.base_url,
        });
        defer client.deinit();
        client.sendMessageStreamingWithEvents(
            pending_prompt,
            args.history.items,
            req_cfg,
            streamEventCb,
            &state,
        ) catch |e| {
            try surfaceApiError(args.err, &client.http_client, e);
            return e;
        };

        if (first_turn) {
            try appendUser(args.gpa, args.io, args.history, args.user_prompt);
            first_turn = false;
        }
        pending_prompt = "";

        if (state.text.items.len > 0 and state.text.items[state.text.items.len - 1] != '\n') {
            try args.out.writeAll("\n");
            try args.out.flush();
        }

        try printTurnUsage(args, &state, turn);

        const text_owned = try args.gpa.dupe(u8, state.text.items);
        var assistant_calls: ?[]hs.ai.common.ToolCall = null;
        if (state.saw_tool_use and state.tools.items.len > 0) {
            const calls = try args.gpa.alloc(hs.ai.common.ToolCall, state.tools.items.len);
            errdefer args.gpa.free(calls);
            for (state.tools.items, 0..) |*tb, i| {
                const args_json = if (tb.args.items.len == 0) "{}" else tb.args.items;
                calls[i] = .{
                    .id = try args.gpa.dupe(u8, tb.id.items),
                    .name = try args.gpa.dupe(u8, tb.name.items),
                    .arguments = try args.gpa.dupe(u8, args_json),
                    .allocator = args.gpa,
                };
            }
            assistant_calls = calls;
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .assistant,
            .content = text_owned,
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_calls = assistant_calls,
            .allocator = args.gpa,
        });

        if (assistant_calls == null) return;

        const calls = args.history.items[args.history.items.len - 1].tool_calls.?;
        var results = try args.gpa.alloc(hs.ai.common.ToolResult, calls.len);
        for (calls, 0..) |call, i| {
            const out_text = try executeToolWithConfirm(args, call);
            results[i] = .{
                .tool_call_id = try args.gpa.dupe(u8, call.id),
                .content = out_text,
                // Gemini wants the function name (not the synthetic id) when
                // sending back tool_results.
                .tool_name = try args.gpa.dupe(u8, call.name),
                .allocator = args.gpa,
            };
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .user,
            .content = try args.gpa.dupe(u8, ""),
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_results = results,
            .allocator = args.gpa,
        });
    }

    try args.err.print("[agent] reached MAX_AGENT_TURNS ({d}) — stopping\n", .{MAX_AGENT_TURNS});
    try args.err.flush();
}

const ResponsesApiProvider = enum { openai, grok };

/// Streaming agent loop for the OpenAI / xAI Responses API. Uses the same
/// unified `StreamEventCallback` / `TurnState` plumbing as the Anthropic
/// path — only the per-turn HTTP call (and its event-shape translation,
/// which lives in the provider client) differs.
fn runResponsesApiStream(args: RunArgs, provider: ResponsesApiProvider) !void {
    var tool_defs = buildToolDefs();

    // GPT-5.4 and gpt-5-mini reject `effort=none` (only gpt-5.2 accepts it),
    // and Grok ignores the field. Caller controls via cfg.reasoning_effort.
    const effort = std.meta.stringToEnum(hs.ai.common.ReasoningEffort, args.reasoning_effort) orelse .low;
    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = args.model,
        .max_tokens = args.max_tokens,
        .temperature = args.temperature,
        .system_prompt = args.system_prompt orelse DEFAULT_AGENT_SYSTEM_PROMPT,
        .tools = &tool_defs,
        .reasoning_effort = effort,
        .stream = true,
    };

    var pending_prompt: []const u8 = args.user_prompt;
    var first_turn = true;

    var turn: u32 = 0;
    while (turn < MAX_AGENT_TURNS) : (turn += 1) {
        var state = TurnState{
            .gpa = args.gpa,
            .out = args.out,
            .err = args.err,
        };
        defer state.deinit();

        switch (provider) {
            .openai => {
                var client = try hs.ai.OpenAIClient.initWithConfig(args.gpa, .{
                    .api_key = args.api_key,
                    .base_url = args.base_url,
                });
                defer client.deinit();
                client.sendMessageStreamingWithEvents(
                    pending_prompt,
                    args.history.items,
                    req_cfg,
                    streamEventCb,
                    &state,
                ) catch |e| {
                    try surfaceApiError(args.err, &client.http_client, e);
                    return e;
                };
            },
            .grok => {
                var client = try hs.ai.GrokClient.initWithConfig(args.gpa, .{
                    .api_key = args.api_key,
                    .base_url = args.base_url,
                });
                defer client.deinit();
                client.sendMessageStreamingWithEvents(
                    pending_prompt,
                    args.history.items,
                    req_cfg,
                    streamEventCb,
                    &state,
                ) catch |e| {
                    try surfaceApiError(args.err, &client.http_client, e);
                    return e;
                };
            },
        }

        if (first_turn) {
            try appendUser(args.gpa, args.io, args.history, args.user_prompt);
            first_turn = false;
        }
        pending_prompt = "";

        if (state.text.items.len > 0 and state.text.items[state.text.items.len - 1] != '\n') {
            try args.out.writeAll("\n");
            try args.out.flush();
        }

        try printTurnUsage(args, &state, turn);

        const text_owned = try args.gpa.dupe(u8, state.text.items);
        var assistant_calls: ?[]hs.ai.common.ToolCall = null;
        if (state.saw_tool_use and state.tools.items.len > 0) {
            const calls = try args.gpa.alloc(hs.ai.common.ToolCall, state.tools.items.len);
            errdefer args.gpa.free(calls);
            for (state.tools.items, 0..) |*tb, i| {
                const args_json = if (tb.args.items.len == 0) "{}" else tb.args.items;
                calls[i] = .{
                    .id = try args.gpa.dupe(u8, tb.id.items),
                    .name = try args.gpa.dupe(u8, tb.name.items),
                    .arguments = try args.gpa.dupe(u8, args_json),
                    .allocator = args.gpa,
                };
            }
            assistant_calls = calls;
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .assistant,
            .content = text_owned,
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_calls = assistant_calls,
            .allocator = args.gpa,
        });

        if (assistant_calls == null) return;

        const calls = args.history.items[args.history.items.len - 1].tool_calls.?;
        var results = try args.gpa.alloc(hs.ai.common.ToolResult, calls.len);
        for (calls, 0..) |call, i| {
            const out_text = try executeToolWithConfirm(args, call);
            results[i] = .{
                .tool_call_id = try args.gpa.dupe(u8, call.id),
                .content = out_text,
                .allocator = args.gpa,
            };
        }

        try args.history.append(args.gpa, .{
            .id = try std.fmt.allocPrint(args.gpa, "msg-{d}", .{args.history.items.len}),
            .role = .user,
            .content = try args.gpa.dupe(u8, ""),
            .timestamp = std.Io.Timestamp.now(args.io, .real).toSeconds(),
            .tool_results = results,
            .allocator = args.gpa,
        });
    }

    try args.err.print("[agent] reached MAX_AGENT_TURNS ({d}) — stopping\n", .{MAX_AGENT_TURNS});
    try args.err.flush();
}
