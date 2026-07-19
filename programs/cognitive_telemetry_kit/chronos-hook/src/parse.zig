//! Pure, side-effect-free helpers for the chronos-hook PostToolUse tick.
//!
//! Everything here is deliberately I/O-free (no fork/exec, no git, no sockets)
//! so it can be unit-tested directly — the hook's real failure modes live in
//! this parsing/attribution logic (agent misattribution, field mis-extraction,
//! UTF-8 truncation), not in the git plumbing. `main.zig` is the thin process
//! shell that wires these to stdin/argv/exec.

const std = @import("std");

// ---------------------------------------------------------------------------
// Agent attribution
// ---------------------------------------------------------------------------

pub const AgentPattern = struct { needle: []const u8, name: []const u8 };

// Grok reads its hooks from ~/.claude (shares Claude's settings.json), so the
// same hook command fires for both — config can't tell them apart, the kernel
// can. We climb the process tree and match the executing agent *binary*.
pub const AGENT_PATTERNS = [_]AgentPattern{
    .{ .needle = "grok", .name = "grok" },
    .{ .needle = "codex", .name = "codex" },
    .{ .needle = "gemini", .name = "gemini" },
    .{ .needle = "antigravity", .name = "gemini" },
    .{ .needle = "claude", .name = "claude" },
};

/// Identify the agent from a process command line by inspecting only the
/// EXECUTABLE (and, for runtimes like node, the script path) — never the prompt
/// or args. This is what stops `claude -p "fix grok stuff"` from being misread as
/// grok: the agent name must be in the binary that's running, not its arguments.
pub fn agentFromCommand(cmd: []const u8) ?[]const u8 {
    const exe = firstToken(cmd);
    if (matchAgentToken(exe)) |n| return n;
    if (isRuntime(basename(exe))) {
        const rest = std.mem.trimStart(u8, cmd[exe.len..], " \t");
        if (matchAgentToken(firstToken(rest))) |n| return n;
    }
    return null;
}

pub fn matchAgentToken(token: []const u8) ?[]const u8 {
    for (AGENT_PATTERNS) |pat| {
        if (containsCI(token, pat.needle)) return pat.name;
    }
    return null;
}

pub fn firstToken(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t') : (end += 1) {}
    return s[0..end];
}

pub fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

pub fn isRuntime(name: []const u8) bool {
    const runtimes = [_][]const u8{ "node", "deno", "bun", "python", "python3", "sh", "bash", "zsh", "ruby", "electron" };
    for (runtimes) |r| {
        if (std.ascii.eqlIgnoreCase(name, r)) return true;
    }
    return false;
}

pub fn containsCI(haystack: []const u8, needle: []const u8) bool {
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

// ---------------------------------------------------------------------------
// `ps -axo pid=,ppid=,command=` row parsing
// ---------------------------------------------------------------------------

pub const ProcRow = struct { pid: i32, ppid: i32, cmd: []const u8 };

pub fn findProc(rows: []const ProcRow, pid: i32) ?ProcRow {
    for (rows) |r| {
        if (r.pid == pid) return r;
    }
    return null;
}

pub fn scanInt(s: []const u8, i: *usize) ?i32 {
    const start = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {}
    if (i.* == start) return null;
    return std.fmt.parseInt(i32, s[start..i.*], 10) catch null;
}

pub fn skipSpaces(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) : (i.* += 1) {}
}

/// Parse one `ps -axo pid=,ppid=,command=` line into a ProcRow. `cmd` aliases
/// `raw` (no copy). Returns null for blank / malformed rows so the caller can
/// skip them — the same tolerance the ancestry walk needs against a hostile or
/// truncated `ps`.
pub fn parseProcRow(raw: []const u8) ?ProcRow {
    const line = std.mem.trimStart(u8, raw, " ");
    if (line.len == 0) return null;
    var i: usize = 0;
    const pid = scanInt(line, &i) orelse return null;
    skipSpaces(line, &i);
    const ppid = scanInt(line, &i) orelse return null;
    skipSpaces(line, &i);
    return .{ .pid = pid, .ppid = ppid, .cmd = line[i..] };
}

