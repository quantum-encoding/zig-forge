//! zterm — standalone mux server + CLI for terminal_mux, mirroring the `wezterm cli` verbs so the agent
//! ecosystem (mac-drive / imsg bridge / the roster / baton) can drive the Zig terminal exactly as it drives
//! WezTerm — with no WezTerm installed.
//!
//! One binary, `zterm` (terminal_mux):
//!   - `zterm` / `zterm new` — the VISIBLE multiplexer in this terminal
//!     (src/main.zig). It binds the control socket too (src/ctl.zig), so
//!     `zterm cli` drives it: list/send/enter/capture plus `split h|v`,
//!     `new-window`, `focus <pane>` — the wezterm-cli model.
//!   - `zterm server` — a HEADLESS pane pool (this file), for agents that need
//!     invisible shells. It is also a baton RUNNER (see "Runner door" below).
//!   Newest binder wins the default path; $ZTERM_SOCKET targets a specific one.
//!
//! Persistent sessions (the tmux detach guarantee): the SERVER owns the
//! shells; `zterm attach <pane>` is a disposable raw window onto one. Close
//! the terminal, reattach later — the shell never notices. Ctrl-b d detaches.
//!
//! Test loop (two terminals):
//!     zterm server                 # headless pool (or run bare `zterm` for the visible mux)
//!     zterm attach 1               # raw window onto pane 1; Ctrl-b d detaches
//!     zterm cli list               # → [{"pane":1,...}]
//!     zterm cli spawn              # → {"ok":true,"pane":2}
//!     zterm cli send <id> "ls -la" # type into a pane (no implicit Enter)
//!     zterm cli send <id> -- ls -la  # JSON path: binary-safe, submits with Enter
//!     zterm cli capture <id>       # dump the pane's grid as text  (get-text)
//!     zterm cli kill <id>
//!
//! ## Wire protocol — one request line in, one response, then close
//!
//! Three request shapes share every socket this server listens on; the first
//! byte and the first key decide which:
//!
//!   * line   `"<cmd> <args...>\n"` — hand-typed use. list/spawn/send/enter/
//!            capture/kill/attach. `attach` turns the connection into a raw
//!            PTY relay instead of closing it.
//!   * `{"cmd":...}` — the JSON control protocol, shared with ctl.zig (the
//!            visible mux). Binary-safe text, options, JSON answers:
//!              list
//!              spawn   {cwd?, name?, run?, rows?, cols?}      → {ok, pane}
//!              send    {pane, text, paste?, enter?}           → {ok, bytes, entered}
//!              enter   {pane}
//!              capture {pane, lines?, escapes?}              → plain text
//!              kill    {pane}
//!              title   {pane, title}                          (sets the designation)
//!              resize  {pane, rows, cols}
//!   * `{"verb":...}` — baton's RUNNER CONTRACT (baton src/runner/contract.rs):
//!              hello, status, list, send, stop.
//!
//! ## Running it
//!
//! As a SERVICE, not from inside an agent's session. baton's Linux payload
//! installs it as the `baton-zterm.service` systemd user unit (see baton's
//! scripts/install-linux.sh); anything equivalent works. Two reasons:
//!   * On a box with Guardian Shield in agent-containment mode, a process
//!     started from an agent's tree inherits the agent tag and cannot unlink
//!     under $HOME — so zterm could not remove its own socket on shutdown and
//!     the next start would find the door taken. Started by systemd it can.
//!   * It owns the shells agents run in. Its lifetime is the host's, not the
//!     lifetime of whichever session happened to start it.
//! With no $SHELL (a service need not have one) panes get the account's login
//! shell from passwd. Every pane gets `ZTERM_PANE=<id>` so a program inside
//! it (an agent's SessionStart hook) can name the pane it is in; baton
//! addresses zterm pane n as 1000000+n (baton src/wez/zterm.rs).
//!
//! ## Runner door
//!
//! baton finds runner `<name>` at `<fleet home>/var/<name>.sock`, where the
//! fleet home is `$BATON_HOME`, else `~/.baton` if that directory exists
//! (baton src/config/home.rs `home_base_live`). `zterm server` binds
//! `zterm.sock` there as well as its control socket, so `baton runner list`
//! sees it with zero configuration. `--no-runner` opts out; `--runner-socket`
//! or `$ZTERM_RUNNER_SOCKET` names another path.
//!
//! What the runner declares, and does not:
//!   * It hosts no transcript, so it never claims `observe_consumption`. A
//!     delivery tops out at `written` — bytes the PTY accepted — which is a
//!     true statement about a weaker door.
//!   * `send` goes only to a pane whose FOREGROUND process is an agent
//!     (claude, codex, agy, rust-agent-tui; `$BATON_AGENT_EXES` replaces the
//!     list, exactly as in baton). A pane sitting at a shell prompt FAILS with
//!     the door named: a peer's prose must never land in a shell as commands.
//!   * It does not `dispatch`. Launching a harness is baton's knowledge, and
//!     baton already does it through the pane verbs (spawn + send), which this
//!     server answers.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const capi = @import("capi.zig");
const pty = @import("pty.zig");
const ctl = @import("ctl.zig");
const session = @import("session.zig");
const visible = @import("main.zig");
const view = @import("view.zig");
const config = @import("config.zig");

pub const VERSION = "0.3.0";

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

/// The foreground process group of the terminal behind `fd`. On a PTY master
/// this is the slave's foreground job — the program the user would be typing
/// into — on both Linux and Darwin.
extern "c" fn tcgetpgrp(fd: c_int) c.pid_t;
/// libproc (Darwin): a process's short name. Only referenced on Darwin.
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
/// std.c has no signal(3) on this toolchain; same declaration as main.zig.
const SignalHandler = ?*const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SignalHandler) SignalHandler;

pub const RUNNER_NAME = "zterm";
/// The runner-contract version this server speaks (baton's TestRunner is 2).
pub const CONTRACT_VERSION = 2;
/// Largest request line accepted. A brief pasted through `send` is the big
/// case; anything past this is a mistake or an attack, not a message.
const MAX_REQUEST: usize = 8 << 20;
/// Designations are addresses, not prose.
const NAME_MAX: usize = 64;
/// baton's DEFAULT_AGENT_EXES (src/wez/driver.rs), verbatim. Interpreters such
/// as `node` are deliberately absent: an injected message would run as code.
const DEFAULT_AGENT_EXES = [_][]const u8{
    "claude",         "claude.exe",
    "codex",          "codex.exe",
    "agy",            "agy.exe",
    "rust-agent-tui", "rust-agent-tui.exe",
};

// ══ small I/O helpers ═════════════════════════════════════════════════════════════════════════════════

// std.posix (zig 0.16) only exposes read/poll for these; accept/write/close live in std.c.
fn pwrite(fd: c.fd_t, bytes: []const u8) !usize {
    const r = c.write(fd, bytes.ptr, bytes.len);
    if (r < 0) return error.WriteFailed;
    return @intCast(r);
}

/// Write everything or give up. Request connections carry a send timeout, so
/// a client that stops reading cannot hold the loop longer than that.
fn cwrite(fd: c.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (r <= 0) return;
        off += @intCast(r);
    }
}

fn paccept(lfd: c.fd_t) !c.fd_t {
    const f = pty.cloexecUnderLock(c.accept, .{ lfd, null, null });
    if (f < 0) return error.AcceptFailed;
    return f;
}
// Server sockets stay out of spawned shells: `spawn` forks a shell while the
// client connection is open; without CLOEXEC the child inherits the socket,
// the server's close is no longer the last close, and the client — which
// frames the response by EOF — hangs until that shell exits. macOS has no
// accept4/SOCK_CLOEXEC, so every socket is created through
// `pty.cloexecUnderLock`, which holds the lock `Pty.spawnIn` forks under.
fn pclose(fd: c.fd_t) void {
    _ = c.close(fd);
}

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.sliceTo(v, 0);
    return if (s.len == 0) null else s;
}

fn isDirectory(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = c.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

// ══ pure protocol logic (unit-tested below, no PTY needed) ════════════════════════════════════════════

/// Where baton looks for this runner, given the environment it would see.
/// Mirrors baton's `home_base` (src/config/home.rs) exactly: `$BATON_HOME`
/// when set and non-empty, else `$HOME/.baton` when that directory EXISTS,
/// else no fleet home. An explicit override wins over both.
pub fn runnerSocketPathFrom(
    alloc: std.mem.Allocator,
    override: ?[]const u8,
    baton_home: ?[]const u8,
    home: ?[]const u8,
    baton_dir_present: bool,
) !?[:0]u8 {
    if (override) |o| return try alloc.dupeSentinel(u8, o, 0);
    if (baton_home) |b| return try std.fmt.allocPrintSentinel(alloc, "{s}/var/{s}.sock", .{ b, RUNNER_NAME }, 0);
    if (baton_dir_present) {
        if (home) |h| return try std.fmt.allocPrintSentinel(alloc, "{s}/.baton/var/{s}.sock", .{ h, RUNNER_NAME }, 0);
    }
    return null;
}

/// What a paste may carry — baton's `scrub_for_paste` (src/wez/driver.rs),
/// ported so a message typed by THIS door obeys the same rule as one typed by
/// baton's: printable text, `\n` and `\t`. ESC, the other C0 controls, DEL and
/// the C1 range are dropped (they include the bracketed-paste terminator that
/// would end a paste early and let the rest arrive as keystrokes); `\r\n` and
/// `\r` become `\n`. Invalid UTF-8 bytes are dropped rather than guessed at.
pub fn scrubForPaste(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len); // output never exceeds input
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            switch (b) {
                '\r' => {
                    if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                    try out.append(alloc, '\n');
                },
                '\n', '\t' => try out.append(alloc, b),
                0...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F => {},
                else => try out.append(alloc, b),
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (cp < 0x80 or (cp >= 0x80 and cp <= 0x9F)) {
            i += len; // C1 control (or an overlong ASCII) — never typed
            continue;
        }
        try out.appendSlice(alloc, text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(alloc);
}

/// baton's `format_injection`: the provenance header every injected federation
/// message carries, so the agent reading it knows who is speaking.
pub fn formatInjection(alloc: std.mem.Allocator, from_node: []const u8, from_agent: []const u8, body: []const u8) ![]u8 {
    if (from_node.len > 0 and from_agent.len > 0)
        return std.fmt.allocPrint(alloc, "[federation msg — {s}/{s}] {s}", .{ from_node, from_agent, body });
    if (from_node.len > 0) return std.fmt.allocPrint(alloc, "[federation msg — {s}] {s}", .{ from_node, body });
    if (from_agent.len > 0) return std.fmt.allocPrint(alloc, "[federation msg — {s}] {s}", .{ from_agent, body });
    return std.fmt.allocPrint(alloc, "[federation msg — unknown] {s}", .{body});
}

/// baton's `settle_micros`: the CEILING on how long to wait between a paste
/// and its submitting CR. A too-early CR is absorbed into a large bracketed
/// paste and the message stages but never sends. 250ms + 0.3ms/byte, capped
/// at 1.2s. Evidence (`pasteLanded`) usually ends the wait far sooner.
pub fn settleNs(text_len: usize) u64 {
    const us = std.math.clamp(@as(u64, text_len) * 300, 250_000, 1_200_000);
    return us * std.time.ns_per_us;
}

/// Collapse every whitespace run to one space and trim — the composer wraps
/// long lines, so raw substring matching fails on anything wide.
pub fn normalizeWs(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0b\x0c");
    var first = true;
    while (it.next()) |w| {
        if (!first) try out.append(alloc, ' ');
        try out.appendSlice(alloc, w);
        first = false;
    }
    return out.toOwnedSlice(alloc);
}

/// The last 48 codepoints of an already-normalized payload — what must appear
/// on screen for a paste to count as landed.
pub fn tailOf(norm: []const u8) []const u8 {
    var count: usize = 0;
    var i: usize = norm.len;
    while (i > 0 and count < 48) {
        i -= 1;
        // Step back over continuation bytes to the start of the codepoint.
        while (i > 0 and (norm[i] & 0xC0) == 0x80) i -= 1;
        count += 1;
    }
    return norm[i..];
}

/// baton's `paste_landed`, against normalized screens: the payload's tail is
/// visible now and was not before, or a Claude Code paste placeholder
/// appeared. "Was not before" is what makes it evidence rather than a guess.
pub fn pasteLanded(before: []const u8, now: []const u8, tail: []const u8) bool {
    const placeholder = "[Pasted text";
    if (std.mem.count(u8, now, placeholder) > std.mem.count(u8, before, placeholder)) return true;
    if (tail.len == 0) return true;
    return std.mem.indexOf(u8, now, tail) != null and std.mem.indexOf(u8, before, tail) == null;
}

/// A designation: 1..64 bytes of `[A-Za-z0-9._@-]`. It is an address typed
/// into CLIs and messages, and `pid:` is reserved for baton's process form.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX) return false;
    if (std.ascii.startsWithIgnoreCase(name, "pid:")) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '@', '-' => {},
        else => return false,
    };
    return true;
}

/// Bounds on a spawn's `env`: a front end passes a handful of variables
/// (shell integration), not an environment.
pub const SPAWN_ENV_MAX_VARS: usize = 32;
pub const SPAWN_ENV_MAX_KEY: usize = 64;
pub const SPAWN_ENV_MAX_VALUE: usize = 4096;

/// An environment variable name a spawn may set: `[A-Z_][A-Z0-9_]*`, at most
/// SPAWN_ENV_MAX_KEY bytes, and not a pane-identity variable (`ZTERM_PANE` is
/// the server's to set; `WEZTERM_PANE` would name somebody else's pane).
pub fn validEnvKey(key: []const u8) bool {
    if (key.len == 0 or key.len > SPAWN_ENV_MAX_KEY) return false;
    if (!(std.ascii.isUpper(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |ch| if (!(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    if (std.mem.eql(u8, key, "ZTERM_PANE") or std.mem.eql(u8, key, "WEZTERM_PANE")) return false;
    return true;
}

/// A spawn request's `env` object as owned "KEY=value" entries for the
/// child's environment, or null with `why` set. Everything is checked before
/// anything is kept: a request is applied whole or refused whole.
pub fn parseSpawnEnv(alloc: std.mem.Allocator, env: std.json.Value, why: *[]const u8) ?[][:0]u8 {
    if (env != .object) {
        why.* = "env must be an object of string values";
        return null;
    }
    const map = env.object;
    if (map.count() > SPAWN_ENV_MAX_VARS) {
        why.* = "env has more than 32 variables";
        return null;
    }
    var it = map.iterator();
    while (it.next()) |kv| {
        if (!validEnvKey(kv.key_ptr.*)) {
            why.* = "env keys must be 1-64 characters of [A-Z0-9_], not starting with a digit, and not ZTERM_PANE or WEZTERM_PANE";
            return null;
        }
        const val = switch (kv.value_ptr.*) {
            .string => |x| x,
            else => {
                why.* = "env values must be strings";
                return null;
            },
        };
        if (val.len > SPAWN_ENV_MAX_VALUE or std.mem.indexOfScalar(u8, val, 0) != null) {
            why.* = "env values must be at most 4096 bytes with no NUL";
            return null;
        }
    }
    const out = alloc.alloc([:0]u8, map.count()) catch {
        why.* = "out of memory";
        return null;
    };
    var made: usize = 0;
    it = map.iterator();
    while (it.next()) |kv| : (made += 1) {
        out[made] = std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.string }, 0) catch {
            freeSpawnEnv(alloc, out[0..made]);
            alloc.free(out);
            why.* = "out of memory";
            return null;
        };
    }
    return out;
}

pub fn freeSpawnEnv(alloc: std.mem.Allocator, entries: []const [:0]u8) void {
    for (entries) |e| alloc.free(e);
}

/// baton's `Session::answers_to`: a designation (any case), or `pid:<n>` for
/// the session whose process is n. A bare number is a designation, never a
/// pid, and pid 0 ("unknown") answers to nothing.
pub fn answersTo(designation: []const u8, pid: i64, address: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(address, "pid:")) {
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, address[4..], " "), 10) catch return false;
        return n > 0 and n == pid;
    }
    return std.ascii.eqlIgnoreCase(designation, address);
}

