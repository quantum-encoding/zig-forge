// One row in .git/index (the staging area).
//
// Layout per gitformat-index(5), v2:
//
//   offset  size  field
//        0     4  ctime seconds (big-endian)
//        4     4  ctime nanoseconds
//        8     4  mtime seconds
//       12     4  mtime nanoseconds
//       16     4  dev
//       20     4  ino
//       24     4  mode (object type [4 bits] | unix permissions [9 bits])
//       28     4  uid
//       32     4  gid
//       36     4  file size (lower 32 bits — anything bigger is truncated)
//       40    20  SHA-1 of blob content
//       60     2  flags  (see below)
//       62     N  path bytes (no terminator inside the entry)
//
// flags bits, MSB first:
//   15      assume-valid
//   14      extended  (must be 0 in v2)
//   13:12   stage     (0 normal, 1 base, 2 ours, 3 theirs)
//   11:0    path length, capped at 0xFFF — paths longer than that
//          report 0xFFF and the parser uses the trailing NUL.
//
// Each entry is padded with NULs so its total length is a multiple of
// 8, including a mandatory single trailing NUL even when no padding
// would otherwise be required.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const Oid = oid_mod.Oid;

pub const Mode = enum(u32) {
    regular = 0o100644,
    executable = 0o100755,
    symlink = 0o120000,

    pub fn fromRaw(raw: u32) ?Mode {
        return std.meta.intToEnum(Mode, raw) catch null;
    }
};

pub const fixed_size: usize = 62;

pub const Entry = struct {
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    file_size: u32,
    oid: Oid,
    flags: u16,
    /// Owned by the Index — entries are bulk-allocated alongside it.
    path: []const u8,

    pub fn stage(self: Entry) u2 {
        return @intCast((self.flags >> 12) & 0b11);
    }

    /// Total on-disk length including the 8-byte alignment padding
    /// (which always includes ≥ 1 trailing NUL).
    pub fn onDiskLen(path_len: usize) usize {
        const unpadded = fixed_size + path_len;
        // git pads to the next multiple of 8 *with at least one NUL*,
        // so a perfectly-aligned unpadded length still gets 8 NULs.
        const next_aligned = (unpadded + 8) & ~@as(usize, 7);
        return next_aligned;
    }
};

/// Append `entry` to `out` in v2 wire format. `out` must accommodate
/// the entire entry; no allocation happens here.
pub fn write(entry: Entry, out: *std.Io.Writer) !void {
    try out.writeInt(u32, entry.ctime_s, .big);
    try out.writeInt(u32, entry.ctime_ns, .big);
    try out.writeInt(u32, entry.mtime_s, .big);
    try out.writeInt(u32, entry.mtime_ns, .big);
    try out.writeInt(u32, entry.dev, .big);
    try out.writeInt(u32, entry.ino, .big);
    try out.writeInt(u32, entry.mode, .big);
    try out.writeInt(u32, entry.uid, .big);
    try out.writeInt(u32, entry.gid, .big);
    try out.writeInt(u32, entry.file_size, .big);
    try out.writeAll(&entry.oid.bytes);
    try out.writeInt(u16, entry.flags, .big);
    try out.writeAll(entry.path);

    const total = Entry.onDiskLen(entry.path.len);
    const written = fixed_size + entry.path.len;
    const pad = total - written;
    var zeros: [8]u8 = @splat(0);
    try out.writeAll(zeros[0..pad]);
}

/// Read a single entry out of `bytes` starting at `offset`.
/// Returns the entry plus the number of bytes consumed (including pad).
/// The returned `path` slice is borrowed from `bytes` — copy if needed.
pub fn read(bytes: []const u8, offset: usize) !struct { entry: Entry, advance: usize } {
    if (bytes.len < offset + fixed_size) return error.UnexpectedEndOfIndex;
    const fixed = bytes[offset..][0..fixed_size];

    const flags = std.mem.readInt(u16, fixed[60..62], .big);
    const reported_len: usize = flags & 0x0FFF;

    // If the path is longer than 0xFFF it's NUL-terminated; scan from
    // the start of the path region for the first NUL.
    const path_start = offset + fixed_size;
    const path_len: usize = if (reported_len < 0xFFF) reported_len else blk: {
        const search = bytes[path_start..];
        const nul = std.mem.indexOfScalar(u8, search, 0) orelse return error.UnterminatedPath;
        break :blk nul;
    };
    if (bytes.len < path_start + path_len) return error.UnexpectedEndOfIndex;

    var oid: Oid = undefined;
    @memcpy(&oid.bytes, fixed[40..60]);

    const entry: Entry = .{
        .ctime_s = std.mem.readInt(u32, fixed[0..4], .big),
        .ctime_ns = std.mem.readInt(u32, fixed[4..8], .big),
        .mtime_s = std.mem.readInt(u32, fixed[8..12], .big),
        .mtime_ns = std.mem.readInt(u32, fixed[12..16], .big),
        .dev = std.mem.readInt(u32, fixed[16..20], .big),
        .ino = std.mem.readInt(u32, fixed[20..24], .big),
        .mode = std.mem.readInt(u32, fixed[24..28], .big),
        .uid = std.mem.readInt(u32, fixed[28..32], .big),
        .gid = std.mem.readInt(u32, fixed[32..36], .big),
        .file_size = std.mem.readInt(u32, fixed[36..40], .big),
        .oid = oid,
        .flags = flags,
        .path = bytes[path_start .. path_start + path_len],
    };

    return .{ .entry = entry, .advance = Entry.onDiskLen(path_len) };
}

const testing = std.testing;

test "onDiskLen pads to multiple of 8 with at least one NUL" {
    // header(62) + path(1) = 63 → 1 NUL fits, total 64
    try testing.expectEqual(@as(usize, 64), Entry.onDiskLen(1));
    // header(62) + path(2) = 64 — already aligned, must still pad with 8 NULs
    try testing.expectEqual(@as(usize, 72), Entry.onDiskLen(2));
    // header(62) + path(9) = 71 → 1 NUL gets us to 72
    try testing.expectEqual(@as(usize, 72), Entry.onDiskLen(9));
    // header(62) + path(10) = 72 → already aligned, pad to 80
    try testing.expectEqual(@as(usize, 80), Entry.onDiskLen(10));
}

test "round-trip a single entry" {
    var oid: Oid = undefined;
    @memset(&oid.bytes, 0xAB);

    const entry: Entry = .{
        .ctime_s = 1700000000,
        .ctime_ns = 12345,
        .mtime_s = 1700000001,
        .mtime_ns = 67890,
        .dev = 16777220,
        .ino = 9999,
        .mode = @intFromEnum(Mode.regular),
        .uid = 501,
        .gid = 20,
        .file_size = 42,
        .oid = oid,
        .flags = @intCast("hello.txt".len),
        .path = "hello.txt",
    };

    var allocating: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 128);
    defer allocating.deinit();
    try write(entry, &allocating.writer);

    const buf = allocating.written();
    try testing.expectEqual(Entry.onDiskLen("hello.txt".len), buf.len);

    const got = try read(buf, 0);
    try testing.expectEqual(entry.ctime_s, got.entry.ctime_s);
    try testing.expectEqual(entry.mtime_ns, got.entry.mtime_ns);
    try testing.expectEqual(entry.mode, got.entry.mode);
    try testing.expectEqualStrings(entry.path, got.entry.path);
    try testing.expectEqual(buf.len, got.advance);
}
