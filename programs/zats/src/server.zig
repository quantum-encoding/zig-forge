//! NATS Server
//!
//! TCP server implementing the NATS protocol. Uses std.c for cross-platform
//! socket operations (Linux, macOS, BSD). Uses poll-based I/O multiplexing.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const connection_mod = @import("connection.zig");
const router_mod = @import("router.zig");
const jetstream_mod = @import("jetstream.zig");
const js_api_mod = @import("js_api.zig");
const consumer_mod = @import("consumer.zig");
const headers_mod = @import("headers.zig");
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;

extern "c" fn time(t: ?*isize) isize;

pub const ServerConfig = struct {
    port: u16 = 4222,
    host: []const u8 = "0.0.0.0",
    max_payload: usize = 1024 * 1024, // 1 MB
    max_connections: usize = 1024,
    max_pending_bytes: usize = 64 * 1024 * 1024, // 64 MB
    auth_token: ?[]const u8 = null,
    auth_user: ?[]const u8 = null,
    auth_pass: ?[]const u8 = null,
    server_name: []const u8 = "zats",
};

pub const NatsServer = struct {
    config: ServerConfig,
    listen_fd: posix.socket_t,
    connections: std.AutoHashMapUnmanaged(u64, *connection_mod.ClientConnection),
    router: router_mod.Router,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    next_conn_id: u64,

    // JetStream
    jetstream: ?*jetstream_mod.JetStream,
    js_api: ?js_api_mod.JsApiHandler,

    // Stats
    total_connections: u64,
    total_messages: u64,
    total_bytes: u64,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !NatsServer {
        return .{
            .config = config,
            .listen_fd = 0,
            .connections = .{},
            .router = try router_mod.Router.init(allocator),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .next_conn_id = 1,
            .jetstream = null,
            .js_api = null,
            .total_connections = 0,
            .total_messages = 0,
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *NatsServer) void {
        // Close all client connections
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            _ = std.c.close(entry.value_ptr.*.fd);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit(self.allocator);
        self.router.deinit();

        if (self.jetstream) |js| {
            js.deinit();
        }

        if (self.listen_fd != 0) {
            _ = std.c.close(self.listen_fd);
        }
    }

    /// Enable JetStream on this server.
    pub fn enableJetStream(self: *NatsServer, config: jetstream_mod.JetStreamConfig) !void {
        const js = try jetstream_mod.JetStream.init(self.allocator, config);
        self.jetstream = js;
        self.js_api = js_api_mod.JsApiHandler.init(self.allocator, js);
    }

    /// Bind and listen on the configured port.
    pub fn listen(self: *NatsServer) !void {
        // Create socket
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        self.listen_fd = @intCast(fd);

        // SO_REUSEADDR
        const enable: c_int = 1;
        _ = std.c.setsockopt(
            self.listen_fd,
            std.c.SOL.SOCKET,
            std.c.SO.REUSEADDR,
            std.mem.asBytes(&enable),
            @sizeOf(c_int),
        );

        // Bind
        const addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.config.port),
            .addr = 0, // INADDR_ANY
        };

        if (std.c.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) {
            return error.BindFailed;
        }

        // Listen
        if (std.c.listen(self.listen_fd, 128) < 0) {
            return error.ListenFailed;
        }
    }

    /// Run the server event loop. Blocks until stop() is called.
    pub fn run(self: *NatsServer) !void {
        self.running.store(true, .release);

        // Set listen socket to non-blocking
        setNonblocking(self.listen_fd);

        var tick_counter: u32 = 0;

        while (self.running.load(.acquire)) {
            // Build poll fd list
            var poll_fds: std.ArrayListUnmanaged(PollFd) = .empty;
            defer poll_fds.deinit(self.allocator);

            // Listen socket
            try poll_fds.append(self.allocator, .{
                .fd = self.listen_fd,
                .events = POLLIN,
                .revents = 0,
            });

            // Client sockets
            var conn_it = self.connections.iterator();
            while (conn_it.next()) |entry| {
                var events: i16 = POLLIN;
                if (entry.value_ptr.*.send_queue.items.len > 0) {
                    events |= POLLOUT;
                }
                try poll_fds.append(self.allocator, .{
                    .fd = entry.value_ptr.*.fd,
                    .events = events,
                    .revents = 0,
                });
            }

            // Poll with 100ms timeout
            const n = doPoll(poll_fds.items.ptr, @intCast(poll_fds.items.len), 100);
            if (n <= 0) continue;

            // Check listen socket for new connections
            if (poll_fds.items[0].revents & POLLIN != 0) {
                self.acceptNewConnection() catch {};
            }

            // Process client sockets
            var i: usize = 1;
            while (i < poll_fds.items.len) : (i += 1) {
                const pfd = &poll_fds.items[i];
                const conn = self.findConnectionByFd(pfd.fd) orelse continue;

                if (pfd.revents & (POLLERR | POLLHUP) != 0) {
                    self.closeConnection(conn.id);
                    continue;
                }

                if (pfd.revents & POLLIN != 0) {
                    self.handleRead(conn) catch {
                        self.closeConnection(conn.id);
                        continue;
                    };
                }

                if (pfd.revents & POLLOUT != 0) {
                    _ = conn.flushSendQueue() catch {
                        self.closeConnection(conn.id);
                        continue;
                    };
                }
            }

            // Check for slow consumers
            self.checkSlowConsumers();

            // Periodic JetStream maintenance (~1 second at 100ms poll timeout)
            tick_counter += 1;
            if (tick_counter >= 10) {
                tick_counter = 0;
                if (self.jetstream) |js| {
                    const now_ns = @as(i64, time(null)) * 1_000_000_000;
                    js.tick(now_ns);
                }
            }
        }
    }

    /// Stop the server.
    pub fn stop(self: *NatsServer) void {
        self.running.store(false, .release);
    }

    fn acceptNewConnection(self: *NatsServer) !void {
        var client_addr: std.c.sockaddr.in = undefined;
        var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);

        const client_ret = std.c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
        if (client_ret < 0) return;

        const client_fd: posix.socket_t = @intCast(client_ret);
        setNonblocking(client_fd);

        // Check max connections
        if (self.connections.count() >= self.config.max_connections) {
            _ = std.c.close(client_fd);
            return;
        }

        const conn_id = self.next_conn_id;
        self.next_conn_id += 1;

        const conn = try self.allocator.create(connection_mod.ClientConnection);
        conn.* = try connection_mod.ClientConnection.init(self.allocator, client_fd, conn_id);
        conn.max_pending_bytes = self.config.max_pending_bytes;

        try self.connections.put(self.allocator, conn_id, conn);
        self.total_connections += 1;

        // Send INFO
        try self.sendInfo(conn);
        conn.state = .info_sent;
    }

    fn sendInfo(self: *NatsServer, conn: *connection_mod.ClientConnection) !void {
        var buf: [1024]u8 = undefined;
        const auth_str: []const u8 = if (self.config.auth_token != null or self.config.auth_user != null) "true" else "false";
        const js_str: []const u8 = if (self.jetstream != null) "true" else "false";
        const info = std.fmt.bufPrint(&buf,
            "INFO {{\"server_id\":\"zats_0\",\"server_name\":\"{s}\",\"version\":\"1.0.0\",\"proto\":1,\"max_payload\":{d},\"auth_required\":{s},\"headers\":true,\"jetstream\":{s}}}\r\n",
            .{ self.config.server_name, self.config.max_payload, auth_str, js_str },
        ) catch return error.BufferTooSmall;

        try conn.sendDirect(info);
    }

    fn handleRead(self: *NatsServer, conn: *connection_mod.ClientConnection) !void {
        var buf: [8192]u8 = undefined;
        const result = std.c.recv(conn.fd, @ptrCast(&buf), buf.len, 0);
        if (result <= 0) return error.ConnectionClosed;

        const n: usize = @intCast(result);
        try conn.appendRecvData(buf[0..n]);

        // Process all available commands
        while (conn.nextCommand()) |parse_result| {
            try self.handleCommand(conn, parse_result.command);
        }
    }

    fn handleCommand(self: *NatsServer, conn: *connection_mod.ClientConnection, cmd: protocol.Command) !void {
        switch (cmd) {
            .connect => |connect_data| {
                // Validate auth if required
                if (!self.validateAuth(connect_data.json)) {
                    try conn.sendDirect("-ERR 'Authorization Violation'\r\n");
                    return error.AuthFailed;
                }

                // Extract verbose/pedantic from CONNECT options
                if (protocol.jsonGetBool(connect_data.json, "verbose")) |v| {
                    conn.verbose = v;
                }
                if (protocol.jsonGetBool(connect_data.json, "pedantic")) |p| {
                    conn.pedantic = p;
                }

                conn.state = .ready;
                if (conn.verbose) {
                    try conn.sendDirect("+OK\r\n");
                }
            },
            .ping => {
                try conn.sendDirect("PONG\r\n");
            },
            .pong => {
                // Client responded to our PING — no action needed
            },
            .sub => |sub| {
                if (conn.state != .ready and conn.state != .info_sent) return;

                const sid = std.fmt.parseInt(u64, sub.sid, 10) catch return;
                _ = try self.router.subscribe(conn.id, sid, sub.subject, sub.queue_group);

                if (conn.verbose) {
                    try conn.sendDirect("+OK\r\n");
                }
            },
            .unsub => |unsub| {
                const sid = std.fmt.parseInt(u64, unsub.sid, 10) catch return;

                if (unsub.max_msgs) |max| {
                    _ = self.router.setMaxMsgs(conn.id, sid, max);
                } else {
                    _ = self.router.unsubscribe(conn.id, sid);
                }

                if (conn.verbose) {
                    try conn.sendDirect("+OK\r\n");
                }
            },
            .pub_msg => |pub_msg| {
                if (conn.state != .ready and conn.state != .info_sent) return;

                // Check max payload
                if (pub_msg.payload.len > self.config.max_payload) {
                    try conn.sendDirect("-ERR 'Maximum Payload Violation'\r\n");
                    return;
                }

                self.total_messages += 1;
                self.total_bytes += pub_msg.payload.len;

                // JetStream ack interception ($JS.ACK.*)
                if (self.jetstream) |js| {
                    if (startsWith(pub_msg.subject, "$JS.ACK.")) {
                        _ = js.interceptAck(pub_msg.subject, pub_msg.payload);
                        if (conn.verbose) try conn.sendDirect("+OK\r\n");
                        return;
                    }
                }

                // JetStream API interception
                if (self.js_api) |*api| {
                    if (startsWith(pub_msg.subject, "$JS.API.")) {
                        // MSG.NEXT: delivers messages to reply_to, not a JSON response
                        if (startsWith(pub_msg.subject, "$JS.API.CONSUMER.MSG.NEXT.")) {
                            self.handleMsgNext(pub_msg.subject, pub_msg.reply_to, pub_msg.payload);
                            if (conn.verbose) try conn.sendDirect("+OK\r\n");
                            return;
                        }

                        if (api.handleRequest(pub_msg.subject, pub_msg.payload)) |response| {
                            defer self.allocator.free(response);
                            if (pub_msg.reply_to) |reply_to| {
                                self.publishInternal(reply_to, response);
                            }
                            if (conn.verbose) {
                                try conn.sendDirect("+OK\r\n");
                            }
                            return;
                        }
                    }
                }

                // JetStream publish interception
                if (self.jetstream) |js| {
                    if (!startsWith(pub_msg.subject, "$JS.")) {
                        if (js.interceptPublish(pub_msg.subject, pub_msg.reply_to, null, pub_msg.payload)) |ack_json| {
                            defer self.allocator.free(ack_json);
                            if (pub_msg.reply_to) |reply_to| {
                                self.publishInternal(reply_to, ack_json);
                            }
                            // Deliver to push consumers
                            self.deliverPushMessages(js, pub_msg.subject);
                        }
                    }
                }

                // Route to matching subscribers
                var targets = try self.router.route(pub_msg.subject, pub_msg.payload);
                defer targets.deinit(self.allocator);

                for (targets.items) |target| {
                    const target_conn = self.connections.get(target.conn_id) orelse continue;

                    // Format SID as string
                    var sid_buf: [20]u8 = undefined;
                    const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{target.sid}) catch continue;

                    target_conn.queueMsg(pub_msg.subject, sid_str, pub_msg.reply_to, pub_msg.payload) catch continue;
                }

                if (conn.verbose) {
                    try conn.sendDirect("+OK\r\n");
                }
            },
            .hpub => |hpub| {
                if (conn.state != .ready and conn.state != .info_sent) return;

                // Check max payload
                if (hpub.total_len > self.config.max_payload) {
                    try conn.sendDirect("-ERR 'Maximum Payload Violation'\r\n");
                    return;
                }

                self.total_messages += 1;
                self.total_bytes += hpub.total_len;

                // JetStream ack interception ($JS.ACK.*)
                if (self.jetstream) |js| {
                    if (startsWith(hpub.subject, "$JS.ACK.")) {
                        _ = js.interceptAck(hpub.subject, hpub.payload);
                        if (conn.verbose) try conn.sendDirect("+OK\r\n");
                        return;
                    }
                }

                // JetStream API interception
                if (self.js_api) |*api| {
                    if (startsWith(hpub.subject, "$JS.API.")) {
                        // MSG.NEXT via HPUB
                        if (startsWith(hpub.subject, "$JS.API.CONSUMER.MSG.NEXT.")) {
                            self.handleMsgNext(hpub.subject, hpub.reply_to, hpub.payload);
                            if (conn.verbose) try conn.sendDirect("+OK\r\n");
                            return;
                        }

                        if (api.handleRequest(hpub.subject, hpub.payload)) |response| {
                            defer self.allocator.free(response);
                            if (hpub.reply_to) |reply_to| {
                                self.publishInternal(reply_to, response);
                            }
                            if (conn.verbose) {
                                try conn.sendDirect("+OK\r\n");
                            }
                            return;
                        }
                    }
                }

                // JetStream publish interception
                if (self.jetstream) |js| {
                    if (!startsWith(hpub.subject, "$JS.")) {
                        if (js.interceptPublish(hpub.subject, hpub.reply_to, hpub.headers, hpub.payload)) |ack_json| {
                            defer self.allocator.free(ack_json);
                            if (hpub.reply_to) |reply_to| {
                                self.publishInternal(reply_to, ack_json);
                            }
                            // Deliver to push consumers
                            self.deliverPushMessages(js, hpub.subject);
                        }
                    }
                }

                // Route to matching subscribers as HMSG
                var targets = try self.router.route(hpub.subject, hpub.payload);
                defer targets.deinit(self.allocator);

                for (targets.items) |target| {
                    const target_conn = self.connections.get(target.conn_id) orelse continue;

                    var sid_buf: [20]u8 = undefined;
                    const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{target.sid}) catch continue;

                    target_conn.queueHmsg(hpub.subject, sid_str, hpub.reply_to, hpub.headers, hpub.payload) catch continue;
                }

                if (conn.verbose) {
                    try conn.sendDirect("+OK\r\n");
                }
            },
            .info, .msg, .hmsg, .ok, .err => {
                // These are server→client messages, ignore from client
            },
        }
    }

    /// Route a response message to subscribers of the given subject.
    fn publishInternal(self: *NatsServer, subject: []const u8, payload: []const u8) void {
        self.publishInternalWithReply(subject, null, null, payload);
    }

    /// Route a message with optional reply-to and headers to subscribers.
    fn publishInternalWithReply(self: *NatsServer, subject: []const u8, reply_to: ?[]const u8, hdrs: ?[]const u8, payload: []const u8) void {
        var targets = self.router.route(subject, payload) catch return;
        defer targets.deinit(self.allocator);

        for (targets.items) |target| {
            const target_conn = self.connections.get(target.conn_id) orelse continue;
            var sid_buf: [20]u8 = undefined;
            const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{target.sid}) catch continue;
            if (hdrs) |h| {
                target_conn.queueHmsg(subject, sid_str, reply_to, h, payload) catch continue;
            } else {
                target_conn.queueMsg(subject, sid_str, reply_to, payload) catch continue;
            }
        }
    }

    /// Deliver messages to push consumers after a stream stores a message.
    fn deliverPushMessages(self: *NatsServer, js: *jetstream_mod.JetStream, subject: []const u8) void {
        // Find stream name from subject match
        var matches: std.ArrayListUnmanaged(*@import("stream.zig").Stream) = .empty;
        defer matches.deinit(self.allocator);
        js.subject_trie.match(subject, &matches) catch return;
        if (matches.items.len == 0) return;

        const stream_name = matches.items[0].config.name;

        var deliveries = js.getPushDeliveries(stream_name, subject);
        defer {
            for (deliveries.items) |*d| {
                consumer_mod.freeDeliveredMessages(&d.messages, self.allocator);
            }
            deliveries.deinit(self.allocator);
        }

        for (deliveries.items) |d| {
            for (d.messages.items) |msg| {
                self.publishInternalWithReply(d.deliver_subject, msg.ack_reply, msg.headers, msg.data);
            }
        }
    }

    /// Handle $JS.API.CONSUMER.MSG.NEXT.* pull requests.
    fn handleMsgNext(self: *NatsServer, subject: []const u8, reply_to: ?[]const u8, data: []const u8) void {
        const inbox = reply_to orelse return;
        const rest = subject["$JS.API.CONSUMER.MSG.NEXT.".len..];

        const parts = splitDot(rest) orelse return;
        const stream_name = parts.first;
        const consumer_name = parts.rest;

        const js = self.jetstream orelse return;
        const consumer = js.getConsumer(stream_name, consumer_name) orelse {
            self.publishInternal(inbox, "{\"error\":{\"code\":10014,\"description\":\"consumer not found\"}}");
            return;
        };

        var batch: u32 = 1;
        if (data.len > 2) {
            if (js_api_mod.jsonGetInt(data, "batch")) |b| {
                batch = @intCast(@min(b, 256));
            }
        }

        var messages = consumer.fetch(batch) catch return;
        defer consumer_mod.freeDeliveredMessages(&messages, self.allocator);

        if (messages.items.len == 0) {
            // 404 — no messages available
            self.publishInternal(inbox, "");
            return;
        }

        // Deliver each message to the reply-to inbox with ack subject as reply-to
        for (messages.items) |msg| {
            self.publishInternalWithReply(inbox, msg.ack_reply, msg.headers, msg.data);
        }
    }

    fn validateAuth(self: *NatsServer, connect_json: []const u8) bool {
        // Token auth
        if (self.config.auth_token) |expected_token| {
            const client_token = protocol.jsonGetString(connect_json, "auth_token") orelse return false;
            return std.mem.eql(u8, client_token, expected_token);
        }

        // User/password auth
        if (self.config.auth_user) |expected_user| {
            const client_user = protocol.jsonGetString(connect_json, "user") orelse return false;
            if (!std.mem.eql(u8, client_user, expected_user)) return false;
            if (self.config.auth_pass) |expected_pass| {
                const client_pass = protocol.jsonGetString(connect_json, "pass") orelse return false;
                return std.mem.eql(u8, client_pass, expected_pass);
            }
            return true;
        }

        // No auth required
        return true;
    }

    fn closeConnection(self: *NatsServer, conn_id: u64) void {
        if (self.connections.fetchRemove(conn_id)) |entry| {
            const conn = entry.value;
            self.router.removeConnection(conn_id);
            _ = std.c.close(conn.fd);
            conn.deinit();
            self.allocator.destroy(conn);
        }
    }

    fn checkSlowConsumers(self: *NatsServer) void {
        var to_close: std.ArrayListUnmanaged(u64) = .empty;
        defer to_close.deinit(self.allocator);

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.isSlowConsumer()) {
                // Try to send error before closing
                entry.value_ptr.*.sendDirect("-ERR 'Slow Consumer'\r\n") catch {};
                to_close.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_close.items) |id| {
            self.closeConnection(id);
        }
    }

    fn findConnectionByFd(self: *NatsServer, fd: posix.socket_t) ?*connection_mod.ClientConnection {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.fd == fd) return entry.value_ptr.*;
        }
        return null;
    }

    /// Get current stats.
    pub fn getStats(self: *const NatsServer) Stats {
        return .{
            .connections = self.connections.count(),
            .total_connections = self.total_connections,
            .subscriptions = self.router.subscriptionCount(),
            .total_messages = self.total_messages,
            .total_bytes = self.total_bytes,
        };
    }
};