/// Is `comm` one of the allowed agent executables? Basename compare; an empty
/// name never matches. `allowed` is `$BATON_AGENT_EXES` (comma-separated) when
/// set, else baton's default list — one rule for both doors.
pub fn isAgentComm(comm: []const u8, env_list: ?[]const u8) bool {
    const base_full = std.mem.trim(u8, comm, " \t\r\n");
    const base = if (std.mem.lastIndexOfScalar(u8, base_full, '/')) |k| base_full[k + 1 ..] else base_full;
    if (base.len == 0) return false;
    if (env_list) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |raw| {
            if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), base)) return true;
        }
        return false;
    }
    for (DEFAULT_AGENT_EXES) |a| if (std.mem.eql(u8, a, base)) return true;
    return false;
}

// ══ process introspection ═════════════════════════════════════════════════════════════════════════════

/// A process's short name (Linux /proc/<pid>/comm, Darwin proc_name). Null
/// when unreadable — callers treat that as "not an agent" (fail closed).
fn procComm(pid: c.pid_t, buf: []u8) ?[]const u8 {
    if (pid <= 0) return null;
    if (comptime is_linux) {
        var pb: [48]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/comm", .{pid}, 0) catch return null;
        const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return null;
        defer _ = c.close(fd);
        const n = c.read(fd, buf.ptr, buf.len);
        if (n <= 0) return null;
        return std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n");
    } else if (comptime is_darwin) {
        const n = proc_name(pid, buf.ptr, @intCast(buf.len));
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    } else {
        return null;
    }
}

