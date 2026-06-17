const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const c = std.c;
const canonical = @import("canonical"); // RFC 8785 encoder (chronos-ledger)
const emit_client = @import("chronos_emit"); // non-blocking UDS writer (chronos-ledger)

const CHRONOS_STAMP_PATH = "/usr/local/bin/chronos-stamp";
const GET_COGNITIVE_STATE_PATH = "/usr/local/bin/get-cognitive-state";
const AGENT_ID = "claude-code";
const LEDGER_SOCKET_DEFAULT = "/tmp/chronos-ledger.sock";

// std.c exposes neither fork nor execvp in this Zig build — declare them.
// (execvp does PATH resolution, which execve would not.)
extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getppid() std.c.pid_t;

// Agent identity is resolved at RUNTIME, never from config — because Grok reads
// its hooks from ~/.claude (shares Claude's settings.json), so the same hook
// command fires for both. Config can't tell them apart; the kernel can. We climb
// the process tree and match the executing agent binary. `CHRONOS_AGENT` overrides.
const AgentPattern = struct { needle: []const u8, name: []const u8 };
const AGENT_PATTERNS = [_]AgentPattern{
    .{ .needle = "grok", .name = "grok" },
    .{ .needle = "codex", .name = "codex" },
    .{ .needle = "gemini", .name = "gemini" },
    .{ .needle = "antigravity", .name = "gemini" },
    .{ .needle = "claude", .name = "claude" },
};

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    // Check if we're in a git repository
    if (!try isGitRepository(allocator)) {
        return 0;
    }

    // Per-repo opt-in gate. We do NOT auto-commit a tick in every git repo on
    // the machine — that would turn normal work in unrelated repos into a flood
    // of [CHRONOS] commits. A repo opts in with:
    //     git config chronos.enabled true
    // (the chronos-enable-repo installer does this and also drops the
    // post-commit squash hook). An env override is honored for one-offs.
    if (!try chronosEnabled(allocator)) {
        return 0;
    }

    // .gitignore-first safety rule. If a repo's root has no .gitignore, refuse to
    // auto-stage: the very first `git add .` would otherwise sweep build bloat
    // (zig-cache/, .DS_Store, DerivedData, node_modules/, …) permanently into the
    // packfiles. Warn loudly so the agent writes a .gitignore before proceeding.
    const repo_root = try gitOutput(allocator, &[_][]const u8{ "git", "rev-parse", "--show-toplevel" });
    defer if (repo_root) |r| allocator.free(r);
    if (repo_root) |root| {
        if (!gitignoreExists(root)) {
            const msg = "[CHRONOS ERROR] Missing .gitignore file in repository root! " ++
                "Please create a .gitignore before executing further tools to prevent tracking bloat.\n";
            _ = c.write(2, msg.ptr, msg.len);
            return 2;
        }
    }

    // Self-bootstrap the squash. Global ticking (git config --global
    // chronos.enabled true) must come WITH global squashing, or non-enabled
    // repos would silently accumulate un-squashed [CHRONOS] commits. Ensure this
    // repo has the post-commit shim before we start laying down ticks.
    ensureSquashShim(allocator) catch {};

    // The PostToolUse payload arrives as JSON on STDIN. Current Claude Code does
    // NOT set CLAUDE_TOOL_INPUT / CLAUDE_PID / CLAUDE_TOOL_NAME env vars — the old
    // env-based reads silently produced empty descriptions. Read stdin and pull
    // tool_name + tool_input.description. (STDIN is always closed -> no hang.)
    const hook_json = readAllStdin(allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(hook_json);

    // Field extraction is provider-agnostic: Claude/Grok use snake_case
    // (tool_name, file_path, description), Codex's shell payload uses `command`,
    // and other CLIs may use camelCase. Try each spelling, first hit wins.
    const tool_name = try extractAny(allocator, hook_json, &.{ "\"tool_name\"", "\"toolName\"" });
    defer if (tool_name) |t| allocator.free(t);

    // Tick description: a VERBOSE action so the squash log preserves intent —
    // "<tool> <file_path>" for file tools (Edit/Write/Read/NotebookEdit/...),
    // "<tool> <description|command>" for Bash/shell, else just the tool name.
    // file_path takes priority (an Edit has no description; a Bash has no
    // file_path), so each captures its most informative detail.
    const file_path = try extractAny(allocator, hook_json, &.{ "\"file_path\"", "\"filePath\"", "\"path\"", "\"absolute_path\"" });
    defer if (file_path) |f| allocator.free(f);
    const desc_field = try extractAny(allocator, hook_json, &.{ "\"description\"", "\"command\"", "\"cmd\"" });
    defer if (desc_field) |d| allocator.free(d);

    // Cap the detail: Codex's `apply_patch` puts the WHOLE patch in
    // tool_input.command, which would otherwise bloat the one-line commit subject.
    var tool_description: ?[]const u8 = null;
    if (tool_name) |verb| {
        if (file_path orelse desc_field) |detail| {
            tool_description = try std.fmt.allocPrint(allocator, "{s} {s}", .{ verb, capDetail(detail, 200) });
        } else {
            tool_description = try allocator.dupe(u8, verb);
        }
    } else if (desc_field) |d| {
        tool_description = try allocator.dupe(u8, capDetail(d, 200));
    }
    defer if (tool_description) |desc| allocator.free(desc);

    // Cognitive state: the live gerund from a PTY tap (get-cognitive-state reads
    // /tmp/cognitive-state-<pid>), else fall back to the just-fired tool's activity
    // (Editing / Executing / Reading / ...) instead of NOT-DETECTED.
    const cognitive_state = try getCognitiveState(allocator, tool_name);
    defer allocator.free(cognitive_state);

    // Which agent is running this hook (kernel ground truth — see resolveAgent),
    // and the firing process's pid/ppid (the GS-correlation join key).
    const agent_info = try resolveAgent(allocator);
    defer allocator.free(agent_info.name);
    const agent = agent_info.name;

    // Generate CHRONOS timestamp (agent → the `::<agent>::` body segment).
    const chronos_output = try generateChronosTimestamp(allocator, agent);
    defer allocator.free(chronos_output);

    // Stamp the agent into the tick PREFIX: [CHRONOS] -> [CHRONOS:<agent>]. The
    // fold/squash (chronos-push) matches ^\[CHRONOS(:…)?\], so per-agent ticks
    // still squash cleanly, and the aiconductor app attributes each tick to its
    // provider by this prefix.
    const TICK_PREFIX = "[CHRONOS]";
    const stamped: []const u8 = if (std.mem.startsWith(u8, chronos_output, TICK_PREFIX))
        try std.fmt.allocPrint(allocator, "[CHRONOS:{s}]{s}", .{ agent, chronos_output[TICK_PREFIX.len..] })
    else
        try allocator.dupe(u8, chronos_output);
    defer allocator.free(stamped);

    // Build commit message
    var commit_msg = std.ArrayList(u8).empty;
    defer commit_msg.deinit(allocator);

    // Inject cognitive state into CHRONOS output
    // Replace "::::TICK" with "::<state>::TICK"
    if (std.mem.indexOf(u8, stamped, "::::TICK")) |pos| {
        try commit_msg.appendSlice(allocator, stamped[0..pos]);
        try commit_msg.appendSlice(allocator, "::");
        try commit_msg.appendSlice(allocator, cognitive_state);
        try commit_msg.appendSlice(allocator, "::");
        try commit_msg.appendSlice(allocator, stamped[pos + 4 ..]);
    } else {
        try commit_msg.appendSlice(allocator, stamped);
    }

    // Append tool description if available
    if (tool_description) |desc| {
        try commit_msg.appendSlice(allocator, " - ");
        try commit_msg.appendSlice(allocator, desc);
    }

    // Restore the firing process's PID into the tick (the Linux ticks carried
    // `PID-<n>`; the macOS port dropped it). Lets the squash / aiconductor attribute
    // a tick to a specific process; the ledger below carries the same pid.
    const pid_tag = try std.fmt.allocPrint(allocator, " PID-{d}", .{agent_info.pid});
    defer allocator.free(pid_tag);
    try commit_msg.appendSlice(allocator, pid_tag);

    // Plane 2 (accountability ledger): emit a structured event for EVERY tool
    // call — including reads/searches that change no files and so create no git
    // tick — to the privileged sink (ledger-daemon / Guardian Shield). This is
    // exactly the data that catches an exfil chain (read → search → send), most
    // of which leaves no git diff. Best-effort and non-blocking: any failure is
    // swallowed so it can never affect ticking. The hook holds NO signing key;
    // the sink chains and signs (see ../chronos-ledger/DESIGN.md, Addition 1).
    emitLedgerEvent(allocator, hook_json, repo_root, agent, agent_info.pid, agent_info.ppid, tool_name, file_path, desc_field, cognitive_state) catch {};

    // Stage all changes
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });

    // Check if there are changes to commit
    const diff_result = try runCommand(allocator, &[_][]const u8{ "git", "diff", "--cached", "--quiet" });
    if (diff_result.exit_code == 0) {
        // No changes to commit
        return 0;
    }

    // Commit with message. --no-verify keeps ticks fast and unobtrusive: a tick
    // fires after every tool call, so it must not run the repo's own pre-commit
    // hooks (linters, formatters) on each one. The post-commit squash hook still
    // runs on ticks, but it identifies them by their "[CHRONOS]" message prefix
    // and skips them — only a real (non-CHRONOS) commit triggers the squash.
    const commit_result = try runCommand(allocator, &[_][]const u8{ "git", "commit", "--no-verify", "-m", commit_msg.items });

    return if (commit_result.exit_code == 0) 0 else 1;
}

