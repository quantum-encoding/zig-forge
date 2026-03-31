const std = @import("std");

/// Format bytes into human-readable format
/// Options: SI (1000) or Binary (1024)
pub const ByteFormat = enum {
    SI,
    Binary,
};

/// Format bytes with default SI units (KB, MB, GB, etc.)
pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    return formatBytesOptions(allocator, bytes, .SI);
}

/// Format bytes with specified unit type
pub fn formatBytesOptions(allocator: std.mem.Allocator, bytes: u64, format: ByteFormat) ![]const u8 {
    const divisor: f64 = if (format == .SI) 1000.0 else 1024.0;
    const units: []const []const u8 = if (format == .SI)
        &.{ "B", "KB", "MB", "GB", "TB", "PB" }
    else
        &.{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

    if (bytes == 0) {
        return try std.fmt.allocPrint(allocator, "0 B", .{});
    }

    var bytes_f: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (bytes_f >= divisor and unit_idx < units.len - 1) {
        bytes_f /= divisor;
        unit_idx += 1;
    }

    // Format with appropriate precision
    if (bytes_f >= 100.0) {
        return try std.fmt.allocPrint(allocator, "{d:.0} {s}", .{ bytes_f, units[unit_idx] });
    } else if (bytes_f >= 10.0) {
        return try std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ bytes_f, units[unit_idx] });
    } else {
        return try std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ bytes_f, units[unit_idx] });
    }
}

/// Format duration in milliseconds to human-readable format
pub fn formatDuration(allocator: std.mem.Allocator, milliseconds: u64) ![]const u8 {
    const seconds = milliseconds / 1000;
    const millis = milliseconds % 1000;

    if (milliseconds < 1000) {
        return try std.fmt.allocPrint(allocator, "{d}ms", .{milliseconds});
    }

    const minutes = seconds / 60;
    const secs = seconds % 60;

    if (minutes == 0) {
        if (millis == 0) {
            return try std.fmt.allocPrint(allocator, "{d}s", .{seconds});
        } else {
            return try std.fmt.allocPrint(allocator, "{d}.{d:0>3}s", .{ seconds, millis });
        }
    }

    const hours = minutes / 60;
    const mins = minutes % 60;

    if (hours == 0) {
        if (millis == 0) {
            return try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, secs });
        } else {
            return try std.fmt.allocPrint(allocator, "{d}m {d}.{d:0>3}s", .{ minutes, secs, millis });
        }
    }

    const days = hours / 24;
    const hrs = hours % 24;

    if (days == 0) {
        if (secs == 0 and millis == 0) {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m", .{ hours, mins });
        } else if (millis == 0) {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, mins, secs });
        } else {
            return try std.fmt.allocPrint(allocator, "{d}h {d}m {d}.{d:0>3}s", .{ hours, mins, secs, millis });
        }
    }

    if (mins == 0 and secs == 0 and millis == 0) {
        return try std.fmt.allocPrint(allocator, "{d}d {d}h", .{ days, hrs });
    } else if (secs == 0 and millis == 0) {
        return try std.fmt.allocPrint(allocator, "{d}d {d}h {d}m", .{ days, hrs, mins });
    } else {
        return try std.fmt.allocPrint(allocator, "{d}d {d}h {d}m {d}s", .{ days, hrs, mins, secs });
    }
}