/// A process's live working directory. Linux only (/proc); elsewhere the
/// caller falls back to the directory the pane was spawned in.
fn procCwd(pid: c.pid_t, buf: []u8) ?[]const u8 {
    if (comptime !is_linux) return null;
    if (pid <= 0) return null;
    var pb: [48]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/cwd", .{pid}, 0) catch return null;
    const n = c.readlink(path.ptr, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

// ══ SERVER ════════════════════════════════════════════════════════════════════════════════════════════

const Pane = struct {
    id: u64,
    handle: *capi.TmuxSession,
    fd: c.fd_t,
    /// The designation, when one was given (spawn `name`, or `title`). Owned.
    name: ?[]u8 = null,
    /// The master reported EOF/HUP: stop polling it (it would report HUP on
    /// every poll forever and spin the loop). Exit status is read lazily.
    hup: bool = false,
    /// When `hup` was first seen (monotonic ms), to bound the wait for the
    /// child to be reaped before viewers are told it exited.
    hup_ms: i64 = 0,
    /// Counts the inputs, focus changes and resizes clients have sent this
    /// pane. A viewer whose last frame predates the latest one is owed an
    /// unpaced frame: someone is waiting to see the result.
    input_seq: u64 = 0,

    fn noteInput(self: *Pane) void {
        self.input_seq +%= 1;
    }

    fn spane(self: *const Pane) *session.Pane {
        return self.handle.sess.getActiveWindow().getActivePane();
    }

    fn childPid(self: *const Pane) c.pid_t {
        const p = self.spane();
        if (p.pty) |pt| if (pt.child_pid) |cp| return cp;
        return 0;
    }

    fn alive(self: *const Pane) bool {
        return self.spane().isAlive();
    }

    fn foregroundPgid(self: *const Pane) c.pid_t {
        const pg = tcgetpgrp(self.fd);
        return if (pg > 0) pg else 0;
    }

    fn designation(self: *const Pane, buf: []u8) []const u8 {
        if (self.name) |n| return n;
        return std.fmt.bufPrint(buf, "zterm-{d}", .{self.id}) catch "zterm-?";
    }
};

/// A live `zterm attach` connection: raw PTY passthrough for one pane. The
/// pane's output broadcasts to every attach; attach input writes to the pane.
/// conn == -1 marks a dead entry awaiting the sweep.
const Attach = struct { conn: c.fd_t, pane_id: u64 };

/// A `view` connection (docs/VIEW-PROTOCOL.md): frames out, input in, on one
/// non-blocking socket. STATE-SYNCED: a frame is built only when the previous
/// one is fully written, and changes made meanwhile accumulate in `dirty`, so
/// a slow client never blocks the server, is never dropped, and converges on
/// the latest state. conn == -1 marks a dead entry awaiting the sweep.
const Viewer = struct {
    conn: c.fd_t,
    pane_id: u64,
    seq: u64 = 0,
    /// Bytes owed to the client, from `out_off`.
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    /// An input line still arriving.
    inbuf: std.ArrayList(u8) = .empty,
    /// Rows changed since this client's last frame.
    dirty: std.DynamicBitSetUnmanaged = .{},
    /// Next frame carries every row (first frame, resize, overflow).
    full: bool = true,
    /// Something visible (rows, cursor, modes, title) may have moved.
    changed: bool = true,
    exit_sent: bool = false,
    /// Close once `out` drains (the pane was killed).
    closing: bool = false,
    /// When this client's last frame was built (monotonic ms; 0 = never), for
    /// frame pacing (`Server.frame_ms`).
    last_frame_ms: i64 = 0,
    /// The pane's `input_seq` when this client's last frame was built.
    answered_input: u64 = 0,
    /// OSC 133 marks this client is owed: every mark on lines >= this, sent
    /// ahead of the next frame (docs/VIEW-PROTOCOL.md `marks`). Starts at the
    /// bottom of i64 — the whole set — and returns there when a backlog that
    /// may have held a `marks` message is discarded.
    marks_from: ?i64 = std.math.minInt(i64),

    /// Close and release. Idempotent: a viewer can die where it is found
    /// dead and again at the sweep.
    fn deinit(self: *Viewer, alloc: std.mem.Allocator) void {
        if (self.conn >= 0) pclose(self.conn);
        self.conn = -1;
        self.out.deinit(alloc);
        self.out = .empty;
        self.out_off = 0;
        self.inbuf.deinit(alloc);
        self.inbuf = .empty;
        self.dirty.deinit(alloc);
        self.dirty = .{};
    }

    fn pending(self: *const Viewer) bool {
        return self.out.items.len > self.out_off;
    }
};

/// Unsent output a viewer may accumulate from events (bell, clipboard,
/// history) before the backlog is discarded and the client is resynced with
/// a full frame. Frames themselves never pile up — see `Viewer`.
const VIEW_OUT_CAP: usize = 8 << 20;
/// Longest input line a viewer may send (a large paste).
const VIEW_IN_CAP: usize = 8 << 20;

/// A text delivery in flight: paste now, submit (CR) once the paste has
/// visibly landed or the settle ceiling passes. Held on the event loop rather
/// than slept through, so one slow submit never freezes the other panes. The
/// requester's connection stays open and gets its answer only when the CR is
/// written — a reply that says "written" before the submit would be a claim
/// about something that has not happened yet.
const Submit = struct {
    pane_id: u64,
    conn: c.fd_t,
    proto: enum { runner, cmd },
    /// What to type. Owned.
    payload: []u8,
    paste: bool,
    enter: bool,
    state: enum { queued, pasted } = .queued,
    deadline: u64 = 0,
    next_check: u64 = 0,
    /// Normalized screen before the paste, and the normalized payload tail. Owned.
    before: []u8 = &.{},
    tail: []u8 = &.{},
    landed: bool = false,
    written: usize = 0,
};

/// A bound socket. `ident` is the (dev, inode) of the path as bound, so
/// shutdown can tell whether the path is still OURS: the control path is
/// newest-binder-wins by design, and an older server exiting must not unlink
/// the socket a newer one has since bound there — that leaves the newer
/// server running and unreachable.
const Listener = struct { fd: c.fd_t, path: [:0]u8, kind: enum { control, runner }, ident: ?PathIdent };

const PathIdent = struct { dev: u64, ino: u64 };

fn pathIdent(path: [*:0]const u8) ?PathIdent {
    // Zig 0.16 declares no std.c.fstatat for Linux (it routes through
    // statx); Darwin and the BSDs get the right $INODE64 symbol from std.c.
    if (comptime is_linux) {
        var stx: std.os.linux.Statx = undefined;
        if (c.statx(c.AT.FDCWD, path, c.AT.SYMLINK_NOFOLLOW, .{ .INO = true }, &stx) != 0) return null;
        return .{ .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .ino = stx.ino };
    }
    var st: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    // dev_t is signed on Darwin/BSD: reinterpret, never @intCast — it is an
    // identity key, not a number (same rule as zdedupe/src/pstat.zig).
    return .{ .dev = @bitCast(@as(i64, st.dev)), .ino = @intCast(st.ino) };
}

/// Unlink `l.path` only while it still names the socket `l` bound. The check
/// and the unlink are two steps, so a successor binding in between can still
/// lose its path; that window is microseconds wide, where the old behaviour
/// lost it every time an older server exited.
fn unlinkIfOurs(l: Listener) void {
    const mine = l.ident orelse return;
    const now = pathIdent(l.path.ptr) orelse return;
    if (now.dev != mine.dev or now.ino != mine.ino) return;
    if (c.unlink(l.path.ptr) != 0) {
        // Say so: a door left on disk makes the NEXT server's bind fail.
        std.debug.print("zterm server: could not remove {s} ({s}); the next server cannot bind it until it is removed\n", .{ l.path, @tagName(posix.errno(-1)) });
    }
}

pub const ServerOptions = struct {
    /// false = never bind a runner door (`--no-runner`).
    runner: bool = true,
    /// An explicit runner socket path (`--runner-socket`), else resolved.
    runner_path: ?[]const u8 = null,
    /// Minimum ms between two frames to one viewer (`--frame-ms`); 0 = a
    /// frame for every read of pane output, the pre-pacing behaviour.
    frame_ms: u32 = DEFAULT_FRAME_MS,
};

/// ~120 Hz: at or above most displays' refresh, so pacing costs no visible
/// latency, while a pane streaming output is sent as ~120 frames a second
/// instead of one per PTY read (2000-5000/s measured: bench/runs).
pub const DEFAULT_FRAME_MS: u32 = 8;


var stop_requested = std.atomic.Value(bool).init(false);
fn onStopSignal(_: c_int) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

const Server = struct {
    alloc: std.mem.Allocator,
    pid: c.pid_t,
    panes: std.ArrayList(Pane) = .empty,
    attaches: std.ArrayList(Attach) = .empty,
    submits: std.ArrayList(Submit) = .empty,
    viewers: std.ArrayList(Viewer) = .empty,
    listeners: std.ArrayList(Listener) = .empty,
    agent_env: ?[]const u8,
    /// Frame pacing interval (ServerOptions.frame_ms).
    frame_ms: i64 = DEFAULT_FRAME_MS,
    /// Bytes a client sent after its request line, for a request that turns
    /// the connection into a stream (`view`): they are its first input.
    trailing: []const u8 = &.{},

    fn deinit(self: *Server) void {
        // Doors first: once the loop has stopped nothing answers them, and a
        // pane teardown that stalls or dies must not leave a dead door that
        // callers keep probing.
        for (self.listeners.items) |l| {
            pclose(l.fd);
            unlinkIfOurs(l);
        }
        for (self.submits.items) |*s| self.finishSubmit(s, false, "zterm server is shutting down");
        self.submits.deinit(self.alloc);
        for (self.attaches.items) |a| if (a.conn >= 0) pclose(a.conn);
        self.attaches.deinit(self.alloc);
        for (self.viewers.items) |*v| v.deinit(self.alloc);
        self.viewers.deinit(self.alloc);
        for (self.panes.items) |p| {
            capi.tmux_destroy(p.handle);
            if (p.name) |n| self.alloc.free(n);
        }
        self.panes.deinit(self.alloc);
        for (self.listeners.items) |l| self.alloc.free(l.path);
        self.listeners.deinit(self.alloc);
    }

    // ── listeners ────────────────────────────────────────────────────────────────────────────────────

    fn listenOn(self: *Server, path: [:0]u8, kind: @FieldType(Listener, "kind")) !void {
        var addr = ctl.fillAddr(path) catch |e| {
            std.debug.print("zterm server: socket path is {d} bytes, longer than sun_path allows: {s}\n", .{ path.len, path });
            return e;
        };
        // Clear a stale socket. A refusal here (EPERM from a filesystem
        // policy such as Guardian Shield) would otherwise surface as an
        // opaque BindFailed; name it instead.
        if (c.unlink(path.ptr) != 0) switch (posix.errno(-1)) {
            .NOENT => {},
            else => |e| {
                std.debug.print("zterm server: a stale socket at {s} cannot be removed ({s}); remove it and restart\n", .{ path, @tagName(e) });
                return error.StaleSocketUnremovable;
            },
        };
        const lfd = pty.cloexecUnderLock(c.socket, .{ c.AF.UNIX, c.SOCK.STREAM, @as(c_uint, 0) });
        if (lfd < 0) return error.SocketCreateFailed;
        errdefer pclose(lfd);
        if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) {
            std.debug.print("zterm server: cannot bind {s} ({s})\n", .{ path, @tagName(posix.errno(-1)) });
            return error.BindFailed;
        }
        // Owner-only (matches ctl.zig): any local user on a 0755 socket could
        // spawn shells and type into them.
        _ = c.chmod(path.ptr, 0o600);
        if (c.listen(lfd, 16) < 0) return error.ListenFailed;
        try self.listeners.append(self.alloc, .{ .fd = lfd, .path = path, .kind = kind, .ident = pathIdent(path.ptr) });
    }

    /// Is a server already answering at `path`? A connect is the whole test —
    /// the listener dies with its process, so this cannot be stale.
    fn socketIsLive(path: []const u8) bool {
        var addr = ctl.fillAddr(path) catch return false;
        const fd = pty.cloexecUnderLock(c.socket, .{ c.AF.UNIX, c.SOCK.STREAM, @as(c_uint, 0) });
        if (fd < 0) return false;
        defer pclose(fd);
        return c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) == 0;
    }

    /// Bind the runner door, unless another zterm already holds it. Unlike the
    /// control socket (newest binder wins, by design), stealing a LIVE runner
    /// door would make every session of the older server invisible to baton
    /// while it keeps running them — a silent loss of addressability.
    fn bindRunnerDoor(self: *Server, opts: ServerOptions) !void {
        if (!opts.runner) return;
        const home = envSlice("HOME");
        const baton_home = envSlice("BATON_HOME");
        const present = if (home) |h| blk: {
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const d = std.fmt.bufPrint(&pb, "{s}/.baton", .{h}) catch break :blk false;
            break :blk isDirectory(d);
        } else false;
        const override = opts.runner_path orelse envSlice("ZTERM_RUNNER_SOCKET");
        const path = (try runnerSocketPathFrom(self.alloc, override, baton_home, home, present)) orelse {
            std.debug.print("zterm server: no baton fleet home ($BATON_HOME or ~/.baton) — serving without a runner door\n", .{});
            return;
        };
        errdefer self.alloc.free(path);
        // baton creates var/ on init; make sure it exists before binding into it.
        if (std.fs.path.dirname(path)) |dir| {
            var db: [std.fs.max_path_bytes + 1]u8 = undefined;
            if (dir.len <= std.fs.max_path_bytes) {
                @memcpy(db[0..dir.len], dir);
                db[dir.len] = 0;
                _ = c.mkdir(@ptrCast(&db), 0o700);
            }
        }
        if (socketIsLive(path)) {
            std.debug.print("zterm server: another runner already answers at {s} — not taking the runner door\n", .{path});
            self.alloc.free(path);
            return;
        }
        try self.listenOn(path, .runner);
        std.debug.print("zterm server: runner door (baton) on {s}\n", .{path});
    }

    // ── panes ────────────────────────────────────────────────────────────────────────────────────────

    fn findPane(self: *Server, id: u64) ?*Pane {
        for (self.panes.items) |*p| if (p.id == id) return p;
        return null;
    }

    fn nameTaken(self: *Server, name: []const u8, except: u64) bool {
        var db: [32]u8 = undefined;
        for (self.panes.items) |*p| {
            if (p.id == except) continue;
            if (std.ascii.eqlIgnoreCase(p.designation(&db), name)) return true;
        }
        return false;
    }

    const SpawnOpts = struct {
        rows: u16 = 40,
        cols: u16 = 120,
        cwd: ?[]const u8 = null,
        name: ?[]const u8 = null,
        run: ?[]const u8 = null,
        /// Extra "KEY=value" entries for this pane's environment only
        /// (`parseSpawnEnv`).
        env: []const [:0]const u8 = &.{},
    };

    /// Spawn a pane. Returns the pane id, or a sentence saying why not.
    fn spawn(self: *Server, o: SpawnOpts, why: *[]const u8) ?u64 {
        if (o.cwd) |d| {
            if (!std.fs.path.isAbsolute(d) or !isDirectory(d)) {
                why.* = "cwd is not an absolute path to an existing directory";
                return null;
            }
        }
        if (o.name) |n| {
            if (!validName(n)) {
                why.* = "name must be 1-64 characters of [A-Za-z0-9._@-] and not start with 'pid:'";
                return null;
            }
            if (self.nameTaken(n, 0)) {
                why.* = "that name is already a designation here";
                return null;
            }
        }
        if (o.run) |r| if (r.len > 1024) {
            why.* = "run command longer than 1024 bytes (send it after spawn instead)";
            return null;
        };
        const name_copy: ?[]u8 = if (o.name) |n| (self.alloc.dupe(u8, n) catch {
            why.* = "out of memory";
            return null;
        }) else null;
        var id: u64 = 0;
        const h = capi.createIn(o.rows, o.cols, null, o.cwd, true, o.env, &id) orelse {
            if (name_copy) |n| self.alloc.free(n);
            why.* = "could not start a shell in a new PTY";
            return null;
        };
        const fd = capi.tmux_pty_fd(h);
        self.panes.append(self.alloc, .{ .id = id, .handle = h, .fd = fd, .name = name_copy }) catch {
            capi.tmux_destroy(h);
            if (name_copy) |n| self.alloc.free(n);
            why.* = "out of memory";
            return null;
        };
        const sp = h.sess.getActiveWindow().getActivePane();
        if (o.cwd == null) {
            // Inherited: record where the shell actually started, so `list`
            // has an answer where the live cwd cannot be read (no /proc on
            // Darwin; /proc/<pid>/cwd can be denied by policy on Linux).
            if (c.getcwd(&sp.cwd, sp.cwd.len)) |_| {
                sp.cwd_len = std.mem.indexOfScalar(u8, &sp.cwd, 0) orelse 0;
            }
        }
        if (o.run) |r| if (r.len > 0) sp.setBootCommand(r);
        return id;
    }

    fn killPane(self: *Server, id: u64) bool {
        for (self.panes.items, 0..) |p, idx| {
            if (p.id != id) continue;
            // Anything still waiting to be typed into it fails by name.
            for (self.submits.items) |*s| if (s.pane_id == id) self.finishSubmit(s, false, "the pane was killed before the message was submitted");
            self.dropFinishedSubmits();
            for (self.viewers.items) |*v| {
                if (v.conn < 0 or v.pane_id != id) continue;
                self.viewerEvent(v, .{ .t = "exit", .pane = id, .killed = true });
                v.exit_sent = true;
                v.closing = true;
            }
            capi.tmux_destroy(p.handle);
            if (p.name) |n| self.alloc.free(n);
            _ = self.panes.orderedRemove(idx);
            return true;
        }
        return false;
    }

    // ── the loop ─────────────────────────────────────────────────────────────────────────────────────

    fn run(self: *Server) !void {
        var pfds: std.ArrayList(posix.pollfd) = .empty;
        defer pfds.deinit(self.alloc);
        var polled_panes: std.ArrayList(u64) = .empty;
        defer polled_panes.deinit(self.alloc);
        var io_buf: [65536]u8 = undefined;

        while (!stop_requested.load(.monotonic)) {
            // Sweep dead attaches before rebuilding the poll set.
            var ai: usize = 0;
            while (ai < self.attaches.items.len) {
                if (self.attaches.items[ai].conn < 0) {
                    _ = self.attaches.orderedRemove(ai);
                } else ai += 1;
            }
            self.advanceSubmits(nowNs());
            // Viewers: flush owed bytes, build frames that are due, drop the dead.
            const view_wake = self.pumpViewers();
            var vi: usize = 0;
            while (vi < self.viewers.items.len) {
                if (self.viewers.items[vi].conn < 0) {
                    var dead = self.viewers.orderedRemove(vi);
                    dead.deinit(self.alloc);
                } else vi += 1;
            }

            pfds.clearRetainingCapacity();
            polled_panes.clearRetainingCapacity();
            for (self.listeners.items) |l| try pfds.append(self.alloc, .{ .fd = l.fd, .events = posix.POLL.IN, .revents = 0 });
            for (self.panes.items) |p| {
                if (p.hup) continue;
                try pfds.append(self.alloc, .{ .fd = p.fd, .events = posix.POLL.IN, .revents = 0 });
                try polled_panes.append(self.alloc, p.id);
            }
            for (self.attaches.items) |a| try pfds.append(self.alloc, .{ .fd = a.conn, .events = posix.POLL.IN, .revents = 0 });
            for (self.viewers.items) |v| {
                const want_out: i16 = if (v.pending()) posix.POLL.OUT else 0;
                try pfds.append(self.alloc, .{ .fd = v.conn, .events = posix.POLL.IN | want_out, .revents = 0 });
            }
            const nl = self.listeners.items.len;
            const np = polled_panes.items.len;
            const attach_count = self.attaches.items.len;
            const viewer_count = self.viewers.items.len;

            // A viewer's held frame wakes the loop when it falls due (pacing,
            // a synchronized update, a pane awaiting its reap); a pending
            // submit is watched for evidence every ~50ms; otherwise wake once
            // a second so a stop signal is noticed.
            var timeout: i32 = if (self.submits.items.len > 0) 50 else 1000;
            if (view_wake) |ms| timeout = @min(timeout, @as(i32, @intCast(std.math.clamp(ms, 1, 1000))));
            _ = posix.poll(pfds.items, timeout) catch continue;

            // Pane output: read the raw bytes ONCE — feed the VT grid (so capture/
            // list stay live) and mirror them to every attached client.
            for (polled_panes.items, 0..) |pid, k| {
                const rev = pfds.items[nl + k].revents;
                if (rev == 0) continue;
                const p = self.findPane(pid) orelse continue;
                if (rev & posix.POLL.IN == 0) {
                    // HUP/ERR with nothing to read: the slave side is closed.
                    if (rev & (posix.POLL.HUP | posix.POLL.ERR) != 0) self.paneHungUp(p);
                    continue;
                }
                // Linux reports a dead child as EIO on the master, macOS as 0
                // bytes; both mean "stop polling this pane".
                const r = posix.read(p.fd, &io_buf) catch |err| {
                    if (err != error.WouldBlock) self.paneHungUp(p);
                    continue;
                };
                if (r == 0) {
                    self.paneHungUp(p);
                    continue;
                }
                p.spane().processOutput(io_buf[0..r]);
                // zterm is this pane's terminal: answer its DA/CPR/OSC 10-11
                // queries — unless a raw-relay attach is open on it, whose own
                // terminal already received the query and answers it. Replies
                // owed to that terminal are dropped, never sent late.
                if (self.hasRawAttach(p.id)) {
                    p.spane().terminal.resp_len = 0;
                } else {
                    p.spane().flushResponses();
                }
                self.notePaneOutput(p);
                for (self.attaches.items) |*a| {
                    if (a.conn < 0 or a.pane_id != p.id) continue;
                    // A stalled attach reader must not block the whole pool.
                    // Bounded write: wait up to 200ms for writability, then
                    // DROP the client — it can reattach and gets a fresh
                    // snapshot; skipping bytes instead would tear its VT stream.
                    relayWrite(a.conn, io_buf[0..r]) catch {
                        pclose(a.conn);
                        a.conn = -1;
                    };
                }
            }

            // Attached clients' keystrokes → their pane. EOF = detach; the pane
            // and its shell keep running — that's the whole point.
            for (self.attaches.items[0..attach_count], 0..) |*a, k| {
                if (a.conn < 0) continue;
                const pf = pfds.items[nl + np + k];
                if (pf.revents & (posix.POLL.IN | posix.POLL.HUP) == 0) continue;
                const r = posix.read(a.conn, &io_buf) catch |err| {
                    if (err == error.WouldBlock) continue; // spurious wakeup on a non-blocking conn
                    pclose(a.conn);
                    a.conn = -1;
                    continue;
                };
                if (r == 0) {
                    pclose(a.conn);
                    a.conn = -1;
                    continue;
                }
                if (self.findPane(a.pane_id)) |p| {
                    _ = capi.tmux_send(p.handle, &io_buf, r);
                    p.noteInput();
                } else {
                    pclose(a.conn);
                    a.conn = -1;
                }
            }

            // Viewers: input lines in; POLLOUT is served by the next pump.
            for (self.viewers.items[0..viewer_count], 0..) |*v, k| {
                if (v.conn < 0) continue;
                const pf = pfds.items[nl + np + attach_count + k];
                if (pf.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
                const r = posix.read(v.conn, &io_buf) catch |err| {
                    if (err == error.WouldBlock) continue;
                    v.deinit(self.alloc);
                    continue;
                };
                if (r == 0) {
                    v.deinit(self.alloc);
                    continue;
                }
                self.viewerInput(v, io_buf[0..r]);
            }

            // Clients with a request (or an attach).
            for (self.listeners.items[0..nl], 0..) |l, k| {
                if ((pfds.items[k].revents & posix.POLL.IN) == 0) continue;
                const conn = paccept(l.fd) catch continue;
                // Without a receive timeout, a client that connects and sends
                // nothing (nc -U) blocks this single-threaded loop forever —
                // every pane stops draining. Same 500ms guard ctl.zig has
                // always had; the send timeout bounds a client that stops
                // reading its answer.
                const rtv = c.timeval{ .sec = 0, .usec = 500_000 };
                _ = c.setsockopt(conn, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&rtv), @sizeOf(c.timeval));
                const stv = c.timeval{ .sec = 2, .usec = 0 };
                _ = c.setsockopt(conn, c.SOL.SOCKET, c.SO.SNDTIMEO, @ptrCast(&stv), @sizeOf(c.timeval));
                const keep = self.handleConn(conn) catch .close;
                if (keep == .close) pclose(conn);
            }
        }
    }

    // ── requests ─────────────────────────────────────────────────────────────────────────────────────

    const Disposition = enum { close, keep };

    /// Read one request line (up to MAX_REQUEST). Returns the line without its
    /// terminator; `rest` receives any bytes that followed the newline.
    fn readRequest(self: *Server, conn: c.fd_t, buf: *std.ArrayList(u8)) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
                var end = nl;
                if (end > 0 and buf.items[end - 1] == '\r') end -= 1;
                return buf.items[0..end];
            }
            if (buf.items.len >= MAX_REQUEST) return error.RequestTooLarge;
            try buf.ensureUnusedCapacity(self.alloc, 65536);
            const room = buf.unusedCapacitySlice();
            const want = @min(room.len, MAX_REQUEST - buf.items.len);
            const n = posix.read(conn, room[0..want]) catch |err| {
                // RCVTIMEO expired: a partial line without its newline is
                // still a request (hand-typed `nc -U` often omits it).
                if (err == error.WouldBlock and buf.items.len > 0) return buf.items;
                return err;
            };
            if (n == 0) return buf.items; // EOF ends the line
            buf.items.len += n;
        }
    }

    fn handleConn(self: *Server, conn: c.fd_t) !Disposition {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        const line = self.readRequest(conn, &buf) catch |err| {
            if (err == error.RequestTooLarge) cwrite(conn, "{\"ok\":false,\"error\":\"request larger than 8 MiB\"}\n");
            return .close;
        };
        if (line.len == 0) return .close;
        self.trailing = if (buf.items.len > line.len + 1) buf.items[line.len + 1 ..] else &.{};
        defer self.trailing = &.{};
        if (line[0] == '{') return self.handleJson(conn, line);
        return self.handleLine(conn, line, buf.items[@min(buf.items.len, line.len + 1)..]);
    }

    /// The hand-typed line protocol. Answers are unchanged from before the
    /// JSON protocol existed, so existing scripts keep working.
    fn handleLine(self: *Server, conn: c.fd_t, line: []const u8, trailing: []const u8) !Disposition {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse return .close;

        if (std.mem.eql(u8, cmd, "list")) {
            try self.writeList(conn);
        } else if (std.mem.eql(u8, cmd, "spawn")) {
            var why: []const u8 = "";
            if (self.spawn(.{}, &why)) |id| {
                self.reply(conn, .{ .ok = true, .pane = id });
            } else self.reply(conn, .{ .ok = false, .@"error" = why });
        } else if (std.mem.eql(u8, cmd, "send")) {
            const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch {
                cwrite(conn, "err usage: send <id> <text>\n");
                return .close;
            };
            const text = it.rest(); // the remainder of the line after "send <id> "
            const p = self.findPane(id) orelse {
                cwrite(conn, "err no such pane\n");
                return .close;
            };
            if (text.len > 0) _ = capi.tmux_send(p.handle, text.ptr, text.len);
            cwrite(conn, "ok\n");
        } else if (std.mem.eql(u8, cmd, "enter")) {
            const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return .close;
            const p = self.findPane(id) orelse {
                cwrite(conn, "err no such pane\n");
                return .close;
            };
            _ = capi.tmux_send(p.handle, "\r", 1);
            cwrite(conn, "ok\n");
        } else if (std.mem.eql(u8, cmd, "capture")) {
            const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return .close;
            const p = self.findPane(id) orelse {
                cwrite(conn, "err no such pane\n");
                return .close;
            };
            try ctl.writeCapture(conn, p.spane(), self.alloc, 0, false);
        } else if (std.mem.eql(u8, cmd, "kill")) {
            const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return .close;
            cwrite(conn, if (self.killPane(id)) "ok\n" else "err no such pane\n");
        } else if (std.mem.eql(u8, cmd, "attach")) {
            // attach <id> [rows cols] — the connection becomes a raw PTY relay
            // until the client hangs up; the pane (and its shell) outlive it.
            const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch {
                cwrite(conn, "err usage: attach <id> [rows cols]\n");
                return .close;
            };
            const p = self.findPane(id) orelse {
                cwrite(conn, "err no such pane\n");
                return .close;
            };
            if (it.next()) |rows_s| {
                if (it.next()) |cols_s| {
                    const rows = std.fmt.parseInt(u16, rows_s, 10) catch 0;
                    const cols = std.fmt.parseInt(u16, cols_s, 10) catch 0;
                    if (rows > 1 and cols > 1) self.resizePane(p, rows, cols);
                }
            }
            try writeSnapshot(conn, p.handle, self.alloc);
            // Keystrokes that raced in behind the attach line belong to the pane.
            if (trailing.len > 0) _ = capi.tmux_send(p.handle, trailing.ptr, trailing.len);
            // Relay writes are bounded (relayWrite); the conn must be non-blocking
            // so a stalled reader surfaces as EAGAIN instead of wedging the loop.
            const fl = c.fcntl(conn, c.F.GETFL, @as(c_int, 0));
            _ = c.fcntl(conn, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
            try self.attaches.append(self.alloc, .{ .conn = conn, .pane_id = id });
            return .keep;
        } else {
            cwrite(conn, "err unknown command\n");
        }
        return .close;
    }

    fn handleJson(self: *Server, conn: c.fd_t, line: []const u8) !Disposition {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"bad json\"}\n");
            return .close;
        };
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .object) {
            cwrite(conn, "{\"ok\":false,\"error\":\"expected object\"}\n");
            return .close;
        }
        if (jsonStr(v, "verb")) |verb| return self.handleRunner(conn, v, verb);
        if (jsonStr(v, "cmd")) |cmd| return self.handleCmd(conn, v, cmd);
        cwrite(conn, "{\"ok\":false,\"error\":\"missing cmd or verb\"}\n");
        return .close;
    }

    /// The JSON control protocol (shared vocabulary with ctl.zig).
    fn handleCmd(self: *Server, conn: c.fd_t, v: std.json.Value, cmd: []const u8) !Disposition {
        const pane_id: u64 = @intCast(@max(jsonInt(v, "pane") orelse 0, 0));

        if (std.mem.eql(u8, cmd, "list")) {
            try self.writeList(conn);
        } else if (std.mem.eql(u8, cmd, "view")) {
            return self.openViewer(conn, v, pane_id);
        } else if (std.mem.eql(u8, cmd, "spawn")) {
            var why: []const u8 = "";
            var env: [][:0]u8 = &.{};
            if (v == .object) if (v.object.get("env")) |e| if (e != .null) {
                env = parseSpawnEnv(self.alloc, e, &why) orelse {
                    self.reply(conn, .{ .ok = false, .@"error" = why });
                    return .close;
                };
            };
            defer {
                freeSpawnEnv(self.alloc, env);
                if (env.len > 0) self.alloc.free(env);
            }
            const o = SpawnOpts{
                .rows = clampDim(jsonInt(v, "rows"), 40),
                .cols = clampDim(jsonInt(v, "cols"), 120),
                .cwd = jsonStr(v, "cwd"),
                .name = jsonStr(v, "name"),
                .run = jsonStr(v, "run"),
                .env = env,
            };
            if (self.spawn(o, &why)) |id| {
                self.reply(conn, .{ .ok = true, .pane = id });
            } else self.reply(conn, .{ .ok = false, .@"error" = why });
        } else if (std.mem.eql(u8, cmd, "send")) {
            const p = self.findPane(pane_id) orelse {
                cwrite(conn, "{\"ok\":false,\"error\":\"no such pane\"}\n");
                return .close;
            };
            if (p.hup) {
                cwrite(conn, "{\"ok\":false,\"error\":\"pane has exited\"}\n");
                return .close;
            }
            const text = jsonStr(v, "text") orelse "";
            const payload = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(payload);
            try self.submits.append(self.alloc, .{
                .pane_id = p.id,
                .conn = conn,
                .proto = .cmd,
                .payload = payload,
                .paste = jsonBool(v, "paste") orelse false,
                .enter = jsonBool(v, "enter") orelse false,
            });
            // Answered from advanceSubmits once the text (and any CR) is typed.
            self.advanceSubmits(nowNs());
            return .keep;
        } else if (std.mem.eql(u8, cmd, "enter")) {
            const p = self.findPane(pane_id) orelse {
                cwrite(conn, "{\"ok\":false,\"error\":\"no such pane\"}\n");
                return .close;
            };
            _ = capi.tmux_send(p.handle, "\r", 1);
            cwrite(conn, "{\"ok\":true}\n");
        } else if (std.mem.eql(u8, cmd, "capture")) {
            const p = self.findPane(pane_id) orelse {
                cwrite(conn, "{\"ok\":false,\"error\":\"no such pane\"}\n");
                return .close;
            };
            const lines: usize = @intCast(@max(jsonInt(v, "lines") orelse 0, 0));
            try ctl.writeCapture(conn, p.spane(), self.alloc, lines, jsonBool(v, "escapes") orelse false);
        } else if (std.mem.eql(u8, cmd, "kill")) {
            cwrite(conn, if (self.killPane(pane_id)) "{\"ok\":true}\n" else "{\"ok\":false,\"error\":\"no such pane\"}\n");
        } else if (std.mem.eql(u8, cmd, "title")) {
            const p = self.findPane(pane_id) orelse {
                cwrite(conn, "{\"ok\":false,\"error\":\"no such pane\"}\n");
                return .close;
            };
            const t = jsonStr(v, "title") orelse "";
            if (!validName(t)) {
                cwrite(conn, "{\"ok\":false,\"error\":\"title must be 1-64 characters of [A-Za-z0-9._@-] and not start with 'pid:'\"}\n");
                return .close;
            }
            if (self.nameTaken(t, p.id)) {
                cwrite(conn, "{\"ok\":false,\"error\":\"that name is already a designation here\"}\n");
                return .close;
            }
            const copy = try self.alloc.dupe(u8, t);
            if (p.name) |old| self.alloc.free(old);
            p.name = copy;
            cwrite(conn, "{\"ok\":true}\n");
        } else if (std.mem.eql(u8, cmd, "resize")) {
            const p = self.findPane(pane_id) orelse {
                cwrite(conn, "{\"ok\":false,\"error\":\"no such pane\"}\n");
                return .close;
            };
            const rows = clampDim(jsonInt(v, "rows"), 0);
            const cols = clampDim(jsonInt(v, "cols"), 0);
            if (rows < 2 or cols < 2) {
                cwrite(conn, "{\"ok\":false,\"error\":\"rows and cols must be 2..1000\"}\n");
                return .close;
            }
            // Through resizePane, so every viewer is resynced at the new size.
            self.resizePane(p, rows, cols);
            cwrite(conn, "{\"ok\":true}\n");
        } else {
            cwrite(conn, "{\"ok\":false,\"error\":\"unknown cmd\"}\n");
        }
        return .close;
    }

    /// baton's runner contract (src/runner/contract.rs).
    fn handleRunner(self: *Server, conn: c.fd_t, v: std.json.Value, verb_raw: []const u8) !Disposition {
        var vb: [32]u8 = undefined;
        const verb = std.ascii.lowerString(vb[0..@min(verb_raw.len, vb.len)], verb_raw[0..@min(verb_raw.len, vb.len)]);

        if (std.mem.eql(u8, verb, "hello")) {
            self.reply(conn, .{
                .ok = true,
                .runner = RUNNER_NAME,
                .pid = @as(i64, self.pid),
                .version = CONTRACT_VERSION,
                // No transcript here, so no `observe_consumption`; no dispatch
                // (see the file header). Declared, never assumed.
                .capabilities = [_][]const u8{ "list", "send", "status", "stop" },
            });
        } else if (std.mem.eql(u8, verb, "status")) {
            var busy: usize = 0;
            for (self.panes.items) |*p| {
                var cb: [64]u8 = undefined;
                if (!p.hup and isAgentComm(procComm(p.foregroundPgid(), &cb) orelse "", self.agent_env)) busy += 1;
            }
            self.reply(conn, .{ .ok = true, .busy = busy, .sessions = self.panes.items.len });
        } else if (std.mem.eql(u8, verb, "list")) {
            try self.writeSessions(conn);
        } else if (std.mem.eql(u8, verb, "send")) {
            const to = jsonStr(v, "to") orelse "";
            const p = self.resolveAddress(to) orelse {
                const why = try std.fmt.allocPrint(self.alloc, "no session called '{s}' is hosted here", .{to});
                defer self.alloc.free(why);
                self.reply(conn, .{ .ok = false, .receipt = "failed", .@"error" = why, .door = "zterm" });
                return .close;
            };
            var door_buf: [96]u8 = undefined;
            const door = self.doorOf(p, &door_buf);
            var db: [32]u8 = undefined;
            const desig = p.designation(&db);
            if (p.hup or !p.alive()) {
                const why = try std.fmt.allocPrint(self.alloc, "session '{s}' is not accepting input (its shell has exited)", .{desig});
                defer self.alloc.free(why);
                self.reply(conn, .{ .ok = false, .receipt = "failed", .@"error" = why, .door = door });
                return .close;
            }
            var cb: [64]u8 = undefined;
            const fg = procComm(p.foregroundPgid(), &cb) orelse "";
            if (!isAgentComm(fg, self.agent_env)) {
                // The contract's hard rule: a failure never falls through to
                // shell input. A pane at a prompt is not an agent.
                const why = try std.fmt.allocPrint(self.alloc, "session '{s}' is not accepting input (no agent in the foreground; '{s}' is)", .{ desig, if (fg.len > 0) fg else "unknown" });
                defer self.alloc.free(why);
                self.reply(conn, .{ .ok = false, .receipt = "failed", .@"error" = why, .door = door });
                return .close;
            }
            const formatted = try formatInjection(self.alloc, jsonStr(v, "from_node") orelse "", jsonStr(v, "from_agent") orelse "", jsonStr(v, "text") orelse "");
            defer self.alloc.free(formatted);
            const payload = try scrubForPaste(self.alloc, formatted);
            errdefer self.alloc.free(payload);
            try self.submits.append(self.alloc, .{
                .pane_id = p.id,
                .conn = conn,
                .proto = .runner,
                .payload = payload,
                .paste = true,
                .enter = true,
            });
            self.advanceSubmits(nowNs());
            return .keep;
        } else if (std.mem.eql(u8, verb, "stop")) {
            const to = jsonStr(v, "to") orelse "";
            const p = self.resolveAddress(to) orelse {
                const why = try std.fmt.allocPrint(self.alloc, "no session called '{s}'", .{to});
                defer self.alloc.free(why);
                self.reply(conn, .{ .ok = false, .@"error" = why });
                return .close;
            };
            _ = self.killPane(p.id);
            self.reply(conn, .{ .ok = true, .stopped = to });
        } else {
            const why = try std.fmt.allocPrint(self.alloc, "unknown verb '{s}' — the zterm runner speaks version {d} (hello, list, send, status, stop)", .{ verb_raw, CONTRACT_VERSION });
            defer self.alloc.free(why);
            self.reply(conn, .{ .ok = false, .@"error" = why });
        }
        return .close;
    }

    fn resolveAddress(self: *Server, address: []const u8) ?*Pane {
        if (address.len == 0) return null;
        for (self.panes.items) |*p| {
            var db: [32]u8 = undefined;
            if (answersTo(p.designation(&db), self.sessionPid(p), address)) return p;
        }
        return null;
    }

    /// The process a session IS: the agent when one holds the foreground,
    /// else the pane's shell.
    fn sessionPid(self: *Server, p: *const Pane) i64 {
        var cb: [64]u8 = undefined;
        const fg = p.foregroundPgid();
        if (fg > 0 and isAgentComm(procComm(fg, &cb) orelse "", self.agent_env)) return fg;
        return p.childPid();
    }

    fn doorOf(self: *Server, p: *const Pane, buf: []u8) []const u8 {
        _ = self;
        const sp = p.spane();
        const tty = if (sp.pty) |*pt| pt.getSlavePath() else "";
        return std.fmt.bufPrint(buf, "zterm pane {d} ({s})", .{ p.id, tty }) catch "zterm";
    }

    fn reply(self: *Server, conn: c.fd_t, value: anytype) void {
        const j = std.json.Stringify.valueAlloc(self.alloc, value, .{}) catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"out of memory\"}\n");
            return;
        };
        defer self.alloc.free(j);
        cwrite(conn, j);
        cwrite(conn, "\n");
    }

    // ── viewers (docs/VIEW-PROTOCOL.md) ──────────────────────────────────────────────────────────────

    fn viewerCount(self: *Server, pane_id: u64) usize {
        var n: usize = 0;
        for (self.viewers.items) |v| {
            if (v.conn >= 0 and v.pane_id == pane_id) n += 1;
        }
        for (self.attaches.items) |a| {
            if (a.conn >= 0 and a.pane_id == pane_id) n += 1;
        }
        return n;
    }

    fn hasRawAttach(self: *Server, pane_id: u64) bool {
        for (self.attaches.items) |a| if (a.conn >= 0 and a.pane_id == pane_id) return true;
        return false;
    }

    fn openViewer(self: *Server, conn: c.fd_t, v: std.json.Value, pane_id: u64) !Disposition {
        const p = self.findPane(pane_id) orelse {
            cwrite(conn, "{\"t\":\"error\",\"error\":\"no such pane\"}\n");
            return .close;
        };
        const rows = clampDim(jsonInt(v, "rows"), 0);
        const cols = clampDim(jsonInt(v, "cols"), 0);
        if (rows >= 2 and cols >= 2) self.resizePane(p, rows, cols);
        const fl = c.fcntl(conn, c.F.GETFL, @as(c_int, 0));
        _ = c.fcntl(conn, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        try self.viewers.append(self.alloc, .{ .conn = conn, .pane_id = p.id });
        const vw = &self.viewers.items[self.viewers.items.len - 1];
        // hello carries the theme: the colours every palette index and
        // "default" resolve to — the same theme zterm answers OSC 10/11 from.
        {
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &vw.out);
            defer vw.out = aw.toArrayList();
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            view.writeHello(&s, p.id, &config.active_theme) catch {};
            aw.writer.writeByte('\n') catch {};
        }
        // Anything the client sent right behind its request is its first input.
        if (self.trailing.len > 0) self.viewerInput(vw, self.trailing);
        return .keep;
    }

    /// Resize a pane and resync everyone viewing it: the grid has new
    /// dimensions, so only a full frame describes it.
    fn resizePane(self: *Server, p: *Pane, rows: u16, cols: u16) void {
        _ = capi.tmux_resize(p.handle, rows, cols);
        p.noteInput(); // a window being dragged wants its frames now
        for (self.viewers.items) |*v| {
            if (v.conn < 0 or v.pane_id != p.id) continue;
            v.full = true;
            v.changed = true;
        }
    }

    fn paneHungUp(self: *Server, p: *Pane) void {
        if (!p.hup) p.hup_ms = @import("terminal.zig").monotonicMs();
        p.hup = true;
        // Its viewers are owed a last frame and an `exit`.
        for (self.viewers.items) |*v| {
            if (v.conn >= 0 and v.pane_id == p.id) v.changed = true;
        }
    }

    /// After a pane's output was fed to its emulator: fold the rows it
    /// dirtied into every viewer's own dirty set, hand out bell and
    /// clipboard events, then clear the emulator's flags. The server is the
    /// only consumer of those flags in a headless pool.
    fn notePaneOutput(self: *Server, p: *Pane) void {
        const t = &p.spane().terminal;
        const bells = t.bell_pending;
        t.bell_pending = 0;
        const marks_touched = t.takeMarksTouched();
        const clip = t.clipboard_pending[0..t.clipboard_len];
        const rows = t.getCurrentGrid().rows;
        for (self.viewers.items) |*v| {
            if (v.conn < 0 or v.pane_id != p.id) continue;
            v.changed = true;
            if (v.dirty.capacity() != rows) {
                v.dirty.resize(self.alloc, rows, false) catch {};
                v.full = true;
            }
            if (!v.full) {
                var r: u16 = 0;
                while (r < rows) : (r += 1) if (t.isDirty(r)) v.dirty.set(r);
            }
            if (marks_touched) |line| v.marks_from = if (v.marks_from) |cur| @min(cur, line) else line;
            if (bells > 0) self.viewerEvent(v, .{ .t = "bell", .pane = p.id });
            if (clip.len > 0) {
                const enc = std.base64.standard.Encoder;
                const b64 = self.alloc.alloc(u8, enc.calcSize(clip.len)) catch continue;
                defer self.alloc.free(b64);
                self.viewerEvent(v, .{ .t = "clipboard", .pane = p.id, .b64 = enc.encode(b64, clip) });
            }
        }
        t.clipboard_len = 0;
        t.clearDirty();
    }

    /// Queue one small JSON message for a viewer. If events pile up past the
    /// cap while the client is not reading, the unsent backlog is discarded
    /// (keeping any message already partly written, so lines stay whole) and
    /// the client is resynced with a full frame.
    fn viewerEvent(self: *Server, v: *Viewer, value: anytype) void {
        if (v.out.items.len - v.out_off > VIEW_OUT_CAP) {
            const keep_to = if (v.out_off == 0) 0 else blk: {
                const nl = std.mem.indexOfScalarPos(u8, v.out.items, v.out_off - 1, '\n') orelse v.out.items.len - 1;
                break :blk nl + 1;
            };
            v.out.items.len = keep_to;
            v.full = true;
            v.changed = true;
            v.marks_from = std.math.minInt(i64);
        }
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &v.out);
        defer v.out = aw.toArrayList();
        std.json.Stringify.value(value, .{}, &aw.writer) catch return;
        aw.writer.writeByte('\n') catch return;
    }

    /// Write what a viewer is owed, as far as the socket takes it. False
    /// when the connection is broken.
    fn flushViewer(v: *Viewer) bool {
        while (v.pending()) {
            const rest = v.out.items[v.out_off..];
            const n = c.write(v.conn, rest.ptr, rest.len);
            if (n > 0) {
                v.out_off += @intCast(n);
                continue;
            }
            if (n < 0 and posix.errno(n) == .INTR) continue;
            if (n < 0 and posix.errno(n) == .AGAIN) return true;
            return false;
        }
        v.out.clearRetainingCapacity();
        v.out_off = 0;
        return true;
    }

    /// Flush every viewer, and build the frames that are due for those that
    /// have caught up. Returns in how many ms the loop must come back for a
    /// frame being held (pacing, a synchronized update, a pane not yet
    /// reaped), or null when nothing is held.
    ///
    /// Pacing: a viewer gets at most one frame per `frame_ms`. The first
    /// change after a quiet spell goes out at once (a keystroke's echo is
    /// never delayed); changes inside the interval fold into the next frame.
    /// A frame holds the pane's state when it is built, so nothing is lost —
    /// only intermediate states nobody could have seen at display rate.
    fn pumpViewers(self: *Server) ?i64 {
        var wake: ?i64 = null;
        const soon = struct {
            fn f(w: *?i64, ms: i64) void {
                w.* = if (w.*) |cur| @min(cur, ms) else ms;
            }
        }.f;
        const now = @import("terminal.zig").monotonicMs();
        for (self.viewers.items) |*v| {
            if (v.conn < 0) continue;
            if (!flushViewer(v)) {
                v.deinit(self.alloc);
                continue;
            }
            if (v.pending()) continue; // still catching up: the next frame waits
            if (v.closing) {
                v.deinit(self.alloc);
                continue;
            }
            if (v.exit_sent) continue;
            const p = self.findPane(v.pane_id) orelse continue;
            // A hung-up pane is revisited until its exit has been reported.
            if (!(v.full or v.changed) and !p.hup) continue;
            const t = &p.spane().terminal;
            // Never a frame from inside an application's synchronized update
            // (DEC 2026) — unless it has run past 250ms, when the app is
            // presumed stuck and the screen is shown as it stands.
            if (t.modes.synchronized and now - t.sync_began_ms < 250) {
                soon(&wake, 20);
                continue;
            }
            const since = now - v.last_frame_ms;
            // The first frame after input is never held (without this, pacing
            // added the whole interval to every key typed within 8 ms of the
            // previous frame). Only the first: a 50 ms unpaced window let a
            // command that floods on Enter send a frame per PTY read — ~300
            // frames in 50 ms once the emulator got faster (bench/runs).
            const answering_input = v.answered_input != p.input_seq;
            if ((v.changed or v.full) and v.last_frame_ms != 0 and since < self.frame_ms and !answering_input) {
                soon(&wake, self.frame_ms - since);
                continue;
            }
            // The hangup comes before the child is reaped: the exit status
            // exists only once `isAlive` has reaped it. Wait for that (the
            // last frame goes out meanwhile) — up to 2s, after which a child
            // that closed its terminal but kept running is reported with no
            // status rather than a made-up one.
            const reaped = p.hup and !p.alive();
            const gave_up = p.hup and now - p.hup_ms > 2000;
            if (p.hup and !reaped and !gave_up) soon(&wake, 20);
            if (v.changed or v.full or !p.hup) {
                self.writeFrame(v, p) catch {};
                v.last_frame_ms = now;
                v.answered_input = p.input_seq;
            }
            if ((reaped or gave_up) and !v.exit_sent) {
                const st = if (reaped) p.spane().exitStatus() else null;
                self.viewerEvent(v, .{
                    .t = "exit",
                    .pane = p.id,
                    .code = if (st) |x| @as(?i64, x.code) else null,
                    .signal = if (st) |x| @as(?i64, x.signal) else null,
                });
                v.exit_sent = true;
            }
            if (!flushViewer(v)) v.deinit(self.alloc);
        }
        return wake;
    }

    fn writeFrame(self: *Server, v: *Viewer, p: *Pane) !void {
        const t = &p.spane().terminal;
        const rows = t.getCurrentGrid().rows;
        if (v.dirty.capacity() != rows) {
            try v.dirty.resize(self.alloc, rows, false);
            v.full = true;
        }
        v.seq += 1;
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &v.out);
        defer v.out = aw.toArrayList();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        // Marks go out ahead of the frame that shows their lines. Never below
        // the oldest primary line held: nothing is there to replace.
        if (v.marks_from) |from| {
            const oldest = t.primaryEpoch() - @as(i64, @intCast(t.scrollback.len));
            try view.writeMarks(&s, t, p.id, @max(from, oldest));
            try aw.writer.writeByte('\n');
            s = .{ .writer = &aw.writer };
            v.marks_from = null;
        }
        try view.writeFrame(&s, t, .{ .pane = p.id, .seq = v.seq, .full = v.full, .dirty = &v.dirty }, self.alloc);
        try aw.writer.writeByte('\n');
        v.dirty.setRangeValue(.{ .start = 0, .end = v.dirty.capacity() }, false);
        v.full = false;
        v.changed = false;
    }

    /// Bytes from a viewer: split into lines, act on each complete one.
    fn viewerInput(self: *Server, v: *Viewer, bytes: []const u8) void {
        v.inbuf.appendSlice(self.alloc, bytes) catch {
            v.deinit(self.alloc);
            return;
        };
        while (std.mem.indexOfScalar(u8, v.inbuf.items, '\n')) |nl| {
            self.viewerLine(v, v.inbuf.items[0..nl]);
            if (v.conn < 0) return;
            const rest = v.inbuf.items.len - (nl + 1);
            std.mem.copyForwards(u8, v.inbuf.items[0..rest], v.inbuf.items[nl + 1 ..]);
            v.inbuf.items.len = rest;
        }
        if (v.inbuf.items.len > VIEW_IN_CAP) v.deinit(self.alloc); // a line that never ends
    }

    fn viewerLine(self: *Server, v: *Viewer, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch return;
        defer parsed.deinit();
        const m = parsed.value;
        if (m != .object) return;
        const p = self.findPane(v.pane_id) orelse return;

        if (m.object.get("resize")) |r| {
            if (r != .object) return;
            const rows = clampDim(jsonInt(r, "rows"), 0);
            const cols = clampDim(jsonInt(r, "cols"), 0);
            if (rows >= 2 and cols >= 2) self.resizePane(p, rows, cols);
            return;
        }
        if (m.object.get("history")) |h| {
            if (h != .object) return;
            const from = jsonInt(h, "from") orelse return;
            const count: usize = @intCast(std.math.clamp(jsonInt(h, "count") orelse 0, 0, 5000));
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &v.out);
            defer v.out = aw.toArrayList();
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            view.writeHistory(&s, &p.spane().terminal, p.id, from, count, self.alloc) catch return;
            aw.writer.writeByte('\n') catch return;
            return;
        }
        if (p.hup) return; // input to a finished pane goes nowhere
        p.noteInput();
        if (jsonBool(m, "focus")) |focused| {
            if (p.spane().terminal.modes.focus_events) {
                const seq: []const u8 = if (focused) "\x1b[I" else "\x1b[O";
                _ = capi.tmux_send(p.handle, seq.ptr, seq.len);
            }
            return;
        }
        const kind = jsonStr(m, "input") orelse return;
        if (std.mem.eql(u8, kind, "text")) {
            const data = jsonStr(m, "data") orelse return;
            if (data.len > 0) _ = capi.tmux_send(p.handle, data.ptr, data.len);
        } else if (std.mem.eql(u8, kind, "bytes")) {
            const b64 = jsonStr(m, "b64") orelse return;
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(b64) catch return;
            const buf = self.alloc.alloc(u8, n) catch return;
            defer self.alloc.free(buf);
            dec.decode(buf, b64) catch return;
            if (n > 0) _ = capi.tmux_send(p.handle, buf.ptr, n);
        } else if (std.mem.eql(u8, kind, "paste")) {
            const data = jsonStr(m, "data") orelse return;
            var clean: std.ArrayList(u8) = .empty;
            defer clean.deinit(self.alloc);
            const text = view.stripPasteEnd(data, &clean, self.alloc) catch return;
            if (text.len > 0) _ = capi.tmux_paste(p.handle, text.ptr, text.len);
        } else if (std.mem.eql(u8, kind, "mouse")) {
            const what = jsonStr(m, "kind") orelse return;
            const k: c_int = if (std.mem.eql(u8, what, "press")) 0 else if (std.mem.eql(u8, what, "release")) 1 else if (std.mem.eql(u8, what, "motion")) 2 else return;
            const x = std.math.cast(u16, jsonInt(m, "x") orelse return) orelse return;
            const y = std.math.cast(u16, jsonInt(m, "y") orelse return) orelse return;
            const button = std.math.cast(c_int, jsonInt(m, "button") orelse 0) orelse return;
            const mods = std.math.cast(c_int, jsonInt(m, "mods") orelse 0) orelse return;
            _ = capi.tmux_mouse(p.handle, k, button, y, x, mods);
        }
    }

    // ── list / sessions ──────────────────────────────────────────────────────────────────────────────

    /// The pane list for the control protocol: ctl.zig's fields plus what a
    /// headless pool knows and a driver needs (name, tty, liveness, exit).
    fn writeList(self: *Server, conn: c.fd_t) !void {
        const PaneInfo = struct {
            pane: u64,
            window: u64,
            active: bool,
            rows: u16,
            cols: u16,
            pid: i64,
            cwd: []const u8,
            name: ?[]const u8,
            title: []const u8,
            tty: []const u8,
            alive: bool,
            exit_code: ?i64,
            exit_signal: ?i64,
            foreground: []const u8,
            /// Clients drawing this pane now (view connections + raw
            /// attaches). A front end reattaching after a restart takes a
            /// named pane only when this is 0, so two windows never share one.
            viewers: usize,
        };
        var infos: std.ArrayList(PaneInfo) = .empty;
        defer infos.deinit(self.alloc);
        // Per-row scratch that must outlive the loop until serialization.
        const Scratch = struct { cwd: [std.fs.max_path_bytes]u8, title: [256]u8, fg: [64]u8 };
        const scratch = try self.alloc.alloc(Scratch, self.panes.items.len);
        defer self.alloc.free(scratch);

        for (self.panes.items, 0..) |*p, i| {
            var rows: u16 = 0;
            var cols: u16 = 0;
            capi.tmux_grid_size(p.handle, &rows, &cols);
            const sp = p.spane();
            const alive = p.alive();
            const st = if (!alive) sp.exitStatus() else null;
            const child = p.childPid();
            const cwd = procCwd(child, &scratch[i].cwd) orelse sp.cwd[0..sp.cwd_len];
            const tlen = capi.tmux_title(p.handle, &scratch[i].title, scratch[i].title.len);
            const fg = if (alive and !p.hup) procComm(p.foregroundPgid(), &scratch[i].fg) orelse "" else "";
            try infos.append(self.alloc, .{
                .pane = p.id,
                .window = p.id,
                .active = false,
                .rows = rows,
                .cols = cols,
                .pid = child,
                .cwd = cwd,
                .name = p.name,
                .title = scratch[i].title[0..@min(tlen, scratch[i].title.len)],
                .tty = if (sp.pty) |*pt| pt.getSlavePath() else "",
                .alive = alive,
                .exit_code = if (st) |s| s.code else null,
                .exit_signal = if (st) |s| s.signal else null,
                .foreground = fg,
                .viewers = self.viewerCount(p.id),
            });
        }
        const json = try std.json.Stringify.valueAlloc(self.alloc, infos.items, .{});
        defer self.alloc.free(json);
        cwrite(conn, json);
        cwrite(conn, "\n");
    }

    /// The runner contract's `list`: one session per pane, identified by its
    /// process GENERATION, never by pane number alone (pane numbers are
    /// reused; a designation can outlive a process).
    fn writeSessions(self: *Server, conn: c.fd_t) !void {
        const Row = struct {
            designation: []const u8,
            generation: []const u8,
            pid: i64,
            cwd: []const u8,
            harness: []const u8,
            state: []const u8,
            addressable: bool,
            observes_consumption: bool,
            door: []const u8,
        };
        const Scratch = struct {
            desig: [72]u8,
            gen: [96]u8,
            cwd: [std.fs.max_path_bytes]u8,
            fg: [64]u8,
            state: [96]u8,
            door: [96]u8,
        };
        const scratch = try self.alloc.alloc(Scratch, self.panes.items.len);
        defer self.alloc.free(scratch);
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.alloc);

        for (self.panes.items, 0..) |*p, i| {
            const s = &scratch[i];
            const sp = p.spane();
            const alive = !p.hup and p.alive();
            const child = p.childPid();
            const fg_pid = if (alive) p.foregroundPgid() else 0;
            const fg = if (alive) procComm(fg_pid, &s.fg) orelse "" else "";
            const agent = alive and isAgentComm(fg, self.agent_env);
            const pid: i64 = if (agent) fg_pid else child;
            const state: []const u8 = if (agent)
                "live"
            else if (alive)
                std.fmt.bufPrint(&s.state, "shell (no agent in the foreground: {s})", .{if (fg.len > 0) fg else "unknown"}) catch "shell"
            else if (sp.exitStatus()) |st|
                (std.fmt.bufPrint(&s.state, "exited (code {d}, signal {d})", .{ st.code, st.signal }) catch "exited")
            else
                "exited";
            try rows.append(self.alloc, .{
                .designation = p.designation(&s.desig),
                .generation = std.fmt.bufPrint(&s.gen, "zterm:{d}:{d}:{d}", .{ self.pid, p.id, pid }) catch "",
                .pid = pid,
                .cwd = procCwd(if (agent) fg_pid else child, &s.cwd) orelse sp.cwd[0..sp.cwd_len],
                .harness = if (agent) fg else if (alive) "shell" else "none",
                .state = state,
                .addressable = agent,
                .observes_consumption = false,
                .door = self.doorOf(p, &s.door),
            });
        }
        self.reply(conn, .{ .ok = true, .runner = RUNNER_NAME, .sessions = rows.items });
    }

    // ── deferred submits ─────────────────────────────────────────────────────────────────────────────

    fn screenNorm(self: *Server, p: *Pane) ![]u8 {
        const term = &p.spane().terminal;
        const grid = term.getCurrentGrid();
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.alloc);
        var last = @import("terminal.zig").Cell.default;
        var r: u16 = 0;
        while (r < grid.rows) : (r += 1) try ctl.appendRow(&raw, self.alloc, grid.rowSlice(r), false, &last);
        return normalizeWs(self.alloc, raw.items);
    }

    /// Answer a submit's requester and release it. The entry is marked done
    /// (conn = -2); `dropFinishedSubmits` removes it.
    fn finishSubmit(self: *Server, s: *Submit, ok: bool, detail: []const u8) void {
        if (s.conn == -2) return;
        if (s.conn >= 0) {
            switch (s.proto) {
                .runner => if (ok) self.reply(s.conn, .{
                    .ok = true,
                    .receipt = "written",
                    .bytes = s.written,
                    .detail = detail,
                }) else {
                    var door_buf: [96]u8 = undefined;
                    const door = if (self.findPane(s.pane_id)) |p| self.doorOf(p, &door_buf) else "zterm";
                    self.reply(s.conn, .{ .ok = false, .receipt = "failed", .@"error" = detail, .door = door });
                },
                .cmd => if (ok)
                    self.reply(s.conn, .{ .ok = true, .bytes = s.written, .entered = s.enter })
                else
                    self.reply(s.conn, .{ .ok = false, .@"error" = detail }),
            }
            pclose(s.conn);
        }
        self.alloc.free(s.payload);
        if (s.before.len > 0) self.alloc.free(s.before);
        if (s.tail.len > 0) self.alloc.free(s.tail);
        s.payload = &.{};
        s.before = &.{};
        s.tail = &.{};
        s.conn = -2;
    }

    fn dropFinishedSubmits(self: *Server) void {
        var i: usize = 0;
        while (i < self.submits.items.len) {
            if (self.submits.items[i].conn == -2) {
                _ = self.submits.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Drive every pane's HEAD submit one step. Per pane the queue is strictly
    /// ordered: a second message is not pasted until the first one's CR is
    /// written, or one CR would submit both.
    fn advanceSubmits(self: *Server, now: u64) void {
        for (self.submits.items, 0..) |*s, i| {
            if (s.conn == -2) continue;
            var head = true;
            for (self.submits.items[0..i]) |prev| {
                if (prev.conn != -2 and prev.pane_id == s.pane_id) {
                    head = false;
                    break;
                }
            }
            if (!head) continue;
            self.stepSubmit(s, now);
        }
        self.dropFinishedSubmits();
    }

    fn stepSubmit(self: *Server, s: *Submit, now: u64) void {
        const p = self.findPane(s.pane_id) orelse return self.finishSubmit(s, false, "the pane is gone");
        if (p.hup) return self.finishSubmit(s, false, "the pane's shell exited before the message was submitted");
        switch (s.state) {
            .queued => {
                if (s.enter and s.payload.len > 0) {
                    s.before = self.screenNorm(p) catch &.{};
                    const norm = normalizeWs(self.alloc, s.payload) catch &.{};
                    defer if (norm.len > 0) self.alloc.free(norm);
                    s.tail = if (norm.len > 0) (self.alloc.dupe(u8, tailOf(norm)) catch &.{}) else &.{};
                }
                if (s.payload.len > 0) {
                    const n = if (s.paste)
                        capi.tmux_paste(p.handle, s.payload.ptr, s.payload.len)
                    else
                        capi.tmux_send(p.handle, s.payload.ptr, s.payload.len);
                    if (n < 0) return self.finishSubmit(s, false, "the PTY refused the write");
                    s.written = @intCast(n);
                    if (s.written < s.payload.len) {
                        // A partial message must not be submitted; the caller
                        // hears exactly how much reached the PTY.
                        var wb: [160]u8 = undefined;
                        const why = std.fmt.bufPrint(&wb, "the pane stopped reading after {d} of {d} bytes; NOT submitted", .{ s.written, s.payload.len }) catch "short write; not submitted";
                        return self.finishSubmit(s, false, why);
                    }
                }
                if (!s.enter) return self.finishSubmit(s, true, "written without a submit (enter=false)");
                s.state = .pasted;
                s.deadline = now + settleNs(s.payload.len);
                s.next_check = now + 50 * std.time.ns_per_ms;
            },
            .pasted => {
                if (!s.landed and s.payload.len > 0 and now >= s.next_check) {
                    s.next_check = now + 100 * std.time.ns_per_ms;
                    if (self.screenNorm(p)) |screen| {
                        defer self.alloc.free(screen);
                        if (pasteLanded(s.before, screen, s.tail)) {
                            s.landed = true;
                            // A short grace for render-vs-state skew.
                            s.deadline = @min(s.deadline, now + 50 * std.time.ns_per_ms);
                        }
                    } else |_| {}
                }
                if (now < s.deadline) return;
                const n = capi.tmux_send(p.handle, "\r", 1);
                if (n != 1) return self.finishSubmit(s, false, "the paste was written but the submitting CR was not");
                const detail = if (s.landed or s.payload.len == 0)
                    "zterm hosts no transcript, so consumption is not observable here; submitted after the paste showed on screen"
                else
                    "zterm hosts no transcript, so consumption is not observable here; submitted at the settle ceiling (no on-screen evidence of the paste)";
                self.finishSubmit(s, true, detail);
            },
        }
    }
};

fn clampDim(v: ?i64, default: u16) u16 {
    const x = v orelse return default;
    if (x < 2 or x > 1000) return default;
    return @intCast(x);
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = v.object.get(key) orelse return null;
    return switch (o) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    const o = v.object.get(key) orelse return null;
    return switch (o) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonBool(v: std.json.Value, key: []const u8) ?bool {
    const o = v.object.get(key) orelse return null;
    return switch (o) {
        .bool => |b| b,
        else => null,
    };
}

/// Write all of `data` to an attach conn, waiting at most ~200ms total for a
/// full socket buffer. Errors (incl. timeout) mean the caller drops the client.
fn relayWrite(fd: c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    var waits: u8 = 0;
    while (off < data.len) {
        const r = c.write(fd, data.ptr + off, data.len - off);
        if (r > 0) {
            off += @intCast(r);
            continue;
        }
        if (r == 0) return error.WriteFailed;
        switch (posix.errno(r)) {
            .INTR => continue,
            .AGAIN => {
                if (waits >= 2) return error.ClientStalled; // ~200ms budget spent
                waits += 1;
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&pfd, 100) catch return error.WriteFailed;
            },
            else => return error.WriteFailed,
        }
    }
}

/// Redraw a pane's current screen onto a freshly-attached client: clear, home,
/// then the grid rows joined with CRLF (the client tty is raw — bare LF would
/// staircase). Colors return as the app repaints; this restores the text.
fn writeSnapshot(conn: i32, h: *capi.TmuxSession, alloc: std.mem.Allocator) !void {
    var rows: u16 = 0;
    var cols: u16 = 0;
    capi.tmux_grid_size(h, &rows, &cols);
    const total = @as(usize, rows) * @as(usize, cols);
    if (total == 0) return;
    const cells = try alloc.alloc(capi.CCell, total);
    defer alloc.free(cells);
    const got = capi.tmux_read_cells(h, cells.ptr, total);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "\x1b[2J\x1b[H");
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if (r != 0) try out.appendSlice(alloc, "\r\n");
        const line_start = out.items.len;
        const row_cells = cells[r * cols .. @min((r + 1) * cols, got)];
        for (row_cells) |cell| {
            if (cell.width == 0 or cell.ch == 0) continue;
            var ub: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cell.ch), &ub) catch continue;
            try out.appendSlice(alloc, ub[0..len]);
        }
        while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
        }
    }
    // Park the cursor where the pane thinks it is.
    var crow: u16 = 0;
    var ccol: u16 = 0;
    var cvis = false;
    capi.tmux_cursor(h, &crow, &ccol, &cvis);
    var cb: [24]u8 = undefined;
    try out.appendSlice(alloc, std.fmt.bufPrint(&cb, "\x1b[{d};{d}H", .{ crow + 1, ccol + 1 }) catch "");
    _ = pwrite(conn, out.items) catch {};
}

