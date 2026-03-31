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


// chronos-ctl.zig - Chronos Clock Control Interface
// Purpose: CLI tool for interacting with the Sovereign Clock
//
// Commands:
//   chronos-ctl init           - Initialize Chronos Clock
//   chronos-ctl tick           - Get current tick (non-destructive)
//   chronos-ctl next           - Increment and return next tick
//   chronos-ctl stamp <agent>  - Generate full Phi timestamp
//   chronos-ctl log <agent> <action> <status> [details]  - Log with Phi timestamp
//   chronos-ctl reset          - Reset tick to 0 (DANGEROUS - requires confirmation)

const std = @import("std");
const chronos = @import("chronos.zig");
const phi = @import("phi_timestamp.zig");

const VERSION = "1.0.0";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "version")) {
        std.debug.print("chronos-ctl version {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "help")) {
        try printUsage();
        return;
    }

    // Initialize Chronos Clock for all other commands
    var clock = try chronos.ChronosClock.init(allocator, null);
    defer clock.deinit();

    if (std.mem.eql(u8, command, "init")) {
        std.debug.print("✓ Chronos Clock initialized\n", .{});
        return;
    }

    if (std.mem.eql(u8, command, "tick")) {
        const tick = clock.getTick();
        std.debug.print("{d}\n", .{tick});
        return;
    }

    if (std.mem.eql(u8, command, "next")) {
        const tick = try clock.nextTick();
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
        var gen = phi.PhiGenerator.init(allocator, &clock, agent_id);
        const timestamp = try gen.next();
        const formatted = try timestamp.format(allocator);
        defer allocator.free(formatted);

        std.debug.print("{s}\n", .{formatted});
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
        const details = if (args.len > 5) args[5] else null;

        var gen = phi.PhiGenerator.init(allocator, &clock, agent_id);
        const timestamp = try gen.next();

        const log_entry = phi.PhiLogEntry{
            .timestamp = timestamp,
            .action = action,
            .status = status,
            .details = details,
        };

        const json = try log_entry.toJson(allocator);
        defer allocator.free(json);

        std.debug.print("{s}\n", .{json});
        return;
    }

    if (std.mem.eql(u8, command, "reset")) {
        // Reset requires --force flag for safety
        var force = false;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--force")) {
                force = true;
                break;
            }
        }

        if (!force) {
            std.debug.print("⚠️  ERROR: Reset requires --force flag\n", .{});
            std.debug.print("Usage: chronos-ctl reset --force\n", .{});
            std.debug.print("WARNING: This will break timeline continuity!\n", .{});
            std.process.exit(1);
        }

        clock.tick.store(0, .monotonic);
        try clock.persistTick(0);
        std.debug.print("✓ Chronos Clock reset to 0\n", .{});
        return;
    }

    std.debug.print("Error: Unknown command '{s}'\n", .{command});
    try printUsage();
    std.process.exit(1);
}

fn printUsage() !void {
    const usage =
        \\
        \\chronos-ctl - Sovereign Clock Control Interface
        \\
        \\USAGE:
        \\    chronos-ctl <command> [args...]
        \\
        \\COMMANDS:
        \\    version                               Show version
        \\    help                                  Show this help
        \\    init                                  Initialize Chronos Clock
        \\    tick                                  Get current tick (non-destructive)
        \\    next                                  Increment and return next tick
        \\    stamp <agent-id>                      Generate Phi timestamp
        \\    log <agent-id> <action> <status> [details]
        \\                                          Log action with Phi timestamp (JSON)
        \\    reset                                 Reset tick to 0 (DANGEROUS)
        \\
        \\EXAMPLES:
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
        \\PERSISTENT STATE:
        \\    /var/lib/chronos/tick.dat (system)
        \\    /tmp/chronos-tick.dat (fallback)
        \\
        \\DOCTRINE:
        \\    The Chronos Clock is the Sovereign Timeline of the JesterNet.
        \\    It provides absolute, verifiable sequencing for parallel agentic warfare.
        \\    The tick is monotonically increasing and survives reboots.
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}