/// Format number with thousands separators
pub fn formatNumber(allocator: std.mem.Allocator, number: u64) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{number});
    defer allocator.free(num_str);

    // Count from the right
    var count_from_right: usize = 0;

    for (0..num_str.len) |i| {
        const idx = num_str.len - 1 - i;
        if (count_from_right > 0 and count_from_right % 3 == 0) {
            try buffer.insert(allocator, 0, ',');
        }
        try buffer.insert(allocator, 0, num_str[idx]);
        count_from_right += 1;
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Get ordinal suffix for a number (1st, 2nd, 3rd, etc.)
pub fn ordinalSuffix(number: u64) []const u8 {
    const last_digit = number % 10;
    const last_two_digits = number % 100;

    if (last_two_digits >= 10 and last_two_digits <= 20) {
        return "th";
    }

    return switch (last_digit) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

/// Format number as ordinal (1st, 2nd, 3rd, etc.)
pub fn formatOrdinal(allocator: std.mem.Allocator, number: u64) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{d}{s}", .{ number, ordinalSuffix(number) });
}

/// Format percentage
pub fn formatPercentage(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    if (value == @floor(value)) {
        return try std.fmt.allocPrint(allocator, "{d:.0}%", .{value});
    } else if (value * 10 == @floor(value * 10)) {
        return try std.fmt.allocPrint(allocator, "{d:.1}%", .{value});
    } else {
        return try std.fmt.allocPrint(allocator, "{d:.2}%", .{value});
    }
}

/// Relative time formatter
pub const RelativeTimeOptions = struct {
    future: bool = false,
};

/// Format time relative to now
pub fn formatRelativeTime(allocator: std.mem.Allocator, seconds: u64, options: RelativeTimeOptions) ![]const u8 {
    const prefix = if (options.future) "in " else "";
    const suffix = if (options.future) "" else " ago";

    if (seconds < 60) {
        return try std.fmt.allocPrint(allocator, "{s}{d} second{s}{s}", .{
            prefix,
            seconds,
            if (seconds == 1) "" else "s",
            suffix,
        });
    }

    const minutes = seconds / 60;
    if (minutes < 60) {
        return try std.fmt.allocPrint(allocator, "{s}{d} minute{s}{s}", .{
            prefix,
            minutes,
            if (minutes == 1) "" else "s",
            suffix,
        });
    }

    const hours = minutes / 60;
    if (hours < 24) {
        return try std.fmt.allocPrint(allocator, "{s}{d} hour{s}{s}", .{
            prefix,
            hours,
            if (hours == 1) "" else "s",
            suffix,
        });
    }

    const days = hours / 24;
    if (days < 30) {
        return try std.fmt.allocPrint(allocator, "{s}{d} day{s}{s}", .{
            prefix,
            days,
            if (days == 1) "" else "s",
            suffix,
        });
    }

    const months = days / 30;
    if (months < 12) {
        return try std.fmt.allocPrint(allocator, "{s}{d} month{s}{s}", .{
            prefix,
            months,
            if (months == 1) "" else "s",
            suffix,
        });
    }

    const years = days / 365;
    return try std.fmt.allocPrint(allocator, "{s}{d} year{s}{s}", .{
        prefix,
        years,
        if (years == 1) "" else "s",
        suffix,
    });
}

/// Format a list of items
pub fn formatList(allocator: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) {
        return try allocator.dupe(u8, "");
    }
    if (items.len == 1) {
        return try allocator.dupe(u8, items[0]);
    }
    if (items.len == 2) {
        return try std.fmt.allocPrint(allocator, "{s} and {s}", .{ items[0], items[1] });
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    for (items[0 .. items.len - 1], 0..) |item, idx| {
        try result.appendSlice(allocator, item);
        if (idx < items.len - 2) {
            try result.appendSlice(allocator, ", ");
        } else {
            try result.appendSlice(allocator, ", and ");
        }
    }
    try result.appendSlice(allocator, items[items.len - 1]);

    return try result.toOwnedSlice(allocator);
}

// Tests
const testing = std.testing;

test "formatBytes SI units" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatBytesOptions(allocator, 1500, .SI);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.50 KB", result);
    }

    {
        const result = try formatBytesOptions(allocator, 1500000, .SI);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.50 MB", result);
    }

    {
        const result = try formatBytesOptions(allocator, 1500000000, .SI);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.50 GB", result);
    }
}

test "formatBytes binary units" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatBytesOptions(allocator, 1536, .Binary);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.50 KiB", result);
    }

    {
        const result = try formatBytesOptions(allocator, 1048576, .Binary);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.00 MiB", result);
    }
}

test "formatDuration" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatDuration(allocator, 500);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "500ms", result);
    }

    {
        const result = try formatDuration(allocator, 5000);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "5s", result);
    }

    {
        const result = try formatDuration(allocator, 125000);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "2m 5s", result);
    }

    {
        const result = try formatDuration(allocator, 7530000);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "2h 5m 30s", result);
    }
}

test "formatNumber" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatNumber(allocator, 1000);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1,000", result);
    }

    {
        const result = try formatNumber(allocator, 1234567);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1,234,567", result);
    }

    {
        const result = try formatNumber(allocator, 42);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "42", result);
    }
}

test "ordinalSuffix" {
    try testing.expectEqualSlices(u8, "st", ordinalSuffix(1));
    try testing.expectEqualSlices(u8, "nd", ordinalSuffix(2));
    try testing.expectEqualSlices(u8, "rd", ordinalSuffix(3));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(4));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(11));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(12));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(13));
    try testing.expectEqualSlices(u8, "st", ordinalSuffix(21));
    try testing.expectEqualSlices(u8, "nd", ordinalSuffix(22));
}

test "formatOrdinal" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatOrdinal(allocator, 1);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1st", result);
    }

    {
        const result = try formatOrdinal(allocator, 22);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "22nd", result);
    }

    {
        const result = try formatOrdinal(allocator, 103);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "103rd", result);
    }
}

test "formatPercentage" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatPercentage(allocator, 50.0);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "50%", result);
    }

    {
        const result = try formatPercentage(allocator, 33.33);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "33.33%", result);
    }
}

test "formatRelativeTime past" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatRelativeTime(allocator, 30, .{});
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "30 seconds ago", result);
    }

    {
        const result = try formatRelativeTime(allocator, 300, .{});
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "5 minutes ago", result);
    }

    {
        const result = try formatRelativeTime(allocator, 7200, .{});
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "2 hours ago", result);
    }
}

