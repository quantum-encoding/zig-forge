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


// phi_timestamp.zig - The Phi Temporal Stream: Multi-Dimensional Timeline
// Purpose: Generate unique, composite timestamps for parallel agentic warfare
//
// Phi Timestamp Format:
//   UTC::AGENT-ID::TICK-NNNNNNNNNN
//   Example: 2025-10-19T22:00:01.123456789Z::CLAUDE-A::TICK-0000000123
//
// Components:
//   1. Universal Time (UTC) - High-precision timestamp for external correlation
//   2. Agent Facet ID - Unique identifier for the agent instance
//   3. Chronos Tick - Absolute sequential tick from Sovereign Clock

const std = @import("std");
const c = std.c;
const chronos = @import("chronos.zig");

/// Get current time as nanoseconds since epoch (replacement for std.time.nanoTimestamp)
fn nanoTimestamp() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Agent Facet Identifier
pub const AgentID = []const u8;

/// Phi Timestamp - Composite multi-dimensional identifier
pub const PhiTimestamp = struct {
    utc: i128,          // Unix timestamp (nanoseconds)
    agent_id: AgentID,  // Agent facet identifier
    tick: u64,          // Chronos tick

    /// Format Phi timestamp as string
    pub fn format(
        self: PhiTimestamp,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // Convert Unix nanoseconds to human-readable UTC
        const seconds = @divFloor(self.utc, std.time.ns_per_s);
        const nanoseconds = @mod(self.utc, std.time.ns_per_s);

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z::{s}::TICK-{d:0>10}",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                nanoseconds,
                self.agent_id,
                self.tick,
            },
        );
    }

    /// Parse Phi timestamp from string (for log replay/analysis)
    pub fn parse(allocator: std.mem.Allocator, timestamp_str: []const u8) !PhiTimestamp {
        // Split by "::" delimiter
        var parts = std.mem.split(u8, timestamp_str, "::");

        const utc_str = parts.next() orelse return error.InvalidFormat;
        const agent_id_str = parts.next() orelse return error.InvalidFormat;
        const tick_str = parts.next() orelse return error.InvalidFormat;

        // Parse UTC (ISO 8601 format: 2025-10-19T22:00:01.123456789Z)
        const utc: i128 = parseISO8601(utc_str) catch return error.InvalidTimestamp;

        // Extract agent ID
        const agent_id = try allocator.dupe(u8, agent_id_str);

        // Parse tick (format: "TICK-NNNNNNNNNN")
        if (!std.mem.startsWith(u8, tick_str, "TICK-")) {
            return error.InvalidTickFormat;
        }
        const tick_num_str = tick_str[5..];
        const tick = try std.fmt.parseInt(u64, tick_num_str, 10);

        return PhiTimestamp{
            .utc = utc,
            .agent_id = agent_id,
            .tick = tick,
        };
    }
};

/// Phi Timestamp Generator
pub const PhiGenerator = struct {
    clock: *chronos.ChronosClock,
    agent_id: AgentID,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        clock: *chronos.ChronosClock,
        agent_id: AgentID,
    ) PhiGenerator {
        return PhiGenerator{
            .clock = clock,
            .agent_id = agent_id,
            .allocator = allocator,
        };
    }

    /// Generate next Phi timestamp
    pub fn next(self: *PhiGenerator) !PhiTimestamp {
        const utc = nanoTimestamp();
        const tick = try self.clock.nextTick();

        return PhiTimestamp{
            .utc = utc,
            .agent_id = self.agent_id,
            .tick = tick,
        };
    }

    /// Generate Phi timestamp with current tick (no increment)
    pub fn current(self: *const PhiGenerator) PhiTimestamp {
        const utc = nanoTimestamp();
        const tick = self.clock.getTick();

        return PhiTimestamp{
            .utc = utc,
            .agent_id = self.agent_id,
            .tick = tick,
        };
    }
};

/// Structured log entry with Phi timestamp
pub const PhiLogEntry = struct {
    timestamp: PhiTimestamp,
    action: []const u8,
    status: []const u8,
    details: ?[]const u8 = null,

    /// Format as JSON
    pub fn toJson(self: PhiLogEntry, allocator: std.mem.Allocator) ![]u8 {
        const timestamp_str = try self.timestamp.format(allocator);
        defer allocator.free(timestamp_str);

        if (self.details) |details| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"timestamp\":\"{s}\",\"action\":\"{s}\",\"status\":\"{s}\",\"details\":\"{s}\"}}",
                .{ timestamp_str, self.action, self.status, details },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "{{\"timestamp\":\"{s}\",\"action\":\"{s}\",\"status\":\"{s}\"}}",
                .{ timestamp_str, self.action, self.status },
            );
        }
    }
};