// ---------------------------------------------------------------------------
// Tick subject helpers
// ---------------------------------------------------------------------------

/// Truncate `s` to at most `max` bytes, backing off so a multi-byte UTF-8
/// sequence is never split (keeps the commit subject / one-liner sane).
pub fn capDetail(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

/// Map a Claude Code tool name to a gerund activity, used as the cognitive-state
/// fallback when no live spinner gerund is available from the PTY tap.
pub fn toolActivity(tool_name: ?[]const u8) []const u8 {
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

/// Map a Claude Code tool name to a ledger event `kind`.
pub fn ledgerKind(tool: []const u8) []const u8 {
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

// ---------------------------------------------------------------------------
// JSON field extraction
// ---------------------------------------------------------------------------

/// Structured lookup: recursively find the first STRING-valued member whose key
/// equals `key`, checking an object's direct members before descending. Because
/// it walks real parsed keys, a literal `"url"` (or any other key spelling)
/// sitting inside a string VALUE — e.g. a Bash `command` that mentions `"url"` —
/// is never mistaken for the field. Direct-members-first keeps the top-level
/// `tool_name` winning over any same-named key nested deeper.
pub fn findStringByKey(root: std.json.Value, key: []const u8) ?[]const u8 {
    switch (root) {
        .object => |obj| {
            for (obj.keys(), obj.values()) |k, v| {
                if (std.mem.eql(u8, k, key) and v == .string) return v.string;
            }
            for (obj.values()) |v| {
                if (findStringByKey(v, key)) |s| return s;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findStringByKey(item, key)) |s| return s;
            }
        },
        else => {},
    }
    return null;
}

/// Resolve a field from the hook payload, preferring the parsed JSON tree.
///
///   - `root` present (payload parsed as JSON): try each key spelling in order
///     against the tree via `findStringByKey`. A genuinely-absent key returns
///     null — we do NOT fall back to the byte scanner, which is exactly the
///     mis-extraction we're eliminating (matching a key that only appears inside
///     a string value).
///   - `root` null (stdin was not valid JSON / truncated): degrade to the
///     tolerant byte scanner so behaviour never regresses below the old hook.
///
/// `keys` are BARE (unquoted) key names; the fallback quotes them itself.
/// Returned bytes are owned by `allocator`.
pub fn extractField(
    allocator: std.mem.Allocator,
    root: ?std.json.Value,
    json: []const u8,
    keys: []const []const u8,
) !?[]const u8 {
    if (root) |r| {
        for (keys) |k| {
            if (findStringByKey(r, k)) |s| return try allocator.dupe(u8, s);
        }
        return null;
    }
    // Fallback path — parse failed. Quote each bare key and scan the raw bytes.
    var kbuf: [128]u8 = undefined;
    for (keys) |k| {
        if (k.len + 2 > kbuf.len) continue;
        const quoted = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{k}) catch continue;
        if (try extractJsonStringScan(allocator, json, quoted)) |v| return v;
    }
    return null;
}

/// Legacy tolerant byte scanner. Extract a JSON string value for `key` (key
/// includes its quotes, e.g. `"\"tool_name\""`). Finds the first occurrence,
/// then the next `"..."` after the colon, honouring backslash escapes. Returns
/// owned bytes or null. Retained only as the fallback for non-JSON stdin — the
/// structured path above is preferred and is what production hits.
pub fn extractJsonStringScan(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
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

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "agentFromCommand matches on the executable, not the prompt args" {
    // `claude -p "fix grok stuff"` must attribute to claude — grok appears only
    // in the prompt, never in the binary. This is the core misattribution guard.
    try testing.expectEqualStrings("claude", agentFromCommand("/usr/local/bin/claude -p \"fix grok stuff\"").?);
    try testing.expectEqualStrings("grok", agentFromCommand("/opt/homebrew/bin/grok chat").?);
    try testing.expectEqualStrings("codex", agentFromCommand("codex exec 'do the thing'").?);
    // antigravity is a Gemini surface → normalised to gemini.
    try testing.expectEqualStrings("gemini", agentFromCommand("/Applications/antigravity --flag").?);
}

test "agentFromCommand descends one level for known runtimes only" {
    // node running a claude script → claude (script path is the 2nd token).
    try testing.expectEqualStrings("claude", agentFromCommand("node /usr/lib/claude/cli.js").?);
    try testing.expectEqualStrings("gemini", agentFromCommand("/usr/bin/python3 /x/gemini_cli.py").?);
    // A non-runtime parent whose ARG mentions an agent must NOT match: `vim`
    // editing grok.md is not the grok agent.
    try testing.expect(agentFromCommand("/usr/bin/vim grok_notes.md") == null);
    // node with no agent script → no match.
    try testing.expect(agentFromCommand("node /srv/app/server.js") == null);
}

test "agentFromCommand returns null for unrelated processes" {
    try testing.expect(agentFromCommand("/bin/zsh -l") == null);
    try testing.expect(agentFromCommand("") == null);
    try testing.expect(agentFromCommand("/usr/sbin/mDNSResponder") == null);
}

test "parseProcRow tolerates hostile / malformed ps output" {
    const r = parseProcRow("  1234   567 /usr/local/bin/claude -p hi").?;
    try testing.expectEqual(@as(i32, 1234), r.pid);
    try testing.expectEqual(@as(i32, 567), r.ppid);
    try testing.expectEqualStrings("/usr/local/bin/claude -p hi", r.cmd);

    // Blank, header-ish, and non-numeric rows are rejected, not crashed on.
    try testing.expect(parseProcRow("") == null);
    try testing.expect(parseProcRow("   ") == null);
    try testing.expect(parseProcRow("PID PPID COMMAND") == null);
    try testing.expect(parseProcRow("42") == null); // pid but no ppid
    // A command that itself contains digits/spaces stays intact after the ppid.
    const r2 = parseProcRow("7 1 sh -c 'echo 12 34'").?;
    try testing.expectEqualStrings("sh -c 'echo 12 34'", r2.cmd);
}

test "detectAncestor-style walk picks the nearest agent" {
    const rows = [_]ProcRow{
        .{ .pid = 100, .ppid = 1, .cmd = "/sbin/launchd" },
        .{ .pid = 200, .ppid = 100, .cmd = "/usr/local/bin/claude" },
        .{ .pid = 300, .ppid = 200, .cmd = "/bin/zsh" },
        .{ .pid = 400, .ppid = 300, .cmd = "git commit" },
    };
    // Walk from pid 400 up: git → zsh → claude. Nearest agent is claude@200.
    var cur: i32 = 400;
    var found: ?[]const u8 = null;
    var depth: usize = 0;
    while (cur > 1 and depth < 40) : (depth += 1) {
        const row = findProc(&rows, cur) orelse break;
        if (agentFromCommand(row.cmd)) |name| {
            found = name;
            break;
        }
        cur = row.ppid;
    }
    try testing.expectEqualStrings("claude", found.?);
}

test "capDetail never splits a UTF-8 sequence" {
    // "é" is 2 bytes (0xC3 0xA9). Cap at 3 → keeps "aé"? "aé" is 3 bytes total.
    try testing.expectEqualStrings("aé", capDetail("aération", 3));
    // Cap between the two bytes of é → back off to just "a".
    try testing.expectEqualStrings("a", capDetail("aé", 2));
    // Under the cap → unchanged.
    try testing.expectEqualStrings("short", capDetail("short", 200));
    // A 4-byte emoji cut mid-sequence backs off cleanly.
    try testing.expectEqualStrings("x", capDetail("x😀", 3));
}

test "ledgerKind and toolActivity map the tool taxonomy" {
    try testing.expectEqualStrings("read", ledgerKind("Read"));
    try testing.expectEqualStrings("write", ledgerKind("apply_patch"));
    try testing.expectEqualStrings("exec", ledgerKind("Bash"));
    try testing.expectEqualStrings("net", ledgerKind("WebFetch"));
    try testing.expectEqualStrings("search", ledgerKind("Grep"));
    try testing.expectEqualStrings("other", ledgerKind("mcp__whatever"));
    try testing.expectEqualStrings("Executing", toolActivity("Bash"));
    try testing.expectEqualStrings("Working", toolActivity(null));
    try testing.expectEqualStrings("Working", toolActivity("mcp__x"));
}

fn parseRoot(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, s, .{ .duplicate_field_behavior = .use_first });
}

test "extractField: structured lookup ignores keys that only appear inside a value" {
    const a = testing.allocator;
    // The Bash command STRING contains the text "url": ... — the old byte scanner
    // would mis-extract "http://evil" as the WebFetch url. Structured lookup must
    // not, because there is no real `url` KEY in this payload.
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"curl \"url\":\"http://evil\""}}
    ;
    var p = try parseRoot(a, json);
    defer p.deinit();

    const url = try extractField(a, p.value, json, &.{"url"});
    try testing.expect(url == null); // no real url key → no false positive

    const tool = (try extractField(a, p.value, json, &.{ "tool_name", "toolName" })).?;
    defer a.free(tool);
    try testing.expectEqualStrings("Bash", tool);

    const cmd = (try extractField(a, p.value, json, &.{ "description", "command", "cmd" })).?;
    defer a.free(cmd);
    try testing.expectEqualStrings("curl \"url\":\"http://evil\"", cmd);
}

