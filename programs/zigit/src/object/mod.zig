// Re-exports + the small shared helpers that don't deserve their own
// file (computeOid, write/read object headers).

const std = @import("std");

pub const Oid = @import("oid.zig").Oid;
pub const Kind = @import("kind.zig").Kind;
pub const LooseStore = @import("loose_store.zig").LooseStore;
pub const LoadedObject = @import("loose_store.zig").LoadedObject;
pub const tree = @import("tree.zig");
pub const TreeEntry = tree.Entry;
pub const commit = @import("commit.zig");

/// Hash framed object content (header + payload) and return its Oid.
///
/// The on-disk loose-object format prefixes the payload with
///   "<kind> <size>\0"
/// using the lowercase kind name and the decimal byte length, then
/// SHA-1s the whole thing. Real git emits the same header before
/// zlib-compressing.
pub fn computeOid(kind: Kind, payload: []const u8) Oid {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{s} {d}\x00",
        .{ kind.name(), payload.len },
    ) catch unreachable; // 32 bytes is plenty for "tag <u64>\0"
    hasher.update(header);
    hasher.update(payload);
    var bytes: [20]u8 = undefined;
    hasher.final(&bytes);
    return .{ .bytes = bytes };
}

test {
    _ = @import("oid.zig");
    _ = @import("kind.zig");
    _ = @import("loose_store.zig");
    _ = @import("tree.zig");
    _ = @import("commit.zig");
}

test "computeOid empty blob == e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" {
    const oid = computeOid(.blob, "");
    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "computeOid hello == ce013625030ba8dba906f756967f9e9ca394464a" {
    // git hash-object --stdin <<<"hello" → ce0136...
    // Note the trailing newline that bash adds.
    const oid = computeOid(.blob, "hello\n");
    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &hex);
}
