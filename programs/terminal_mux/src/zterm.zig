//! zterm — standalone mux server + CLI for terminal_mux, mirroring the `wezterm cli` verbs so the agent
//! ecosystem (mac-drive / imsg bridge / the roster) can drive the Zig terminal exactly as it drives WezTerm.
//!
//! TWO servers speak this protocol:
//!   - `zterm server` — a HEADLESS pane pool (this file), for agents that need
//!     invisible shells.
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
//!     zterm cli list               # → pane <id> <rows>x<cols>
//!     zterm cli spawn              # → pane <id>   (new shell; headless server only)
//!     zterm cli send <id> "ls -la" # type into a pane (no implicit Enter; add \n yourself or use --enter)
//!     zterm cli capture <id>       # dump the pane's grid as text  (get-text)
//!     zterm cli kill <id>
//!
//! Wire protocol (deliberately trivial for now — one request line, one response, close):
//!     request:  "<cmd> <args...>\n"
//!     response: text bytes, then EOF.
//! JSON output + CosmicDuck's embedded server come later; this proves the loop from a shell first.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const capi = @import("capi.zig");
const pty = @import("pty.zig");

fn socketPath(alloc: std.mem.Allocator) ![:0]u8 {
    // $ZTERM_SOCKET overrides (matches ctl.zig, so a driver can target a
    // specific mux instance); default is the shared per-user path. Note the
    // interactive `tmux` binary binds this same default — newest binder wins.
    if (c.getenv("ZTERM_SOCKET")) |p| {
        const s = std.mem.sliceTo(p, 0);
        if (s.len > 0) return alloc.dupeZ(u8, s);
    }
    return std.fmt.allocPrintSentinel(alloc, "/tmp/zterm-{d}.sock", .{c.getuid()}, 0);
}

// ── shared: bind a sockaddr.un to a path (mirrors ipc.zig) ───────────────────────────────────────────
fn fillAddr(path: []const u8) c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    const n = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..n], path[0..n]);
    return addr;
}

// std.posix (zig 0.16) only exposes read/poll for these; accept/write/close live in std.c. Thin wrappers
// keep the same shapes the call sites use.
fn pwrite(fd: c.fd_t, bytes: []const u8) !usize {
    const r = c.write(fd, bytes.ptr, bytes.len);
    if (r < 0) return error.WriteFailed;
    return @intCast(r);
}
fn paccept(lfd: c.fd_t) !c.fd_t {
    const f = c.accept(lfd, null, null);
    if (f < 0) return error.AcceptFailed;
    return f;
}
fn pclose(fd: c.fd_t) void {
    _ = c.close(fd);
}

/// Append a JSON-escaped string ("..."), so cwd/title with quotes/backslashes don't break the output.
fn appendJsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch >= 0x20) try out.append(alloc, ch), // drop other control bytes
    };
    try out.append(alloc, '"');
}

// ══ SERVER ════════════════════════════════════════════════════════════════════════════════════════════
const Pane = struct { id: u64, handle: *capi.TmuxSession, fd: i32 };

fn spawnPane(panes: *std.ArrayList(Pane), alloc: std.mem.Allocator) !u64 {
    var id: u64 = 0;
    const h = capi.tmux_create(40, 120, null, &id) orelse return error.SpawnFailed;
    try panes.append(alloc, .{ .id = id, .handle = h, .fd = capi.tmux_pty_fd(h) });
    return id;
}

fn findPane(panes: *std.ArrayList(Pane), id: u64) ?*Pane {
    for (panes.items) |*p| if (p.id == id) return p;
    return null;
}

/// A live `zterm attach` connection: raw PTY passthrough for one pane. The
/// pane's output broadcasts to every attach; attach input writes to the pane.
/// conn == -1 marks a dead entry awaiting the sweep.
const Attach = struct { conn: c.fd_t, pane_id: u64 };

