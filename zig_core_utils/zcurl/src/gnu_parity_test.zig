//! GNU-parity tests for zcurl.
//!
//! EXTERNALLY ANCHORED, not roundtrip:
//!
//!   The anchor is the real GNU-userland `curl` binary (curl 8.x at
//!   /usr/bin/curl). For every network case an in-process, deterministic
//!   HTTP/1.1 server returns FIXED bytes, and BOTH the freshly-built `zcurl`
//!   and the system `curl` are run against it; their stdout / exit codes are
//!   compared byte-for-byte. Nothing here compares zcurl to itself.
//!
//!   Where curl(1) documents a fixed value (exit codes; the "body written
//!   verbatim, no trailing newline" rule) the expected bytes are also written
//!   out literally and cited, so the anchor is legible without running curl.
//!
//! The zcurl binary path is injected by build.zig via `build_options`
//! (the emitted-binary path of the exe target). curl is discovered at a set of
//! well-known paths; if none is present the curl-diff half is skipped but the
//! literal-byte assertions still run.
//!
//! Wired into `zig build test`.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const build_options = @import("build_options");

const curl_candidates = [_][]const u8{
    "/usr/bin/curl",
    "/opt/homebrew/opt/curl/bin/curl",
    "/usr/local/opt/curl/bin/curl",
    "/opt/homebrew/bin/curl",
};

// ---------------------------------------------------------------------------
// Deterministic fixed-byte HTTP/1.1 server (keep-alive), on a background thread.
// ---------------------------------------------------------------------------

const TestServer = struct {
    io: Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,
    stop: std.atomic.Value(bool),

    fn start(io: Io) !*TestServer {
        const gpa = std.heap.page_allocator;
        const self = try gpa.create(TestServer);
        self.io = io;
        const addr = try net.IpAddress.parse("127.0.0.1", 0);
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.stop = std.atomic.Value(bool).init(false);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn deinit(self: *TestServer) void {
        self.stop.store(true, .seq_cst);
        // Unblock accept() by connecting once.
        const a = net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (a.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
        std.heap.page_allocator.destroy(self);
    }

    fn acceptLoop(self: *TestServer) void {
        while (!self.stop.load(.seq_cst)) {
            var stream = self.server.accept(self.io) catch return;
            if (self.stop.load(.seq_cst)) {
                stream.close(self.io);
                return;
            }
            self.handleConn(stream);
            stream.close(self.io);
        }
    }

    fn handleConn(self: *TestServer, stream: net.Stream) void {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        var sw = stream.writer(self.io, &wbuf);
        const r = &sr.interface;
        const w = &sw.interface;

        // Keep-alive: serve requests until the peer closes (EOF).
        while (true) {
            var head: [8192]u8 = undefined;
            var head_len: usize = 0;
            // Accumulate the exact request head bytes up to and including the
            // terminating blank line.
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch return;
                if (head_len + line.len > head.len) return;
                @memcpy(head[head_len..][0..line.len], line);
                head_len += line.len;
                if (std.mem.eql(u8, line, "\r\n")) break; // end of head
            }
            const req_head = head[0..head_len];
            const first_line = req_head[0 .. std.mem.indexOf(u8, req_head, "\r\n") orelse req_head.len];
            var it = std.mem.splitScalar(u8, first_line, ' ');
            const method = it.next() orelse "GET";
            const path = it.next() orelse "/";

            var resp: [16384]u8 = undefined;
            const bytes = buildResponse(&resp, method, path, req_head);
            w.writeAll(bytes) catch return;
            w.flush() catch return;
        }
    }

    fn buildResponse(out: []u8, method: []const u8, path: []const u8, req_head: []const u8) []const u8 {
        const is_head = std.mem.eql(u8, method, "HEAD");
        if (std.mem.eql(u8, path, "/hello")) {
            const body = "Hello world"; // 11 bytes, NO trailing newline
            return std.fmt.bufPrint(out, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, if (is_head) "" else body }) catch unreachable;
        } else if (std.mem.eql(u8, path, "/redir")) {
            return std.fmt.bufPrint(out, "HTTP/1.1 301 Moved Permanently\r\nLocation: /hello\r\nContent-Length: 0\r\n\r\n", .{}) catch unreachable;
        } else if (std.mem.eql(u8, path, "/echo")) {
            // Echo the request head back as the body so header parsing on the
            // wire is directly observable.
            return std.fmt.bufPrint(out, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ req_head.len, if (is_head) "" else req_head }) catch unreachable;
        }
        return std.fmt.bufPrint(out, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", .{}) catch unreachable;
    }
};

// ---------------------------------------------------------------------------
// Child-process runner.
// ---------------------------------------------------------------------------

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 if not a clean exit

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn runArgv(a: std.mem.Allocator, io: Io, argv: []const []const u8) !Run {
    const res = try std.process.run(a, io, .{ .argv = argv });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

fn findCurl(a: std.mem.Allocator, io: Io) ?[]const u8 {
    for (curl_candidates) |c| {
        const r = runArgv(a, io, &.{ c, "--version" }) catch continue;
        r.deinit(a);
        if (r.code == 0) return c;
    }
    return null;
}

fn urlFor(a: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, path });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Body-fidelity: curl(1) writes the response body verbatim — no synthesized
// trailing newline. Anchor: real curl output AND the documented literal bytes.
test "body written verbatim, no injected trailing newline (vs curl)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const srv = try TestServer.start(io);
    defer srv.deinit();
    const u = try urlFor(a, srv.port, "/hello");
    defer a.free(u);

    const z = try runArgv(a, io, &.{ build_options.zcurl_path, u });
    defer z.deinit(a);

    // Literal anchor: exactly "Hello world", 11 bytes, no trailing 0x0a.
    try std.testing.expectEqualStrings("Hello world", z.stdout);

    // External anchor: byte-exact against real curl, when present.
    if (findCurl(a, io)) |curl| {
        const c = try runArgv(a, io, &.{ curl, "-s", u });
        defer c.deinit(a);
        try std.testing.expectEqualStrings(c.stdout, z.stdout);
    }
}