pub const Stats = struct {
    connections: usize,
    total_connections: u64,
    subscriptions: usize,
    total_messages: u64,
    total_bytes: u64,
};

// --- Cross-platform poll ---

const PollFd = extern struct {
    fd: posix.socket_t,
    events: i16,
    revents: i16,
};

const POLLIN: i16 = 0x0001;
const POLLOUT: i16 = 0x0004;
const POLLERR: i16 = 0x0008;
const POLLHUP: i16 = 0x0010;

fn doPoll(fds: [*]PollFd, nfds: u32, timeout_ms: c_int) c_int {
    if (is_linux) {
        return @intCast(std.os.linux.poll(@ptrCast(fds), nfds, timeout_ms));
    } else {
        return std.c.poll(@ptrCast(fds), nfds, timeout_ms);
    }
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

const DotSplit = struct { first: []const u8, rest: []const u8 };

fn splitDot(s: []const u8) ?DotSplit {
    for (s, 0..) |c, i| {
        if (c == '.') return .{ .first = s[0..i], .rest = s[i + 1 ..] };
    }
    return null;
}

fn setNonblocking(fd: posix.socket_t) void {
    if (is_linux) {
        _ = std.os.linux.fcntl(@intCast(fd), @intCast(std.c.F.SETFL), @as(c_uint, 0o4000));
    } else {
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_uint, 0x0004));
    }
}