fn runServer(alloc: std.mem.Allocator) !void {
    const path = try socketPath(alloc);
    defer alloc.free(path);
    _ = c.unlink(path.ptr); // clear a stale socket (path is sentinel-terminated)

    const lfd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (lfd < 0) return error.SocketCreateFailed;
    var addr = fillAddr(path);
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.BindFailed;
    // Owner-only (matches ctl.zig): any local user on a 0755 socket could
    // spawn shells and type into them.
    _ = c.chmod(path.ptr, 0o600);
    if (c.listen(lfd, 16) < 0) return error.ListenFailed;
    std.debug.print("zterm server: listening on {s}\n", .{path});

    var panes: std.ArrayList(Pane) = .empty;
    defer panes.deinit(alloc);
    const first = try spawnPane(&panes, alloc);
    std.debug.print("zterm server: pane {d} (shell) ready\n", .{first});

    var attaches: std.ArrayList(Attach) = .empty;
    defer attaches.deinit(alloc);

    var pfds: std.ArrayList(posix.pollfd) = .empty;
    defer pfds.deinit(alloc);
    var io_buf: [65536]u8 = undefined;
    while (true) {
        // Sweep dead attaches before rebuilding the poll set.
        var ai: usize = 0;
        while (ai < attaches.items.len) {
            if (attaches.items[ai].conn < 0) {
                _ = attaches.orderedRemove(ai);
            } else ai += 1;
        }

        pfds.clearRetainingCapacity();
        try pfds.append(alloc, .{ .fd = lfd, .events = posix.POLL.IN, .revents = 0 });
        for (panes.items) |p| try pfds.append(alloc, .{ .fd = p.fd, .events = posix.POLL.IN, .revents = 0 });
        for (attaches.items) |a| try pfds.append(alloc, .{ .fd = a.conn, .events = posix.POLL.IN, .revents = 0 });
        // Panes/attaches only mutate below the sections that use these counts.
        const pane_count = panes.items.len;
        const attach_count = attaches.items.len;

        _ = posix.poll(pfds.items, 1000) catch continue;

        // Pane output: read the raw bytes ONCE — feed the VT grid (so capture/
        // list stay live) and mirror them to every attached client.
        for (panes.items[0..pane_count], 0..) |p, pi| {
            if (pfds.items[1 + pi].revents & posix.POLL.IN == 0) continue;
            const r = posix.read(p.fd, &io_buf) catch continue;
            if (r == 0) continue;
            capi.tmux_feed(p.handle, &io_buf, r);
            for (attaches.items) |*a| {
                if (a.conn < 0 or a.pane_id != p.id) continue;
                _ = pwrite(a.conn, io_buf[0..r]) catch {
                    pclose(a.conn);
                    a.conn = -1;
                };
            }
        }

        // Attached clients' keystrokes → their pane. EOF = detach; the pane
        // and its shell keep running — that's the whole point.
        for (attaches.items[0..attach_count], 0..) |*a, k| {
            if (a.conn < 0) continue;
            const pf = pfds.items[1 + pane_count + k];
            if (pf.revents & (posix.POLL.IN | posix.POLL.HUP) == 0) continue;
            const r = posix.read(a.conn, &io_buf) catch {
                pclose(a.conn);
                a.conn = -1;
                continue;
            };
            if (r == 0) {
                pclose(a.conn);
                a.conn = -1;
                continue;
            }
            if (findPane(&panes, a.pane_id)) |p| {
                _ = capi.tmux_send(p.handle, &io_buf, r);
            } else {
                pclose(a.conn);
                a.conn = -1;
            }
        }

        // A client wants to issue a command (or start an attach).
        if ((pfds.items[0].revents & posix.POLL.IN) != 0) {
            const conn = paccept(lfd) catch continue;
            const keep_open = handleConn(conn, &panes, &attaches, alloc) catch false;
            if (!keep_open) pclose(conn);
        }
    }
}