/// Parse ISO 8601 timestamp string to nanoseconds since Unix epoch.
/// Supports: YYYY-MM-DDThh:mm:ss[.nnnnnnnnn]Z
fn parseISO8601(s: []const u8) !i128 {
    if (s.len < 20) return error.InvalidFormat; // Minimum: 2025-10-19T22:00:01Z

    // Parse date components
    const year = try std.fmt.parseInt(i32, s[0..4], 10);
    if (s[4] != '-') return error.InvalidFormat;
    const month = try std.fmt.parseInt(u8, s[5..7], 10);
    if (s[7] != '-') return error.InvalidFormat;
    const day = try std.fmt.parseInt(u8, s[8..10], 10);
    if (s[10] != 'T') return error.InvalidFormat;

    // Parse time components
    const hour = try std.fmt.parseInt(u8, s[11..13], 10);
    if (s[13] != ':') return error.InvalidFormat;
    const minute = try std.fmt.parseInt(u8, s[14..16], 10);
    if (s[16] != ':') return error.InvalidFormat;
    const second = try std.fmt.parseInt(u8, s[17..19], 10);

    // Parse optional fractional seconds
    var nanos: i128 = 0;
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        // Find end of fraction (Z or +/-)
        var frac_end: usize = 0;
        while (frac_end < rest.len and rest[frac_end] >= '0' and rest[frac_end] <= '9') {
            frac_end += 1;
        }
        if (frac_end > 0) {
            const frac_str = rest[0..frac_end];
            var frac_val = try std.fmt.parseInt(i128, frac_str, 10);
            // Scale to nanoseconds (9 digits)
            var digits = frac_end;
            while (digits < 9) : (digits += 1) {
                frac_val *= 10;
            }
            while (digits > 9) : (digits -= 1) {
                frac_val = @divFloor(frac_val, 10);
            }
            nanos = frac_val;
        }
    }

    // Validate ranges
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (day < 1 or day > 31) return error.InvalidFormat;
    if (hour > 23 or minute > 59 or second > 60) return error.InvalidFormat;

    // Convert to Unix timestamp
    // Days from year 1970 to target year
    var total_days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }
    // Handle years before 1970
    while (y > year) {
        y -= 1;
        total_days -= if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }

    // Days from months
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        total_days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) total_days += 1;
    }
    total_days += day - 1;

    // Convert to nanoseconds
    const secs: i128 = @as(i128, total_days) * 86400 + @as(i128, hour) * 3600 + @as(i128, minute) * 60 + @as(i128, second);
    return secs * 1_000_000_000 + nanos;
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

// ============================================================
// Tests
// ============================================================

test "PhiTimestamp format" {
    const allocator = std.testing.allocator;

    const phi = PhiTimestamp{
        .utc = 1729372801123456789, // Example timestamp
        .agent_id = "CLAUDE-A",
        .tick = 123,
    };

    const formatted = try phi.format(allocator);
    defer allocator.free(formatted);

    // Should contain all three components
    try std.testing.expect(std.mem.indexOf(u8, formatted, "::CLAUDE-A::") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "::TICK-0000000123") != null);
}

test "PhiGenerator creates unique timestamps" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/phi-gen-test.dat";
    defer {
        const path_z: [*:0]const u8 = @ptrCast(test_path.ptr);
        _ = std.c.unlink(path_z);
    }

    var clock = try chronos.ChronosClock.init(allocator, test_path);
    defer clock.deinit();

    var gen = PhiGenerator.init(allocator, &clock, "TESTBOT-1");

    const phi1 = try gen.next();
    const phi2 = try gen.next();
    const phi3 = try gen.next();

    // Ticks should be sequential
    try std.testing.expectEqual(@as(u64, 1), phi1.tick);
    try std.testing.expectEqual(@as(u64, 2), phi2.tick);
    try std.testing.expectEqual(@as(u64, 3), phi3.tick);

    // Agent IDs should match
    try std.testing.expectEqualStrings("TESTBOT-1", phi1.agent_id);
}

test "PhiLogEntry JSON serialization" {
    const allocator = std.testing.allocator;

    const phi = PhiTimestamp{
        .utc = 1729372801000000000,
        .agent_id = "CLAUDE-A",
        .tick = 42,
    };

    const log_entry = PhiLogEntry{
        .timestamp = phi,
        .action = "test_defense",
        .status = "SUCCESS",
        .details = "All tests passed",
    };

    const json = try log_entry.toJson(allocator);
    defer allocator.free(json);

    // Should be valid JSON with all fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamp\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"action\":\"test_defense\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"SUCCESS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"details\":\"All tests passed\"") != null);
}