// --- Tests ---

test "server init and deinit" {
    const allocator = std.testing.allocator;
    var server = try NatsServer.init(allocator, .{});
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 4222), server.config.port);
    try std.testing.expectEqual(@as(usize, 0), server.connections.count());
}

test "server stats" {
    const allocator = std.testing.allocator;
    var server = try NatsServer.init(allocator, .{});
    defer server.deinit();

    const stats = server.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.connections);
    try std.testing.expectEqual(@as(u64, 0), stats.total_messages);
}

test "server auth validation — no auth required" {
    const allocator = std.testing.allocator;
    var srv = try NatsServer.init(allocator, .{});
    defer srv.deinit();

    try std.testing.expect(srv.validateAuth("{}"));
    try std.testing.expect(srv.validateAuth("{\"verbose\":false}"));
}

test "server auth validation — token" {
    const allocator = std.testing.allocator;
    var srv = try NatsServer.init(allocator, .{ .auth_token = "s3cret" });
    defer srv.deinit();

    try std.testing.expect(srv.validateAuth("{\"auth_token\":\"s3cret\"}"));
    try std.testing.expect(!srv.validateAuth("{\"auth_token\":\"wrong\"}"));
    try std.testing.expect(!srv.validateAuth("{\"verbose\":false}"));
}

test "server auth validation — user/pass" {
    const allocator = std.testing.allocator;
    var srv = try NatsServer.init(allocator, .{ .auth_user = "admin", .auth_pass = "password" });
    defer srv.deinit();

    try std.testing.expect(srv.validateAuth("{\"user\":\"admin\",\"pass\":\"password\"}"));
    try std.testing.expect(!srv.validateAuth("{\"user\":\"admin\",\"pass\":\"wrong\"}"));
    try std.testing.expect(!srv.validateAuth("{\"user\":\"other\",\"pass\":\"password\"}"));
    try std.testing.expect(!srv.validateAuth("{\"verbose\":false}"));
}
