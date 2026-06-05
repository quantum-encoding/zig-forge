const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const c = std.c;

const CHRONOS_STAMP_PATH = "/usr/local/bin/chronos-stamp";
const GET_COGNITIVE_STATE_PATH = "/usr/local/bin/get-cognitive-state";
const AGENT_ID = "claude-code";

// std.c exposes neither fork nor execvp in this Zig build — declare them.
// (execvp does PATH resolution, which execve would not.)
extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

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

    // Get environment variables
    const tool_input = if (c.getenv("CLAUDE_TOOL_INPUT")) |ptr| std.mem.sliceTo(ptr, 0) else null;
    const claude_pid_str = if (c.getenv("CLAUDE_PID")) |ptr| std.mem.sliceTo(ptr, 0) else null;

    // Extract tool description from JSON if available
    var tool_description: ?[]const u8 = null;
    if (tool_input) |input| {
        tool_description = try extractToolDescription(allocator, input);
    }
    defer if (tool_description) |desc| allocator.free(desc);

    // Get Claude PID
    var pid: ?u32 = null;
    if (claude_pid_str) |pid_str| {
        pid = std.fmt.parseInt(u32, pid_str, 10) catch null;
    }
    if (pid == null) {
        // Fallback: try to find Claude process
        pid = try findClaudePid(allocator);
    }

    // Get cognitive state
    const cognitive_state = try getCognitiveState(allocator, pid);
    defer allocator.free(cognitive_state);

    // Generate CHRONOS timestamp
    const chronos_output = try generateChronosTimestamp(allocator);
    defer allocator.free(chronos_output);

    // Build commit message
    var commit_msg = std.ArrayList(u8).empty;
    defer commit_msg.deinit(allocator);

    // Inject cognitive state into CHRONOS output
    // Replace "::::TICK" with "::<state>::TICK"
    if (std.mem.indexOf(u8, chronos_output, "::::TICK")) |pos| {
        try commit_msg.appendSlice(allocator, chronos_output[0..pos]);
        try commit_msg.appendSlice(allocator, "::");
        try commit_msg.appendSlice(allocator, cognitive_state);
        try commit_msg.appendSlice(allocator, "::");
        try commit_msg.appendSlice(allocator, chronos_output[pos + 4 ..]);
    } else {
        try commit_msg.appendSlice(allocator, chronos_output);
    }

    // Append tool description if available
    if (tool_description) |desc| {
        try commit_msg.appendSlice(allocator, " - ");
        try commit_msg.appendSlice(allocator, desc);
    }

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

fn extractToolDescription(allocator: std.mem.Allocator, json_input: []const u8) !?[]const u8 {
    // Simple JSON parsing - look for "description":"..."
    const needle = "\"description\":\"";
    const start_pos = std.mem.indexOf(u8, json_input, needle) orelse return null;
    const value_start = start_pos + needle.len;

    // Find closing quote
    const end_pos = std.mem.indexOfPos(u8, json_input, value_start, "\"") orelse return null;

    const description = json_input[value_start..end_pos];
    return try allocator.dupe(u8, description);
}

fn findClaudePid(allocator: std.mem.Allocator) !?u32 {
    var result = try runCommand(allocator, &[_][]const u8{ "pgrep", "-f", "claude" });
    defer result.deinit();

    if (result.exit_code != 0 or result.stdout.len == 0) {
        return null;
    }

    // Get first line
    const newline_pos = std.mem.indexOf(u8, result.stdout, "\n") orelse result.stdout.len;
    const pid_str = std.mem.trim(u8, result.stdout[0..newline_pos], " \t\n\r");

    return std.fmt.parseInt(u32, pid_str, 10) catch null;
}

fn getCognitiveState(allocator: std.mem.Allocator, pid: ?u32) ![]const u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    try args.append(allocator, GET_COGNITIVE_STATE_PATH);

    if (pid) |p| {
        const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{p});
        defer allocator.free(pid_str);
        try args.append(allocator, pid_str);
    }

    var result = try runCommand(allocator, args.items);
    defer result.deinit();

    if (result.exit_code == 0 and result.stdout.len > 0) {
        // Trim whitespace
        const state = std.mem.trim(u8, result.stdout, " \t\n\r");
        if (state.len > 0) {
            return try allocator.dupe(u8, state);
        }
    }

    // Fallback
    return try allocator.dupe(u8, "Active");
}

fn generateChronosTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    var result = try runCommand(allocator, &[_][]const u8{ CHRONOS_STAMP_PATH, AGENT_ID, "tool-completion" });
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
        return try std.fmt.allocPrint(allocator, "[FALLBACK] 0::{s}::::tool-completion", .{AGENT_ID});
    }
    const timestamp = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    return try std.fmt.allocPrint(allocator, "[FALLBACK] {d}::{s}::::tool-completion", .{ timestamp, AGENT_ID });
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
