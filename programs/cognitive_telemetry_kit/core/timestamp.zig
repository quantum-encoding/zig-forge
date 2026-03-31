//! PHI timestamp — three-dimensional composite identifier.
//!
//! Format: YYYY-MM-DDThh:mm:ss.nnnnnnnnnZ::AGENT-ID::TICK-NNNNNNNNNN
//!
//! Combines:
//!   - UTC nanosecond wall clock (external correlation)
//!   - Agent identifier (which Claude instance)
//!   - Monotonic tick counter (absolute sequence, survives reboots)
//!
//! Extracted from chronos_engine/phi_timestamp.zig.

const std = @import("std");

pub const PhiTimestamp = struct {
    utc_ns: i128, // nanoseconds since Unix epoch
    agent_id: []const u8,
    tick: u64,

    /// Format into the canonical CHRONOS string representation.
    /// Returns a slice of the provided buffer.
    pub fn format(self: PhiTimestamp, buf: []u8) []const u8 {
        // Decompose nanoseconds into components
        const total_secs: u64 = @intCast(@divFloor(self.utc_ns, 1_000_000_000));
        const ns_part: u64 = @intCast(@mod(self.utc_ns, 1_000_000_000));

        // Approximate date from epoch seconds (good enough for display)
        const secs_per_day: u64 = 86400;
        var days = total_secs / secs_per_day;
        const day_secs = total_secs % secs_per_day;
        const hour = day_secs / 3600;
        const minute = (day_secs % 3600) / 60;
        const second = day_secs % 60;

        // Calculate year/month/day from days since epoch
        var year: u32 = 1970;
        while (true) {
            const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
            if (days < days_in_year) break;
            days -= days_in_year;
            year += 1;
        }
        const month_days = if (isLeapYear(year))
            [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u32 = 0;
        while (month < 12) : (month += 1) {
            if (days < month_days[month]) break;
            days -= month_days[month];
        }
        const day: u32 = @intCast(days + 1);

        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z::{s}::TICK-{d:0>10}", .{
            year,
            month + 1,
            day,
            hour,
            minute,
            second,
            ns_part,
            self.agent_id,
            self.tick,
        }) catch "";
    }

    /// Parse a CHRONOS timestamp string back into a PhiTimestamp.
    /// Returns null if the format doesn't match.
    pub fn parse(s: []const u8) ?PhiTimestamp {
        // Minimum: "YYYY-MM-DDThh:mm:ss.nnnnnnnnnZ::X::TICK-N" = 42+ chars
        if (s.len < 42) return null;

        // Find "::" delimiters
        const first_sep = std.mem.indexOf(u8, s, "::") orelse return null;
        const rest = s[first_sep + 2 ..];
        const second_sep = std.mem.indexOf(u8, rest, "::") orelse return null;

        const agent_id = rest[0..second_sep];
        const tick_part = rest[second_sep + 2 ..];

        // Parse tick
        if (!std.mem.startsWith(u8, tick_part, "TICK-")) return null;
        const tick = std.fmt.parseInt(u64, tick_part[5..], 10) catch return null;

        return PhiTimestamp{
            .utc_ns = 0, // TODO: parse full ISO timestamp if needed
            .agent_id = agent_id,
            .tick = tick,
        };
    }
};

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

test "timestamp: format and parse roundtrip" {
    const ts = PhiTimestamp{
        .utc_ns = 1_711_900_000_000_000_000, // ~2024-03-31
        .agent_id = "claude-a",
        .tick = 42,
    };
    var buf: [256]u8 = undefined;
    const formatted = ts.format(&buf);
    try std.testing.expect(formatted.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "::claude-a::") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "TICK-0000000042") != null);

    const parsed = PhiTimestamp.parse(formatted).?;
    try std.testing.expectEqualStrings("claude-a", parsed.agent_id);
    try std.testing.expectEqual(@as(u64, 42), parsed.tick);
}