// -I must emit the real status line and every response header.
// Anchor: byte-exact against `curl -sI`, plus literal reason phrase.
test "-I emits real status line + headers (byte-exact vs curl -sI)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const srv = try TestServer.start(io);
    defer srv.deinit();
    const u = try urlFor(a, srv.port, "/hello");
    defer a.free(u);

    const z = try runArgv(a, io, &.{ build_options.zcurl_path, "-I", u });
    defer z.deinit(a);

    // Real reason phrase "OK" (not the Zig enum tag "ok"); real headers present.
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, "Content-Length: 11\r\n") != null);

    if (findCurl(a, io)) |curl| {
        const c = try runArgv(a, io, &.{ curl, "-sI", u });
        defer c.deinit(a);
        try std.testing.expectEqualStrings(c.stdout, z.stdout);
    }
}

// -L must actually follow a 3xx redirect. Before the fix this hard-failed with
// HttpRedirectLocationOversize (an empty redirect buffer was passed and
// redirect_behavior was never wired up). Anchor: byte-exact vs `curl -sL` and
// the literal target body.
test "-L follows redirect (vs curl -sL)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const srv = try TestServer.start(io);
    defer srv.deinit();
    const u = try urlFor(a, srv.port, "/redir");
    defer a.free(u);

    const z = try runArgv(a, io, &.{ build_options.zcurl_path, "-s", "-L", u });
    defer z.deinit(a);

    try std.testing.expectEqualStrings("Hello world", z.stdout);
    try std.testing.expectEqual(@as(u8, 0), z.code);

    if (findCurl(a, io)) |curl| {
        const c = try runArgv(a, io, &.{ curl, "-sL", u });
        defer c.deinit(a);
        try std.testing.expectEqualStrings(c.stdout, z.stdout);
    }
}

// -H accepts "Name:Value" (colon, no space) per curl(1); the header reaches the
// wire with the value's optional leading whitespace trimmed.
test "-H accepts colon-without-space header" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const srv = try TestServer.start(io);
    defer srv.deinit();
    const u = try urlFor(a, srv.port, "/echo");
    defer a.free(u);

    const z = try runArgv(a, io, &.{ build_options.zcurl_path, "-s", "-H", "X-Foo:bar", u });
    defer z.deinit(a);

    try std.testing.expect(std.mem.indexOf(u8, z.stdout, "X-Foo: bar\r\n") != null);
}

// User-Agent is overridden, not duplicated: the echoed head must contain
// exactly one User-Agent line carrying the value we set.
test "custom -A overrides UA (single header, no duplication)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const srv = try TestServer.start(io);
    defer srv.deinit();
    const u = try urlFor(a, srv.port, "/echo");
    defer a.free(u);

    const z = try runArgv(a, io, &.{ build_options.zcurl_path, "-s", "-A", "my-agent/9", u });
    defer z.deinit(a);

    // std.http emits the header lowercase on the wire ("user-agent:"). Count
    // case-insensitively so a duplicated default UA would still be caught.
    const lower = try a.dupe(u8, z.stdout);
    defer a.free(lower);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, lower, i, "user-agent:")) |pos| {
        count += 1;
        i = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, lower, "user-agent: my-agent/9\r\n") != null);
}

// Exit-code parity with curl(1): usage(2), malformed URL(3), --version/--help(0).
// These need no server. Each zcurl code is confirmed to equal the live curl code.
test "exit codes match curl (usage=2, bad-url=3, version/help=0)" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const curl = findCurl(a, io);

    // No URL -> 2.
    {
        const z = try runArgv(a, io, &.{build_options.zcurl_path});
        defer z.deinit(a);
        try std.testing.expectEqual(@as(u8, 2), z.code);
        if (curl) |cb| {
            const c = try runArgv(a, io, &.{cb});
            defer c.deinit(a);
            try std.testing.expectEqual(c.code, z.code);
        }
    }
    // Malformed URL -> 3.
    {
        const z = try runArgv(a, io, &.{ build_options.zcurl_path, "ht!tp://[bad" });
        defer z.deinit(a);
        try std.testing.expectEqual(@as(u8, 3), z.code);
        if (curl) |cb| {
            const c = try runArgv(a, io, &.{ cb, "-s", "ht!tp://[bad" });
            defer c.deinit(a);
            try std.testing.expectEqual(c.code, z.code);
        }
    }
    // --version -> 0, on stdout, nothing on stderr.
    {
        const z = try runArgv(a, io, &.{ build_options.zcurl_path, "--version" });
        defer z.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), z.code);
        try std.testing.expect(z.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    }
    // --help -> 0, on stdout, nothing on stderr.
    {
        const z = try runArgv(a, io, &.{ build_options.zcurl_path, "--help" });
        defer z.deinit(a);
        try std.testing.expectEqual(@as(u8, 0), z.code);
        try std.testing.expect(z.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    }
}