/// Map a Claude Code tool name to a ledger event `kind`.
fn ledgerKind(tool: []const u8) []const u8 {
    const eq = std.ascii.eqlIgnoreCase; // tolerate casing across CLIs
    const any = struct {
        fn f(t: []const u8, names: []const []const u8) bool {
            for (names) |n| if (eq(t, n)) return true;
            return false;
        }
    }.f;
    if (any(tool, &.{ "Read", "NotebookRead", "read_file", "readFile", "view" })) return "read";
    if (any(tool, &.{ "Edit", "Write", "MultiEdit", "NotebookEdit", "write_file", "edit_file", "apply_patch", "str_replace_editor" })) return "write";
    if (any(tool, &.{ "Bash", "BashOutput", "KillShell", "shell", "exec", "local_shell", "run_terminal_cmd" })) return "exec";
    if (any(tool, &.{ "WebFetch", "fetch", "web_fetch" })) return "net";
    if (any(tool, &.{ "WebSearch", "Grep", "Glob", "web_search", "grep", "glob" })) return "search";
    return "other";
}

/// Build a v1 ledger event body (no seq/prev/this/sig — the sink owns those) and
/// fire it at the sink, non-blocking. The body is assembled via the RFC 8785
/// encoder, NOT a format string, so caller-controlled values (paths, URLs, the
/// cognitive-state line) are escaped — no JSON-injection (JSON-IN-FMT).
fn emitLedgerEvent(
    allocator: std.mem.Allocator,
    hook_json: []const u8,
    repo_root: ?[]const u8,
    agent: []const u8,
    pid: i32,
    ppid: i32,
    tool_name: ?[]const u8,
    file_path: ?[]const u8,
    desc_field: ?[]const u8,
    state: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const name = tool_name orelse "unknown";
    const kind = ledgerKind(name);
    const is_web = std.mem.eql(u8, name, "WebFetch") or std.mem.eql(u8, name, "WebSearch");

    const url = try extractJsonString(a, hook_json, "\"url\"");
    const detail: ?[]const u8 = file_path orelse url orelse desc_field;

    const source_trust: []const u8 = if (is_web)
        "web"
    else if (file_path) |fp|
        (if (repo_root) |rr| (if (std.mem.startsWith(u8, fp, rr)) "repo" else "external") else "external")
    else
        "unknown";

    // act { tool, [detail], source_trust }
    var actm: [3]canonical.Member = undefined;
    var an: usize = 0;
    actm[an] = .{ .key = "tool", .value = .{ .string = name } };
    an += 1;
    if (detail) |d| {
        actm[an] = .{ .key = "detail", .value = .{ .string = d } };
        an += 1;
    }
    actm[an] = .{ .key = "source_trust", .value = .{ .string = source_trust } };
    an += 1;

    // Wall-clock ms for display only (t_wall_ms) — std.time.milliTimestamp is
    // absent in this stripped std; order is the sink's seq, not this value.
    var tspec: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &tspec);
    const ms: i64 = @as(i64, @intCast(tspec.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tspec.nsec)), 1_000_000);
    var ts_buf: [24]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{ms}) catch "0";

    // pid/ppid as decimal STRINGS (the schema is float-free and carries magnitudes
    // as strings; keeps the wire uniform with the Swift WireAgent's String fields so
    // CLI- and app-emitted events share one canonical shape in a unified ledger).
    const pid_s = try std.fmt.allocPrint(a, "{d}", .{pid});
    const ppid_s = try std.fmt.allocPrint(a, "{d}", .{ppid});
    const agent_members = [_]canonical.Member{
        .{ .key = "id", .value = .{ .string = agent } },
        .{ .key = "pid", .value = .{ .string = pid_s } },
        .{ .key = "ppid", .value = .{ .string = ppid_s } },
    };
    const ev = canonical.Value{ .object = &[_]canonical.Member{
        .{ .key = "agent", .value = .{ .object = &agent_members } },
        .{ .key = "kind", .value = .{ .string = kind } },
        .{ .key = "act", .value = .{ .object = actm[0..an] } },
        .{ .key = "state", .value = .{ .string = state } },
        .{ .key = "t_wall_ms", .value = .{ .string = ts } },
    } };

    const json = try canonical.encodeAlloc(a, ev);
    const socket_path = if (c.getenv("CHRONOS_LEDGER_SOCKET")) |p| std.mem.span(p) else LEDGER_SOCKET_DEFAULT;
    emit_client.emit(socket_path, json) catch {}; // best-effort; sink may be down
}

