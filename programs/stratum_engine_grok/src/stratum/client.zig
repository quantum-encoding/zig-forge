const std = @import("std");
const protocol = @import("protocol.zig");
const compat = @import("../compat.zig");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;
const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("arpa/inet.h");
});

pub const Client = struct {
    allocator: std.mem.Allocator,
    ring: IoUring,
    sockfd: posix.fd_t,
    parser: protocol.Parser,
    recv_buffer: [4096]u8,
    buffer_pos: usize,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Client {
        std.debug.print("=== STRATUM CLIENT v2 ===\n", .{});
        std.debug.print("Connecting to {s}:{d}...\n", .{host, port});

        // Initialize io_uring without SQPOLL (requires elevated privileges)
        // Use standard io_uring mode instead
        var ring = try IoUring.init(64, 0);
        std.debug.print("io_uring initialized\n", .{});

        // Create TCP socket using compat wrapper for Zig 0.16.2187+
        const sockfd = try compat.createSocket(linux.SOCK.STREAM | linux.SOCK.CLOEXEC);
        std.debug.print("Socket created: {d}\n", .{sockfd});

        // Resolve DNS address using libc getaddrinfo (Zig 0.16 compatibility)
        std.debug.print("Resolving DNS for {s}...\n", .{host});

        // Create null-terminated host string
        var host_buf: [256]u8 = undefined;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;

        // Create port string
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return error.InvalidPort;
        port_buf[port_str.len] = 0;

        var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
        hints.ai_family = c.AF_INET;
        hints.ai_socktype = c.SOCK_STREAM;

        var result: ?*c.addrinfo = null;
        const gai_ret = c.getaddrinfo(&host_buf, &port_buf, &hints, &result);
        if (gai_ret != 0) {
            std.debug.print("DNS resolution failed: {d}\n", .{gai_ret});
            return error.DNSResolutionFailed;
        }
        defer c.freeaddrinfo(result);

        if (result == null) {
            return error.NoAddressFound;
        }

        // Copy the resolved address
        var address: linux.sockaddr.in = undefined;
        const addr_ptr: *linux.sockaddr.in = @ptrCast(@alignCast(result.?.ai_addr));
        address = addr_ptr.*;

        // Submit connect operation
        const sqe = try ring.get_sqe();
        sqe.prep_connect(sockfd, @ptrCast(&address), @sizeOf(linux.sockaddr.in));

        // Wait for completion
        _ = try ring.submit_and_wait(1);
        var cqe = try ring.copy_cqe();
        defer ring.cqe_seen(&cqe);

        if (cqe.res < 0) {
            const err_code = -cqe.res;
            std.debug.print("Connection failed with error code: {d}\n", .{err_code});
            std.debug.print("Trying to connect to {s}:{d}\n", .{host, port});
            return error.ConnectFailed;
        }

        return .{
            .allocator = allocator,
            .ring = ring,
            .sockfd = sockfd,
            .parser = protocol.Parser.init(allocator),
            .recv_buffer = undefined,
            .buffer_pos = 0,
        };
    }

    pub fn deinit(self: *Client) void {
        compat.closeSocket(self.sockfd);
        self.parser.deinit();
        self.ring.deinit();
    }

    pub fn sendMessage(self: *Client, message: []const u8) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(self.sockfd, message, 0);

        _ = try self.ring.submit();
        // Note: Completions are not waited for here (fire-and-forget)
        // Call flush_completions() when needed to sync
    }

    pub fn receiveMessage(self: *Client) !?protocol.ParsedMessage {
        // Submit recv operation
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(self.sockfd, self.recv_buffer[self.buffer_pos..], 0);

        _ = try self.ring.submit_and_wait(1);
        var cqe = try self.ring.copy_cqe();
        defer self.ring.cqe_seen(&cqe);

        if (cqe.res < 0) {
            return error.RecvFailed;
        }

        const bytes_read = @as(usize, @intCast(cqe.res));
        if (bytes_read == 0) {
            return null; // Connection closed
        }

        self.buffer_pos += bytes_read;

        // Look for complete messages (separated by newlines)
        var start: usize = 0;
        for (0..self.buffer_pos) |i| {
            if (self.recv_buffer[i] == '\n') {
                const message_slice = self.recv_buffer[start..i];
                if (message_slice.len > 0) {
                    if (try self.parser.parseMessage(message_slice)) |parsed| {
                        // Shift remaining buffer
                        const remaining = self.buffer_pos - (i + 1);
                        if (remaining > 0) {
                            std.mem.copyForwards(u8, &self.recv_buffer, self.recv_buffer[i + 1..self.buffer_pos]);
                        }
                        self.buffer_pos = remaining;
                        return parsed;
                    }
                }
                start = i + 1;
            }
        }

        // If buffer is full and no newline, clear it (simple error recovery)
        if (self.buffer_pos == self.recv_buffer.len) {
            self.buffer_pos = 0;
        }

        return null;
    }

    pub fn subscribe(self: *Client) !void {
        const subscribe_msg = "{\"id\": 1, \"method\": \"mining.subscribe\", \"params\": [\"zig-stratum-engine/1.0\"]}\n";
        try self.sendMessage(subscribe_msg);
    }

    pub fn authorize(self: *Client, username: []const u8, password: []const u8) !void {
        const auth_msg = try std.fmt.allocPrint(self.allocator, "{{\"id\": 2, \"method\": \"mining.authorize\", \"params\": [\"{s}\", \"{s}\"]}}\n", .{username, password});
        defer self.allocator.free(auth_msg);
        try self.sendMessage(auth_msg);
    }

    pub fn submitShare(self: *Client, job_id: []const u8, extranonce2: []const u8, ntime: []const u8, nonce: []const u8) !void {
        const submit_msg = try std.fmt.allocPrint(self.allocator, "{{\"id\": 3, \"method\": \"mining.submit\", \"params\": [\"user\", \"{s}\", \"{s}\", \"{s}\", \"{s}\"]}}\n", .{job_id, extranonce2, ntime, nonce});
        defer self.allocator.free(submit_msg);
        try self.sendMessage(submit_msg);
    }
};