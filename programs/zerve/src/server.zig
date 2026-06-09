// zerve server core — evented HTTP/1.1 server.
//
// Concurrency model (the Zap/nginx-style design the AI gateway's
// thread-per-connection model can't match):
//   - N worker threads (default = CPU count), each with its OWN listening
//     socket on the same addr:port via SO_REUSEPORT. The kernel load-balances
//     incoming connections across the workers — no shared accept lock, no
//     thundering herd, linear scaling across cores.
//   - Each worker runs one kqueue event loop over its listener + its
//     connections. Non-blocking everything; each connection is a small state
//     machine (read → parse → handle → write → keep-alive).
//   - Per-worker Conn freelist: connection structs (with inline read/write
//     buffers) are pooled and reused, so steady-state serving does zero
//     per-request heap allocation.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const http = @import("http.zig");
const Reactor = @import("reactor.zig").Reactor;

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// 0 → auto-detect (CPU count).
    workers: usize = 0,
    backlog: u31 = 1024,
};

/// A request handler fills in `res`; the server serializes it onto the wire.
pub const Handler = *const fn (req: *const http.Request, res: *http.Response) void;

const READ_CAP: usize = 16 * 1024;
const WRITE_CAP: usize = 16 * 1024;
const EVENTS_CAP: usize = 512;

const LISTENER_UDATA: usize = 0; // connections are heap pointers → never 0

const Conn = struct {
    fd: posix.socket_t = -1,
    rbuf: [READ_CAP]u8 = undefined,
    rlen: usize = 0,
    wbuf: [WRITE_CAP]u8 = undefined,
    wlen: usize = 0,
    wsent: usize = 0,
    keep_alive: bool = true,
    next_free: ?*Conn = null,
};

const ConnPool = struct {
    allocator: std.mem.Allocator,
    free: ?*Conn = null,

    fn acquire(self: *ConnPool) !*Conn {
        if (self.free) |conn| {
            self.free = conn.next_free;
            return conn;
        }
        return self.allocator.create(Conn);
    }
    fn release(self: *ConnPool, conn: *Conn) {
        conn.next_free = self.free;
        self.free = conn;
    }
};

pub const Server = struct {
    config: Config,
    handler: Handler,
    running: std.atomic.Value(bool) = .init(true),

    pub fn init(config: Config, handler: Handler) Server {
        return .{ .config = config, .handler = handler };
    }

    /// Start the workers and block serving. Returns when `stop()` is called
    /// (or never, for a foreground server).
    pub fn run(self: *Server) !void {
        const n = if (self.config.workers != 0) self.config.workers else (std.Thread.getCpuCount() catch 1);

        var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
        defer threads.deinit(std.heap.c_allocator);

        // Spawn n-1 background workers; run one inline on this thread.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const t = std.Thread.spawn(.{}, workerMain, .{self}) catch break;
            threads.append(std.heap.c_allocator, t) catch t.detach();
        }
        workerMain(self);
        for (threads.items) |t| t.join();
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }
};

fn workerMain(server: *Server) void {
    const lfd = createListener(server.config) catch |e| {
        std.debug.print("zerve worker: listen failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer posix.close(lfd);

    var reactor = Reactor.init() catch return;
    defer reactor.deinit();
    reactor.addRead(lfd, LISTENER_UDATA) catch return;

    var pool = ConnPool{ .allocator = std.heap.c_allocator };
    var events: [EVENTS_CAP]c.Kevent = undefined;

    while (server.running.load(.acquire)) {
        const n = reactor.poll(&events, 1000);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const ev = Reactor.decode(events[idx]);
            if (ev.udata == LISTENER_UDATA) {
                acceptAll(lfd, &reactor, &pool);
                continue;
            }
            const conn: *Conn = @ptrFromInt(ev.udata);
            if (ev.isWrite()) {
                onWritable(conn, &reactor, &pool, server.handler);
            } else {
                onReadable(conn, &reactor, &pool, server.handler);
            }
        }
    }
}

fn acceptAll(lfd: posix.socket_t, reactor: *Reactor, pool: *ConnPool) void {
    while (true) {
        const cfd = posix.accept(lfd, null, null, 0) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return, // transient accept error — stop this drain, try next wakeup
        };
        setNonblock(cfd);
        setNoDelay(cfd);
        const conn = pool.acquire() catch {
            posix.close(cfd);
            continue;
        };
        conn.fd = cfd;
        conn.rlen = 0;
        conn.wlen = 0;
        conn.wsent = 0;
        conn.keep_alive = true;
        conn.next_free = null;
        reactor.addRead(cfd, @intFromPtr(conn)) catch {
            posix.close(cfd);
            pool.release(conn);
            continue;
        };
    }
}