fn runServer(alloc: std.mem.Allocator, opts: ServerOptions) !void {
    var srv = Server{
        .alloc = alloc,
        .pid = c.getpid(),
        .agent_env = envSlice("BATON_AGENT_EXES"),
        .frame_ms = opts.frame_ms,
    };
    defer srv.deinit();

    const path = try ctl.socketPath(alloc);
    srv.listenOn(path, .control) catch |e| {
        alloc.free(path);
        return e;
    };
    std.debug.print("zterm server: listening on {s}\n", .{path});
    // The runner door is an addition to the control socket, not a condition
    // of serving: without it baton cannot SEE this pool, but every pane verb
    // still works. Degrade loudly rather than refuse to start.
    srv.bindRunnerDoor(opts) catch |e| {
        std.debug.print("zterm server: serving WITHOUT a runner door ({s}) — `baton runner list` will not show this server\n", .{@errorName(e)});
    };

    // SIGINT/SIGTERM end the loop so both sockets are unlinked and the panes'
    // shells are hung up, instead of leaving a dead door for baton to probe.
    _ = signal(@intFromEnum(c.SIG.INT), onStopSignal);
    _ = signal(@intFromEnum(c.SIG.TERM), onStopSignal);

    var why: []const u8 = "";
    const first = srv.spawn(.{}, &why) orelse {
        std.debug.print("zterm server: first pane failed: {s}\n", .{why});
        return error.SpawnFailed;
    };
    std.debug.print("zterm server: pane {d} (shell) ready\n", .{first});

    try srv.run();
    std.debug.print("zterm server: stopping\n", .{});
}

