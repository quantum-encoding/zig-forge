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


// chronos_client.zig - Client library for Chronos Daemon
// Purpose: Provide simple API for connecting to chronosd via Unix socket
//
// Usage:
//   var client = try ChronosClient.connect(allocator);
//   defer client.disconnect();
//
//   const tick = try client.getTick();
//   const next = try client.nextTick();
//   const timestamp = try client.getPhiTimestamp("CLAUDE-A");
//   const log = try client.logEvent("CLAUDE-A", "action", "SUCCESS", "details");

const std = @import("std");
const protocol = @import("socket_protocol.zig");
const net = std.net;
const posix = std.posix;

pub const ChronosClient = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream,
    socket_path: []const u8,

    /// Connect to Chronos daemon
    pub fn connect(allocator: std.mem.Allocator) !ChronosClient {
        // Try default path first, then fallback
        const socket_path = blk: {
            std.fs.cwd().access(protocol.DEFAULT_SOCKET_PATH, .{}) catch {
                break :blk protocol.FALLBACK_SOCKET_PATH;
            };
            break :blk protocol.DEFAULT_SOCKET_PATH;
        };

        // Create Unix domain socket
        const sockfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer _ = std.c.close(sockfd);

        // Connect to daemon
        const address = try net.Address.initUnix(socket_path);
        try posix.connect(sockfd, &address.any, address.getOsSockLen());

        const stream = net.Stream{ .handle = sockfd };

        return ChronosClient{
            .allocator = allocator,
            .stream = stream,
            .socket_path = socket_path,
        };
    }

    /// Disconnect from daemon
    pub fn disconnect(self: *ChronosClient) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
    }

    /// Send command and receive response
    fn sendCommand(self: *ChronosClient, command: []const u8) ![]u8 {
        const stream = self.stream orelse return error.NotConnected;

        // Send command
        try stream.writeAll(command);
        try stream.writeAll("\n");

        // Read response
        var buf: [protocol.MAX_MESSAGE_LEN]u8 = undefined;
        const bytes_read = try stream.read(&buf);
        if (bytes_read == 0) return error.ConnectionClosed;

        const response = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);

        // Parse response
        if (std.mem.startsWith(u8, response, "OK:")) {
            const result = response[3..]; // Skip "OK:"
            return try self.allocator.dupe(u8, result);
        } else if (std.mem.startsWith(u8, response, "ERR:")) {
            const message = response[4..]; // Skip "ERR:"
            std.debug.print("Chronos error: {s}\n", .{message});
            return error.ChronosError;
        } else if (std.mem.eql(u8, response, "PONG")) {
            return try self.allocator.dupe(u8, "PONG");
        } else {
            return error.InvalidResponse;
        }
    }

    /// Get current tick (non-destructive)
    pub fn getTick(self: *ChronosClient) !u64 {
        const response = try self.sendCommand("GET_TICK");
        defer self.allocator.free(response);
        return try std.fmt.parseInt(u64, response, 10);
    }

    /// Increment and get next tick
    pub fn nextTick(self: *ChronosClient) !u64 {
        const response = try self.sendCommand("NEXT_TICK");
        defer self.allocator.free(response);
        return try std.fmt.parseInt(u64, response, 10);
    }

    /// Generate Phi timestamp
    pub fn getPhiTimestamp(self: *ChronosClient, agent_id: []const u8) ![]u8 {
        const command = try std.fmt.allocPrint(self.allocator, "STAMP:{s}", .{agent_id});
        defer self.allocator.free(command);
        return try self.sendCommand(command);
    }

    /// Log event with Phi timestamp
    pub fn logEvent(
        self: *ChronosClient,
        agent_id: []const u8,
        action: []const u8,
        status: []const u8,
        details: []const u8,
    ) ![]u8 {
        const command = try std.fmt.allocPrint(
            self.allocator,
            "LOG:{s}:{s}:{s}:{s}",
            .{ agent_id, action, status, details },
        );
        defer self.allocator.free(command);
        return try self.sendCommand(command);
    }

    /// Ping daemon (health check)
    pub fn ping(self: *ChronosClient) !void {
        const response = try self.sendCommand("PING");
        defer self.allocator.free(response);
        if (!std.mem.eql(u8, response, "PONG")) {
            return error.InvalidPong;
        }
    }

    /// Shutdown daemon (requires privilege)
    pub fn shutdown(self: *ChronosClient) !void {
        _ = try self.sendCommand("SHUTDOWN");
    }
};

// ============================================================
// Tests (require running daemon)
// ============================================================

test "ChronosClient basic operations" {
    // NOTE: This test requires chronosd to be running
    // Run manually: ./chronosd &
    // Then: zig test chronos_client.zig

    const allocator = std.testing.allocator;

    var client = ChronosClient.connect(allocator) catch |err| {
        std.debug.print("⚠️  Skipping test - daemon not running: {any}\n", .{err});
        return;
    };
    defer client.disconnect();

    // Test ping
    try client.ping();

    // Test getTick
    const tick1 = try client.getTick();
    std.debug.print("Current tick: {d}\n", .{tick1});

    // Test nextTick
    const tick2 = try client.nextTick();
    try std.testing.expect(tick2 > tick1);

    // Test Phi timestamp
    const timestamp = try client.getPhiTimestamp("TEST-AGENT");
    defer allocator.free(timestamp);
    std.debug.print("Phi timestamp: {s}\n", .{timestamp});

    // Test log event
    const log_json = try client.logEvent("TEST-AGENT", "test_action", "SUCCESS", "test details");
    defer allocator.free(log_json);
    std.debug.print("Log JSON: {s}\n", .{log_json});
}
