const std = @import("std");

pub fn main() !void {
    const test_text = "Test 🛡️\x00\x00PAYLOAD suspicious";

    std.debug.print("Hex dump:\n", .{});
    for (test_text, 0..) |byte, i| {
        std.debug.print("{d:3}: 0x{X:0>2} '{c}'\n", .{i, byte, if (byte >= 32 and byte < 127) byte else '.'});
    }
}