// ══ CLIENT ════════════════════════════════════════════════════════════════════════════════════════════
fn connectServer(alloc: std.mem.Allocator) !c.fd_t {
    const path = try ctl.socketPath(alloc);
    defer alloc.free(path);
    var addr = ctl.fillAddr(path) catch {
        std.debug.print("zterm: socket path is {d} bytes, longer than sun_path allows: {s}\n", .{ path.len, path });
        return error.SocketPathTooLong;
    };
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) {
        pclose(fd);
        std.debug.print("zterm: cannot reach server at {s} (is `zterm server` running?)\n", .{path});
        return error.ConnectFailed;
    }
    return fd;
}

fn runClient(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const fd = try connectServer(alloc);
    defer pclose(fd);

    // Build the request. `--` routes the remainder through the JSON protocol
    // (binary-safe text; split/spawn gain a run command typed once the shell is up):
    //   zterm cli split h -- claude        → {"cmd":"split","dir":"h","run":"claude\n"}
    //   zterm cli spawn -- claude          → {"cmd":"spawn","run":"claude\n"}
    //   zterm cli send 0 -- git log -5     → {"cmd":"send","pane":0,"text":"git log -5\n"}
    // Raw JSON also works directly: zterm cli '{"cmd":"capture","pane":0,"lines":100}'
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);

    var dash: ?usize = null;
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) {
            dash = i;
            break;
        }
    }

    if (dash) |di| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        for (args[di + 1 ..], 0..) |a, i| {
            if (i != 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, a);
        }
        try payload.append(alloc, '\n'); // typed input: submit it

        const verb = args[0];
        if (std.mem.eql(u8, verb, "split")) {
            const dir = if (di >= 2) args[1] else "h";
            const json = try std.json.Stringify.valueAlloc(alloc, .{
                .cmd = "split",
                .dir = if (dir.len > 0 and (dir[0] == 'v' or dir[0] == 'V')) "v" else "h",
                .run = payload.items,
            }, .{});
            defer alloc.free(json);
            try req.appendSlice(alloc, json);
        } else if (std.mem.eql(u8, verb, "spawn")) {
            const json = try std.json.Stringify.valueAlloc(alloc, .{ .cmd = "spawn", .run = payload.items }, .{});
            defer alloc.free(json);
            try req.appendSlice(alloc, json);
        } else if (std.mem.eql(u8, verb, "send")) {
            const id_str = if (di >= 2) args[1] else "0";
            const json = try std.json.Stringify.valueAlloc(alloc, .{
                .cmd = "send",
                .pane = std.fmt.parseInt(usize, id_str, 10) catch 0,
                .text = payload.items,
            }, .{});
            defer alloc.free(json);
            try req.appendSlice(alloc, json);
        } else {
            std.debug.print("zterm: '--' payload is only supported for split/spawn/send\n", .{});
            return error.BadUsage;
        }
    } else {
        for (args, 0..) |a, i| {
            if (i != 0) try req.append(alloc, ' ');
            try req.appendSlice(alloc, a);
        }
    }
    try req.append(alloc, '\n');
    _ = try pwrite(fd, req.items);

    // Stream the response to stdout until EOF.
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        _ = pwrite(1, buf[0..n]) catch break;
    }
}