/// Serve one request line. Returns true when the connection must STAY OPEN
/// (it became an attach relay).
fn handleConn(conn: i32, panes: *std.ArrayList(Pane), attaches: *std.ArrayList(Attach), alloc: std.mem.Allocator) !bool {
    var buf: [4096]u8 = undefined;
    const n = posix.read(conn, &buf) catch return false;
    if (n == 0) return false;
    var ln = n;
    while (ln > 0 and (buf[ln - 1] == '\n' or buf[ln - 1] == '\r')) ln -= 1;
    const line = buf[0..ln];

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return false;

    if (std.mem.eql(u8, cmd, "list")) {
        // JSON array, mirroring `wezterm cli list --format json` so mac-drive parses it identically.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "[");
        for (panes.items, 0..) |p, i| {
            var rows: u16 = 0;
            var cols: u16 = 0;
            capi.tmux_grid_size(p.handle, &rows, &cols);
            const pane = p.handle.sess.getActiveWindow().getActivePane();
            const pid: i64 = if (pane.pty) |pt| (if (pt.child_pid) |cp| @intCast(cp) else 0) else 0;
            if (i != 0) try out.append(alloc, ',');
            var hb: [96]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&hb, "{{\"pane\":{d},\"rows\":{d},\"cols\":{d},\"pid\":{d},\"cwd\":", .{ p.id, rows, cols, pid }) catch "{");
            try appendJsonStr(&out, alloc, pane.cwd[0..pane.cwd_len]);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]\n");
        _ = pwrite(conn, out.items) catch {};
    } else if (std.mem.eql(u8, cmd, "spawn")) {
        const id = spawnPane(panes, alloc) catch {
            _ = pwrite(conn, "{\"ok\":false,\"error\":\"spawn failed\"}\n") catch {};
            return false;
        };
        var b: [64]u8 = undefined;
        _ = pwrite(conn, std.fmt.bufPrint(&b, "{{\"ok\":true,\"pane\":{d}}}\n", .{id}) catch "{\"ok\":false}\n") catch {};
    } else if (std.mem.eql(u8, cmd, "send")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch {
            _ = pwrite(conn, "err usage: send <id> <text>\n") catch {};
            return false;
        };
        const text = it.rest(); // the remainder of the line after "send <id> "
        const p = findPane(panes, id) orelse {
            _ = pwrite(conn, "err no such pane\n") catch {};
            return false;
        };
        if (text.len > 0) _ = capi.tmux_send(p.handle, text.ptr, text.len);
        _ = pwrite(conn, "ok\n") catch {};
    } else if (std.mem.eql(u8, cmd, "enter")) {
        // convenience: press Return in a pane
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return false;
        const p = findPane(panes, id) orelse return false;
        _ = capi.tmux_send(p.handle, "\r", 1);
        _ = pwrite(conn, "ok\n") catch {};
    } else if (std.mem.eql(u8, cmd, "capture")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return false;
        const p = findPane(panes, id) orelse {
            _ = pwrite(conn, "err no such pane\n") catch {};
            return false;
        };
        try writeCapture(conn, p.handle, alloc);
    } else if (std.mem.eql(u8, cmd, "kill")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return false;
        for (panes.items, 0..) |p, idx| {
            if (p.id == id) {
                capi.tmux_destroy(p.handle);
                _ = panes.orderedRemove(idx);
                _ = pwrite(conn, "ok\n") catch {};
                return false;
            }
        }
        _ = pwrite(conn, "err no such pane\n") catch {};
    } else if (std.mem.eql(u8, cmd, "attach")) {
        // attach <id> [rows cols] — the connection becomes a raw PTY relay
        // until the client hangs up; the pane (and its shell) outlive it.
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch {
            _ = pwrite(conn, "err usage: attach <id> [rows cols]\n") catch {};
            return false;
        };
        const p = findPane(panes, id) orelse {
            _ = pwrite(conn, "err no such pane\n") catch {};
            return false;
        };
        if (it.next()) |rows_s| {
            if (it.next()) |cols_s| {
                const rows = std.fmt.parseInt(u16, rows_s, 10) catch 0;
                const cols = std.fmt.parseInt(u16, cols_s, 10) catch 0;
                if (rows > 1 and cols > 1) _ = capi.tmux_resize(p.handle, rows, cols);
            }
        }
        try attaches.append(alloc, .{ .conn = conn, .pane_id = id });
        try writeSnapshot(conn, p.handle, alloc);
        return true;
    } else {
        _ = pwrite(conn, "err unknown command\n") catch {};
    }
    return false;
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

