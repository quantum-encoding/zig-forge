// .git/index — the staging area.
//
// Wire layout:
//
//   "DIRC"            4 bytes  magic
//   version           4 bytes  big-endian, we only emit/parse v2
//   entry count       4 bytes  big-endian u32
//   entries           N bytes  IndexEntry × count, sorted by path
//   extensions        ?        we drop these on read, never write any
//   trailer          20 bytes  SHA-1 over everything before it
//
// We only know about v2. v3 added a flag bit, v4 prefix-compresses
// paths — both can land in Phase 5 once we need them. For our use
// (round-tripping zigit's own writes) v2 is sufficient.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const entry_mod = @import("entry.zig");
const Entry = entry_mod.Entry;

pub const signature = "DIRC";
pub const version: u32 = 2;
pub const trailer_size: usize = 20;

pub const Index = struct {
    allocator: std.mem.Allocator,
    /// Sorted by `Entry.path`. Owned by this Index — paths point into
    /// `path_storage` so we get one allocation for all of them.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Backing storage for entry paths. Re-built on every save.
    path_storage: std.ArrayListUnmanaged(u8) = .empty,

    pub fn empty(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        self.entries.deinit(self.allocator);
        self.path_storage.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add or replace the entry for `path`. The slice is dup'd into
    /// our path_storage so the caller can free its copy.
    pub fn upsert(self: *Index, e: Entry) !void {
        // Dup the path into storage, then point e.path at the dup.
        const path_copy_offset = self.path_storage.items.len;
        try self.path_storage.appendSlice(self.allocator, e.path);
        const stored_path = self.path_storage.items[path_copy_offset..][0..e.path.len];

        var copy = e;
        copy.path = stored_path;

        // Look for an existing entry by path (linear — fine for now,
        // small repos). Replace if found.
        for (self.entries.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.path, copy.path)) {
                self.entries.items[i] = copy;
                return;
            }
        }

        try self.entries.append(self.allocator, copy);
        sortEntries(self.entries.items);
    }

    /// Load .git/index from disk, or return an empty Index if the
    /// file is missing.
    pub fn load(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !Index {
        const bytes = git_dir.readFileAlloc(io, "index", allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return .empty(allocator),
            else => return err,
        };
        defer allocator.free(bytes);

        return try parse(allocator, bytes);
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Index {
        if (bytes.len < 12 + trailer_size) return error.IndexTooShort;
        if (!std.mem.eql(u8, bytes[0..4], signature)) return error.BadIndexSignature;

        const ver = std.mem.readInt(u32, bytes[4..8], .big);
        if (ver != 2) return error.UnsupportedIndexVersion;

        // Verify the SHA-1 trailer over everything before it.
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(bytes[0 .. bytes.len - trailer_size]);
        var computed: [20]u8 = undefined;
        hasher.final(&computed);
        const stored = bytes[bytes.len - trailer_size ..];
        if (!std.mem.eql(u8, &computed, stored)) return error.IndexChecksumMismatch;

        const count = std.mem.readInt(u32, bytes[8..12], .big);

        var index: Index = .empty(allocator);
        errdefer index.deinit();

        var offset: usize = 12;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const got = try entry_mod.read(bytes, offset);

            // Copy path into our backing storage so the entry survives
            // the original buffer being freed.
            const path_copy_offset = index.path_storage.items.len;
            try index.path_storage.appendSlice(allocator, got.entry.path);
            const stored_path = index.path_storage.items[path_copy_offset..][0..got.entry.path.len];

            var copy = got.entry;
            copy.path = stored_path;
            try index.entries.append(allocator, copy);

            offset += got.advance;
        }
        // We deliberately ignore extensions between offset and the trailer.

        sortEntries(index.entries.items);
        return index;
    }

    /// Write to .git/index atomically: build the bytes in memory,
    /// write to .git/index.tmp, rename over .git/index.
    pub fn save(self: *Index, io: Io, git_dir: Dir) !void {
        sortEntries(self.entries.items);

        var allocating: std.Io.Writer.Allocating = try .initCapacity(
            self.allocator,
            12 + self.entries.items.len * 80 + trailer_size,
        );
        defer allocating.deinit();

        const w = &allocating.writer;
        try w.writeAll(signature);
        try w.writeInt(u32, version, .big);
        try w.writeInt(u32, @intCast(self.entries.items.len), .big);

        for (self.entries.items) |e| {
            try entry_mod.write(e, w);
        }

        // Append SHA-1 trailer over everything written so far.
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(allocating.written());
        var sha: [20]u8 = undefined;
        hasher.final(&sha);
        try w.writeAll(&sha);

        try git_dir.writeFile(io, .{ .sub_path = "index.tmp", .data = allocating.written() });
        try git_dir.rename("index.tmp", git_dir, "index", io);
    }
};

fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
}

const testing = std.testing;

test "round-trip an empty index in memory" {
    var idx: Index = .empty(testing.allocator);
    defer idx.deinit();

    var allocating: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer allocating.deinit();
    const w = &allocating.writer;
    try w.writeAll(signature);
    try w.writeInt(u32, version, .big);
    try w.writeInt(u32, 0, .big);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(allocating.written());
    var sha: [20]u8 = undefined;
    hasher.final(&sha);
    try w.writeAll(&sha);

    var parsed = try Index.parse(testing.allocator, allocating.written());
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.entries.items.len);
}

test "upsert inserts then replaces" {
    var idx: Index = .empty(testing.allocator);
    defer idx.deinit();

    var oid_a: @import("../object/oid.zig").Oid = undefined;
    @memset(&oid_a.bytes, 0xAA);
    var oid_b = oid_a;
    @memset(&oid_b.bytes, 0xBB);

    try idx.upsert(.{
        .ctime_s = 1, .ctime_ns = 0, .mtime_s = 1, .mtime_ns = 0,
        .dev = 0, .ino = 0, .mode = @intFromEnum(entry_mod.Mode.regular),
        .uid = 0, .gid = 0, .file_size = 5, .oid = oid_a,
        .flags = @intCast("foo".len), .path = "foo",
    });
    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);

    try idx.upsert(.{
        .ctime_s = 2, .ctime_ns = 0, .mtime_s = 2, .mtime_ns = 0,
        .dev = 0, .ino = 0, .mode = @intFromEnum(entry_mod.Mode.regular),
        .uid = 0, .gid = 0, .file_size = 7, .oid = oid_b,
        .flags = @intCast("foo".len), .path = "foo",
    });
    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try testing.expectEqual(@as(u32, 7), idx.entries.items[0].file_size);
    try testing.expect(std.mem.eql(u8, &oid_b.bytes, &idx.entries.items[0].oid.bytes));
}
