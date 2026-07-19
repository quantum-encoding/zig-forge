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
    /// Close a connection that has been idle (no bytes read) for longer than
    /// this. Guards against slow-loris / half-open connection holds. 0 disables
    /// the sweep. Active connections update their timer on every read, so a
    /// busy keep-alive connection is never reaped.
    idle_timeout_ms: u32 = 30_000,
    /// Ceiling on live connections **per worker**. When reached, further
    /// accepts are drained and closed immediately instead of growing the pool
    /// unbounded. 0 → unlimited (the historical behavior).
    max_connections: usize = 0,
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
    /// Monotonic-clock nanoseconds of the last read activity; drives the idle
    /// sweep. Monotonic (never wall-clock) so a clock step can't defeat the
    /// slow-loris guard.
    last_active: u64 = 0,
    /// Freelist link (valid only while pooled).
    next_free: ?*Conn = null,
    /// Live-list links (valid only while acquired) — an intrusive doubly-linked
    /// list of in-use connections so the idle sweep can walk them in O(live).
    next_live: ?*Conn = null,
    prev_live: ?*Conn = null,
};

const ConnPool = struct {
    allocator: std.mem.Allocator,
    free: ?*Conn = null,
    live_head: ?*Conn = null,
    live_count: usize = 0,
    /// 0 → unlimited.
    max: usize = 0,

    fn acquire(self: *ConnPool) !*Conn {
        if (self.max != 0 and self.live_count >= self.max) return error.TooManyConnections;
        const conn = if (self.free) |free_conn| blk: {
            self.free = free_conn.next_free;
            break :blk free_conn;
        } else try self.allocator.create(Conn);

        // Push onto the live list.
        conn.prev_live = null;
        conn.next_live = self.live_head;
        if (self.live_head) |h| h.prev_live = conn;
        self.live_head = conn;
        self.live_count += 1;
        return conn;
    }
    fn release(self: *ConnPool, conn: *Conn) void {
        // Unlink from the live list.
        if (conn.prev_live) |p| p.next_live = conn.next_live else self.live_head = conn.next_live;
        if (conn.next_live) |nx| nx.prev_live = conn.prev_live;
        conn.next_live = null;
        conn.prev_live = null;
        self.live_count -= 1;

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
    defer _ = c.close(lfd);

    var reactor = Reactor.init() catch return;
    defer reactor.deinit();
    reactor.addRead(lfd, LISTENER_UDATA) catch return;

    var pool = ConnPool{ .allocator = std.heap.c_allocator, .max = server.config.max_connections };
    var events: [EVENTS_CAP]c.Kevent = undefined;

    const idle_ns: u64 = @as(u64, server.config.idle_timeout_ms) * std.time.ns_per_ms;
    // With the sweep enabled, cap the poll timeout so an all-idle worker still
    // wakes often enough to reap a stalled connection near its deadline.
    const poll_ms: i32 = if (idle_ns == 0) 1000 else @intCast(@min(@as(u64, 1000), @max(@as(u64, 50), server.config.idle_timeout_ms)));
    const sweep_interval_ns: u64 = @as(u64, @intCast(poll_ms)) * std.time.ns_per_ms / 2;
    var last_sweep: u64 = if (idle_ns == 0) 0 else monotonicNs();

    while (server.running.load(.acquire)) {
        const n = reactor.poll(&events, poll_ms);
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

        // Idle sweep — bounded to at most once per (poll_ms/2) so a busy worker
        // doesn't walk the live list on every event batch.
        if (idle_ns != 0) {
            const now = monotonicNs();
            if (now -| last_sweep >= sweep_interval_ns) {
                sweepIdle(&pool, &reactor, idle_ns, now);
                last_sweep = now;
            }
        }
    }
}

/// Monotonic clock in nanoseconds. Never steps backward across NTP/clock
/// adjustments, so it is the correct base for the slow-loris idle deadline.
fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Close every live connection idle for at least `idle_ns`. Runs off the
/// worker's own poll wakeup, so it needs no separate timer fd.
fn sweepIdle(pool: *ConnPool, reactor: *Reactor, idle_ns: u64, now: u64) void {
    var it = pool.live_head;
    while (it) |conn| {
        const next = conn.next_live; // capture before closeConn unlinks it
        if (now -| conn.last_active >= idle_ns) closeConn(conn, reactor, pool);
        it = next;
    }
}

fn acceptAll(lfd: posix.socket_t, reactor: *Reactor, pool: *ConnPool) void {
    while (true) {
        const cfd_raw = c.accept(lfd, null, null);
        if (cfd_raw < 0) {
            switch (lastErrno()) {
                .INTR => continue, // interrupted — retry the accept
                else => return, // EAGAIN (drained) or transient — wait for next wakeup
            }
        }
        const cfd: posix.socket_t = @intCast(cfd_raw);
        setNonblock(cfd);
        setNoDelay(cfd);
        const conn = pool.acquire() catch {
            _ = c.close(cfd);
            continue;
        };
        conn.fd = cfd;
        conn.rlen = 0;
        conn.wlen = 0;
        conn.wsent = 0;
        conn.keep_alive = true;
        conn.next_free = null;
        conn.last_active = monotonicNs();
        reactor.addRead(cfd, @intFromPtr(conn)) catch {
            _ = c.close(cfd);
            pool.release(conn);
            continue;
        };
    }
}

fn onReadable(conn: *Conn, reactor: *Reactor, pool: *ConnPool, handler: Handler) void {
    // Drain the socket into the read buffer.
    while (true) {
        if (conn.rlen == conn.rbuf.len) break; // buffer full — process what we have
        const want = conn.rbuf.len - conn.rlen;
        const r = c.read(conn.fd, conn.rbuf[conn.rlen..].ptr, want);
        if (r < 0) {
            switch (lastErrno()) {
                .AGAIN => break, // drained — process what we have
                .INTR => continue, // interrupted — retry
                else => return closeConn(conn, reactor, pool),
            }
        }
        if (r == 0) return closeConn(conn, reactor, pool); // peer closed
        conn.rlen += @intCast(r);
        conn.last_active = monotonicNs(); // reset idle timer on read progress
    }
    processAndRespond(conn, reactor, pool, handler);
}

fn processAndRespond(conn: *Conn, reactor: *Reactor, pool: *ConnPool, handler: Handler) void {
    while (conn.rlen > 0) {
        if (conn.wsent < conn.wlen) return; // a response is still flushing

        switch (http.parse(conn.rbuf[0..conn.rlen])) {
            .incomplete => {
                // Head still incomplete but the read buffer is full → the
                // header block is larger than READ_CAP and can never complete.
                // Answer 431 and close instead of busy-spinning on a
                // level-triggered readable socket that never drains.
                if (conn.rlen == conn.rbuf.len) return respondError(conn, reactor, pool, 431);
                return; // genuinely need more bytes
            },
            .invalid => return respondError(conn, reactor, pool, 400),
            .ok => |req| {
                // A declared body that cannot fit the fixed buffer can never be
                // fully read → reject with 413 rather than parking the conn.
                if (req.total_len > conn.rbuf.len) return respondError(conn, reactor, pool, 413);
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

/// Emit a minimal error response (empty body, `Connection: close`) and tear the
/// connection down. Used for oversized heads (431), oversized bodies (413), and
/// malformed input (400) — none of which may keep-alive.
fn respondError(conn: *Conn, reactor: *Reactor, pool: *ConnPool, status: u16) void {
    var res = http.Response{};
    res.status = status;
    res.content_type = "text/plain; charset=utf-8";
    res.body = ""; // the status line already carries the reason phrase
    conn.keep_alive = false;

    const wn = http.writeResponse(&conn.wbuf, &res, false) orelse
        return closeConn(conn, reactor, pool);
    conn.wlen = wn;
    conn.wsent = 0;

    switch (flush(conn, reactor)) {
        .blocked => return, // onWritable closes once the head flushes (keep_alive=false)
        else => return closeConn(conn, reactor, pool),
    }
}

const FlushResult = enum { done, blocked, closed };

fn flush(conn: *Conn, reactor: *Reactor) FlushResult {
    while (conn.wsent < conn.wlen) {
        const want = conn.wlen - conn.wsent;
        const w = c.write(conn.fd, conn.wbuf[conn.wsent..conn.wlen].ptr, want);
        if (w < 0) {
            switch (lastErrno()) {
                .AGAIN => {
                    reactor.enableWrite(conn.fd, @intFromPtr(conn)) catch return .closed;
                    return .blocked;
                },
                .INTR => continue, // interrupted — retry the write
                else => return .closed,
            }
        }
        if (w == 0) return .closed;
        conn.wsent += @intCast(w);
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
    _ = c.close(conn.fd);
    conn.fd = -1;
    pool.release(conn);
}

/// Read the C library errno for the most recent failed syscall.
fn lastErrno() c.E {
    return @enumFromInt(c._errno().*);
}

// ── socket setup ─────────────────────────────────────────────────────

fn createListener(config: Config) !posix.socket_t {
    const fd_raw = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd_raw < 0) return error.SocketFailed;
    const fd: posix.socket_t = @intCast(fd_raw);
    errdefer _ = c.close(fd);

    const one = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one);
    // SO_REUSEPORT: each worker binds its own socket to the same port; the
    // kernel distributes connections across them. This is what makes the
    // multi-worker design scale without an accept lock.
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &one) catch {};

    setNonblock(fd);

    var addr = c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, config.port),
        .addr = parseIpv4(config.host),
    };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) return error.BindFailed;
    if (c.listen(fd, config.backlog) < 0) return error.ListenFailed;
    return fd;
}

