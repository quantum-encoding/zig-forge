//! Minimal test to debug format specifier issues

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Test 1: Fixed array to slice formatting
    const sec_key = [_]u8{'a'} ** 24;

    // Method 1: Using slice operator
    var buffer1: [1024]u8 = undefined;
    const result1 = try std.fmt.bufPrint(&buffer1, "Key: {s}\n", .{sec_key[0..]});
    std.debug.print("{s}", .{result1});

    // Method 2: Using allocPrint (like Grok does)
    const result2 = try std.fmt.allocPrint(allocator, "Key: {s}\n", .{sec_key[0..]});
    defer allocator.free(result2);
    std.debug.print("{s}", .{result2});

    // Test 2: ArrayList with new API
    var list = try std.ArrayList(u8).initCapacity(allocator, 100);
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "Hello");
    std.debug.print("ArrayList: {s}\n", .{list.items});

    std.debug.print("✅ All tests passed!\n", .{});
}