fn isGitRepository(allocator: std.mem.Allocator) !bool {
    const result = try runCommand(allocator, &[_][]const u8{ "git", "rev-parse", "--git-dir" });
    return result.exit_code == 0;
}

/// Run a git command and return its trimmed stdout (owned), or null on failure /
/// empty output. Caller frees on success.
fn gitOutput(allocator: std.mem.Allocator, argv: []const []const u8) !?[]const u8 {
    var r = try runCommand(allocator, argv);
    defer r.deinit();
    if (r.exit_code != 0) return null;
    const t = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}

/// Whether <root>/.gitignore exists.
fn gitignoreExists(root: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/.gitignore", .{root}) catch return false;
    return c.access(path.ptr, c.F_OK) == 0;
}

/// Ensure the current repo has the chronos post-commit squash shim installed.
/// Idempotent and cheap: if the shim is already present we return immediately;
/// otherwise we delegate to the tested chronos-enable-repo installer, which sets
/// local config and chains any pre-existing post-commit hook. This pairs global
/// ticking with global squashing so no repo accumulates un-squashed ticks.
fn ensureSquashShim(allocator: std.mem.Allocator) !void {
    const hooks = (try gitOutput(allocator, &[_][]const u8{ "git", "rev-parse", "--git-path", "hooks" })) orelse return;
    defer allocator.free(hooks);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const post_commit = std.fmt.bufPrint(&buf, "{s}/post-commit", .{hooks}) catch return;

    // Already installed? grep is cheap and avoids std.fs read-API churn.
    var grep = try runCommand(allocator, &[_][]const u8{ "grep", "-q", "chronos post-commit shim", post_commit });
    grep.deinit();
    if (grep.exit_code == 0) return;

    const root = (try gitOutput(allocator, &[_][]const u8{ "git", "rev-parse", "--show-toplevel" })) orelse return;
    defer allocator.free(root);
    var install = try runCommand(allocator, &[_][]const u8{ "/usr/local/bin/chronos-enable-repo", root });
    install.deinit();
}