// ══ ATTACH CLIENT ═════════════════════════════════════════════════════════════════════════════════════
//
// `zterm attach <pane>` — a view-protocol client (docs/VIEW-PROTOCOL.md) that
// draws the server's frames into this terminal with ANSI. The SERVER owns the
// shell and is the only emulator; this client never sees the pane's raw
// output, so it cannot answer a terminal query twice, it redraws a pane in
// full colour however long ago the application painted it, and it resizes
// the pane when this window resizes. Close the terminal, reattach later — the
// shell never noticed. Detach key: Ctrl-b d.

var winch_seen = std.atomic.Value(bool).init(false);
fn onWinch(_: c_int) callconv(.c) void {
    winch_seen.store(true, .monotonic);
}

/// The pane's modes as last mirrored onto the host terminal. Mirroring them
/// means the host sends input already encoded the way the application asked
/// (application cursor keys, bracketed paste, its mouse protocol, focus
/// reports), so keystrokes pass through untouched.
const HostModes = struct {
    app_cursor: bool = false,
    bracketed_paste: bool = false,
    mouse: []const u8 = "none",
    mouse_sgr: bool = false,
    focus: bool = false,
};

/// The server's theme, from `hello` (docs/VIEW-PROTOCOL.md): every colour on
/// the wire — each palette index and "default" — resolves through it, so this
/// window shows the pane in the same colours as any other client, and as
/// zterm answers OSC 10/11. Emitted as truecolour, never as the host's own
/// palette codes.
const ViewTheme = struct {
    fg: [3]u8,
    bg: [3]u8,
    palette: [256][3]u8,
    bold_is_bright: bool,

    fn rgb(col: config.Color) [3]u8 {
        return .{ col.r, col.g, col.b };
    }

    /// zterm's built-in default theme — what applies until `hello` arrives.
    fn fromConfig(t: *const config.Theme) ViewTheme {
        var vt: ViewTheme = .{ .fg = rgb(t.fg), .bg = rgb(t.bg), .palette = undefined, .bold_is_bright = t.bold_is_bright };
        for (0..256) |i| {
            const idx: u8 = @intCast(i);
            vt.palette[i] = rgb(if (idx < 16) t.palette[idx] else config.Color.from256(idx));
        }
        return vt;
    }

    fn parseHex(v: ?std.json.Value) ?[3]u8 {
        const val = v orelse return null;
        if (val != .string or val.string.len != 7 or val.string[0] != '#') return null;
        const h = val.string;
        return .{
            std.fmt.parseInt(u8, h[1..3], 16) catch return null,
            std.fmt.parseInt(u8, h[3..5], 16) catch return null,
            std.fmt.parseInt(u8, h[5..7], 16) catch return null,
        };
    }

    /// Overlay a `theme` object from `hello` (or a `palette` message).
    fn apply(self: *ViewTheme, t: std.json.Value) void {
        if (t != .object) return;
        if (parseHex(t.object.get("fg"))) |col| self.fg = col;
        if (parseHex(t.object.get("bg"))) |col| self.bg = col;
        if (jsonBool(t, "bold_is_bright")) |b| self.bold_is_bright = b;
        if (t.object.get("palette")) |pal| if (pal == .array) {
            for (pal.array.items, 0..) |entry, i| {
                if (i >= 256) break;
                if (parseHex(entry)) |col| self.palette[i] = col;
            }
        };
    }

    fn resolve(self: *const ViewTheme, v: ?std.json.Value, default: [3]u8, bold: bool) [3]u8 {
        const val = v orelse return default;
        return switch (val) {
            .integer => |i| blk: {
                var idx: usize = @intCast(std.math.clamp(i, 0, 255));
                if (bold and self.bold_is_bright and idx < 8) idx += 8;
                break :blk self.palette[idx];
            },
            .string => parseHex(val) orelse default,
            else => default,
        };
    }
};

