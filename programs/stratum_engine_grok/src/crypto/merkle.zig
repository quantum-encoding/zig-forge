const std = @import("std");
const sha256d = @import("sha256d.zig");

pub fn buildMerkleRoot(coinbase_hash: [32]u8, merkle_branches: [][32]u8) [32]u8 {
    var current = coinbase_hash;

    for (merkle_branches) |branch| {
        // Concatenate current and branch, then sha256d
        var concat: [64]u8 = undefined;
        @memcpy(concat[0..32], &current);
        @memcpy(concat[32..64], &branch);
        sha256d.sha256d(&current, &concat);
    }

    return current;
}

pub fn merkleRootToString(allocator: std.mem.Allocator, root: [32]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&root)});
}