/// Whether this repo has opted in to chronos ticking. True when either the
/// CHRONOS_ENABLED env var is set to a truthy value, or `git config
/// chronos.enabled` resolves to "true" in the current repo.
fn chronosEnabled(allocator: std.mem.Allocator) !bool {
    if (c.getenv("CHRONOS_ENABLED")) |ptr| {
        const v = std.mem.sliceTo(ptr, 0);
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) return true;
    }
    var result = try runCommand(allocator, &[_][]const u8{ "git", "config", "--get", "chronos.enabled" });
    defer result.deinit();
    if (result.exit_code != 0) return false;
    const val = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.mem.eql(u8, val, "true");
}

/// Read all of stdin to EOF (the hook JSON). Capped at 1 MiB. Returns owned bytes.
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = c.read(0, &tmp, tmp.len);
        if (n <= 0) break;
        try buf.appendSlice(allocator, tmp[0..@intCast(n)]);
        if (buf.items.len > (1 << 20)) break;
    }
    return buf.toOwnedSlice(allocator);
}

/// Truncate `s` to at most `max` bytes, backing off so a multi-byte UTF-8
/// sequence is never split (keeps the commit subject / one-liner sane).
fn capDetail(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

/// Try several quoted keys in order; return the first that yields a value.
/// Lets one hook serve providers with different payload spellings (snake_case
/// vs camelCase, description vs command) without a per-provider code path.
fn extractAny(allocator: std.mem.Allocator, json: []const u8, keys: []const []const u8) !?[]const u8 {
    for (keys) |k| {
        if (try extractJsonString(allocator, json, k)) |v| return v;
    }
    return null;
}

/// Extract a JSON string value for `key` (key includes its quotes, e.g.
/// "\"tool_name\""). Finds the first occurrence, then the next "..." after the
/// colon, honouring backslash escapes. Returns owned bytes or null.
fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const kpos = std.mem.indexOf(u8, json, key) orelse return null;
    var i = kpos + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip the escaped char
            continue;
        }
        if (json[i] == '"') break;
    }
    if (i > json.len) return null;
    return try allocator.dupe(u8, json[start..i]);
}

