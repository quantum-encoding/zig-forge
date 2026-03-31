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


// chronos-stamp.zig - Simple timestamping tool for agent actions
// Usage: chronos-stamp AGENT-ID [ACTION]

const std = @import("std");
const client = @import("chronos_client_dbus.zig");
const dbus = @import("dbus_bindings.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: chronos-stamp AGENT-ID [ACTION]\n", .{});
        return;
    }

    const agent_id = args[1];
    const action = if (args.len > 2) args[2] else "";

    var chronos = client.ChronosClient.connect(allocator, dbus.BusType.SYSTEM) catch {
        // Silently fail if daemon not available
        return;
    };
    defer chronos.disconnect();

    const timestamp = chronos.getPhiTimestamp(agent_id) catch {
        return;
    };
    defer allocator.free(timestamp);

    // Capture session context (Claude Code project directory or equivalent)
    const session = std.posix.getenv("CLAUDE_PROJECT_DIR") orelse
                    std.posix.getenv("PROJECT_ROOT") orelse
                    "UNKNOWN-SESSION";

    // Capture present working directory (spatial dimension)
    var pwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pwd = std.fs.cwd().realpath(".", &pwd_buf) catch "UNKNOWN-PWD";

    // Output format: [CHRONOS] timestamp::[SESSION]::[PWD] → action
    // Four-dimensional chronicle: UTC::AGENT::TICK::[SESSION]::[PWD]
    if (action.len > 0) {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}] → {s}\n", .{ timestamp, session, pwd, action });
    } else {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}]\n", .{ timestamp, session, pwd });
    }
}
