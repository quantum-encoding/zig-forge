const std = @import("std");
const humanize = @import("humanize.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Use debug print for output instead
    const stdout = std.debug;

    stdout.print("=== Zig Humanize - Human-readable Formatting Utilities ===\n\n", .{});

    // Bytes formatting examples
    stdout.print("Bytes Formatting:\n", .{});
    const bytes256 = try humanize.formatBytes(allocator, 256);
    defer allocator.free(bytes256);
    stdout.print("  256 bytes: {s}\n", .{bytes256});

    const bytes1500 = try humanize.formatBytes(allocator, 1500);
    defer allocator.free(bytes1500);
    stdout.print("  1.5 KB: {s}\n", .{bytes1500});

    const bytes256k = try humanize.formatBytes(allocator, 256000);
    defer allocator.free(bytes256k);
    stdout.print("  256 KB: {s}\n", .{bytes256k});

    const bytes1500m = try humanize.formatBytes(allocator, 1500000000);
    defer allocator.free(bytes1500m);
    stdout.print("  1.5 GB: {s}\n", .{bytes1500m});

    // Binary units
    stdout.print("\nBytes Formatting (Binary):\n", .{});
    const bin256k = try humanize.formatBytesOptions(allocator, 262144, .Binary);
    stdout.print("  256 KiB: {s}\n", .{bin256k});
    defer allocator.free(bin256k);

    // Duration formatting
    stdout.print("\nDuration Formatting:\n", .{});
    const dur500ms = try humanize.formatDuration(allocator, 500);
    stdout.print("  500ms: {s}\n", .{dur500ms});
    defer allocator.free(dur500ms);

    const dur5s = try humanize.formatDuration(allocator, 5000);
    stdout.print("  5s: {s}\n", .{dur5s});
    defer allocator.free(dur5s);

    const dur2m5s = try humanize.formatDuration(allocator, 125000);
    stdout.print("  2m 5s: {s}\n", .{dur2m5s});
    defer allocator.free(dur2m5s);

    const dur2h5m30s = try humanize.formatDuration(allocator, 7530000);
    stdout.print("  2h 5m 30s: {s}\n", .{dur2h5m30s});
    defer allocator.free(dur2h5m30s);

    // Number formatting
    stdout.print("\nNumber Formatting:\n", .{});
    const num1000 = try humanize.formatNumber(allocator, 1000);
    stdout.print("  1000: {s}\n", .{num1000});
    defer allocator.free(num1000);

    const num1234567 = try humanize.formatNumber(allocator, 1234567);
    stdout.print("  1234567: {s}\n", .{num1234567});
    defer allocator.free(num1234567);

    // Ordinal numbers
    stdout.print("\nOrdinal Numbers:\n", .{});
    const ord1 = try humanize.formatOrdinal(allocator, 1);
    stdout.print("  1: {s}\n", .{ord1});
    defer allocator.free(ord1);

    const ord2 = try humanize.formatOrdinal(allocator, 2);
    stdout.print("  2: {s}\n", .{ord2});
    defer allocator.free(ord2);

    const ord3 = try humanize.formatOrdinal(allocator, 3);
    stdout.print("  3: {s}\n", .{ord3});
    defer allocator.free(ord3);

    const ord11 = try humanize.formatOrdinal(allocator, 11);
    stdout.print("  11: {s}\n", .{ord11});
    defer allocator.free(ord11);

    const ord21 = try humanize.formatOrdinal(allocator, 21);
    stdout.print("  21: {s}\n", .{ord21});
    defer allocator.free(ord21);

    const ord103 = try humanize.formatOrdinal(allocator, 103);
    stdout.print("  103: {s}\n", .{ord103});
    defer allocator.free(ord103);

    // Percentage formatting
    stdout.print("\nPercentage Formatting:\n", .{});
    const pct50 = try humanize.formatPercentage(allocator, 50.0);
    stdout.print("  50: {s}\n", .{pct50});
    defer allocator.free(pct50);

    const pct33 = try humanize.formatPercentage(allocator, 33.33);
    stdout.print("  33.33: {s}\n", .{pct33});
    defer allocator.free(pct33);

    // Relative time
    stdout.print("\nRelative Time (Past):\n", .{});
    const rel30s = try humanize.formatRelativeTime(allocator, 30, .{});
    stdout.print("  30 seconds: {s}\n", .{rel30s});
    defer allocator.free(rel30s);

    const rel5m = try humanize.formatRelativeTime(allocator, 300, .{});
    stdout.print("  5 minutes: {s}\n", .{rel5m});
    defer allocator.free(rel5m);

    const rel2h = try humanize.formatRelativeTime(allocator, 7200, .{});
    stdout.print("  2 hours: {s}\n", .{rel2h});
    defer allocator.free(rel2h);

    stdout.print("\nRelative Time (Future):\n", .{});
    const rel5m_fut = try humanize.formatRelativeTime(allocator, 300, .{ .future = true });
    stdout.print("  5 minutes: {s}\n", .{rel5m_fut});
    defer allocator.free(rel5m_fut);

    const rel2h_fut = try humanize.formatRelativeTime(allocator, 7200, .{ .future = true });
    stdout.print("  2 hours: {s}\n", .{rel2h_fut});
    defer allocator.free(rel2h_fut);

    // List formatting
    stdout.print("\nList Formatting:\n", .{});
    const items1 = [_][]const u8{"apple"};
    const list1 = try humanize.formatList(allocator, &items1);
    stdout.print("  1 item: {s}\n", .{list1});
    defer allocator.free(list1);

    const items2 = [_][]const u8{ "apple", "banana" };
    const list2 = try humanize.formatList(allocator, &items2);
    stdout.print("  2 items: {s}\n", .{list2});
    defer allocator.free(list2);

    const items3 = [_][]const u8{ "apple", "banana", "cherry" };
    const list3 = try humanize.formatList(allocator, &items3);
    stdout.print("  3 items: {s}\n", .{list3});
    defer allocator.free(list3);

    const items4 = [_][]const u8{ "apple", "banana", "cherry", "date" };
    const list4 = try humanize.formatList(allocator, &items4);
    stdout.print("  4 items: {s}\n", .{list4});
    defer allocator.free(list4);

    stdout.print("\n", .{});
}