/// Map a Claude Code tool name to a gerund activity, used as the cognitive-state
/// fallback when no live spinner gerund is available from the PTY tap.
fn toolActivity(tool_name: ?[]const u8) []const u8 {
    const t = tool_name orelse return "Working";
    const map = [_]struct { []const u8, []const u8 }{
        .{ "Bash", "Executing" },
        .{ "Edit", "Editing" },
        .{ "MultiEdit", "Editing" },
        .{ "Write", "Writing" },
        .{ "NotebookEdit", "Editing" },
        .{ "Read", "Reading" },
        .{ "Glob", "Searching" },
        .{ "Grep", "Searching" },
        .{ "TodoWrite", "Planning" },
        .{ "Task", "Delegating" },
        .{ "Agent", "Delegating" },
        .{ "WebFetch", "Researching" },
        .{ "WebSearch", "Researching" },
        .{ "ExitPlanMode", "Planning" },
    };
    for (map) |kv| {
        if (std.mem.eql(u8, t, kv[0])) return kv[1];
    }
    return "Working"; // MCP tools (mcp__*) and anything unmapped
}

/// Resolve the cognitive state for the stamp. Prefers the live gerund that a PTY
/// tap wrote to /tmp/cognitive-state-<pid> (get-cognitive-state resolves the
/// firing claude's PID itself); on NOT-DETECTED, falls back to the tool activity.
fn getCognitiveState(allocator: std.mem.Allocator, tool_name: ?[]const u8) ![]const u8 {
    var result = try runCommand(allocator, &[_][]const u8{GET_COGNITIVE_STATE_PATH});
    defer result.deinit();

    if (result.exit_code == 0) {
        const state = std.mem.trim(u8, result.stdout, " \t\n\r");
        if (state.len > 0 and !std.mem.eql(u8, state, "NOT-DETECTED")) {
            return try allocator.dupe(u8, state);
        }
    }
    return try allocator.dupe(u8, toolActivity(tool_name));
}