test "extractField: finds nested tool_input fields and a real url key" {
    const a = testing.allocator;
    const json =
        \\{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/x","prompt":"go"}}
    ;
    var p = try parseRoot(a, json);
    defer p.deinit();
    const url = (try extractField(a, p.value, json, &.{"url"})).?;
    defer a.free(url);
    try testing.expectEqualStrings("https://example.com/x", url);

    const fp_json =
        \\{"tool_name":"Edit","tool_input":{"file_path":"/repo/a.zig","old_string":"x"}}
    ;
    var p2 = try parseRoot(a, fp_json);
    defer p2.deinit();
    const fp = (try extractField(a, p2.value, fp_json, &.{ "file_path", "filePath", "path", "absolute_path" })).?;
    defer a.free(fp);
    try testing.expectEqualStrings("/repo/a.zig", fp);
}

test "extractField: key spelling priority is honoured (first spelling wins)" {
    const a = testing.allocator;
    // Both file_path and path present → file_path (first in the list) wins.
    const json =
        \\{"tool_input":{"path":"/second","file_path":"/first"}}
    ;
    var p = try parseRoot(a, json);
    defer p.deinit();
    const v = (try extractField(a, p.value, json, &.{ "file_path", "filePath", "path" })).?;
    defer a.free(v);
    try testing.expectEqualStrings("/first", v);
}

test "extractField: non-JSON stdin falls back to the byte scanner" {
    const a = testing.allocator;
    // root=null simulates a parse failure; the tolerant scanner still recovers
    // the field so the hook degrades gracefully rather than losing all detail.
    const raw = "garbage prefix \"tool_name\": \"Read\" trailing";
    const tool = (try extractField(a, null, raw, &.{ "tool_name", "toolName" })).?;
    defer a.free(tool);
    try testing.expectEqualStrings("Read", tool);

    const missing = try extractField(a, null, raw, &.{"nope"});
    try testing.expect(missing == null);
}

test "extractJsonStringScan honours escapes and handles unterminated input" {
    const a = testing.allocator;
    const v = (try extractJsonStringScan(a, "{\"k\": \"a\\\"b\"}", "\"k\"")).?;
    defer a.free(v);
    try testing.expectEqualStrings("a\\\"b", v); // escaped quote kept, not a terminator
    // Trailing backslash / unterminated string → null, no OOB.
    try testing.expect((try extractJsonStringScan(a, "{\"k\": \"abc\\", "\"k\"")) == null);
    // Missing key → null.
    try testing.expect((try extractJsonStringScan(a, "{\"other\":1}", "\"k\"")) == null);
}
