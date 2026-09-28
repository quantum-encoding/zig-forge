//! zterm — standalone mux server + CLI for terminal_mux, mirroring the `wezterm cli` verbs so the agent
//! ecosystem (mac-drive / imsg bridge / the roster / baton) can drive the Zig terminal exactly as it drives
//! WezTerm — with no WezTerm installed.
//!
//! TWO servers speak the control protocol:
//!   - `zterm server` — a HEADLESS pane pool (this file), for agents that need
//!     invisible shells. It is also a baton RUNNER (see "Runner door" below).
//!   - the interactive `tmux` binary — binds the same socket (src/ctl.zig), so
//!     `zterm cli` drives the VISIBLE terminal: list/send/enter/capture plus
//!     `split h|v`, `new-window`, `focus <pane>` — the wezterm-cli model.
//!   Newest binder wins the default path; $ZTERM_SOCKET targets a specific one.
//!
//! Persistent sessions (the tmux detach guarantee): the SERVER owns the
//! shells; `zterm attach <pane>` is a disposable raw window onto one. Close
//! the terminal, reattach later — the shell never notices. Ctrl-b d detaches.
//!
//! Test loop (two terminals):
//!     zterm server                 # headless pool (or just run `tmux` for the visible mux)
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
    const f = c.accept(lfd, null, null);
    if (f < 0) return error.AcceptFailed;
    setCloexec(f);
    return f;
}
/// Keep server sockets out of spawned shells. `spawn` forks a shell while the
/// client connection is open; without CLOEXEC the child inherits the socket,
/// the server's close is no longer the last close, and the client — which
/// frames the response by EOF — hangs until that shell exits. (accept4/
/// SOCK_CLOEXEC would do this atomically, but macOS has neither; fcntl is the
/// portable form, and the single-threaded accept loop leaves no fork race.)
fn setCloexec(fd: c.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
}
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
    if (override) |o| return try alloc.dupeZ(u8, o);
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
        const path = std.fmt.bufPrintZ(&pb, "/proc/{d}/comm", .{pid}) catch return null;
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
    const path = std.fmt.bufPrintZ(&pb, "/proc/{d}/cwd", .{pid}) catch return null;
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
};

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
    listeners: std.ArrayList(Listener) = .empty,
    agent_env: ?[]const u8,

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
        const lfd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (lfd < 0) return error.SocketCreateFailed;
        errdefer pclose(lfd);
        setCloexec(lfd); // shells spawned later must not inherit the listen socket
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
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
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
        const h = capi.createIn(o.rows, o.cols, null, o.cwd, true, &id) orelse {
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

            pfds.clearRetainingCapacity();
            polled_panes.clearRetainingCapacity();
            for (self.listeners.items) |l| try pfds.append(self.alloc, .{ .fd = l.fd, .events = posix.POLL.IN, .revents = 0 });
            for (self.panes.items) |p| {
                if (p.hup) continue;
                try pfds.append(self.alloc, .{ .fd = p.fd, .events = posix.POLL.IN, .revents = 0 });
                try polled_panes.append(self.alloc, p.id);
            }
            for (self.attaches.items) |a| try pfds.append(self.alloc, .{ .fd = a.conn, .events = posix.POLL.IN, .revents = 0 });
            const nl = self.listeners.items.len;
            const np = polled_panes.items.len;
            const attach_count = self.attaches.items.len;

            // A pending submit is watched for evidence every ~50ms; otherwise
            // wake once a second so a stop signal is noticed promptly.
            const timeout: i32 = if (self.submits.items.len > 0) 50 else 1000;
            _ = posix.poll(pfds.items, timeout) catch continue;

            // Pane output: read the raw bytes ONCE — feed the VT grid (so capture/
            // list stay live) and mirror them to every attached client.
            for (polled_panes.items, 0..) |pid, k| {
                const rev = pfds.items[nl + k].revents;
                if (rev == 0) continue;
                const p = self.findPane(pid) orelse continue;
                if (rev & posix.POLL.IN == 0) {
                    // HUP/ERR with nothing to read: the slave side is closed.
                    if (rev & (posix.POLL.HUP | posix.POLL.ERR) != 0) p.hup = true;
                    continue;
                }
                // Linux reports a dead child as EIO on the master, macOS as 0
                // bytes; both mean "stop polling this pane".
                const r = posix.read(p.fd, &io_buf) catch |err| {
                    if (err != error.WouldBlock) p.hup = true;
                    continue;
                };
                if (r == 0) {
                    p.hup = true;
                    continue;
                }
                p.spane().processOutput(io_buf[0..r]);
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
                } else {
                    pclose(a.conn);
                    a.conn = -1;
                }
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
                    if (rows > 1 and cols > 1) _ = capi.tmux_resize(p.handle, rows, cols);
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
        } else if (std.mem.eql(u8, cmd, "spawn")) {
            var why: []const u8 = "";
            const o = SpawnOpts{
                .rows = clampDim(jsonInt(v, "rows"), 40),
                .cols = clampDim(jsonInt(v, "cols"), 120),
                .cwd = jsonStr(v, "cwd"),
                .name = jsonStr(v, "name"),
                .run = jsonStr(v, "run"),
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
            cwrite(conn, if (capi.tmux_resize(p.handle, rows, cols) == 0) "{\"ok\":true}\n" else "{\"ok\":false,\"error\":\"resize failed\"}\n");
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
// `zterm attach <pane>` — the persistent-session workflow: the SERVER owns the
// shell; this client is a disposable raw-mode window onto it. Close the
// terminal, reattach later, the shell never noticed. Detach key: Ctrl-b d.

fn runAttach(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const id_str = if (args.len > 0) args[0] else "1";

    const fd = try connectServer(alloc);
    defer pclose(fd);

    // Attach at OUR terminal's size so the pane's PTY matches this window.
    const ws = pty.getTerminalSize(posix.STDIN_FILENO) catch pty.Winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    var req_buf: [64]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "attach {s} {d} {d}\n", .{ id_str, ws.ws_row, ws.ws_col }) catch return error.BadUsage;
    _ = try pwrite(fd, req);

    var raw = try pty.RawMode.enter(posix.STDIN_FILENO);
    defer raw.exit();

    var buf: [65536]u8 = undefined;
    var held_prefix = false; // saw Ctrl-b, deciding between detach and passthrough
    outer: while (true) {
        var pfds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&pfds, 1000) catch continue;

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const r = posix.read(fd, &buf) catch break;
            if (r == 0) break; // server gone or pane killed
            _ = pwrite(posix.STDOUT_FILENO, buf[0..r]) catch break;
        }

        if (pfds[0].revents & posix.POLL.IN != 0) {
            const r = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (r == 0) break;
            var i: usize = 0;
            while (i < r) {
                if (held_prefix) {
                    held_prefix = false;
                    const b = buf[i];
                    if (b == 'd') break :outer; // Ctrl-b d → detach
                    // Not a detach: deliver the withheld prefix.
                    _ = pwrite(fd, &[_]u8{0x02}) catch break :outer;
                    if (b == 0x02) { // Ctrl-b Ctrl-b = ONE literal Ctrl-b (sent)
                        i += 1;
                        continue;
                    }
                    // b joins the span below.
                }
                var j = i;
                while (j < r and buf[j] != 0x02) j += 1;
                if (j > i) _ = pwrite(fd, buf[i..j]) catch break :outer;
                if (j < r) { // hit a prefix: hold it, decide on the next byte
                    held_prefix = true;
                    j += 1;
                }
                i = j;
            }
        }
    }
    raw.exit();
    std.debug.print("\n[zterm: detached — pane keeps running; `zterm attach {s}` to return]\n", .{id_str});
}