fn generateChronosTimestamp(allocator: std.mem.Allocator, agent: []const u8) ![]const u8 {
    var result = try runCommand(allocator, &[_][]const u8{ CHRONOS_STAMP_PATH, agent, "tool-completion" });
    defer result.deinit();

    if (result.exit_code == 0 and result.stdout.len > 0) {
        // Extract [CHRONOS] line
        if (std.mem.indexOf(u8, result.stdout, "[CHRONOS]")) |start| {
            const newline_pos = std.mem.indexOfPos(u8, result.stdout, start, "\n") orelse result.stdout.len;
            const chronos_line = std.mem.trim(u8, result.stdout[start..newline_pos], " \t\n\r");
            return try allocator.dupe(u8, chronos_line);
        }
    }

    // Fallback: generate manual timestamp
    // Zig 0.16: Use c.clock_gettime for wall clock time
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) {
        return try std.fmt.allocPrint(allocator, "[FALLBACK] 0::{s}::::tool-completion", .{agent});
    }
    const timestamp = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    return try std.fmt.allocPrint(allocator, "[FALLBACK] {d}::{s}::::tool-completion", .{ timestamp, agent });
}

/// Resolved agent identity: the agent NAME plus the firing process's pid/ppid.
/// The pid is kernel ground truth — the join key that lets Guardian Shield's ES
/// view of *this pid's* `open()`/`connect()` calls be compared against the agent's
/// self-reported ledger ("the OS is the tiebreaker"). `name` is caller-owned.
const AgentInfo = struct { name: []u8, pid: i32, ppid: i32 };

/// Resolve which coding agent is running this hook. Priority:
///   1) CHRONOS_AGENT env (explicit override),
///   2) nearest agent binary in our process ancestry (kernel ground truth),
///   3) "claude-code" (legacy default).
fn resolveAgent(allocator: std.mem.Allocator) !AgentInfo {
    if (c.getenv("CHRONOS_AGENT")) |p| {
        const s = std.mem.span(p);
        // Explicit override: the agent's own pid is unknown, so report the hook's
        // parent (the process that spawned us — typically the agent or its shell).
        if (s.len > 0) return .{ .name = try allocator.dupe(u8, s), .pid = getppid(), .ppid = 0 };
    }
    if (try detectAncestorAgent(allocator)) |info| return info;
    return .{ .name = try allocator.dupe(u8, AGENT_ID), .pid = getppid(), .ppid = 0 };
}

const ProcRow = struct { pid: i32, ppid: i32, cmd: []const u8 };

/// Climb the process tree from our parent, matching each ancestor's command line
/// against the known agent binaries. Nearest match wins. Returns the matched
/// agent's name + its pid/ppid (the firing process), or null.
fn detectAncestorAgent(allocator: std.mem.Allocator) !?AgentInfo {
    var result = runCommand(allocator, &[_][]const u8{ "ps", "-axo", "pid=,ppid=,command=" }) catch return null;
    defer result.deinit();
    if (result.exit_code != 0) return null;

    var rows: std.ArrayList(ProcRow) = .empty;
    defer rows.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw| {
        var i: usize = 0;
        const line = std.mem.trimStart(u8, raw, " ");
        if (line.len == 0) continue;
        const pid = scanInt(line, &i) orelse continue;
        skipSpaces(line, &i);
        const ppid = scanInt(line, &i) orelse continue;
        skipSpaces(line, &i);
        try rows.append(allocator, .{ .pid = pid, .ppid = ppid, .cmd = line[i..] });
    }

    var cur: i32 = getppid();
    var depth: usize = 0;
    while (cur > 1 and depth < 40) : (depth += 1) {
        const row = findProc(rows.items, cur) orelse break;
        if (agentFromCommand(row.cmd)) |name|
            return AgentInfo{ .name = try allocator.dupe(u8, name), .pid = row.pid, .ppid = row.ppid };
        cur = row.ppid;
    }
    return null;
}

