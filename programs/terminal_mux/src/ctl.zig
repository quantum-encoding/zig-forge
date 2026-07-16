//! Control socket for the INTERACTIVE mux — the `wezterm cli` analogue.
//!
//! The standalone `tmux` binary binds a unix socket and answers the same
//! one-line protocol `zterm cli` speaks, so a driver (mac-drive, an agent, a
//! script) can list/send/capture/split the panes of the terminal the user is
//! actually looking at — not a separate headless pool (that's `zterm server`).
//!
//!     zterm cli list                → [{"pane":0,"window":0,"active":true,...}]
//!     zterm cli send 0 ls -la       → types into pane 0 (no implicit Enter)
//!     zterm cli enter 0             → presses Return in pane 0
//!     zterm cli capture 0           → pane 0's grid as plain text
//!     zterm cli split h|v           → split the active pane + spawn a shell
//!     zterm cli new-window          → new window + shell, focused
//!     zterm cli focus <pane>        → focus that pane (switches window too)
//!     zterm cli kill <pane>         → kill the pane (refused for the last one)
//!
//! Pane ids are FLAT INDICES over windows-then-panes at the time of the call —
//! stable between layout changes; re-`list` after split/kill.
//!
//! Socket: $ZTERM_SOCKET, else /tmp/zterm-<uid>.sock (same default as zterm,
//! newest binder wins the path — one visible mux per user is the normal case).

const std = @import("std");
const c = std.c;
const posix = std.posix;
const session = @import("session.zig");

pub const Ctl = struct {
    fd: c.fd_t,
    path: [:0]u8,

    pub fn deinit(self: *Ctl, alloc: std.mem.Allocator) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        _ = c.unlink(self.path.ptr);
        alloc.free(self.path);
    }
};

pub fn socketPath(alloc: std.mem.Allocator) ![:0]u8 {
    if (c.getenv("ZTERM_SOCKET")) |p| {
        const s = std.mem.sliceTo(p, 0);
        if (s.len > 0) return alloc.dupeZ(u8, s);
    }
    return std.fmt.allocPrintSentinel(alloc, "/tmp/zterm-{d}.sock", .{c.getuid()}, 0);
}

fn fillAddr(path: []const u8) c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    const n = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..n], path[0..n]);
    return addr;
}

/// Bind + listen. Errors are the caller's to swallow — a mux without a control
/// socket is degraded, not broken.
pub fn bind(alloc: std.mem.Allocator) !Ctl {
    const path = try socketPath(alloc);
    errdefer alloc.free(path);
    _ = c.unlink(path.ptr);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = c.close(fd);
    var addr = fillAddr(path);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.BindFailed;
    if (c.listen(fd, 16) < 0) return error.ListenFailed;
    return .{ .fd = fd, .path = path };
}

fn cwrite(fd: c.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (r <= 0) return;
        off += @intCast(r);
    }
}

/// Flat pane addressing: windows in order, panes in order within each.
const PaneRef = struct { window: *session.Window, win_idx: usize, pane: *session.Pane, pane_idx: usize };

fn nthPane(sess: *session.Session, n: usize) ?PaneRef {
    var i: usize = 0;
    for (sess.windows.items, 0..) |w, wi| {
        for (w.panes.items, 0..) |p, pi| {
            if (i == n) return .{ .window = w, .win_idx = wi, .pane = p, .pane_idx = pi };
            i += 1;
        }
    }
    return null;
}

fn appendJsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch >= 0x20) try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

/// Accept one pending connection and serve one request. Returns true when the
/// command changed layout/focus (caller should clear + full-redraw).
pub fn accept(
    listen_fd: c.fd_t,
    sess: *session.Session,
    shell: []const u8,
    env: [*:null]const ?[*:0]const u8,
    alloc: std.mem.Allocator,
) bool {
    const conn = c.accept(listen_fd, null, null);
    if (conn < 0) return false;
    defer _ = c.close(conn);

    // Don't let a stalled client wedge the UI loop.
    const tv = c.timeval{ .sec = 0, .usec = 500_000 };
    _ = c.setsockopt(conn, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));

    return handle(conn, sess, shell, env, alloc) catch false;
}