// ══ MAIN ══════════════════════════════════════════════════════════════════════════════════════════════
fn usage() void {
    std.debug.print(
        \\usage: zterm server [--no-runner] [--runner-socket PATH]
        \\       zterm attach <pane>
        \\       zterm cli <list|spawn|send <id> <text>|enter <id>|capture <id>|kill <id>>
        \\       zterm cli send <id> -- <text…>     (JSON path: binary-safe, submits with Enter)
        \\       zterm cli '<json request>'
        \\  attach: raw window onto a server pane; Ctrl-b d detaches (shell keeps running)
        \\  server: also answers baton's runner contract on <fleet home>/var/zterm.sock
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try args.append(alloc, a);

    if (args.items.len < 2) return usage();
    const sub = args.items[1];
    if (std.mem.eql(u8, sub, "server")) {
        var opts = ServerOptions{};
        var i: usize = 2;
        while (i < args.items.len) : (i += 1) {
            const a = args.items[i];
            if (std.mem.eql(u8, a, "--no-runner")) {
                opts.runner = false;
            } else if (std.mem.eql(u8, a, "--runner-socket") and i + 1 < args.items.len) {
                i += 1;
                opts.runner_path = args.items[i];
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
    // ctl.zig's own tests (fillAddr) run with these; lib.zig's suite does not import ctl.
    _ = ctl;
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
    const long = "x" ** 60 ++ "日本語";
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
    try testing.expect(!validName("x" ** 65));
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