/// Identify the agent from a process command line by inspecting only the
/// EXECUTABLE (and, for runtimes like node, the script path) — never the prompt
/// or args. This is what stops `claude -p "fix grok stuff"` from being misread as
/// grok: the agent name must be in the binary that's running, not its arguments.
fn agentFromCommand(cmd: []const u8) ?[]const u8 {
    const exe = firstToken(cmd);
    if (matchAgentToken(exe)) |n| return n;
    if (isRuntime(basename(exe))) {
        const rest = std.mem.trimStart(u8, cmd[exe.len..], " \t");
        if (matchAgentToken(firstToken(rest))) |n| return n;
    }
    return null;
}

fn matchAgentToken(token: []const u8) ?[]const u8 {
    for (AGENT_PATTERNS) |pat| {
        if (containsCI(token, pat.needle)) return pat.name;
    }
    return null;
}

fn firstToken(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t') : (end += 1) {}
    return s[0..end];
}

fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

fn isRuntime(name: []const u8) bool {
    const runtimes = [_][]const u8{ "node", "deno", "bun", "python", "python3", "sh", "bash", "zsh", "ruby", "electron" };
    for (runtimes) |r| {
        if (std.ascii.eqlIgnoreCase(name, r)) return true;
    }
    return false;
}

fn findProc(rows: []const ProcRow, pid: i32) ?ProcRow {
    for (rows) |r| {
        if (r.pid == pid) return r;
    }
    return null;
}

fn scanInt(s: []const u8, i: *usize) ?i32 {
    const start = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {}
    if (i.* == start) return null;
    return std.fmt.parseInt(i32, s[start..i.*], 10) catch null;
}

fn skipSpaces(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) : (i.* += 1) {}
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

const CommandResult = struct {
    exit_code: u8,
    stdout: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
    }
};

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    // Build a null-terminated argv of null-terminated strings for execvp.
    // Allocated before fork so the child inherits it without touching the heap.
    var argv_z = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    defer allocator.free(argv_z);
    var built: usize = 0;
    // Single defer frees exactly the strings built so far — correct whether the
    // loop completes or a dupeZ fails partway. (In the child we _exit before
    // returning, so these never run there and there's no cross-fork double free.)
    defer for (0..built) |i| allocator.free(std.mem.sliceTo(argv_z[i].?, 0));
    for (argv, 0..) |arg, i| {
        const z = try allocator.dupeZ(u8, arg);
        argv_z[i] = z.ptr;
        built = i + 1;
    }
    argv_z[argv.len] = null;

    var fds: [2]std.c.fd_t = undefined; // fds[0]=read, fds[1]=write
    if (c.pipe(&fds) != 0) return emptyResult(allocator);

    const pid = fork();
    if (pid < 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return emptyResult(allocator);
    }

    if (pid == 0) {
        // Child: stdout -> pipe, stderr -> /dev/null, then exec.
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], 1) < 0) c._exit(127);
        const devnull = c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devnull >= 0) _ = c.dup2(devnull, 2);
        _ = c.close(fds[1]);
        _ = execvp(argv_z[0].?, @ptrCast(argv_z.ptr));
        c._exit(127); // only reached if execvp failed
    }

    // Parent: read child's stdout to EOF, then reap it.
    _ = c.close(fds[1]);
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    errdefer stdout_buf.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n_signed = c.read(fds[0], &buf, buf.len);
        if (n_signed <= 0) break;
        try stdout_buf.appendSlice(allocator, buf[0..@intCast(n_signed)]);
    }
    _ = c.close(fds[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // Decode exit status portably (macOS/Linux): WIFEXITED / WEXITSTATUS.
    const ust: u32 = @bitCast(status);
    const exit_code: u8 = if ((ust & 0x7f) == 0) @intCast((ust >> 8) & 0xff) else 1;

    const stdout_owned = stdout_buf.toOwnedSlice(allocator) catch return emptyResult(allocator);

    return CommandResult{
        .exit_code = exit_code,
        .stdout = stdout_owned,
        .allocator = allocator,
    };
}

fn emptyResult(allocator: std.mem.Allocator) !CommandResult {
    return CommandResult{
        .exit_code = 1,
        .stdout = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
}
