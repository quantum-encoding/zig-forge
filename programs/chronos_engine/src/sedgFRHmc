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


// chronos-ctl-client.zig - Chronos Clock Control Interface (Client Version)
// Purpose: CLI tool for interacting with chronosd daemon via Unix socket
//
// This version connects to chronosd daemon instead of directly accessing the clock.
// All operations go through the Unix socket IPC.

const std = @import("std");
const ChronosClient = @import("chronos_client.zig").ChronosClient;

const VERSION = "1.0.0-client";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "version")) {
        std.debug.print("chronos-ctl version {s} (client mode)\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "help")) {
        try printUsage();
        return;
    }

    // Connect to daemon for all other commands
    var client = ChronosClient.connect(allocator) catch |err| {
        std.debug.print("Error: Cannot connect to chronosd daemon: {any}\n", .{err});
        std.debug.print("Is chronosd running? Try: ./chronosd &\n", .{});
        std.process.exit(1);
    };
    defer client.disconnect();

    if (std.mem.eql(u8, command, "ping")) {
        client.ping() catch |err| {
            std.debug.print("Error: Ping failed: {any}\n", .{err});
            std.process.exit(1);
        };
        std.debug.print("PONG\n", .{});
        return;
    }

    if (std.mem.eql(u8, command, "tick")) {
        const tick = try client.getTick();
        std.debug.print("{d}\n", .{tick});
        return;
    }

    if (std.mem.eql(u8, command, "next")) {
        const tick = try client.nextTick();
        std.debug.print("{d}\n", .{tick});
        return;
    }

    if (std.mem.eql(u8, command, "stamp")) {
        if (args.len < 3) {
            std.debug.print("Error: 'stamp' requires agent ID\n", .{});
            std.debug.print("Usage: chronos-ctl stamp <agent-id>\n", .{});
            std.process.exit(1);
        }

        const agent_id = args[2];
        const timestamp = try client.getPhiTimestamp(agent_id);
        defer allocator.free(timestamp);

        std.debug.print("{s}\n", .{timestamp});
        return;
    }

    if (std.mem.eql(u8, command, "log")) {
        if (args.len < 5) {
            std.debug.print("Error: 'log' requires agent ID, action, and status\n", .{});
            std.debug.print("Usage: chronos-ctl log <agent-id> <action> <status> [details]\n", .{});
            std.process.exit(1);
        }

        const agent_id = args[2];
        const action = args[3];
        const status = args[4];
        const details = if (args.len > 5) args[5] else "";

        const log_json = try client.logEvent(agent_id, action, status, details);
        defer allocator.free(log_json);

        std.debug.print("{s}\n", .{log_json});
        return;
    }

    if (std.mem.eql(u8, command, "shutdown")) {
        std.debug.print("Sending shutdown command to daemon...\n", .{});
        client.shutdown() catch |err| {
            std.debug.print("Error: Shutdown failed: {any}\n", .{err});
            std.process.exit(1);
        };
        std.debug.print("Shutdown command sent\n", .{});
        return;
    }

    std.debug.print("Error: Unknown command '{s}'\n", .{command});
    try printUsage();
    std.process.exit(1);
}

fn printUsage() !void {
    const usage =
        \\
        \\chronos-ctl - Sovereign Clock Control Interface (Client Mode)
        \\
        \\USAGE:
        \\    chronos-ctl <command> [args...]
        \\
        \\COMMANDS:
        \\    version                               Show version
        \\    help                                  Show this help
        \\    ping                                  Check if daemon is running
        \\    tick                                  Get current tick (non-destructive)
        \\    next                                  Increment and return next tick
        \\    stamp <agent-id>                      Generate Phi timestamp
        \\    log <agent-id> <action> <status> [details]
        \\                                          Log action with Phi timestamp (JSON)
        \\    shutdown                              Shutdown daemon (requires permission)
        \\
        \\EXAMPLES:
        \\    # Check daemon status
        \\    chronos-ctl ping
        \\
        \\    # Get current tick
        \\    chronos-ctl tick
        \\
        \\    # Get next tick (increments)
        \\    chronos-ctl next
        \\
        \\    # Generate Phi timestamp for CLAUDE-A
        \\    chronos-ctl stamp CLAUDE-A
        \\
        \\    # Log action with Phi timestamp
        \\    chronos-ctl log CLAUDE-A test_defense SUCCESS "All tests passed"
        \\
        \\CONNECTION:
        \\    Connects to chronosd via Unix socket:
        \\      /var/run/chronos.sock (default)
        \\      /tmp/chronos.sock (fallback)
        \\
        \\DAEMON:
        \\    This tool requires chronosd to be running.
        \\    Start daemon: ./chronosd &
        \\    Or use systemd: systemctl start chronosd
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}
