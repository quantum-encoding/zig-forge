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
//
// Audit H9: lexical path checks are NOT a TOCTOU-safe sandbox.
//
// `validatePath` rejects obviously bad shapes (absolute, traversal,
// null byte, tilde, backslash). That is the *fast-fail layer*, not
// the safety property. An attacker who controls the workspace
// contents can pass a clean string like "config.json" and swap the
// inode for a symlink to /etc/passwd between the check and the
// `openFile` syscall — the lexical filter cannot close that race.
//
// File I/O on user-supplied paths MUST go through
// `openFileInWorkspace` / `createFileInWorkspace` below. Those
// helpers set `follow_symlinks=false` and `resolve_beneath=true` so
// the OS, not a pre-flight string check, enforces the sandbox at
// the moment the inode is resolved.

/// Lexical-only path filter. Returns the cleaned slice (with any
/// leading "./" stripped) when the path looks safe by shape, or
/// `null` for any rejected form. This is a defense-in-depth layer:
/// it does not bless the path as safe to open, only that it is not
/// obviously malformed. See the file-level note for the actual
/// TOCTOU-safe open path.
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

pub const WorkspaceOpenError = std.Io.File.OpenError || error{PathRejected};

/// Open a regular file by name relative to an open workspace
/// directory. The lexical layer (`validatePath`) is applied first
/// to catch obviously malformed input. The `openFile` call then
/// disables symlink-follow (`follow_symlinks = false`) and asks the
/// kernel to refuse any resolution that escapes the workspace
/// (`resolve_beneath = true`). The OS — not a pre-flight string
/// check — is what enforces the sandbox at the moment the inode
/// is resolved, which is the only way to close the TOCTOU window
/// described in audit H9.
///
/// Use this helper instead of `Dir.openFile` for any file path
/// that originates outside the trust boundary (request bodies,
/// JWT claims, agent tool arguments, …).
pub fn openFileInWorkspace(
    workspace: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) WorkspaceOpenError!std.Io.File {
    const clean = validatePath(sub_path) orelse return error.PathRejected;
    var opts = options;
    opts.follow_symlinks = false;
    opts.resolve_beneath = true;
    return workspace.openFile(io, clean, opts);
}

/// Create-or-open a file by name relative to an open workspace
/// directory. The lexical layer rejects obvious bad input; the
/// `createFile` call sets `resolve_beneath = true` so the OS
/// blocks any path that escapes the workspace. `createFile` does
/// not follow an existing symlink in the final component — it
/// either creates a new inode at the name or (with `.truncate`)
/// truncates a regular file already there.
pub fn createFileInWorkspace(
    workspace: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    flags: std.Io.Dir.CreateFileOptions,
) WorkspaceOpenError!std.Io.File {
    const clean = validatePath(sub_path) orelse return error.PathRejected;
    var f = flags;
    f.resolve_beneath = true;
    return workspace.createFile(io, clean, f);
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

/// Maximum length an account_id may have. Matches the
/// `types.FixedStr64` storage width used by `Account.id`.
///
/// Audit M4: previously 32 chars, which is below the lower bound
/// of an Apple Sign In subject identifier (`apple_<sub>` runs
/// 25–44 chars in the wild). 64 matches the underlying storage so
/// `FixedStr64.fromSlice` is never asked to silently truncate.
pub const max_account_id_len: usize = 64;

/// Validate an account_id at the trust boundary. Returns the input
/// when accepted, `null` when rejected.
///
/// Audit M14 + M4: account_id strings flow into the WAL
/// `update_balance` payload (`{account_id}:{delta}`, parsed via
/// `lastIndexOfScalar(':')`) and into the Firestore document path.
/// The accepted set is `[A-Za-z0-9_.\-]`:
///
///   - `:` is **banned** — it's the WAL delimiter for update_balance;
///     a malicious id like `victim:delta=999999999` would forge
///     sibling fields when the WAL is read back.
///   - `/` and `\` are **banned** — both are path separators in
///     Firestore / filesystem contexts.
///   - whitespace, quote, and control characters are banned for
///     defense-in-depth against any future serializer that doesn't
///     escape (the JSON path is already safe via std.json.Stringify
///     after Batch 13, but a third format could land later).
///   - `.` is **allowed** — Apple Sign In subjects are documented as
///     containing a dot (e.g. `001234.abcdef.0987`). The WAL parser
///     uses `lastIndexOfScalar(':')` so dots in the prefix do not
///     break delimiter recovery.
///
/// Length is bounded at 64 (max_account_id_len) so
/// `FixedStr64.fromSlice` never has to truncate. Apply at every
/// entry point that mints an account_id from user-controlled data:
/// admin POST /accounts, Apple Sign In sub, Google Sign In sub.
pub fn validateAccountId(id: []const u8) ?[]const u8 {
    if (id.len == 0 or id.len > max_account_id_len) return null;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '-' or c == '_' or c == '.') continue;
        return null;
    }
    return id;
}

// ── Request limits ──────────────────────────────────────────

pub const Limits = struct {
    pub const max_chat_body: usize = 1 * 1024 * 1024; // 1MB for chat
    pub const max_agent_body: usize = 256 * 1024; // 256KB for agent
    pub const max_generic_body: usize = 10 * 1024 * 1024; // 10MB fallback
    pub const max_messages: usize = 200; // Max messages in chat context
    pub const max_agent_iterations: u32 = 50; // Agent loop cap
    pub const max_model_name: usize = 128; // Model name length
    /// Per-connection keep-alive request cap. Audit M15: previously
    /// 1000, which combined with the 30s Slowloris idle timeout from
    /// H5 let a single bot hold a worker for ≤30000s (~8 hours) by
    /// drip-feeding bodyless requests. Lowered to 100 (typical web
    /// server default) so the upper bound on a single connection is
    /// ~100 × 30s = ~50 minutes — also bounded by the connection
    /// lifetime cap below, whichever fires first.
    pub const max_requests_per_conn: u32 = 100;
    /// Per-connection total lifetime cap in milliseconds. Audit M15:
    /// SO_RCVTIMEO bounds *idle* time per recv; this bounds *total*
    /// connection time so a bot that keeps issuing 1-byte recv
    /// activity every 29s can't pin a worker for hours. After this
    /// elapses we close the connection regardless of keep-alive.
    pub const max_conn_lifetime_ms: i64 = 5 * 60 * 1000;
    pub const max_tokens_cap: u32 = 128_000; // Max tokens any request can ask for
    /// Maximum response headers emitted by the per-request handler.
    /// Audit M1: previously a fixed `[8]http.Header` with silent
    /// truncation on overflow; if a new endpoint or CORS path pushes
    /// the count past the cap, the missing headers (Set-Cookie, etc.)
    /// would never reach the client. The handler now treats overflow
    /// as a 500 instead of silently dropping. 16 is chosen so the
    /// preflight assembly (handler headers + req-id + CORS reflected
    /// origin + Vary + ACAM + ACAH) fits with room for future
    /// additions.
    pub const max_response_headers: usize = 16;
};
