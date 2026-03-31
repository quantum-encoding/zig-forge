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


// socket_protocol.zig - Unix Domain Socket Protocol for Chronos IPC
// Purpose: Simple text-based protocol for client-daemon communication
//
// Socket Path: /var/run/chronos.sock (or /tmp/chronos.sock fallback)
//
// Protocol Specification:
//   - Text-based, line-delimited (newline-terminated)
//   - Commands: COMMAND [ARGS]\n
//   - Responses: OK:result\n or ERR:message\n
//
// Commands:
//   GET_TICK              → OK:42
//   NEXT_TICK             → OK:43
//   STAMP:AGENT-ID        → OK:2025-10-19T21:28:24.472823544Z::AGENT-ID::TICK-0000000003
//   LOG:AGENT:ACTION:STATUS:DETAILS → OK:{"timestamp":"...","action":"..."}
//   PING                  → PONG
//   SHUTDOWN              → OK (closes connection, shuts down daemon)
//
// Security:
//   - Socket permissions: 0666 (all users can connect)
//   - Only chronosd can bind socket
//   - Commands are unprivileged (no authentication required)

const std = @import("std");

/// Default socket path (system)
pub const DEFAULT_SOCKET_PATH = "/var/run/chronos.sock";

/// Fallback socket path (development/testing)
pub const FALLBACK_SOCKET_PATH = "/tmp/chronos.sock";

/// Maximum command/response length
pub const MAX_MESSAGE_LEN: usize = 4096;

/// Protocol commands
pub const Command = enum {
    get_tick,
    next_tick,
    stamp,
    log,
    ping,
    shutdown,
    status,
    unknown,

    pub fn parse(line: []const u8) Command {
        if (std.mem.startsWith(u8, line, "GET_TICK")) return .get_tick;
        if (std.mem.startsWith(u8, line, "NEXT_TICK")) return .next_tick;
        if (std.mem.startsWith(u8, line, "STAMP:")) return .stamp;
        if (std.mem.startsWith(u8, line, "LOG:")) return .log;
        if (std.mem.startsWith(u8, line, "PING")) return .ping;
        if (std.mem.startsWith(u8, line, "SHUTDOWN")) return .shutdown;
        if (std.mem.startsWith(u8, line, "STATUS")) return .status;
        return .unknown;
    }
};

/// Parse STAMP command arguments
pub fn parseStampArgs(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "STAMP:")) return null;
    const agent_id = line[6..]; // Skip "STAMP:"
    if (agent_id.len == 0) return null;
    return agent_id;
}

/// Parse LOG command arguments
pub const LogArgs = struct {
    agent_id: []const u8,
    action: []const u8,
    status: []const u8,
    details: []const u8,
};

pub fn parseLogArgs(line: []const u8) ?LogArgs {
    if (!std.mem.startsWith(u8, line, "LOG:")) return null;

    var parts = std.mem.splitSequence(u8, line[4..], ":"); // Skip "LOG:"

    const agent_id = parts.next() orelse return null;
    const action = parts.next() orelse return null;
    const status = parts.next() orelse return null;
    const details = parts.rest(); // Everything after 3rd colon

    return LogArgs{
        .agent_id = agent_id,
        .action = action,
        .status = status,
        .details = details,
    };
}

/// Format OK response
pub fn formatOk(allocator: std.mem.Allocator, result: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "OK:{s}\n", .{result});
}

/// Format ERR response
pub fn formatErr(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "ERR:{s}\n", .{message});
}

/// Format PONG response
pub fn formatPong(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "PONG\n");
}

// ============================================================
// Tests
// ============================================================

test "Command parsing" {
    try std.testing.expectEqual(Command.get_tick, Command.parse("GET_TICK"));
    try std.testing.expectEqual(Command.next_tick, Command.parse("NEXT_TICK"));
    try std.testing.expectEqual(Command.stamp, Command.parse("STAMP:CLAUDE-A"));
    try std.testing.expectEqual(Command.log, Command.parse("LOG:AGENT:ACTION:STATUS:DETAILS"));
    try std.testing.expectEqual(Command.ping, Command.parse("PING"));
    try std.testing.expectEqual(Command.shutdown, Command.parse("SHUTDOWN"));
    try std.testing.expectEqual(Command.unknown, Command.parse("INVALID"));
}

test "STAMP argument parsing" {
    const agent_id = parseStampArgs("STAMP:CLAUDE-A");
    try std.testing.expect(agent_id != null);
    try std.testing.expectEqualStrings("CLAUDE-A", agent_id.?);
}

test "LOG argument parsing" {
    const args = parseLogArgs("LOG:CLAUDE-A:test_defense:SUCCESS:All tests passed");
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("CLAUDE-A", args.?.agent_id);
    try std.testing.expectEqualStrings("test_defense", args.?.action);
    try std.testing.expectEqualStrings("SUCCESS", args.?.status);
    try std.testing.expectEqualStrings("All tests passed", args.?.details);
}

test "Response formatting" {
    const allocator = std.testing.allocator;

    const ok = try formatOk(allocator, "42");
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("OK:42\n", ok);

    const err = try formatErr(allocator, "Invalid command");
    defer allocator.free(err);
    try std.testing.expectEqualStrings("ERR:Invalid command\n", err);

    const pong = try formatPong(allocator);
    defer allocator.free(pong);
    try std.testing.expectEqualStrings("PONG\n", pong);
}
