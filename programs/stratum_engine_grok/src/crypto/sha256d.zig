const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sha256d(out: *[32]u8, data: []const u8) void {
    var hash1: [32]u8 = undefined;
    Sha256.hash(data, &hash1, .{});
    Sha256.hash(&hash1, out, .{});
}

pub fn sha256dToString(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    sha256d(&hash, data);
    return std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&hash)});
}