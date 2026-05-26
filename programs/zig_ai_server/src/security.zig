// Security primitives — constant-time comparison, input validation, sandboxing
//
// Sandbox model: strict executable allowlist + structured argv exec.
// No shell interpretation anywhere — child processes are spawned with
// std.process.run + explicit argv, bypassing /bin/sh -c entirely. This
// removes shell-metacharacter injection (|, &&, ||, ;, $(), backticks,
// glob expansion, redirections) as an attack surface.
//
// Replaces an earlier validateCommand blocklist that scanned a single
// shell-command string for substrings like "curl " or "rm -rf /". That
// approach was fundamentally bypassable (e.g. "curl\thttp://...",
// "python -c 'import os; ...'", "echo $(...) | base64") and has been
// removed in favour of this allowlist-driven design.

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

// ── Executable allowlist ────────────────────────────────────
// Only these executables can be spawned by the agent. Bare names only —
// PATH lookup is delegated to the OS, but the *name* must match exactly.
//
// What is in: read-only or build/dev-only tools the agent legitimately
// needs to do software work in its workspace. The shell itself is NOT
// in the list; neither are scripting interpreters (which would re-open
// arbitrary execution), network tools (curl/wget/nc/ssh/scp), privilege
// escalation (sudo/su/doas), destructive ops (rm/mv/chmod/chown/dd),
// or system control (reboot/shutdown/kill/mount).
//
// To extend: add the bare executable name here. Do NOT add any binary
// that takes a -c / -e / -- script flag (sh, bash, python, node, perl,
// ruby, awk, sed -e ...) — those re-introduce shell-style injection.

pub const allowed_executables = [_][]const u8{
    // Build / language tools
    "zig",
    "git",
    "make",
    // File inspection (read-only)
    "ls",
    "cat",
    "head",
    "tail",
    "wc",
    "file",
    "stat",
    "tree",
    // Search
    "grep",
    "rg",
    "find",
    "fd",
    // Directory creation (write but contained to workspace via cwd)
    "mkdir",
    // Misc info
    "pwd",
    "echo",
    "date",
    "which",
    "env",
    "uname",
    // RAG search helper (project-local CLI)
    "rag",
};

const max_executable_name_len: usize = 64;
const max_argument_len: usize = 8 * 1024;
const max_argument_count: usize = 128;

pub const ExecValidationError = error{
    EmptyExecutable,
    ExecutableNameTooLong,
    ExecutablePathContainsSlash,
    ExecutableNullByte,
    ExecutableNotAllowed,
    ArgumentNullByte,
    ArgumentTooLong,
    TooManyArguments,
};

/// Validate that `name` is a permitted bare executable name.
/// Rejects paths (anything containing '/' or '\\') — the executable
/// must be a bare name resolved via PATH by the OS, not an arbitrary
/// filesystem path supplied by the model.
pub fn validateExecutable(name: []const u8) ExecValidationError![]const u8 {
    if (name.len == 0) return ExecValidationError.EmptyExecutable;
    if (name.len > max_executable_name_len) return ExecValidationError.ExecutableNameTooLong;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return ExecValidationError.ExecutableNullByte;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return ExecValidationError.ExecutablePathContainsSlash;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return ExecValidationError.ExecutablePathContainsSlash;

    for (allowed_executables) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return name;
    }
    return ExecValidationError.ExecutableNotAllowed;
}

/// Validate a single argv argument. Even though we never pass arguments
/// through a shell, we still enforce a null-byte ban (would truncate the
/// arg at the syscall boundary on POSIX) and a length cap.
pub fn validateArgument(arg: []const u8) ExecValidationError!void {
    if (arg.len > max_argument_len) return ExecValidationError.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, arg, 0) != null) return ExecValidationError.ArgumentNullByte;
}

/// Validate an argv array: caps argument count and validates each entry.
pub fn validateArgumentCount(count: usize) ExecValidationError!void {
    if (count > max_argument_count) return ExecValidationError.TooManyArguments;
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
