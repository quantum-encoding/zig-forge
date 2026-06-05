//! chronos-run — PTY pump that captures Claude Code's live spinner gerund.
//!
//! Usage:  chronos-run <command> [args...]      e.g.  chronos-run claude
//!         alias claude='chronos-run claude'    (transparent, in ~/.zshrc)
//!
//! It allocates a PTY, runs <command> inside it as a child, and pumps bytes
//! between your real terminal and the child. While pumping, it scans the child's
//! output for the spinner ("✶ Skedaddling…" / legacy "Elucidating (esc to
//! interrupt") and writes the gerund to /tmp/cognitive-state-<child_pid> in the
//! format "<unix_ts>:<state>" — exactly what get-cognitive-state reads. Multiple
//! claudes each run under their own chronos-run, so each maintains its own file
//! keyed by its PID.
//!
//! Zero privilege, zero injection: chronos-run is simply the PARENT of claude, so
//! it sees the bytes legitimately and is immune to hardened runtime. macOS-only
//! (uses forkpty); the scan is allocation-free on the hot path.
//!
//! Copyright (c) Quantum Encoding Ltd — dual MIT (non-commercial) / commercial.

const std = @import("std");

// ── libc (this Zig's std.posix/std.c are stripped; declare what we need) ──
const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
const Termios = extern struct {
    c_iflag: c_ulong,
    c_oflag: c_ulong,
    c_cflag: c_ulong,
    c_lflag: c_ulong,
    c_cc: [20]u8,
    c_ispeed: c_ulong,
    c_ospeed: c_ulong,
};
const Pollfd = extern struct { fd: c_int, events: i16, revents: i16 };

extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const Termios, winp: ?*const Winsize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn tcgetattr(fd: c_int, t: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, t: *const Termios) c_int;
extern "c" fn cfmakeraw(t: *Termios) void;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn poll(fds: [*]Pollfd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*anyopaque;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

const STDIN = 0;
const STDOUT = 1;
const TIOCGWINSZ: c_ulong = 0x40087468; // macOS
const TIOCSWINSZ: c_ulong = 0x80087467; // macOS
const TCSANOW: c_int = 0;
const POLLIN: i16 = 0x0001;
const POLLHUP: i16 = 0x0010;
const POLLERR: i16 = 0x0008;
const SIGWINCH: c_int = 28;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

var g_master: c_int = -1;
var g_winch: bool = false;

fn onWinch(_: c_int) callconv(.c) void {
    g_winch = true;
}

fn propagateWinsize() void {
    if (g_master < 0) return;
    var ws: Winsize = undefined;
    if (ioctl(STDIN, TIOCGWINSZ, &ws) == 0) {
        _ = ioctl(g_master, TIOCSWINSZ, &ws);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const vec = init.args.vector; // []const [*:0]const u8 (raw C argv)
    if (vec.len < 2) {
        const msg = "usage: chronos-run <command> [args...]   (e.g. chronos-run claude)\n";
        _ = write(2, msg, msg.len);
        return 2;
    }

    // Build child argv (null-terminated) from our args[1..].
    var child_argv: [256]?[*:0]const u8 = undefined;
    const n_args = vec.len - 1;
    if (n_args + 1 > child_argv.len) return 2;
    for (0..n_args) |i| child_argv[i] = vec[i + 1];
    child_argv[n_args] = null;

    // Snapshot the real terminal so the PTY matches it (size + modes).
    const have_tty = isatty(STDIN) == 1;
    var orig: Termios = undefined;
    var ws: Winsize = undefined;
    const have_termios = have_tty and tcgetattr(STDIN, &orig) == 0;
    const have_ws = have_tty and ioctl(STDIN, TIOCGWINSZ, &ws) == 0;

    var master: c_int = -1;
    const pid = forkpty(
        &master,
        null,
        if (have_termios) &orig else null,
        if (have_ws) &ws else null,
    );
    if (pid < 0) {
        const msg = "chronos-run: forkpty failed\n";
        _ = write(2, msg, msg.len);
        return 1;
    }

    if (pid == 0) {
        // Child: forkpty already made the slave our controlling tty and dup'd it
        // onto 0/1/2. Just exec the target.
        _ = execvp(child_argv[0].?, @ptrCast(&child_argv));
        _exit(127);
    }

    // ── Parent ──
    g_master = master;
    _ = signal(SIGWINCH, &onWinch);

    // Put our own stdin in raw mode so keystrokes flow untouched to the child.
    var raw: Termios = orig;
    if (have_termios) {
        cfmakeraw(&raw);
        _ = tcsetattr(STDIN, TCSANOW, &raw);
    }

    pump(master, pid);

    // Restore terminal and reap.
    if (have_termios) _ = tcsetattr(STDIN, TCSANOW, &orig);
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    removeStateFile(pid);

    const code: u8 = if ((@as(u32, @bitCast(status)) & 0x7f) == 0)
        @intCast((@as(u32, @bitCast(status)) >> 8) & 0xff)
    else
        1;
    return code;
}

fn pump(master: c_int, child_pid: c_int) void {
    var pfds = [2]Pollfd{
        .{ .fd = STDIN, .events = POLLIN, .revents = 0 },
        .{ .fd = master, .events = POLLIN, .revents = 0 },
    };

    var rbuf: [8192]u8 = undefined;
    var scanbuf: [8192]u8 = undefined;
    var clean: [8192]u8 = undefined; // ANSI-stripped scratch for the scanner
    var scanlen: usize = 0;
    var last_state: [48]u8 = undefined;
    var last_len: usize = 0;

    while (true) {
        const r = poll(&pfds, 2, -1);
        if (r < 0) {
            if (g_winch) {
                propagateWinsize();
                g_winch = false;
            }
            continue; // EINTR (e.g. SIGWINCH)
        }

        // Child output -> our stdout, plus spinner scan.
        if (pfds[1].revents & (POLLIN | POLLHUP | POLLERR) != 0) {
            const got = read(master, &rbuf, rbuf.len);
            if (got <= 0) break; // child closed the PTY
            const ng: usize = @intCast(got);
            _ = write(STDOUT, &rbuf, ng);

            scanlen = appendScan(&scanbuf, scanlen, rbuf[0..ng]);
            if (scanSpinner(scanbuf[0..scanlen], &clean)) |state| {
                if (!eql(state, last_state[0..last_len])) {
                    writeStateFile(child_pid, state);
                    const keep = @min(state.len, last_state.len);
                    @memcpy(last_state[0..keep], state[0..keep]);
                    last_len = keep;
                }
            }
        }

        // Our stdin -> child.
        if (pfds[0].fd >= 0 and pfds[0].revents & (POLLIN | POLLHUP | POLLERR) != 0) {
            const got = read(STDIN, &rbuf, rbuf.len);
            if (got > 0) {
                _ = write(master, &rbuf, @intCast(got));
            } else {
                pfds[0].fd = -1; // stdin EOF/closed — stop watching (poll ignores fd<0)
            }
        }

        if (g_winch) {
            propagateWinsize();
            g_winch = false;
        }
    }
}

/// Append `chunk` into the sliding scan buffer, keeping the most-recent bytes so
/// a spinner sequence split across reads is still seen. Returns new length.
fn appendScan(buf: *[8192]u8, len: usize, chunk: []const u8) usize {
    if (chunk.len >= buf.len) {
        @memcpy(buf[0..buf.len], chunk[chunk.len - buf.len ..]);
        return buf.len;
    }
    var l = len;
    if (l + chunk.len > buf.len) {
        const keep = buf.len - chunk.len; // make room, keep the tail
        std.mem.copyForwards(u8, buf[0..keep], buf[l - keep .. l]);
        l = keep;
    }
    @memcpy(buf[l .. l + chunk.len], chunk);
    return l + chunk.len;
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

/// Strip ANSI escape sequences + CR/NUL from `src` into `dst`, returning the
/// cleaned length. Claude's TUI is dense ANSI (truecolor + cursor positioning
/// like `\x1b[60G`), so we MUST clean before scanning. UTF-8 (glyphs, "…", "·",
/// "↑") is preserved.
fn stripAnsi(src: []const u8, dst: []u8) usize {
    var di: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (ch == 0x1b) { // ESC
            i += 1;
            if (i < src.len and src[i] == '[') { // CSI: ESC [ params final
                i += 1;
                while (i < src.len and !(src[i] >= 0x40 and src[i] <= 0x7e)) i += 1;
                if (i < src.len) i += 1; // final byte
            } else if (i < src.len and src[i] == ']') { // OSC: ESC ] ... BEL/ST
                i += 1;
                while (i < src.len and src[i] != 0x07) {
                    if (src[i] == 0x1b and i + 1 < src.len and src[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                if (i < src.len and src[i] == 0x07) i += 1;
            } else if (i < src.len) {
                i += 1; // other two-byte escape
            }
            continue;
        }
        if (ch == '\r' or ch == 0x00) {
            i += 1;
            continue;
        }
        if (di < dst.len) {
            dst[di] = ch;
            di += 1;
        }
        i += 1;
    }
    return di;
}

/// Find the current spinner gerund, or null. The version-proof signature is
/// "<Capitalised word>… (" — e.g. "✢ Sprouting… (5m 10s · ↑ 17.7k tokens)" or
/// the older "Pondering… (esc to interrupt)". The trailing "(" is what
/// distinguishes the spinner from UI chrome (the input placeholder "…create a…"
/// is followed by a cursor move, not "("). `clean` is a caller-owned scratch
/// buffer; the returned slice points into it and is valid until the next call.
fn scanSpinner(raw: []const u8, clean: []u8) ?[]const u8 {
    const n = stripAnsi(raw, clean);
    const buf = clean[0..n];
    if (buf.len < 4) return null;

    // Newest "…(" wins — the spinner redraws, so the last match is current.
    var ell: ?usize = null;
    var i: usize = 0;
    while (i + 3 <= buf.len) : (i += 1) {
        if (buf[i] == 0xE2 and buf[i + 1] == 0x80 and buf[i + 2] == 0xA6) {
            var j = i + 3;
            while (j < buf.len and buf[j] == ' ') j += 1;
            if (j < buf.len and buf[j] == '(') ell = i;
        }
    }
    if (ell) |e| {
        var s = e;
        while (s > 0 and isAlpha(buf[s - 1])) s -= 1;
        const word = buf[s..e];
        if (word.len >= 3 and word.len <= 32 and word[0] >= 'A' and word[0] <= 'Z') return word;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn stateFilePath(buf: *[64]u8, pid: c_int) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/cognitive-state-{d}", .{pid}) catch unreachable;
}

/// Write "<ts>:<state>" atomically (temp + rename) so the reader never sees a
/// torn line. Allocation-free.
fn writeStateFile(pid: c_int, state: []const u8) void {
    var pbuf: [64]u8 = undefined;
    const path = stateFilePath(&pbuf, pid);
    var tbuf: [80]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tbuf, "/tmp/.cognitive-state-{d}.tmp", .{pid}) catch return;

    var line: [128]u8 = undefined;
    const out = std.fmt.bufPrint(&line, "{d}:{s}", .{ time(null), state }) catch return;

    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return;
    _ = write(fd, out.ptr, out.len);
    _ = close(fd);
    _ = rename(tmp.ptr, path.ptr);
}

fn removeStateFile(pid: c_int) void {
    var pbuf: [64]u8 = undefined;
    const path = stateFilePath(&pbuf, pid);
    _ = unlink(path.ptr);
}
