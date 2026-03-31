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


// chronos_logger_simple.zig - Simplified Chronos Integration for Testing
// Purpose: Mock Chronos logger for testing without D-Bus dependencies

const std = @import("std");

/// Simple Chronos logger for agents (mock version for testing)
pub const ChronosLogger = struct {
    agent_id: []const u8,
    allocator: std.mem.Allocator,

    /// Connect and identify agent
    pub fn init(allocator: std.mem.Allocator, agent_id: []const u8) !ChronosLogger {
        return ChronosLogger{
            .agent_id = agent_id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChronosLogger) void {
        // No cleanup needed for mock
    }

    /// Generate a Phi timestamp (UTC::AGENT::TICK)
    pub fn stamp(self: *ChronosLogger) ![]u8 {
        const timestamp = try std.fmt.allocPrint(self.allocator, "MOCK_TIMESTAMP::{s}::{d}", .{
            self.agent_id,
            std.time.milliTimestamp(),
        });
        return timestamp;
    }

    /// Log an event with automatic Phi timestamp
    /// Returns: Phi timestamp
    pub fn log(self: *ChronosLogger, action: []const u8, status: []const u8, details: []const u8) ![]u8 {
        const timestamp = try self.stamp();
        errdefer self.allocator.free(timestamp);

        // Print to stderr for immediate visibility
        std.debug.print("[{s}] {s}: {s} - {s}\n", .{ timestamp, self.agent_id, action, status });

        return timestamp;
    }

    /// Simple success log
    pub fn success(self: *ChronosLogger, action: []const u8) ![]u8 {
        return try self.log(action, "SUCCESS", "");
    }

    /// Simple failure log
    pub fn failure(self: *ChronosLogger, action: []const u8, error_msg: []const u8) ![]u8 {
        return try self.log(action, "FAILURE", error_msg);
    }

    /// Start activity (returns start timestamp)
    pub fn start(self: *ChronosLogger, activity: []const u8) ![]u8 {
        return try self.log(activity, "START", "");
    }

    /// Complete activity (returns completion timestamp)
    pub fn complete(self: *ChronosLogger, activity: []const u8) ![]u8 {
        return try self.log(activity, "COMPLETE", "");
    }
};
