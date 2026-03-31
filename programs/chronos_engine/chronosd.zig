//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// chronosd.zig - Chronos Sovereign Daemon
// Purpose: Permanent system service providing Sovereign Clock via D-Bus
//
// Architecture:
//   - Runs as dedicated 'chronos' user (created by systemd)
//   - Sole authority over /var/lib/chronos/tick.dat
//   - Exposes D-Bus interface org.jesternet.Chronos
//   - Managed by systemd (automatic restart, boot persistence)
//
// Security Model:
//   - Centralized privilege (only chronosd writes tick file)
//   - Decentralized access (all clients use unprivileged D-Bus)
//   - Minimal trusted computing base

const std = @import("std");
const chronos = @import("chronos.zig");
const phi = @import("phi_timestamp.zig");
const dbus = @import("dbus_interface.zig");
const protocol = @import("socket_protocol.zig");
const net = std.net;
const posix = std.posix;

const VERSION = "1.0.0";

/// Chronos Daemon - manages Sovereign Clock and D-Bus interface
pub const ChronosDaemon = struct {
    clock: chronos.ChronosClock,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) !ChronosDaemon {
        // Initialize Chronos Clock with explicit /tmp path for development
        // Production systemd deployment will have access to /var/lib/chronos
        const clock = try chronos.ChronosClock.init(allocator, "/tmp/chronos-tick.dat");

        std.debug.print("🕐 Chronos Daemon v{s} starting\n", .{VERSION});
        std.debug.print("   Service: {s}\n", .{dbus.DBUS_SERVICE});
        std.debug.print("   Path: {s}\n", .{dbus.DBUS_PATH});

        return ChronosDaemon{
            .clock = clock,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *ChronosDaemon) void {
        self.clock.deinit();
        std.debug.print("🕐 Chronos Daemon shutdown complete\n", .{});
    }

    /// Handle GetTick method
    pub fn handleGetTick(self: *const ChronosDaemon) u64 {
        return self.clock.getTick();
    }

    /// Handle NextTick method
    pub fn handleNextTick(self: *ChronosDaemon) !u64 {
        return try self.clock.nextTick();
    }

    /// Handle GetPhiTimestamp method
    pub fn handleGetPhiTimestamp(self: *ChronosDaemon, agent_id: []const u8) ![]u8 {
        var gen = phi.PhiGenerator.init(self.allocator, &self.clock, agent_id);
        const timestamp = try gen.next();
        return try timestamp.format(self.allocator);
    }

    /// Handle LogEvent method
    pub fn handleLogEvent(
        self: *ChronosDaemon,
        agent_id: []const u8,
        action: []const u8,
        status: []const u8,
        details: []const u8,
    ) ![]u8 {
        var gen = phi.PhiGenerator.init(self.allocator, &self.clock, agent_id);
        const timestamp = try gen.next();

        const log_entry = phi.PhiLogEntry{
            .timestamp = timestamp,
            .action = action,
            .status = status,
            .details = if (details.len > 0) details else null,
        };

        return try log_entry.toJson(self.allocator);
    }

    /// Run daemon with Unix socket server
    pub fn run(self: *ChronosDaemon) !void {
        // Determine socket path
        const socket_path = protocol.FALLBACK_SOCKET_PATH; // Always use /tmp for now

        std.debug.print("🕐 Using socket path: {s}\n", .{socket_path});

        // Remove old socket if it exists
        std.fs.cwd().deleteFile(socket_path) catch {};

        // Create Unix domain socket using lower-level posix APIs
        const sockfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer _ = std.c.close(sockfd);

        std.debug.print("🕐 Socket created, fd={d}\n", .{sockfd});

        const address = try net.Address.initUnix(socket_path);
        std.debug.print("🕐 Address initialized\n", .{});

        try posix.bind(sockfd, &address.any, address.getOsSockLen());
        std.debug.print("🕐 Socket bound\n", .{});

        try posix.listen(sockfd, 128); // backlog
        std.debug.print("🕐 Socket listening\n", .{});

        // Set socket permissions (0666 - all users can connect)
        posix.fchmod(sockfd, 0o666) catch |err| {
            std.debug.print("⚠️  Failed to set socket permissions: {any}\n", .{err});
        };

        std.debug.print("🕐 Chronos Daemon v{s} running\n", .{VERSION});
        std.debug.print("   Socket: {s}\n", .{socket_path});
        std.debug.print("   Current tick: {d}\n", .{self.clock.getTick()});
        std.debug.print("   Ready for connections\n\n", .{});

        // Accept loop
        while (self.running.load(.acquire)) {
            var client_addr: posix.sockaddr = undefined;
            var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const client_fd = posix.accept(sockfd, &client_addr, &client_addr_len, 0) catch |err| {
                std.debug.print("⚠️  Accept error: {any}\n", .{err});
                continue;
            };

            const client_stream = net.Stream{ .handle = client_fd };

            // Handle connection in same thread (simple blocking model)
            self.handleConnection(client_stream) catch |err| {
                std.debug.print("⚠️  Connection handler error: {any}\n", .{err});
            };
            client_stream.close();
        }

        // Cleanup
        _ = std.c.close(sockfd);
        std.fs.cwd().deleteFile(socket_path) catch {};
    }

    /// Handle a client connection
    fn handleConnection(self: *ChronosDaemon, stream: net.Stream) !void {
        var buf: [protocol.MAX_MESSAGE_LEN]u8 = undefined;

        // Read command (line-delimited)
        const bytes_read = stream.read(&buf) catch |err| {
            std.debug.print("⚠️  Read error: {any}\n", .{err});
            return err;
        };

        if (bytes_read == 0) return; // EOF

        const command_line = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
        const cmd = protocol.Command.parse(command_line);

        switch (cmd) {
            .get_tick => {
                const tick = self.handleGetTick();
                const tick_str = try std.fmt.allocPrint(self.allocator, "{d}", .{tick});
                defer self.allocator.free(tick_str);

                const response = try protocol.formatOk(self.allocator, tick_str);
                defer self.allocator.free(response);

                try stream.writeAll(response);
            },

            .next_tick => {
                const tick = try self.handleNextTick();
                const tick_str = try std.fmt.allocPrint(self.allocator, "{d}", .{tick});
                defer self.allocator.free(tick_str);

                const response = try protocol.formatOk(self.allocator, tick_str);
                defer self.allocator.free(response);

                try stream.writeAll(response);
            },

            .stamp => {
                const agent_id = protocol.parseStampArgs(command_line) orelse {
                    const response = try protocol.formatErr(self.allocator, "Invalid STAMP syntax");
                    defer self.allocator.free(response);
                    try stream.writeAll(response);
                    return;
                };

                const timestamp = try self.handleGetPhiTimestamp(agent_id);
                defer self.allocator.free(timestamp);

                const response = try protocol.formatOk(self.allocator, timestamp);
                defer self.allocator.free(response);

                try stream.writeAll(response);
            },

            .log => {
                const args = protocol.parseLogArgs(command_line) orelse {
                    const response = try protocol.formatErr(self.allocator, "Invalid LOG syntax");
                    defer self.allocator.free(response);
                    try stream.writeAll(response);
                    return;
                };

                const log_json = try self.handleLogEvent(
                    args.agent_id,
                    args.action,
                    args.status,
                    args.details,
                );
                defer self.allocator.free(log_json);

                const response = try protocol.formatOk(self.allocator, log_json);
                defer self.allocator.free(response);

                try stream.writeAll(response);
            },

            .ping => {
                const response = try protocol.formatPong(self.allocator);
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },

            .shutdown => {
                std.debug.print("🕐 Shutdown command received\n", .{});
                const response = try protocol.formatOk(self.allocator, "Shutting down");
                defer self.allocator.free(response);
                try stream.writeAll(response);
                self.shutdown();
            },

            .unknown => {
                const response = try protocol.formatErr(self.allocator, "Unknown command");
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },
        }
    }

    /// Shutdown daemon gracefully
    pub fn shutdown(self: *ChronosDaemon) void {
        std.debug.print("🕐 Chronos Daemon shutting down...\n", .{});
        self.running.store(false, .release);
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var daemon = try ChronosDaemon.init(allocator);
    defer daemon.deinit();

    // Setup signal handler for graceful shutdown
    // NOTE: Proper signal handling requires platform-specific code
    // For now, Ctrl+C will trigger deinit via defer

    try daemon.run();
}
