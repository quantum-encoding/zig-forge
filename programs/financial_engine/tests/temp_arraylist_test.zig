const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try list.append('a');
    std.debug.print("{s}\n", .{list.items});
}