/// Parse a dotted-quad IPv4 host into a network-byte-order address word.
/// Anything that isn't a clean a.b.c.d falls back to INADDR_ANY (0.0.0.0).
fn parseIpv4(host: []const u8) u32 {
    var octets: [4]u8 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return 0;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return 0;
    }
    if (i != 4) return 0;
    // Bytes are already in wire order (octets[0] is the high byte on the wire);
    // bitcast preserves that memory layout into the sockaddr's addr field.
    return @bitCast(octets);
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

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseIpv4 accepts dotted-quad, falls back to INADDR_ANY otherwise" {
    try testing.expectEqual(@as(u32, @bitCast([4]u8{ 127, 0, 0, 1 })), parseIpv4("127.0.0.1"));
    try testing.expectEqual(@as(u32, @bitCast([4]u8{ 0, 0, 0, 0 })), parseIpv4("0.0.0.0"));
    try testing.expectEqual(@as(u32, 0), parseIpv4("not.an.ip")); // non-numeric octet
    try testing.expectEqual(@as(u32, 0), parseIpv4("1.2.3")); // too few octets
    try testing.expectEqual(@as(u32, 0), parseIpv4("1.2.3.4.5")); // too many octets
    try testing.expectEqual(@as(u32, 0), parseIpv4("999.0.0.0")); // octet overflows u8
}