fn sgrRgb(out: *std.ArrayList(u8), alloc: std.mem.Allocator, lead: u8, col: [3]u8) !void {
    var b: [24]u8 = undefined;
    try out.appendSlice(alloc, std.fmt.bufPrint(&b, ";{d};2;{d};{d};{d}", .{ lead, col[0], col[1], col[2] }) catch "");
}

/// SGR for a span: attributes, then fg and bg as truecolour from the theme.
fn hostSgr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, span: std.json.Value, theme: *const ViewTheme) !void {
    try out.appendSlice(alloc, "\x1b[0");
    const a: u8 = @intCast(@max(0, @min(255, jsonInt(span, "a") orelse 0)));
    const codes = [_]struct { bit: u8, code: []const u8 }{
        .{ .bit = 1, .code = ";1" },   .{ .bit = 2, .code = ";2" },
        .{ .bit = 4, .code = ";3" },   .{ .bit = 8, .code = ";4" },
        .{ .bit = 16, .code = ";5" },  .{ .bit = 32, .code = ";7" },
        .{ .bit = 64, .code = ";8" },  .{ .bit = 128, .code = ";9" },
    };
    for (codes) |cd| if (a & cd.bit != 0) try out.appendSlice(alloc, cd.code);
    try sgrRgb(out, alloc, 38, theme.resolve(span.object.get("fg"), theme.fg, a & 1 != 0));
    try sgrRgb(out, alloc, 48, theme.resolve(span.object.get("bg"), theme.bg, false));
    try out.append(alloc, 'm');
}

/// Reset to the theme's default colours (what a cleared cell shows).
fn themeReset(out: *std.ArrayList(u8), alloc: std.mem.Allocator, theme: *const ViewTheme) !void {
    try out.appendSlice(alloc, "\x1b[0");
    try sgrRgb(out, alloc, 38, theme.fg);
    try sgrRgb(out, alloc, 48, theme.bg);
    try out.append(alloc, 'm');
}

fn cup(out: *std.ArrayList(u8), alloc: std.mem.Allocator, row: i64, col: i64) !void {
    var b: [32]u8 = undefined;
    try out.appendSlice(alloc, std.fmt.bufPrint(&b, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch "");
}

/// Mirror changed modes onto the host terminal.
fn mirrorModes(out: *std.ArrayList(u8), alloc: std.mem.Allocator, have: *HostModes, want: std.json.Value) !void {
    const w_app = jsonBool(want, "app_cursor") orelse false;
    const w_bp = jsonBool(want, "bracketed_paste") orelse false;
    const w_mouse = jsonStr(want, "mouse") orelse "none";
    const w_sgr = jsonBool(want, "mouse_sgr") orelse false;
    const w_focus = jsonBool(want, "focus") orelse false;
    if (w_app != have.app_cursor) try out.appendSlice(alloc, if (w_app) "\x1b[?1h" else "\x1b[?1l");
    if (w_bp != have.bracketed_paste) try out.appendSlice(alloc, if (w_bp) "\x1b[?2004h" else "\x1b[?2004l");
    if (!std.mem.eql(u8, w_mouse, have.mouse) or w_sgr != have.mouse_sgr) {
        try out.appendSlice(alloc, "\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l");
        const on: []const u8 = if (std.mem.eql(u8, w_mouse, "x10")) "\x1b[?9h" else if (std.mem.eql(u8, w_mouse, "normal")) "\x1b[?1000h" else if (std.mem.eql(u8, w_mouse, "button")) "\x1b[?1002h" else if (std.mem.eql(u8, w_mouse, "any")) "\x1b[?1003h" else "";
        try out.appendSlice(alloc, on);
        if (on.len > 0 and w_sgr) try out.appendSlice(alloc, "\x1b[?1006h");
    }
    if (w_focus != have.focus) try out.appendSlice(alloc, if (w_focus) "\x1b[?1004h" else "\x1b[?1004l");
    have.* = .{
        .app_cursor = w_app,
        .bracketed_paste = w_bp,
        .mouse = if (std.mem.eql(u8, w_mouse, "x10")) "x10" else if (std.mem.eql(u8, w_mouse, "normal")) "normal" else if (std.mem.eql(u8, w_mouse, "button")) "button" else if (std.mem.eql(u8, w_mouse, "any")) "any" else "none",
        .mouse_sgr = w_sgr,
        .focus = w_focus,
    };
}

/// Draw one frame. Rows are cleared and redrawn whole; every span is placed
/// at its own column, so a host whose width tables disagree with zterm's
/// cannot shift the rest of a row. Wrapped in a host synchronized update.
fn drawFrame(alloc: std.mem.Allocator, frame: std.json.Value, have: *HostModes, title_buf: *std.ArrayList(u8), theme: *const ViewTheme) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "\x1b[?2026h\x1b[?25l");
    if (jsonBool(frame, "full") orelse false) {
        // Erase paints with the current background: clear to the theme's.
        try themeReset(&out, alloc, theme);
        try out.appendSlice(alloc, "\x1b[H\x1b[2J");
    }
    if (frame.object.get("lines")) |lines| if (lines == .array) for (lines.array.items) |line| {
        if (line != .object) continue;
        const y = jsonInt(line, "y") orelse continue;
        try cup(&out, alloc, y, 0);
        try themeReset(&out, alloc, theme);
        try out.appendSlice(alloc, "\x1b[2K");
        const spans = line.object.get("spans") orelse continue;
        if (spans != .array) continue;
        for (spans.array.items) |span| {
            if (span != .object) continue;
            const x = jsonInt(span, "x") orelse 0;
            try hostSgr(&out, alloc, span, theme);
            const text = jsonStr(span, "text") orelse "";
            if ((jsonInt(span, "w") orelse 1) == 2) {
                // A run of double-width characters: place each one at its
                // own pair of columns, so a host whose width tables disagree
                // with zterm's cannot drift within the run.
                var it = (std.unicode.Utf8View.init(text) catch continue).iterator();
                var k: i64 = 0;
                while (it.nextCodepointSlice()) |ch| : (k += 1) {
                    try cup(&out, alloc, y, x + 2 * k);
                    try out.appendSlice(alloc, ch);
                }
            } else {
                try cup(&out, alloc, y, x);
                try out.appendSlice(alloc, text);
            }
        }
        try out.appendSlice(alloc, "\x1b[0m");
    };
    if (frame.object.get("modes")) |m| if (m == .object) try mirrorModes(&out, alloc, have, m);
    if (jsonStr(frame, "title")) |t| if (!std.mem.eql(u8, t, title_buf.items)) {
        title_buf.clearRetainingCapacity();
        try title_buf.appendSlice(alloc, t);
        // A title is text; drop what would end the OSC early.
        try out.appendSlice(alloc, "\x1b]2;");
        for (t) |ch| if (ch >= 0x20 and ch != 0x7f) try out.append(alloc, ch);
        try out.append(alloc, 0x07);
    };
    if (frame.object.get("cursor")) |cur| if (cur == .object) {
        try cup(&out, alloc, jsonInt(cur, "y") orelse 0, jsonInt(cur, "x") orelse 0);
        const shape = jsonStr(cur, "shape") orelse "block";
        const blink = jsonBool(cur, "blink") orelse true;
        const ps: u8 = if (std.mem.eql(u8, shape, "underline")) 3 else if (std.mem.eql(u8, shape, "bar")) 5 else 1;
        var b: [16]u8 = undefined;
        try out.appendSlice(alloc, std.fmt.bufPrint(&b, "\x1b[{d} q", .{if (blink) ps else ps + 1}) catch "");
        if (jsonBool(cur, "visible") orelse true) try out.appendSlice(alloc, "\x1b[?25h");
    };
    try out.appendSlice(alloc, "\x1b[?2026l");
    cwrite(posix.STDOUT_FILENO, out.items);
}

fn sendView(fd: c.fd_t, alloc: std.mem.Allocator, value: anytype) void {
    const j = std.json.Stringify.valueAlloc(alloc, value, .{}) catch return;
    defer alloc.free(j);
    cwrite(fd, j);
    cwrite(fd, "\n");
}

fn sendKeys(fd: c.fd_t, alloc: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const enc = std.base64.standard.Encoder;
    const b64 = alloc.alloc(u8, enc.calcSize(bytes.len)) catch return;
    defer alloc.free(b64);
    sendView(fd, alloc, .{ .input = "bytes", .b64 = enc.encode(b64, bytes) });
}