fn handle(
    conn: c.fd_t,
    sess: *session.Session,
    shell: []const u8,
    env: [*:null]const ?[*:0]const u8,
    alloc: std.mem.Allocator,
) !bool {
    var buf: [4096]u8 = undefined;
    const n = posix.read(conn, &buf) catch return false;
    if (n == 0) return false;
    var ln = n;
    while (ln > 0 and (buf[ln - 1] == '\n' or buf[ln - 1] == '\r')) ln -= 1;
    var it = std.mem.tokenizeScalar(u8, buf[0..ln], ' ');
    const cmd = it.next() orelse return false;

    if (std.mem.eql(u8, cmd, "list")) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '[');
        var flat: usize = 0;
        for (sess.windows.items, 0..) |w, wi| {
            for (w.panes.items, 0..) |p, pi| {
                const grid = &p.terminal.grid;
                const pid: i64 = if (p.pty) |pt| (if (pt.child_pid) |cp| @intCast(cp) else 0) else 0;
                const active = wi == sess.active_window_idx and pi == w.active_pane_idx;
                if (flat != 0) try out.append(alloc, ',');
                var hb: [128]u8 = undefined;
                try out.appendSlice(alloc, std.fmt.bufPrint(
                    &hb,
                    "{{\"pane\":{d},\"window\":{d},\"active\":{},\"rows\":{d},\"cols\":{d},\"pid\":{d},\"cwd\":",
                    .{ flat, wi, active, grid.rows, grid.cols, pid },
                ) catch "{");
                try appendJsonStr(&out, alloc, p.cwd[0..p.cwd_len]);
                try out.append(alloc, '}');
                flat += 1;
            }
        }
        try out.appendSlice(alloc, "]\n");
        cwrite(conn, out.items);
        return false;
    } else if (std.mem.eql(u8, cmd, "send")) {
        const id = std.fmt.parseInt(usize, it.next() orelse "", 10) catch {
            cwrite(conn, "err usage: send <pane> <text>\n");
            return false;
        };
        const ref = nthPane(sess, id) orelse {
            cwrite(conn, "err no such pane\n");
            return false;
        };
        const text = it.rest();
        ref.pane.terminal.scrollback_offset = 0; // typing snaps to the live bottom
        if (text.len > 0) ref.pane.sendInput(text) catch {
            cwrite(conn, "err send failed\n");
            return false;
        };
        cwrite(conn, "ok\n");
        return false;
    } else if (std.mem.eql(u8, cmd, "enter")) {
        const id = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return false;
        const ref = nthPane(sess, id) orelse {
            cwrite(conn, "err no such pane\n");
            return false;
        };
        ref.pane.sendInput("\r") catch {};
        cwrite(conn, "ok\n");
        return false;
    } else if (std.mem.eql(u8, cmd, "capture")) {
        const id = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return false;
        const ref = nthPane(sess, id) orelse {
            cwrite(conn, "err no such pane\n");
            return false;
        };
        try writeCapture(conn, ref.pane, alloc);
        return false;
    } else if (std.mem.eql(u8, cmd, "split")) {
        const dir = it.next() orelse "h";
        const d: session.SplitDirection = if (dir.len > 0 and (dir[0] == 'v' or dir[0] == 'V'))
            .vertical
        else
            .horizontal;
        const w = sess.getActiveWindow();
        const new_pane = w.split(d, 10_000) catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"split failed\"}\n");
            return false;
        };
        new_pane.spawn(shell, env) catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"spawn failed\"}\n");
            return true;
        };
        var b: [64]u8 = undefined;
        cwrite(conn, std.fmt.bufPrint(&b, "{{\"ok\":true,\"pane\":{d}}}\n", .{flatIndexOf(sess, new_pane) orelse 0}) catch "{\"ok\":true}\n");
        return true;
    } else if (std.mem.eql(u8, cmd, "new-window")) {
        const new_win = sess.createWindow() catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"create failed\"}\n");
            return false;
        };
        _ = sess.selectWindow(new_win.index);
        new_win.getActivePane().spawn(shell, env) catch {
            cwrite(conn, "{\"ok\":false,\"error\":\"spawn failed\"}\n");
            return true;
        };
        var b: [64]u8 = undefined;
        cwrite(conn, std.fmt.bufPrint(&b, "{{\"ok\":true,\"pane\":{d}}}\n", .{flatIndexOf(sess, new_win.getActivePane()) orelse 0}) catch "{\"ok\":true}\n");
        return true;
    } else if (std.mem.eql(u8, cmd, "focus")) {
        const id = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return false;
        const ref = nthPane(sess, id) orelse {
            cwrite(conn, "err no such pane\n");
            return false;
        };
        _ = sess.selectWindow(ref.win_idx);
        ref.window.panes.items[ref.window.active_pane_idx].active = false;
        ref.window.active_pane_idx = ref.pane_idx;
        ref.pane.active = true;
        cwrite(conn, "ok\n");
        return true;
    } else if (std.mem.eql(u8, cmd, "kill")) {
        const id = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return false;
        const ref = nthPane(sess, id) orelse {
            cwrite(conn, "err no such pane\n");
            return false;
        };
        if (ref.window.panes.items.len <= 1) {
            if (!sess.removeWindow(ref.win_idx)) {
                cwrite(conn, "err cannot kill the last pane\n");
                return false;
            }
            cwrite(conn, "ok\n");
            return true;
        }
        _ = ref.window.removePane(ref.pane.id);
        ref.window.resize(sess.rect) catch {};
        cwrite(conn, "ok\n");
        return true;
    }
    cwrite(conn, "err unknown command\n");
    return false;
}

fn flatIndexOf(sess: *session.Session, pane: *session.Pane) ?usize {
    var i: usize = 0;
    for (sess.windows.items) |w| {
        for (w.panes.items) |p| {
            if (p == pane) return i;
            i += 1;
        }
    }
    return null;
}

/// The pane's grid as UTF-8 text, one line per row, trailing blanks trimmed.
/// Skips wide-glyph continuation cells (char 0 / width 0) — they'd emit NULs.
fn writeCapture(conn: c.fd_t, pane: *session.Pane, alloc: std.mem.Allocator) !void {
    const grid = pane.terminal.getCurrentGrid();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var r: u16 = 0;
    while (r < grid.rows) : (r += 1) {
        const line_start = out.items.len;
        var col: u16 = 0;
        while (col < grid.cols) : (col += 1) {
            const cell = grid.getCellConst(r, col);
            if (cell.width == 0 or cell.char == 0) continue;
            var ub: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &ub) catch continue;
            try out.appendSlice(alloc, ub[0..len]);
        }
        while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
        }
        try out.append(alloc, '\n');
    }
    cwrite(conn, out.items);
}