/// Reconstruct a pane's grid as UTF-8 text (get-text), trailing spaces trimmed per line.
fn writeCapture(conn: i32, h: *capi.TmuxSession, alloc: std.mem.Allocator) !void {
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
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const row = cells[r * cols .. @min((r + 1) * cols, got)];
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        for (row) |cell| {
            var ub: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cell.ch), &ub) catch 1;
            try line.appendSlice(alloc, ub[0..len]);
        }
        var le = line.items.len;
        while (le > 0 and line.items[le - 1] == ' ') le -= 1;
        try out.appendSlice(alloc, line.items[0..le]);
        try out.append(alloc, '\n');
    }
    _ = pwrite(conn, out.items) catch {};
}

// ══ CLIENT ════════════════════════════════════════════════════════════════════════════════════════════
fn runClient(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const path = try socketPath(alloc);
    defer alloc.free(path);

    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    defer pclose(fd);
    var addr = fillAddr(path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) {
        std.debug.print("zterm: cannot reach server at {s} (is `zterm server` running?)\n", .{path});
        return error.ConnectFailed;
    }

    // Build the request. `--` routes the remainder through the JSON protocol
    // (binary-safe text; split gains a run command typed once the shell is up):
    //   zterm cli split h -- claude        → {"cmd":"split","dir":"h","run":"claude\n"}
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
            try req.appendSlice(alloc, "{\"cmd\":\"split\",\"dir\":\"");
            try req.appendSlice(alloc, if (dir.len > 0 and (dir[0] == 'v' or dir[0] == 'V')) "v" else "h");
            try req.appendSlice(alloc, "\",\"run\":");
            try appendJsonStr(&req, alloc, payload.items);
            try req.appendSlice(alloc, "}");
        } else if (std.mem.eql(u8, verb, "send")) {
            const id = if (di >= 2) args[1] else "0";
            try req.appendSlice(alloc, "{\"cmd\":\"send\",\"pane\":");
            try req.appendSlice(alloc, id);
            try req.appendSlice(alloc, ",\"text\":");
            try appendJsonStr(&req, alloc, payload.items);
            try req.appendSlice(alloc, "}");
        } else {
            std.debug.print("zterm: '--' payload is only supported for split/send\n", .{});
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

    const path = try socketPath(alloc);
    defer alloc.free(path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    defer pclose(fd);
    var addr = fillAddr(path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) {
        std.debug.print("zterm: cannot reach server at {s} (is `zterm server` running?)\n", .{path});
        return error.ConnectFailed;
    }

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
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try args.append(alloc, a);

    if (args.items.len < 2) {
        std.debug.print("usage: zterm <server | attach <pane> | cli <list|spawn|send <id> <text>|enter <id>|capture <id>|kill <id>>>\n", .{});
        std.debug.print("  attach: raw window onto a server pane; Ctrl-b d detaches (shell keeps running)\n", .{});
        return;
    }
    const sub = args.items[1];
    if (std.mem.eql(u8, sub, "server")) {
        try runServer(alloc);
    } else if (std.mem.eql(u8, sub, "attach")) {
        try runAttach(alloc, args.items[2..]);
    } else if (std.mem.eql(u8, sub, "cli")) {
        if (args.items.len < 3) {
            std.debug.print("usage: zterm cli <list|spawn|send|enter|capture|kill> ...\n", .{});
            return;
        }
        try runClient(alloc, args.items[2..]);
    } else {
        std.debug.print("zterm: unknown subcommand '{s}'\n", .{sub});
    }
}