fn runAttach(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const id_str = if (args.len > 0) args[0] else "1";
    const pane_id = std.fmt.parseInt(u64, id_str, 10) catch {
        std.debug.print("zterm attach: '{s}' is not a pane id (see `zterm cli list`)\n", .{id_str});
        return error.BadUsage;
    };

    const fd = try connectServer(alloc);
    defer pclose(fd);

    // Attach at OUR terminal's size so the pane matches this window.
    var ws = pty.getTerminalSize(posix.STDIN_FILENO) catch pty.Winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    sendView(fd, alloc, .{ .cmd = "view", .pane = pane_id, .rows = ws.ws_row, .cols = ws.ws_col });

    var raw = try pty.RawMode.enter(posix.STDIN_FILENO);
    defer raw.exit();
    _ = signal(@intFromEnum(c.SIG.WINCH), onWinch);
    cwrite(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[H\x1b[2J");

    var have: HostModes = .{};
    var theme = ViewTheme.fromConfig(&config.Theme{});
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(alloc);
    var inbuf: std.ArrayList(u8) = .empty;
    defer inbuf.deinit(alloc);
    var buf: [65536]u8 = undefined;
    var held_prefix = false; // saw Ctrl-b, deciding between detach and passthrough
    var ending: enum { detached, exited, lost, refused } = .detached;
    var exit_code: ?i64 = null;

    outer: while (true) {
        if (winch_seen.swap(false, .monotonic)) {
            if (pty.getTerminalSize(posix.STDIN_FILENO)) |now| {
                if (now.ws_row != ws.ws_row or now.ws_col != ws.ws_col) {
                    ws = now;
                    sendView(fd, alloc, .{ .resize = .{ .rows = ws.ws_row, .cols = ws.ws_col } });
                }
            } else |_| {}
        }
        var pfds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&pfds, 250) catch continue;

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const r = posix.read(fd, &buf) catch {
                ending = .lost;
                break;
            };
            if (r == 0) {
                ending = .lost;
                break;
            }
            try inbuf.appendSlice(alloc, buf[0..r]);
            while (std.mem.indexOfScalar(u8, inbuf.items, '\n')) |nl| {
                defer {
                    const rest = inbuf.items.len - (nl + 1);
                    std.mem.copyForwards(u8, inbuf.items[0..rest], inbuf.items[nl + 1 ..]);
                    inbuf.items.len = rest;
                }
                const parsed = std.json.parseFromSlice(std.json.Value, alloc, inbuf.items[0..nl], .{}) catch continue;
                defer parsed.deinit();
                const m = parsed.value;
                if (m != .object) continue;
                const t = jsonStr(m, "t") orelse continue;
                if (std.mem.eql(u8, t, "hello")) {
                    if (m.object.get("theme")) |th| theme.apply(th);
                } else if (std.mem.eql(u8, t, "palette")) {
                    if (m.object.get("theme")) |th| theme.apply(th);
                } else if (std.mem.eql(u8, t, "frame")) {
                    try drawFrame(alloc, m, &have, &title, &theme);
                } else if (std.mem.eql(u8, t, "bell")) {
                    cwrite(posix.STDOUT_FILENO, "\x07");
                } else if (std.mem.eql(u8, t, "clipboard")) {
                    // Hand the application's OSC 52 write to this terminal,
                    // which applies its own policy. Base64 is OSC-safe.
                    if (jsonStr(m, "b64")) |b64| {
                        cwrite(posix.STDOUT_FILENO, "\x1b]52;c;");
                        cwrite(posix.STDOUT_FILENO, b64);
                        cwrite(posix.STDOUT_FILENO, "\x07");
                    }
                } else if (std.mem.eql(u8, t, "exit")) {
                    exit_code = jsonInt(m, "code");
                    ending = .exited;
                    break :outer;
                } else if (std.mem.eql(u8, t, "error")) {
                    ending = .refused;
                    break :outer;
                }
            }
        }

        if (pfds[0].revents & posix.POLL.IN != 0) {
            const r = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (r == 0) break;
            // Everything but the detach chord goes to the pane as typed:
            // the host already encodes it per the mirrored modes.
            var fwd: std.ArrayList(u8) = .empty;
            defer fwd.deinit(alloc);
            var i: usize = 0;
            while (i < r) : (i += 1) {
                const b = buf[i];
                if (held_prefix) {
                    held_prefix = false;
                    if (b == 'd') {
                        sendKeys(fd, alloc, fwd.items);
                        break :outer; // Ctrl-b d → detach
                    }
                    try fwd.append(alloc, 0x02); // not a detach: deliver the withheld prefix
                    if (b == 0x02) continue; // Ctrl-b Ctrl-b = ONE literal Ctrl-b
                    try fwd.append(alloc, b);
                    continue;
                }
                if (b == 0x02) {
                    held_prefix = true;
                    continue;
                }
                try fwd.append(alloc, b);
            }
            sendKeys(fd, alloc, fwd.items);
        }
    }

    // Leave the host terminal as we found it.
    cwrite(posix.STDOUT_FILENO, "\x1b[?1l\x1b[?2004l\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l");
    raw.exit();
    switch (ending) {
        .detached => std.debug.print("[zterm: detached — pane {d} keeps running; `zterm attach {d}` to return]\n", .{ pane_id, pane_id }),
        .exited => if (exit_code) |code|
            std.debug.print("[zterm: pane {d} exited ({d})]\n", .{ pane_id, code })
        else
            std.debug.print("[zterm: pane {d} exited]\n", .{pane_id}),
        .lost => std.debug.print("[zterm: the server went away]\n", .{}),
        .refused => std.debug.print("[zterm: no pane {d} (see `zterm cli list`)]\n", .{pane_id}),
    }
}

// ══ MAIN ══════════════════════════════════════════════════════════════════════════════════════════════
fn usage() void {
    std.debug.print(
        \\zterm {s} — terminal multiplexer
        \\
        \\usage: zterm [new [-s NAME]]      the multiplexer, in this terminal
        \\       zterm server [--no-runner] [--runner-socket PATH] [--frame-ms N]
        \\                                 headless pane pool (a service; baton's runner)
        \\       zterm attach <pane>        this terminal onto a server pane
        \\       zterm cli <list|spawn|send <id> <text>|enter <id>|capture <id>|kill <id>>
        \\       zterm cli send <id> -- <text…>   (JSON path: binary-safe, submits with Enter)
        \\       zterm cli '<json request>'
        \\       zterm --version | --help
        \\
        \\In the multiplexer (prefix Ctrl-b):
        \\  d  quit — ends every shell in it     c  new window    n / p  next / previous window
        \\  %  split horizontal   "  split vertical   o  next pane
        \\  [  copy mode: j/k u/d g/G scroll, / search, n next, q/Esc/Enter exit
        \\In an attach: Ctrl-b d DETACHES — the server's shell keeps running.
        \\
        \\Sessions that outlive the terminal: run `zterm server` (as a service) and
        \\`zterm attach <pane>`. `zterm cli` drives whichever of the two owns the socket
        \\($ZTERM_SOCKET, default /tmp/zterm-<uid>.sock).
        \\
    , .{VERSION});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try args.append(alloc, a);

    // Bare `zterm`: the multiplexer, as tmux runs bare.
    if (args.items.len < 2) return visible.run(alloc, "0");
    const sub = args.items[1];
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "help")) {
        return usage();
    } else if (std.mem.eql(u8, sub, "-v") or std.mem.eql(u8, sub, "--version")) {
        std.debug.print("zterm {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, sub, "new") or std.mem.eql(u8, sub, "new-session")) {
        var name: []const u8 = "0";
        var i: usize = 2;
        while (i < args.items.len) : (i += 1) {
            if (std.mem.eql(u8, args.items[i], "-s") and i + 1 < args.items.len) {
                i += 1;
                name = args.items[i];
            } else {
                std.debug.print("zterm new: unknown option '{s}'\n", .{args.items[i]});
                return usage();
            }
        }
        try visible.run(alloc, name);
    } else if (std.mem.eql(u8, sub, "server")) {
        var opts = ServerOptions{};
        var i: usize = 2;
        while (i < args.items.len) : (i += 1) {
            const a = args.items[i];
            if (std.mem.eql(u8, a, "--no-runner")) {
                opts.runner = false;
            } else if (std.mem.eql(u8, a, "--runner-socket") and i + 1 < args.items.len) {
                i += 1;
                opts.runner_path = args.items[i];
            } else if (std.mem.eql(u8, a, "--frame-ms") and i + 1 < args.items.len) {
                i += 1;
                const ms = std.fmt.parseInt(u32, args.items[i], 10) catch {
                    std.debug.print("zterm server: --frame-ms takes a number of milliseconds (0-1000)\n", .{});
                    return usage();
                };
                opts.frame_ms = @min(ms, 1000);
            } else {
                std.debug.print("zterm server: unknown option '{s}'\n", .{a});
                return usage();
            }
        }
        try runServer(alloc, opts);
    } else if (std.mem.eql(u8, sub, "attach")) {
        try runAttach(alloc, args.items[2..]);
    } else if (std.mem.eql(u8, sub, "cli")) {
        if (args.items.len < 3) return usage();
        try runClient(alloc, args.items[2..]);
    } else {
        std.debug.print("zterm: unknown subcommand '{s}'\n", .{sub});
        usage();
    }
}

// ══ tests (pure logic; the live server is exercised by tests/mux_qa.py) ═══════════════════════════════

const testing = std.testing;

test {
    // ctl.zig's own tests (fillAddr) and view.zig's encoding tests run with
    // these; lib.zig's suite imports neither.
    _ = ctl;
    _ = view;
}

test "runner socket path follows baton's home_base tiers" {
    const a = testing.allocator;
    // Override wins over everything.
    {
        const p = (try runnerSocketPathFrom(a, "/x/r.sock", "/bh", "/h", true)).?;
        defer a.free(p);
        try testing.expectEqualStrings("/x/r.sock", p);
    }
    // $BATON_HOME next, whether or not ~/.baton exists.
    {
        const p = (try runnerSocketPathFrom(a, null, "/bh", "/h", false)).?;
        defer a.free(p);
        try testing.expectEqualStrings("/bh/var/zterm.sock", p);
    }
    // ~/.baton only when the directory is present.
    {
        const p = (try runnerSocketPathFrom(a, null, null, "/h", true)).?;
        defer a.free(p);
        try testing.expectEqualStrings("/h/.baton/var/zterm.sock", p);
    }
    try testing.expect((try runnerSocketPathFrom(a, null, null, "/h", false)) == null);
    try testing.expect((try runnerSocketPathFrom(a, null, null, null, true)) == null);
}

test "scrubForPaste drops every sequence a terminal would interpret" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "plain text", .want = "plain text" },
        .{ .in = "a\r\nb\rc\nd\te", .want = "a\nb\nc\nd\te" },
        // The bracketed-paste terminator must not survive: it would end the
        // paste and let the rest arrive as keystrokes.
        .{ .in = "x\x1b[201~rm -rf ~\r", .want = "x[201~rm -rf ~\n" },
        .{ .in = "bell\x07del\x7fnul\x00", .want = "belldelnul" },
        // C1 CSI (U+009B) is a control too, spelled as two UTF-8 bytes.
        .{ .in = "c1\xc2\x9b31m", .want = "c131m" },
        .{ .in = "wide 日本 🚀", .want = "wide 日本 🚀" },
        .{ .in = "bad\xff\xfeutf8", .want = "badutf8" },
    };
    for (cases) |tc| {
        const got = try scrubForPaste(a, tc.in);
        defer a.free(got);
        try testing.expectEqualStrings(tc.want, got);
    }
}

test "formatInjection matches baton's provenance header" {
    const a = testing.allocator;
    const cases = [_]struct { n: []const u8, g: []const u8, want: []const u8 }{
        .{ .n = "mac", .g = "dev", .want = "[federation msg — mac/dev] hi" },
        .{ .n = "mac", .g = "", .want = "[federation msg — mac] hi" },
        .{ .n = "", .g = "dev", .want = "[federation msg — dev] hi" },
        .{ .n = "", .g = "", .want = "[federation msg — unknown] hi" },
    };
    for (cases) |tc| {
        const got = try formatInjection(a, tc.n, tc.g, "hi");
        defer a.free(got);
        try testing.expectEqualStrings(tc.want, got);
    }
}

test "settleNs is baton's curve: 250ms floor, 0.3ms/byte, 1.2s cap" {
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), settleNs(0));
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), settleNs(100));
    try testing.expectEqual(@as(u64, 600 * std.time.ns_per_ms), settleNs(2000));
    try testing.expectEqual(@as(u64, 1200 * std.time.ns_per_ms), settleNs(100_000));
}

test "pasteLanded needs NEW evidence, never evidence that was already there" {
    const a = testing.allocator;
    const payload = try normalizeWs(a, "please review\n   the   diff");
    defer a.free(payload);
    try testing.expectEqualStrings("please review the diff", payload);
    const tail = tailOf(payload);
    try testing.expect(pasteLanded("$", "$ please review the diff", tail));
    // Already on screen before the paste: proves nothing.
    try testing.expect(!pasteLanded("please review the diff", "please review the diff", tail));
    try testing.expect(!pasteLanded("$", "$ please rev", tail));
    // Claude Code collapses a big paste into a placeholder.
    try testing.expect(pasteLanded("> ", "> [Pasted text #1 +40 lines]", tail));
    try testing.expect(!pasteLanded("[Pasted text #1]", "[Pasted text #1]", tail));
}

test "tailOf keeps at most 48 codepoints and never splits one" {
    const long = &@as([60]u8, @splat('x')) ++ "日本語";
    const t = tailOf(long);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
    try testing.expectEqual(@as(usize, 48), try std.unicode.utf8CountCodepoints(t));
    try testing.expect(std.mem.endsWith(u8, t, "日本語"));
    try testing.expectEqualStrings("short", tailOf("short"));
}

test "designations: valid names, pid: addressing, case-insensitive match" {
    try testing.expect(validName("guardianshield-2"));
    try testing.expect(validName("agent@node.local"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("has space"));
    try testing.expect(!validName("pid:12"));
    try testing.expect(!validName(&@as([65]u8, @splat('x'))));
    try testing.expect(answersTo("Scribe", 42, "scribe"));
    try testing.expect(answersTo("scribe", 42, "pid:42"));
    try testing.expect(!answersTo("scribe", 42, "pid:41"));
    try testing.expect(!answersTo("scribe", 0, "pid:0"));
    try testing.expect(!answersTo("scribe", 42, "42"));
    try testing.expect(!answersTo("scribe", 42, "pid:abc"));
}

test "agent detection uses baton's list, or $BATON_AGENT_EXES instead of it" {
    try testing.expect(isAgentComm("claude", null));
    try testing.expect(isAgentComm("/usr/bin/codex", null));
    try testing.expect(isAgentComm("rust-agent-tui", null));
    // Interpreters are never agents: an injected message would run as code.
    try testing.expect(!isAgentComm("node", null));
    try testing.expect(!isAgentComm("zsh", null));
    try testing.expect(!isAgentComm("", null));
    try testing.expect(isAgentComm("qwen", "qwen, claude"));
    try testing.expect(!isAgentComm("codex", "qwen, claude"));
}

test "spawn env: well-formed keys and values become KEY=value entries" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"ZDOTDIR":"/run/user/1000/x","DUCK_REAL_ZDOTDIR":"","_A1":"a=b c"}
    , .{});
    defer parsed.deinit();
    var why: []const u8 = "";
    const env = parseSpawnEnv(alloc, parsed.value, &why).?;
    defer {
        freeSpawnEnv(alloc, env);
        alloc.free(env);
    }
    try std.testing.expectEqual(@as(usize, 3), env.len);
    try std.testing.expectEqualStrings("ZDOTDIR=/run/user/1000/x", env[0]);
    try std.testing.expectEqualStrings("DUCK_REAL_ZDOTDIR=", env[1]);
    try std.testing.expectEqualStrings("_A1=a=b c", env[2]);
}

test "spawn env: anything outside the bounds is refused whole" {
    const alloc = std.testing.allocator;
    var long_val: [SPAWN_ENV_MAX_VALUE + 1]u8 = undefined;
    @memset(&long_val, 'v');
    const long_json = try std.json.Stringify.valueAlloc(alloc, .{ .K = long_val[0..] }, .{});
    defer alloc.free(long_json);
    // SPAWN_ENV_MAX_VARS + 1 variables, built as a value (not formatted text).
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var many_map: std.json.ObjectMap = .empty;
    for (0..SPAWN_ENV_MAX_VARS + 1) |i| {
        try many_map.put(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "K{d}", .{i}), .{ .string = "v" });
    }
    const many = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = many_map }, .{});
    defer alloc.free(many);
    const bad = [_][]const u8{
        "[]",                   "\"X=1\"",
        "{\"lower\":\"x\"}",    "{\"1ABC\":\"x\"}",
        "{\"A-B\":\"x\"}",      "{\"\":\"x\"}",
        "{\"A\":1}",            "{\"A\":null}",
        "{\"A\":\"x\\u0000y\"}", "{\"ZTERM_PANE\":\"9\"}",
        "{\"WEZTERM_PANE\":\"9\"}", "{\"A=B\":\"x\"}",
        long_json,              many,
    };
    for (bad) |src| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
        defer parsed.deinit();
        var why: []const u8 = "";
        if (parseSpawnEnv(alloc, parsed.value, &why)) |env| {
            freeSpawnEnv(alloc, env);
            alloc.free(env);
            std.debug.print("accepted: {s}\n", .{src});
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(why.len > 0);
    }
    // The key-length bound is inclusive at 64.
    try std.testing.expect(validEnvKey(&@as([SPAWN_ENV_MAX_KEY]u8, @splat('A'))));
    try std.testing.expect(!validEnvKey(&@as([(SPAWN_ENV_MAX_KEY + 1)]u8, @splat('A'))));
}
