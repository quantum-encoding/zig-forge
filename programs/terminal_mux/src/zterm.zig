//! zterm — standalone mux server + CLI for terminal_mux, mirroring the `wezterm cli` verbs so the agent
//! ecosystem (mac-drive / imsg bridge / the roster) can drive the Zig terminal exactly as it drives WezTerm.
//!
//! Test loop (two terminals):
//!     zterm server                 # owns the panes; runs the event loop
//!     zterm cli list               # → pane <id> <rows>x<cols>
//!     zterm cli spawn              # → pane <id>   (new shell)
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

fn socketPath(alloc: std.mem.Allocator) ![:0]u8 {
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

fn runServer(alloc: std.mem.Allocator) !void {
    const path = try socketPath(alloc);
    defer alloc.free(path);
    _ = c.unlink(path.ptr); // clear a stale socket (path is sentinel-terminated)

    const lfd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (lfd < 0) return error.SocketCreateFailed;
    var addr = fillAddr(path);
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.BindFailed;
    if (c.listen(lfd, 16) < 0) return error.ListenFailed;
    std.debug.print("zterm server: listening on {s}\n", .{path});

    var panes: std.ArrayList(Pane) = .empty;
    defer panes.deinit(alloc);
    const first = try spawnPane(&panes, alloc);
    std.debug.print("zterm server: pane {d} (shell) ready\n", .{first});

    var pfds: std.ArrayList(posix.pollfd) = .empty;
    defer pfds.deinit(alloc);
    while (true) {
        pfds.clearRetainingCapacity();
        try pfds.append(alloc, .{ .fd = lfd, .events = posix.POLL.IN, .revents = 0 });
        for (panes.items) |p| try pfds.append(alloc, .{ .fd = p.fd, .events = posix.POLL.IN, .revents = 0 });

        _ = posix.poll(pfds.items, 1000) catch continue;

        // Drain readable PTYs into their grids (the agents' output).
        for (panes.items) |p| {
            // index in pfds is offset by 1 (listen is [0]); just pump any pane whose fd matches a ready slot.
            for (pfds.items[1..]) |pf| {
                if (pf.fd == p.fd and (pf.revents & posix.POLL.IN) != 0) {
                    _ = capi.tmux_pump(p.handle, 0);
                }
            }
        }

        // A client wants to issue a command.
        if ((pfds.items[0].revents & posix.POLL.IN) != 0) {
            const conn = paccept(lfd) catch continue;
            handleConn(conn, &panes, alloc) catch {};
            pclose(conn);
        }
    }
}

fn handleConn(conn: i32, panes: *std.ArrayList(Pane), alloc: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    const n = posix.read(conn, &buf) catch return;
    if (n == 0) return;
    var ln = n;
    while (ln > 0 and (buf[ln - 1] == '\n' or buf[ln - 1] == '\r')) ln -= 1;
    const line = buf[0..ln];

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return;

    if (std.mem.eql(u8, cmd, "list")) {
        // JSON array, mirroring `wezterm cli list --format json` so mac-drive parses it identically.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "[");
        for (panes.items, 0..) |p, i| {
            var rows: u16 = 0;
            var cols: u16 = 0;
            capi.tmux_grid_size(p.handle, &rows, &cols);
            var lb: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&lb, "{s}{{\"pane\":{d},\"rows\":{d},\"cols\":{d}}}", .{
                if (i == 0) "" else ",", p.id, rows, cols,
            }) catch continue;
            try out.appendSlice(alloc, s);
        }
        try out.appendSlice(alloc, "]\n");
        _ = pwrite(conn, out.items) catch {};
    } else if (std.mem.eql(u8, cmd, "spawn")) {
        const id = spawnPane(panes, alloc) catch {
            _ = pwrite(conn, "{\"ok\":false,\"error\":\"spawn failed\"}\n") catch {};
            return;
        };
        var b: [64]u8 = undefined;
        _ = pwrite(conn, std.fmt.bufPrint(&b, "{{\"ok\":true,\"pane\":{d}}}\n", .{id}) catch "{\"ok\":false}\n") catch {};
    } else if (std.mem.eql(u8, cmd, "send")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch {
            _ = pwrite(conn, "err usage: send <id> <text>\n") catch {};
            return;
        };
        const text = it.rest(); // the remainder of the line after "send <id> "
        const p = findPane(panes, id) orelse {
            _ = pwrite(conn, "err no such pane\n") catch {};
            return;
        };
        if (text.len > 0) _ = capi.tmux_send(p.handle, text.ptr, text.len);
        _ = pwrite(conn, "ok\n") catch {};
    } else if (std.mem.eql(u8, cmd, "enter")) {
        // convenience: press Return in a pane
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return;
        const p = findPane(panes, id) orelse return;
        _ = capi.tmux_send(p.handle, "\r", 1);
        _ = pwrite(conn, "ok\n") catch {};
    } else if (std.mem.eql(u8, cmd, "capture")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return;
        const p = findPane(panes, id) orelse {
            _ = pwrite(conn, "err no such pane\n") catch {};
            return;
        };
        try writeCapture(conn, p.handle, alloc);
    } else if (std.mem.eql(u8, cmd, "kill")) {
        const id = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return;
        for (panes.items, 0..) |p, idx| {
            if (p.id == id) {
                capi.tmux_destroy(p.handle);
                _ = panes.orderedRemove(idx);
                _ = pwrite(conn, "ok\n") catch {};
                return;
            }
        }
        _ = pwrite(conn, "err no such pane\n") catch {};
    } else {
        _ = pwrite(conn, "err unknown command\n") catch {};
    }
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

    // Join args into one request line.
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    for (args, 0..) |a, i| {
        if (i != 0) try req.append(alloc, ' ');
        try req.appendSlice(alloc, a);
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

// ══ MAIN ══════════════════════════════════════════════════════════════════════════════════════════════
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try args.append(alloc, a);

    if (args.items.len < 2) {
        std.debug.print("usage: zterm <server | cli <list|spawn|send <id> <text>|enter <id>|capture <id>|kill <id>>>\n", .{});
        return;
    }
    const sub = args.items[1];
    if (std.mem.eql(u8, sub, "server")) {
        try runServer(alloc);
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
