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


// chronos-ctl-dbus.zig - Chronos Control CLI (D-Bus Version)
// Purpose: Command-line interface to Chronos daemon via D-Bus
//
// Replaces Unix socket version with D-Bus integration

const std = @import("std");
const client = @import("chronos_client_dbus.zig");
const dbus = @import("dbus_bindings.zig");

const VERSION = "2.0.0-dbus";

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    // Determine bus type from environment or default to SYSTEM
    const bus_type = if (std.posix.getenv("CHRONOS_USE_SESSION_BUS")) |_|
        dbus.BusType.SESSION
    else
        dbus.BusType.SYSTEM;

    var chronos = client.ChronosClient.connect(allocator, bus_type) catch |err| {
        std.debug.print("❌ Failed to connect to Chronos daemon: {any}\n", .{err});
        std.debug.print("   Is chronosd running?\n", .{});
        return err;
    };
    defer chronos.disconnect();

    if (std.mem.eql(u8, command, "ping")) {
        const alive = try chronos.ping();
        if (alive) {
            std.debug.print("✅ Chronos daemon is responding\n", .{});
        } else {
            std.debug.print("❌ Chronos daemon not responding\n", .{});
            return error.DaemonNotResponding;
        }
    } else if (std.mem.eql(u8, command, "tick")) {
        const tick = try chronos.getTick();
        std.debug.print("Current tick: {d}\n", .{tick});
    } else if (std.mem.eql(u8, command, "next")) {
        const tick = try chronos.nextTick();
        std.debug.print("Next tick: {d}\n", .{tick});
    } else if (std.mem.eql(u8, command, "stamp")) {
        if (args.len < 3) {
            std.debug.print("Usage: chronos-ctl stamp <agent-id>\n", .{});
            return error.MissingAgentId;
        }
        const agent_id = args[2];
        const timestamp = try chronos.getPhiTimestamp(agent_id);
        defer allocator.free(timestamp);
        std.debug.print("{s}\n", .{timestamp});
    } else if (std.mem.eql(u8, command, "shutdown")) {
        std.debug.print("Sending shutdown command...\n", .{});
        try chronos.shutdown();
        std.debug.print("✅ Shutdown command sent\n", .{});
    } else if (std.mem.eql(u8, command, "version")) {
        std.debug.print("chronos-ctl v{s} (D-Bus)\n", .{VERSION});
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    std.debug.print(
        \\chronos-ctl - Chronos Sovereign Clock Control (D-Bus Version)
        \\
        \\Usage:
        \\  chronos-ctl ping                 - Check if daemon is running
        \\  chronos-ctl tick                 - Get current tick
        \\  chronos-ctl next                 - Increment and get next tick
        \\  chronos-ctl stamp <agent-id>     - Generate Phi timestamp
        \\  chronos-ctl shutdown             - Shutdown daemon
        \\  chronos-ctl version              - Show version
        \\  chronos-ctl help                 - Show this help
        \\
        \\Environment:
        \\  CHRONOS_USE_SESSION_BUS=1        - Use SESSION bus (default: SYSTEM)
        \\
    , .{});
}