test "formatRelativeTime future" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatRelativeTime(allocator, 300, .{ .future = true });
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "in 5 minutes", result);
    }

    {
        const result = try formatRelativeTime(allocator, 7200, .{ .future = true });
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "in 2 hours", result);
    }
}

test "formatList" {
    const allocator = std.heap.c_allocator;

    {
        const items = [_][]const u8{"apple"};
        const result = try formatList(allocator, &items);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "apple", result);
    }

    {
        const items = [_][]const u8{ "apple", "banana" };
        const result = try formatList(allocator, &items);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "apple and banana", result);
    }

    {
        const items = [_][]const u8{ "apple", "banana", "cherry" };
        const result = try formatList(allocator, &items);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "apple, banana, and cherry", result);
    }
}

// ============================================================================
// ENHANCED TEST SUITE - zig_humanize Edge Cases
// ============================================================================

test "Zero bytes edge case" {
    const allocator = std.heap.c_allocator;

    const result = try formatBytes(allocator, 0);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "0 B", result);
}

test "Negative duration handling - edge case" {
    const allocator = std.heap.c_allocator;

    const result = try formatDuration(allocator, 0);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "0ms", result);
}

test "Large numbers with comma formatting" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatNumber(allocator, 1000000000);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1,000,000,000", result);
    }

    {
        const result = try formatNumber(allocator, 999999999);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "999,999,999", result);
    }
}

test "Ordinal special cases - 11th, 12th, 13th" {
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(11));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(12));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(13));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(111));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(112));
    try testing.expectEqualSlices(u8, "th", ordinalSuffix(113));
}

test "Ordinal special cases - 21st, 22nd, 23rd" {
    try testing.expectEqualSlices(u8, "st", ordinalSuffix(21));
    try testing.expectEqualSlices(u8, "nd", ordinalSuffix(22));
    try testing.expectEqualSlices(u8, "rd", ordinalSuffix(23));
    try testing.expectEqualSlices(u8, "st", ordinalSuffix(121));
    try testing.expectEqualSlices(u8, "nd", ordinalSuffix(122));
    try testing.expectEqualSlices(u8, "rd", ordinalSuffix(123));
}

test "Percentage edge cases - 0%" {
    const allocator = std.heap.c_allocator;

    const result = try formatPercentage(allocator, 0.0);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "0%", result);
}

test "Percentage edge cases - 100%" {
    const allocator = std.heap.c_allocator;

    const result = try formatPercentage(allocator, 100.0);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "100%", result);
}

test "Percentage edge cases - >100%" {
    const allocator = std.heap.c_allocator;

    const result = try formatPercentage(allocator, 150.5);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "150.5%", result);
}

test "Empty list formatting" {
    const allocator = std.heap.c_allocator;

    const items = [_][]const u8{};
    const result = try formatList(allocator, &items);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "", result);
}

test "Single-item list formatting" {
    const allocator = std.heap.c_allocator;

    const items = [_][]const u8{"apple"};
    const result = try formatList(allocator, &items);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "apple", result);
}

test "Duration sub-second - milliseconds" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatDuration(allocator, 1);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1ms", result);
    }

    {
        const result = try formatDuration(allocator, 999);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "999ms", result);
    }
}

test "Duration with seconds sub-milliseconds" {
    const allocator = std.heap.c_allocator;

    const result = try formatDuration(allocator, 1500);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "1.500s", result);
}

test "Ordinal formatting edge cases" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatOrdinal(allocator, 11);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "11th", result);
    }

    {
        const result = try formatOrdinal(allocator, 12);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "12th", result);
    }

    {
        const result = try formatOrdinal(allocator, 13);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "13th", result);
    }

    {
        const result = try formatOrdinal(allocator, 23);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "23rd", result);
    }
}

test "Bytes formatting SI - single byte" {
    const allocator = std.heap.c_allocator;

    const result = try formatBytesOptions(allocator, 1, .SI);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "1.00 B", result);
}

test "Bytes formatting SI - edge transitions" {
    const allocator = std.heap.c_allocator;

    {
        const result = try formatBytesOptions(allocator, 999, .SI);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "999 B", result);
    }

    {
        const result = try formatBytesOptions(allocator, 1000, .SI);
        defer allocator.free(result);
        try testing.expectEqualSlices(u8, "1.00 KB", result);
    }
}

test "Bytes formatting Binary - single byte" {
    const allocator = std.heap.c_allocator;

    const result = try formatBytesOptions(allocator, 1, .Binary);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "1.00 B", result);
}

test "Bytes formatting Binary - 1 MiB" {
    const allocator = std.heap.c_allocator;

    const result = try formatBytesOptions(allocator, 1048576, .Binary);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "1.00 MiB", result);
}