fn onReadable(conn: *Conn, reactor: *Reactor, pool: *ConnPool, handler: Handler) void {
    // Drain the socket into the read buffer.
    while (true) {
        if (conn.rlen == conn.rbuf.len) break; // buffer full — process what we have
        const n = posix.read(conn.fd, conn.rbuf[conn.rlen..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return closeConn(conn, reactor, pool),
        };
        if (n == 0) return closeConn(conn, reactor, pool); // peer closed
        conn.rlen += n;
    }
    processAndRespond(conn, reactor, pool, handler);
}

fn processAndRespond(conn: *Conn, reactor: *Reactor, pool: *ConnPool, handler: Handler) void {
    while (conn.rlen > 0) {
        if (conn.wsent < conn.wlen) return; // a response is still flushing

        switch (http.parse(conn.rbuf[0..conn.rlen])) {
            .incomplete => return, // need more bytes
            .invalid => return closeConn(conn, reactor, pool),
            .ok => |req| {
                if (req.total_len > conn.rlen) return; // body still arriving

                var res = http.Response{};
                handler(&req, &res);
                conn.keep_alive = req.keep_alive;

                const wn = http.writeResponse(&conn.wbuf, &res, conn.keep_alive) orelse
                    return closeConn(conn, reactor, pool); // response too big for buffer
                conn.wlen = wn;
                conn.wsent = 0;

                // Consume this request's bytes (shift any pipelined remainder).
                if (req.total_len < conn.rlen) {
                    std.mem.copyForwards(u8, conn.rbuf[0 .. conn.rlen - req.total_len], conn.rbuf[req.total_len..conn.rlen]);
                    conn.rlen -= req.total_len;
                } else {
                    conn.rlen = 0;
                }

                switch (flush(conn, reactor)) {
                    .blocked => return, // resume in onWritable
                    .closed => return closeConn(conn, reactor, pool),
                    .done => {
                        if (!conn.keep_alive) return closeConn(conn, reactor, pool);
                        // keep-alive: loop to handle any pipelined request.
                    },
                }
            },
        }
    }
}

const FlushResult = enum { done, blocked, closed };

fn flush(conn: *Conn, reactor: *Reactor) FlushResult {
    while (conn.wsent < conn.wlen) {
        const n = posix.write(conn.fd, conn.wbuf[conn.wsent..conn.wlen]) catch |e| switch (e) {
            error.WouldBlock => {
                reactor.enableWrite(conn.fd, @intFromPtr(conn)) catch return .closed;
                return .blocked;
            },
            else => return .closed,
        };
        if (n == 0) return .closed;
        conn.wsent += n;
    }
    return .done;
}

fn onWritable(conn: *Conn, reactor: *Reactor, pool: *ConnPool, handler: Handler) void {
    switch (flush(conn, reactor)) {
        .blocked => return,
        .closed => return closeConn(conn, reactor, pool),
        .done => {
            if (!conn.keep_alive) return closeConn(conn, reactor, pool);
            processAndRespond(conn, reactor, pool, handler);
        },
    }
}

fn closeConn(conn: *Conn, reactor: *Reactor, pool: *ConnPool) void {
    reactor.del(conn.fd);
    posix.close(conn.fd);
    conn.fd = -1;
    pool.release(conn);
}

// ── socket setup ─────────────────────────────────────────────────────

fn createListener(config: Config) !posix.socket_t {
    const addr = try std.net.Address.parseIp(config.host, config.port);
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(fd);

    const one = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one);
    // SO_REUSEPORT: each worker binds its own socket to the same port; the
    // kernel distributes connections across them. This is what makes the
    // multi-worker design scale without an accept lock.
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &one) catch {};

    setNonblock(fd);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, config.backlog);
    return fd;
}

fn setNonblock(fd: posix.socket_t) void {
    // macOS: O_NONBLOCK = 0x0004. Preserve existing flags.
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F.SETFL, flags | @as(c_int, 0x0004));
}

fn setNoDelay(fd: posix.socket_t) void {
    const one = std.mem.toBytes(@as(c_int, 1));
    // TCP_NODELAY = 1, IPPROTO_TCP = 6 — disable Nagle for low-latency replies.
    posix.setsockopt(fd, posix.IPPROTO.TCP, 1, &one) catch {};
}