test "ConnPool enforces max_connections and reuses freed conns" {
    var pool = ConnPool{ .allocator = testing.allocator, .max = 2 };
    defer {
        var it = pool.free;
        while (it) |conn| {
            const nx = conn.next_free;
            testing.allocator.destroy(conn);
            it = nx;
        }
    }

    const a = try pool.acquire();
    const b = try pool.acquire();
    try testing.expectEqual(@as(usize, 2), pool.live_count);
    try testing.expectError(error.TooManyConnections, pool.acquire()); // at cap

    pool.release(a);
    try testing.expectEqual(@as(usize, 1), pool.live_count);
    const reused = try pool.acquire();
    try testing.expectEqual(a, reused); // came off the freelist, not a fresh alloc
    try testing.expectEqual(@as(usize, 2), pool.live_count);

    pool.release(b);
    pool.release(reused);
    try testing.expectEqual(@as(usize, 0), pool.live_count);
}

fn testHandler(req: *const http.Request, res: *http.Response) void {
    if (req.pathEquals("/ok")) res.text("hello") else res.notFound();
}

fn loopbackAddr(port: u16) c.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
}

fn getFreePort() !u16 {
    const fd_raw = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd_raw < 0) return error.SocketFailed;
    const fd: posix.socket_t = @intCast(fd_raw);
    defer _ = c.close(fd);

    const one = std.mem.toBytes(@as(c_int, 1));
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one) catch {};

    var addr = loopbackAddr(0); // port 0 → kernel assigns an ephemeral port
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) return error.BindFailed;
    var slen: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&addr), &slen) < 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, addr.port);
}

fn sleepMs(ms: u64) void {
    var req = c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: c.timespec = undefined;
    _ = c.nanosleep(&req, &rem);
}

fn connectWithRetry(port: u16) !posix.socket_t {
    var addr = loopbackAddr(port);
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const fd_raw = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd_raw < 0) return error.SocketFailed;
        const fd: posix.socket_t = @intCast(fd_raw);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0) {
            // 2s receive timeout so a wedged read can never hang the test.
            const tv = posix.timeval{ .sec = 2, .usec = 0 };
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
            return fd;
        }
        _ = c.close(fd);
        sleepMs(5);
    }
    return error.ConnectFailed;
}

fn writeAll(fd: posix.socket_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const w = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (w <= 0) return; // peer may have closed (e.g. after a 431)
        off += @intCast(w);
    }
}

fn readResponse(fd: posix.socket_t, buf: []u8) usize {
    var total: usize = 0;
    var tries: usize = 0;
    while (tries < 10 and total < buf.len) : (tries += 1) {
        const r = c.read(fd, buf[total..].ptr, buf.len - total);
        if (r <= 0) break;
        total += @intCast(r);
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break; // head complete
    }
    return total;
}

test "loopback integration: 200 + keep-alive, pipelined follow-up, 431 on oversized head" {
    const port = getFreePort() catch return error.SkipZigTest;
    var server = Server.init(.{
        .host = "127.0.0.1",
        .port = port,
        .workers = 1,
        .idle_timeout_ms = 0, // disable the sweep so a slow test step can't be reaped
    }, testHandler);

    const th = std.Thread.spawn(.{}, Server.run, .{&server}) catch return error.SkipZigTest;
    defer {
        server.stop();
        th.join();
    }

    var buf: [1024]u8 = undefined;

    // 1) GET /ok → 200, body "hello", keep-alive.
    const fd = connectWithRetry(port) catch return error.SkipZigTest;
    defer _ = c.close(fd);
    writeAll(fd, "GET /ok HTTP/1.1\r\nHost: x\r\n\r\n");
    const n1 = readResponse(fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "hello") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "keep-alive") != null);

    // 2) Second request on the SAME connection (keep-alive path) → 404.
    writeAll(fd, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
    const n2 = readResponse(fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n2], "404") != null);

    // 3) Oversized header block (> READ_CAP, no terminator) → 431, not a spin.
    const fd2 = connectWithRetry(port) catch return error.SkipZigTest;
    defer _ = c.close(fd2);
    var pad: [READ_CAP + 512]u8 = undefined;
    @memset(&pad, 'A'); // never contains "\r\n\r\n"
    writeAll(fd2, &pad);
    const n3 = readResponse(fd2, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n3], "431") != null);
}
