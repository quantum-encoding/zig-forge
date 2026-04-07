// Security primitives — constant-time comparison, input validation, sandboxing

const std = @import("std");

// ── Constant-time comparison ────────────────────────────────
// Prevents timing side-channel attacks on token validation.
// Always compares all bytes regardless of mismatch position.

pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ── Path validation ─────────────────────────────────────────
// Ensures paths are strictly relative, within workspace, no escapes.

pub fn validatePath(path: []const u8) ?[]const u8 {
    // Empty path
    if (path.len == 0) return null;

    // Absolute paths forbidden
    if (path[0] == '/') return null;
    if (path[0] == '~') return null;

    // No parent directory traversal
    if (std.mem.indexOf(u8, path, "..") != null) return null;

    // No null bytes (path injection)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;

    // No backslash (Windows path injection on cross-platform)
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    // Max path length
    if (path.len > 4096) return null;

    // Strip leading ./
    if (std.mem.startsWith(u8, path, "./")) return path[2..];

    return path;
}

// ── Command sandboxing ──────────────────────────────────────
// Block dangerous commands that could damage the host or exfiltrate data.

const blocked_commands = [_][]const u8{
    // Destructive
    "rm -rf /",
    "rm -rf /*",
    "mkfs",
    "dd if=",
    ":(){",
    // Privilege escalation
    "sudo ",
    "su ",
    "chmod 777",
    "chown ",
    "passwd",
    // Network exfiltration
    "nc ",
    "ncat ",
    "netcat ",
    // Process manipulation
    "kill -9 1",
    "killall",
    "reboot",
    "shutdown",
    "halt",
    "init ",
    // Disk/mount
    "mount ",
    "umount ",
    "fdisk",
};

const blocked_patterns = [_][]const u8{
    // Exfiltration via network
    "curl ",
    "wget ",
    // These are fine for legitimate use but dangerous when model-controlled
    // Comment out if your agent needs them:
    // "ssh ",
    // "scp ",
};

pub fn validateCommand(command: []const u8) ?[]const u8 {
    // Empty command
    if (command.len == 0) return null;

    // Max command length
    if (command.len > 8192) return null;

    // Null byte injection
    if (std.mem.indexOfScalar(u8, command, 0) != null) return null;

    // Check blocked commands
    const trimmed = std.mem.trim(u8, command, " \t\n");
    for (blocked_commands) |blocked| {
        if (std.mem.startsWith(u8, trimmed, blocked)) return null;
        // Also check after pipes/semicolons
        if (std.mem.indexOf(u8, trimmed, blocked) != null) return null;
    }

    // Check blocked patterns (less strict — only block at command position)
    for (blocked_patterns) |pattern| {
        // Block at start of command or after pipe/semicolon/&&/||
        if (std.mem.startsWith(u8, trimmed, pattern)) return null;
        // After pipe
        if (std.mem.indexOf(u8, trimmed, "| ")) |pipe_pos| {
            const after_pipe = std.mem.trim(u8, trimmed[pipe_pos + 2 ..], " ");
            if (std.mem.startsWith(u8, after_pipe, pattern)) return null;
        }
        // After semicolon
        if (std.mem.indexOf(u8, trimmed, "; ")) |semi_pos| {
            const after_semi = std.mem.trim(u8, trimmed[semi_pos + 2 ..], " ");
            if (std.mem.startsWith(u8, after_semi, pattern)) return null;
        }
        // After &&
        if (std.mem.indexOf(u8, trimmed, "&& ")) |and_pos| {
            const after_and = std.mem.trim(u8, trimmed[and_pos + 3 ..], " ");
            if (std.mem.startsWith(u8, after_and, pattern)) return null;
        }
    }

    return command;
}

// ── String sanitization ─────────────────────────────────────

/// Sanitize a workspace ID to only allow alphanumeric, hyphen, underscore
pub fn sanitizeId(input: []const u8) ?[]const u8 {
    if (input.len == 0 or input.len > 128) return null;

    for (input) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return input;
}

// ── Request limits ──────────────────────────────────────────

pub const Limits = struct {
    pub const max_chat_body: usize = 1 * 1024 * 1024; // 1MB for chat
    pub const max_agent_body: usize = 256 * 1024; // 256KB for agent
    pub const max_generic_body: usize = 10 * 1024 * 1024; // 10MB fallback
    pub const max_messages: usize = 200; // Max messages in chat context
    pub const max_agent_iterations: u32 = 50; // Agent loop cap
    pub const max_model_name: usize = 128; // Model name length
    pub const max_requests_per_conn: u32 = 1000; // Keep-alive request limit
    pub const max_tokens_cap: u32 = 128_000; // Max tokens any request can ask for
};
