// The four object kinds git knows about.
//
// Stored on the wire as the lowercase ASCII name in the loose-object
// header ("blob 12\x00...") and as a 3-bit type code in pack files.

const std = @import("std");

pub const Kind = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    pub fn parse(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }
};

test "name round-trips through parse" {
    inline for ([_]Kind{ .blob, .tree, .commit, .tag }) |k| {
        try std.testing.expectEqual(k, Kind.parse(k.name()).?);
    }
}

test "parse unknown returns null" {
    try std.testing.expect(Kind.parse("widget") == null);
    try std.testing.expect(Kind.parse("") == null);
}
